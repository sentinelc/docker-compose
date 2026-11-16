#!/usr/bin/env bash

set -e

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
    echo "Error: configs/api.env points the api to an external database. This script only backs up the built-in" >&2
    echo "api_db service. Use the backups of your database provider, or pg_dump/pg_restore against DATABASE_URL." >&2
    exit 1
fi
mkdir -p backups

BACKUP_NAME="sentinelc-$(hostname)-$(date +"%Y%m%d_%H%M%S")"
BACKUP_DEST="backups/$BACKUP_NAME.tar"

echo "Creating backup in $BACKUP_DEST"

echo "- Backing up non-postgres volumes"
tar -cpf $BACKUP_DEST --exclude=volumes/api/postgres --exclude=volumes/api/postgresql configs/ volumes/ credentials/

echo "- Dumping api db"
COMPOSE_INTERACTIVE_NO_CLI=1 $COMPOSE_COMMAND exec -T api_db bash -c "pg_dump -Fc -n public -U \$POSTGRES_USER \$POSTGRES_DB" | ./scripts/tarappend -f data/api_db.pgdump -t $BACKUP_DEST

echo ""
echo "Backup complete."

