#!/usr/bin/env bash

set -eo pipefail

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
if is_external_database; then
    # A throwaway client container dumps the external database (credentials in its environment).
    export_libpq_env "$(current_database_url)" "$(env_file_value configs/api.env DATABASE_SSL_REQUIRE)"
    pg_client_init
fi
mkdir -p backups

BACKUP_NAME="sentinelc-$(hostname)-$(date +"%Y%m%d_%H%M%S")"
BACKUP_DEST="backups/$BACKUP_NAME.tar"

echo "Creating backup in $BACKUP_DEST"

echo "- Backing up non-postgres volumes"
tar -cpf $BACKUP_DEST --exclude=volumes/api/postgres --exclude=volumes/api/postgresql configs/ volumes/ credentials/

dump_failed() {
    rm -f "$BACKUP_DEST"
    echo "Error: the database dump failed (error above). The incomplete $BACKUP_DEST was deleted." >&2
    exit 1
}

if is_external_database; then
    echo "- Dumping api db (external: $PGHOST:$PGPORT/$PGDATABASE)"
    "${PG_CLIENT[@]}" pg_dump -Fc -n public | ./scripts/tarappend -f data/api_db.pgdump -t "$BACKUP_DEST" \
        || dump_failed
else
    echo "- Dumping api db"
    COMPOSE_INTERACTIVE_NO_CLI=1 $COMPOSE_COMMAND exec -T api_db bash -c "pg_dump -Fc -n public -U \$POSTGRES_USER \$POSTGRES_DB" | ./scripts/tarappend -f data/api_db.pgdump -t $BACKUP_DEST \
        || dump_failed
fi

echo ""
echo "Backup complete."

