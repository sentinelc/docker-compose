#!/usr/bin/env bash
#
# restore.sh
#
# Restores a backup made by scripts/backup.sh. It replaces configs/ and volumes/ with those of the backup, restores
# the api database, then starts all the containers.
#
# The database to restore into is the DATABASE_URL of configs/api.env, or on a new host (no configs/ yet) the one
# of the backup:
#   built-in  `docker compose down -v`, deletes configs/ and volumes/ except volumes/api/postgres (the
#             PostgreSQL 14 data kept by migrate-postgres-18.sh for a rollback), then restores into a new api_db
#             service. A backup made in external mode is refused.
#   external  Checks the connection, unaccent and the right to create tables first. If schema public is not
#             empty, asks to type the database name (needs a terminal). Then `docker compose down` (not -v), and
#             deletes configs/ and volumes/ except volumes/api/postgres and volumes/api/postgresql, kept for a
#             rollback to the built-in database. The external DATABASE_URL and DATABASE_SSL_REQUIRE are kept in
#             configs/api.env, and docker-compose.override.yml is created if missing. Emptying schema public and
#             the restore run in one transaction: if the restore fails, the database is left as it was. A backup
#             made in built-in mode can be restored this way. See guides/external-database.md.
#
# Usage: scripts/restore.sh <backup file name in backups/>
#        scripts/restore.sh                                  lists the backups

# Check if docker-compose is installed
if command -v docker-compose &> /dev/null; then
    COMPOSE_COMMAND="docker-compose"
elif command -v docker &> /dev/null; then
    # Check if docker compose is available as a separate command
    if docker compose --help &> /dev/null; then
        COMPOSE_COMMAND="docker compose"
    else
        echo "Error: docker-compose or docker compose not found. Please make sure Docker and docker-compose are installed." >&2
        exit 1
    fi
else
    echo "Error: Docker not found. Please make sure Docker is installed." >&2
    exit 1
fi


cd "$(dirname "$0")"/..

# shellcheck source=scripts/lib/database.sh
source scripts/lib/database.sh

BACKUP_FILE=./backups/$1

fail() {
        echo "Error: $*" >&2
        exit 1
}

