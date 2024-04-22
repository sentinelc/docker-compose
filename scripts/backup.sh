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
mkdir -p backups

BACKUP_NAME="sentinelc-$(hostname)-$(date +"%Y%m%d_%H%M%S")"
BACKUP_DEST="backups/$BACKUP_NAME.tar"

echo "Creating backup in $BACKUP_DEST"

echo "- Backing up non-postgres volumes"
tar -cpf $BACKUP_DEST --exclude=volumes/api/postgres --exclude=volumes/keycloak/postgres configs/ volumes/ credentials/

echo "- Dumping keycloak db"
COMPOSE_INTERACTIVE_NO_CLI=1 $COMPOSE_COMMAND exec -T keycloak_db bash -c "pg_dump -Fc -n public -U \$POSTGRES_USER \$POSTGRES_DB"  | ./scripts/tarappend -f data/keycloak_db.pgdump -t $BACKUP_DEST

echo "- Dumping api db"
COMPOSE_INTERACTIVE_NO_CLI=1 $COMPOSE_COMMAND exec -T api_db bash -c "pg_dump -Fc -n public -U \$POSTGRES_USER \$POSTGRES_DB" | ./scripts/tarappend -f data/api_db.pgdump -t $BACKUP_DEST

echo ""
echo "Backup complete."

