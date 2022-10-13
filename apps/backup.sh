#!/usr/bin/env bash

set -e

cd "$(dirname "$0")"

BACKUP_NAME="sentinelc-$(hostname)-$(date +"%Y%m%d_%H%M%S")"
API_DB_BACKUP_FILE=$BACKUP_NAME-api.pgdump
KEYCLOAK_DB_BACKUP_FILE=$BACKUP_NAME-keycloak.pgdump

echo "Creating $BACKUP_NAME.tar.gz"

echo "- Backing up keycloak db"
source keycloak_db.env && COMPOSE_INTERACTIVE_NO_CLI=1 docker-compose exec -T keycloak_db pg_dump -Fc -n public -U $POSTGRES_USER -f /backup/$KEYCLOAK_DB_BACKUP_FILE $POSTGRES_DB

echo "- Backing up api db"
source api_db.env && COMPOSE_INTERACTIVE_NO_CLI=1 docker-compose exec -T api_db pg_dump -Fc -n public -U $POSTGRES_USER -f /backup/$API_DB_BACKUP_FILE $POSTGRES_DB

mkdir -p ../backups/
echo "- Backing final backup file"
tar -czpf ../backups/$BACKUP_NAME.tar.gz ../config.sh volumes/api_db/backup/$API_DB_BACKUP_FILE volumes/keycloak_db/backup/$KEYCLOAK_DB_BACKUP_FILE volumes/api volumes/logger_redis volumes/ssl volumes/vpnr
outer

echo "- Cleaning up temporary files"
rm volumes/api_db/backup/$API_DB_BACKUP_FILE volumes/keycloak_db/backup/$KEYCLOAK_DB_BACKUP_FILE

echo ""
echo "Backup complete: $(realpath ../backups/$BACKUP_NAME.tar.gz)"
