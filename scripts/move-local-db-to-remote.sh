#!/usr/bin/env bash
#
# move-local-db-to-remote.sh
#
# Copies the api database of this installation (built-in) to an external PostgreSQL database, for example a
# managed one, by streaming pg_dump into pg_restore, and compares the row count of every table. Nothing is written
# to disk, and the built-in database and the configuration are left as is: switching the installation to the
# external database is a separate step. See guides/external-database.md.
#
# Source, in this order:
#   - the api_db service, when it is running and holds tables (PostgreSQL 14 before `docker compose up -d`
#     recreates it after `git pull`, or 18);
#   - otherwise the PostgreSQL 14 data in volumes/api/postgres, read with a temporary PostgreSQL 14 container.
#
# Target: the TARGET_DATABASE_URL environment variable, or the first line of standard input (a hidden prompt on a
# terminal). Same format as EXTERNAL_DATABASE_URL in config.sh. It is never a command-line argument: those are
# visible in the process list. The target database must exist, be owned by the target user, have unaccent created
# by an admin user, and be empty (schema public): see "Prepare the database" in guides/external-database.md.
#
# The dump is a consistent snapshot, but the api keeps writing after it. For the final copy, stop the writers
# first: docker compose stop api celery beat. A copy while the api runs is fine for a rehearsal.
#
# Usage:
#   scripts/move-local-db-to-remote.sh                  copy the built-in database to the target
#   scripts/move-local-db-to-remote.sh --empty-target   empty schema public of the target (after a rehearsal),
#                                                       after typing the database name

set -euo pipefail

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

MODE=copy
case "${1:-}" in
    "") ;;
    --empty-target) MODE=empty ;;
    *) echo "usage: [TARGET_DATABASE_URL=...] $0 [--empty-target]" >&2; exit 2 ;;
esac

# The PostgreSQL 14 image of the previous release, as in migrate-postgres-18.sh.
OLD_IMAGE="postgres:14.22-trixie@sha256:2f439034a24488d86d69fa1b2254e51a91154fa3dee22a4d70bb906eaba11321"
OLD_DIR=volumes/api/postgres
OLD_CONTAINER=sentinelc-api-db-pg14-copy

# Exact row count of every table, one "schema.table count" line per table.
COUNT_SQL="
SELECT n.nspname || '.' || c.relname || ' ' ||
       (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname),
                                            false, true, '')))[1]::text
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%'
ORDER BY 1;"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

cleanup() {
    # A clean shutdown: $OLD_DIR is kept for a rollback.
    docker stop -t 120 "$OLD_CONTAINER" &> /dev/null || true
    docker rm -f "$OLD_CONTAINER" &> /dev/null || true
}

# --- target ----------------------------------------------------------------------------------------------------
if [[ -z "${TARGET_DATABASE_URL:-}" ]]; then
    if [[ -t 0 ]]; then
        read -r -s -p "Target database URL (postgresql://USER:PASSWORD@HOST:PORT/DATABASE): " TARGET_DATABASE_URL
        echo
    else
        read -r TARGET_DATABASE_URL || true
    fi
fi
[[ -n "$TARGET_DATABASE_URL" ]] || fail "no target: set TARGET_DATABASE_URL or give the URL on standard input."
reason=$(check_external_database_url "$TARGET_DATABASE_URL") || fail "the target URL cannot be used: $reason"
export_libpq_env "$TARGET_DATABASE_URL" "$(database_ssl_require "$TARGET_DATABASE_URL")" || exit 1
pg_client_init || exit 1
TARGET="$PGHOST:$PGPORT/$PGDATABASE"

target_psql() {
    "${PG_CLIENT[@]}" psql -X -At -v ON_ERROR_STOP=1 "$@"
}

echo "1. Checking the target $TARGET"
version=$(target_psql -c "SHOW server_version" < /dev/null) || fail "cannot connect to $TARGET as $PGUSER (error above)."
tables=$(target_psql -c "$COUNT_PUBLIC_SQL" < /dev/null)
echo "   - PostgreSQL $version, $tables table(s), view(s) or sequence(s) in schema public."

if [[ $MODE == empty && "$tables" == 0 ]]; then
    problem=$(external_target_problem) || fail "${problem:-cannot query $TARGET (error above).}"
    echo "   - unaccent installed, $PGUSER can create tables. Nothing to do."
    exit 0
fi

if [[ $MODE == empty ]]; then
    [[ -t 0 ]] || fail "this needs a confirmation: run it from a terminal, with TARGET_DATABASE_URL set."
    echo
    echo "This DELETES the $tables table(s), view(s) and sequence(s) of schema public in $TARGET."
    read -r -p "Type the database name ($PGDATABASE) to continue: " answer
    [[ "$answer" == "$PGDATABASE" ]] || fail "aborted. Nothing was changed."
    target_psql -q <<< "$EMPTY_PUBLIC_SQL"
    echo "   - Schema public of $TARGET is empty. unaccent is kept."
    exit 0