# restore_external URL SSL_REQUIRE: restores the backup into the external database at URL. The installation
# keeps using it: the DATABASE_URL of the backup, which can be a built-in one, is not restored.
restore_external() {
        local url=$1 ssl_require=$2 version tables answer problem
        export_libpq_env "$url" "$ssl_require" || exit 1
        pg_client_init || exit 1
        target_psql() { "${PG_CLIENT[@]}" psql -X -At -v ON_ERROR_STOP=1 "$@"; }

        echo "- Checking the external database $PGHOST:$PGPORT/$PGDATABASE"
        version=$(target_psql -c "SHOW server_version" < /dev/null) \
                || fail "cannot connect to $PGHOST:$PGPORT/$PGDATABASE as $PGUSER (error above). Nothing was changed."
        problem=$(external_target_problem) \
                || fail "${problem:-cannot query $PGDATABASE (error above).} Nothing was changed."
        tables=$(target_psql -c "$COUNT_PUBLIC_SQL" < /dev/null)
        echo "  PostgreSQL $version, unaccent installed, $PGUSER can create tables, $tables table(s), view(s) or"
        echo "  sequence(s) in schema public."

        if [ "$tables" != 0 ]; then
                echo ""
                echo "The restore DELETES the $tables table(s), view(s) and sequence(s) of schema public in"
                echo "$PGHOST:$PGPORT/$PGDATABASE, then restores the backup. This cannot be undone."
                [ -t 0 ] || fail "this needs a confirmation: run restore.sh from a terminal. Nothing was changed."
                read -r -p "Type the database name ($PGDATABASE) to continue: " answer
                [ "$answer" = "$PGDATABASE" ] || fail "aborted. Nothing was changed."
        fi

        # down, not down -v: the external database is not a volume of this project.
        echo "- Stopping all running containers.."
        $COMPOSE_COMMAND down

        # The data of the built-in database (volumes/api/postgres*) is kept for a rollback to it. Backups do not
        # contain it.
        echo "- Deleting configs/ & volumes/, except volumes/api/postgres and volumes/api/postgresql"
        rm -rf configs/
        if [ -d volumes ]; then
                find volumes -mindepth 1 -maxdepth 1 ! -name api -exec rm -rf {} +
                [ ! -d volumes/api ] \
                        || find volumes/api -mindepth 1 -maxdepth 1 ! -name postgres ! -name postgresql -exec rm -rf {} +
        fi

        echo "- Extracting your backup file: $BACKUP_NAME"
        tar -xvpf "$BACKUP_FILE"

        echo "- Keeping the external database in configs/api.env"
        set_env_value configs/api.env DATABASE_URL "$url"
        set_env_value configs/api.env DATABASE_SSL_REQUIRE "$ssl_require"
        if [ ! -f docker-compose.override.yml ]; then
                echo "- Creating docker-compose.override.yml (disables the api_db service)"
                cp "$EXTERNAL_DATABASE_OVERRIDE" docker-compose.override.yml
        fi

        # One transaction: emptying schema public and restoring succeed or fail together. --no-owner --no-acl: the
        # objects belong to the api user of the external database, whatever user made the backup. The schema public
        # itself and its comment are left out: it exists, and belongs to pg_database_owner.
        echo "- Restoring the external database"
        { echo "$EMPTY_PUBLIC_SQL"; "${PG_TOOLS[@]}" bash -c '
                cat > /tmp/api_db.pgdump &&
                pg_restore -l /tmp/api_db.pgdump \
                    | grep -Ev "^[0-9]+; [0-9]+ [0-9]+ (SCHEMA - public|COMMENT - SCHEMA public) " > /tmp/list &&
                pg_restore -L /tmp/list --no-owner --no-acl -f - /tmp/api_db.pgdump' < data/api_db.pgdump \
            || echo "DO \$\$ BEGIN RAISE EXCEPTION 'pg_restore failed, rolling back'; END \$\$;"; } \
                | target_psql -q --single-transaction > /dev/null \
                || fail "the restore failed and was rolled back: $PGDATABASE is as before. configs/ and volumes/
are restored from the backup and the containers are stopped. data/api_db.pgdump is kept."
        "${PG_CLIENT[@]}" vacuumdb --analyze-only --quiet --schema=public < /dev/null
}

echo "Restoring.."
if [ -f "$BACKUP_FILE" ]; then
        BACKUP_NAME=$1
        # The database to restore into: the one of this installation, or on a new host (no configs/ yet), the one
        # of the backup.
        if [ -f configs/api.env ]; then
                TARGET_URL=$(current_database_url)
                TARGET_SSL_REQUIRE=$(env_file_value configs/api.env DATABASE_SSL_REQUIRE)
        else
                BACKUP_API_ENV=$(tar -xOf "$BACKUP_FILE" configs/api.env) || fail "configs/api.env missing in the backup."
                TARGET_URL=$(grep -m1 '^DATABASE_URL=' <<< "$BACKUP_API_ENV" | cut -d= -f2-)
                TARGET_SSL_REQUIRE=$(grep -m1 '^DATABASE_SSL_REQUIRE=' <<< "$BACKUP_API_ENV" | cut -d= -f2-)
        fi
fi

if [ -f "$BACKUP_FILE" ] && database_url_is_external "$TARGET_URL"; then
        restore_external "$TARGET_URL" "$TARGET_SSL_REQUIRE"

        echo "- Deleting temporary pgdump files."
        rm -rf data/

        echo "- Restarting all containers.."
        $COMPOSE_COMMAND up -d
        echo ""
        echo "Restore complete."

        echo "Applications are currently starting with the restored data. This can take a few minutes."
        echo "Check the logs and health status page to monitor application startup."

elif [ -f "$BACKUP_FILE" ]; then
        if database_url_is_external "$(tar -xOf "$BACKUP_FILE" configs/api.env | grep -m1 '^DATABASE_URL=' | cut -d= -f2-)"; then
                fail "this backup comes from an installation with an external database, and this installation uses
the built-in api_db service. Restore it with configs/api.env pointing to an external database. Nothing was changed."
        fi

        echo "- Stopping and deconfiguring all running containers.."
        $COMPOSE_COMMAND down -v

        # volumes/api/postgresql is the database being restored: it is recreated. volumes/api/postgres, the
        # PostgreSQL 14 data kept by migrate-postgres-18.sh for a rollback, is kept: backups do not contain it.
        echo "- Deleting configs/ & volumes/, except volumes/api/postgres"
        rm -rf configs/
        if [ -d volumes ]; then
                find volumes -mindepth 1 -maxdepth 1 ! -name api -exec rm -rf {} +
                [ ! -d volumes/api ] || find volumes/api -mindepth 1 -maxdepth 1 ! -name postgres -exec rm -rf {} +
        fi

        echo "- Extracting your backup file: $1"
        tar -xvpf $BACKUP_FILE

        echo "- Restoring postgresql databases"
        $COMPOSE_COMMAND up -d api_db
        sleep 5

        # Wait over TCP: on a new data directory, the image first runs a temporary server on the Unix socket only,
        # then restarts it.
        max_retry=30
        counter=0

        until $COMPOSE_COMMAND exec -T api_db bash -c 'pg_isready -q -h 127.0.0.1 -U "$POSTGRES_USER"'
        do
                [[ counter -eq $max_retry ]] && echo "Failed!" && exit 1
                echo "Trying again. Try #$counter"
                ((counter++))
                sleep 2
        done

        echo "- Restoring api_db"
        $COMPOSE_COMMAND exec -T api_db bash -c "pg_restore -Fc -U \$POSTGRES_USER -d \$POSTGRES_DB" < data/api_db.pgdump

        echo "- Enabling unaccent extension on api_db"
        $COMPOSE_COMMAND exec api_db bash -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB -c 'CREATE EXTENSION IF NOT EXISTS unaccent'"

        echo "- Deleting temporary pgdump files."
        rm -rf data/

        echo "- Restarting all containers.."
        $COMPOSE_COMMAND up -d
        echo ""
        echo "Restore complete."

        echo "Applications are currently starting with the restored data. This can take a few minutes."
        echo "Check the logs and health status page to monitor application startup."

else
        echo "No backup file was supplied as an argument"
        echo "Choose one of the following:"
        for FILE in ./backups/*; do echo  "${FILE##*/}"; done
        echo ""
fi
