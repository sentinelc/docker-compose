#!/usr/bin/env bash

set -e

cd "$(dirname "$0")"/..
mkdir -p backups

BACKUP_NAME="sentinelc-$(hostname)-$(date +"%Y%m%d_%H%M%S")"
BACKUP_DEST="backups/$BACKUP_NAME.tar"

echo "Creating backup in $BACKUP_DEST"

echo "- Backing up non-postgres volumes"
tar -cpf $BACKUP_DEST --exclude=volumes/api/postgres --exclude=volumes/keycloak/postgres configs/ volumes/ credentials/

echo "- Dumping keycloak db"
source configs/keycloak_db.env && COMPOSE_INTERACTIVE_NO_CLI=1 docker-compose exec -T keycloak_db pg_dump -Fc -n public -U $POSTGRES_USER | ./scripts/tarappend -f data/keycloak_db.pgdump -t $BACKUP_DEST

echo "- Dumping api db"
source configs/api_db.env && COMPOSE_INTERACTIVE_NO_CLI=1 docker-compose exec -T api_db pg_dump -Fc -n public -U $POSTGRES_USER  | ./scripts/tarappend -f data/api_db.pgdump -t $BACKUP_DEST

echo ""
echo "Backup complete."

