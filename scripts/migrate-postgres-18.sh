#!/usr/bin/env bash
#
# migrate-postgres-18.sh
#
# Migrates the api database from PostgreSQL 14 (volumes/api/postgres) to PostgreSQL 18 (volumes/api/postgresql)
# by dump and restore. See guides/postgres-14-to-18-upgrade-guide.md.
#
# Run it after `git pull`, with maintenance mode on, before `docker compose up -d`. The data in
# volumes/api/postgres is left as is: until maintenance mode is turned off, rolling back loses nothing.

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

# The PostgreSQL 14 image of the previous release, used to read the old data directory one last time.
OLD_IMAGE="postgres:14.22-trixie@sha256:2f439034a24488d86d69fa1b2254e51a91154fa3dee22a4d70bb906eaba11321"
OLD_DIR=volumes/api/postgres
NEW_DIR=volumes/api/postgresql
OLD_CONTAINER=sentinelc-api-db-pg14
STAMP=$(date +"%Y%m%d_%H%M%S")
DUMP=backups/api_db-pg14-$STAMP.pgdump
COUNTS_OLD=backups/api_db-pg14-$STAMP.counts
COUNTS_NEW=backups/api_db-pg18-$STAMP.counts

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
    echo "" >&2
    echo "ERROR: $*" >&2
    exit 1
}

cleanup() {
    docker rm -f "$OLD_CONTAINER" &> /dev/null || true
}
trap cleanup EXIT

echo "1. Checks"

old_version=$(cat "$OLD_DIR/PG_VERSION" 2> /dev/null) \
    || fail "cannot read $OLD_DIR/PG_VERSION. Run this script as root, from an installation that ran PostgreSQL 14."
[ "$old_version" = "14" ] || fail "$OLD_DIR holds PostgreSQL $old_version data, expected 14."

if [ -n "$(ls -A "$NEW_DIR" 2> /dev/null)" ]; then
    fail "$NEW_DIR is not empty: the migration already ran, or the api_db service was started on PostgreSQL 18.
If it holds an empty database created by mistake, run '$COMPOSE_COMMAND stop api celery beat api_db',
delete $NEW_DIR and run this script again."
fi

grep -q '^POSTGRES_TAG=18' .env && grep -q "$NEW_DIR:/var/lib/postgresql$" docker-compose.yml \
    || fail ".env and docker-compose.yml are not the PostgreSQL 18 version. Run 'git pull' first."

$COMPOSE_COMMAND exec -T proxy test -s /etc/nginx/maintenance-gate.conf \
    || fail "maintenance mode is not on in the running proxy. Set MAINTENANCE_ON=true in configs/proxy.env,
configs/front.env and configs/api.env, then run '$COMPOSE_COMMAND up -d --no-deps proxy front api'.
Do not run a plain '$COMPOSE_COMMAND up -d': it would start api_db on an empty PostgreSQL 18 database."

echo "   - PostgreSQL 14 data found in $OLD_DIR, maintenance mode is on."

echo "2. Stopping the api, its workers and the database"
$COMPOSE_COMMAND stop api celery beat api_db

echo "3. Dumping the PostgreSQL 14 database"
mkdir -p backups
cleanup
docker run -d --name "$OLD_CONTAINER" --network none --env-file configs/api_db.env \
    -v "$PWD/$OLD_DIR:/var/lib/postgresql/data" "$OLD_IMAGE" > /dev/null

for _ in $(seq 60); do
    docker exec "$OLD_CONTAINER" bash -c 'pg_isready -q -U "$POSTGRES_USER"' && break
    sleep 2
done
docker exec "$OLD_CONTAINER" bash -c 'pg_isready -q -U "$POSTGRES_USER"' \
    || fail "PostgreSQL 14 did not start. Check 'docker logs $OLD_CONTAINER'."

docker exec "$OLD_CONTAINER" bash -c 'pg_dump -Fc -U "$POSTGRES_USER" "$POSTGRES_DB"' > "$DUMP"
docker exec -i "$OLD_CONTAINER" bash -c 'psql -X -At -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
    <<< "$COUNT_SQL" > "$COUNTS_OLD"
echo "   - $DUMP ($(du -h "$DUMP" | cut -f1), $(wc -l < "$COUNTS_OLD") tables)"

docker stop -t 120 "$OLD_CONTAINER" > /dev/null
cleanup

echo "4. Creating the PostgreSQL 18 database in $NEW_DIR"
mkdir -p "$NEW_DIR"
$COMPOSE_COMMAND up -d api_db

# Wait on TCP: during the first initialization, the image runs a temporary server on the Unix socket only.
for _ in $(seq 60); do
    $COMPOSE_COMMAND exec -T api_db bash -c 'pg_isready -q -h 127.0.0.1 -U "$POSTGRES_USER"' && break
    sleep 2
done
$COMPOSE_COMMAND exec -T api_db bash -c 'pg_isready -q -h 127.0.0.1 -U "$POSTGRES_USER"' \
    || fail "PostgreSQL 18 did not start. Check '$COMPOSE_COMMAND logs api_db'."

echo "5. Restoring the dump"
$COMPOSE_COMMAND exec -T api_db bash -c 'pg_restore --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
    < "$DUMP" || fail "the restore failed and was rolled back. Do not turn maintenance mode off: roll back."
$COMPOSE_COMMAND exec -T api_db bash -c 'vacuumdb --analyze-only --quiet -U "$POSTGRES_USER" -d "$POSTGRES_DB"'

echo "6. Verifying"
$COMPOSE_COMMAND exec -T api_db bash -c 'psql -X -At -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
    <<< "$COUNT_SQL" > "$COUNTS_NEW"
diff "$COUNTS_OLD" "$COUNTS_NEW" \
    || fail "row counts differ between PostgreSQL 14 (-) and 18 (+). Do not turn maintenance mode off: roll back."
new_version=$($COMPOSE_COMMAND exec -T api_db bash -c 'psql -X -At -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SHOW server_version"')
echo "   - Same row counts in all $(wc -l < "$COUNTS_NEW") tables. Server version: $new_version"

cat <<EOF

Migration complete. Maintenance mode is still on.

Next steps:
  $COMPOSE_COMMAND up -d
  ./scripts/wait-for-migrations.sh

Then check the health status page and the admin console with the maintenance bypass cookie, and turn
maintenance mode off.

To roll back before turning maintenance mode off (nothing is lost, the data in $OLD_DIR was left as is):
  $COMPOSE_COMMAND down
  git checkout <commit noted before git pull>
  rm -rf $NEW_DIR
  $COMPOSE_COMMAND up -d

Keep $OLD_DIR and $DUMP until the new version is validated.
EOF