fi

problem=$(external_target_problem) || fail "${problem:-cannot query $TARGET (error above).}"
[[ "$tables" == 0 ]] \
    || fail "schema public of $PGDATABASE is not empty. Empty it first: $0 --empty-target"
echo "   - unaccent installed, $PGUSER can create tables, schema public empty."

# --- source ----------------------------------------------------------------------------------------------------
echo "2. Finding the source"
! is_external_database \
    || fail "configs/api.env already points the api to an external database. This script copies the built-in one."
[[ -f configs/api_db.env ]] || fail "configs/api_db.env not found: no built-in database to copy."
SRC_USER=$(env_file_value configs/api_db.env POSTGRES_USER)
SRC_DB=$(env_file_value configs/api_db.env POSTGRES_DB)
[[ -n "$SRC_USER" && -n "$SRC_DB" ]] || fail "POSTGRES_USER or POSTGRES_DB missing in configs/api_db.env."

source_psql() {
    if [[ $SOURCE == service ]]; then
        $COMPOSE_COMMAND exec -T api_db psql -X -At -v ON_ERROR_STOP=1 -U "$SRC_USER" -d "$SRC_DB" "$@"
    else
        docker exec -i "$OLD_CONTAINER" psql -X -At -v ON_ERROR_STOP=1 -U "$SRC_USER" -d "$SRC_DB" "$@"
    fi
}

source_dump() {
    if [[ $SOURCE == service ]]; then
        $COMPOSE_COMMAND exec -T api_db pg_dump -Fc -U "$SRC_USER" "$SRC_DB"
    else
        docker exec "$OLD_CONTAINER" pg_dump -Fc -U "$SRC_USER" "$SRC_DB"
    fi
}

SOURCE=""
running_version=""
if [[ -n "$($COMPOSE_COMMAND ps --status running -q api_db 2> /dev/null)" ]]; then
    SOURCE=service
    running_version=$(source_psql -c "SHOW server_version_num" < /dev/null) || fail "cannot query the api_db service."
    if [[ "$(source_psql -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'" < /dev/null)" == 0 ]]; then
        SOURCE=""
    fi
fi

if [[ -z $SOURCE ]]; then
    [[ "$(cat "$OLD_DIR/PG_VERSION" 2> /dev/null)" == 14 ]] \
        || fail "no data to copy: the api_db service is not running or has no tables, and $OLD_DIR holds no
PostgreSQL 14 data."
    # A running api_db on PostgreSQL 14 uses $OLD_DIR: a second server must not open it.
    [[ "$running_version" != 14* ]] \
        || fail "the api_db service runs PostgreSQL 14 with no tables. Check '$COMPOSE_COMMAND ps' and $OLD_DIR."
    SOURCE=pg14
    trap cleanup EXIT
    cleanup
    docker run -d --name "$OLD_CONTAINER" --network none --env-file configs/api_db.env \
        -v "$PWD/$OLD_DIR:/var/lib/postgresql/data" "$OLD_IMAGE" > /dev/null
    for _ in $(seq 60); do
        docker exec "$OLD_CONTAINER" pg_isready -q -U "$SRC_USER" && break
        sleep 2
    done
    docker exec "$OLD_CONTAINER" pg_isready -q -U "$SRC_USER" \
        || fail "PostgreSQL 14 did not start on $OLD_DIR. Check 'docker logs $OLD_CONTAINER'."
    echo "   - PostgreSQL 14 data in $OLD_DIR, read with a temporary container."
else
    echo "   - The running api_db service (PostgreSQL $(source_psql -c "SHOW server_version" < /dev/null))."
fi

if [[ -n "$($COMPOSE_COMMAND ps --status running -q api celery beat 2> /dev/null)" ]]; then
    echo "   - Warning: api, celery or beat is running. Changes made after the dump are not copied, and the row"
    echo "     counts may differ. Fine for a rehearsal; for the switch, stop them first."
fi

# --- copy ------------------------------------------------------------------------------------------------------
echo "3. Streaming the dump of $SRC_DB to $TARGET"
start=$SECONDS
# --no-owner --no-acl: the objects belong to the target user. --no-comments: only the owner of the extension
# (the admin user) can restore its comment.
source_dump \
    | "${PG_CLIENT[@]}" pg_restore -d "$PGDATABASE" --no-owner --no-acl --no-comments --single-transaction \
    || fail "the copy failed and was rolled back: $PGDATABASE is still empty."
"${PG_CLIENT[@]}" vacuumdb --analyze-only --quiet --schema=public < /dev/null
echo "   - Done in $((SECONDS - start)) s."

echo "4. Comparing row counts"
diff <(source_psql <<< "$COUNT_SQL") <(target_psql <<< "$COUNT_SQL") \
    || fail "row counts differ (-: local, +: remote). Expected if the api was running during the copy."
echo "   - Same row counts in all $(source_psql <<< "$COUNT_SQL" | wc -l) tables."
