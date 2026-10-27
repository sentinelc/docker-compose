#!/usr/bin/env bash
#
# move-local-db-to-remote.sh
#
# Ad-hoc script: copies the api database of this installation (the api_db service) to a remote PostgreSQL
# database, for example a managed database, by streaming pg_dump into pg_restore. Nothing is written to disk and
# the local database is left as is. It is not part of the upgrade procedure.
#
# The source credentials come from configs/api_db.env. The target database must exist, be owned by the target
# user, and have unaccent created by an admin user:
#   ALTER DATABASE api OWNER TO django;
#   \c api
#   CREATE EXTENSION IF NOT EXISTS unaccent;
#
# The dump is a consistent snapshot, but the api keeps writing after it. For the final copy, stop the writers
# first: docker compose stop api celery beat
#
# Usage: scripts/move-local-db-to-remote.sh <host> <port> <user> <password> [database]
# The target database defaults to the local one (POSTGRES_DB, usually "api").

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

if [ $# -lt 4 ] || [ $# -gt 5 ]; then
    echo "usage: $0 <host> <port> <user> <password> [database]" >&2
    exit 2
fi

read_env() {
    sed -n "s/^$1=//p" configs/api_db.env | tail -1
}

SRC_USER=$(read_env POSTGRES_USER)
SRC_DB=$(read_env POSTGRES_DB)
[ -n "$SRC_USER" ] && [ -n "$SRC_DB" ] || { echo "ERROR: POSTGRES_USER or POSTGRES_DB missing in configs/api_db.env" >&2; exit 1; }

DB=${5:-$SRC_DB}
TARGET=(-h "$1" -p "$2" -U "$3" -d "$DB")
# Passed to the client container through the environment, not its command line.
export PGPASSWORD=$4

# PostgreSQL 18 client tools, in a throwaway container. TLS is required (managed databases refuse plain connections).
CLIENT=(docker run --rm -i -e PGPASSWORD -e PGSSLMODE=require postgres:18.6-trixie)

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

source_psql() {
    $COMPOSE_COMMAND exec -T api_db psql -X -At -v ON_ERROR_STOP=1 -U "$SRC_USER" -d "$SRC_DB"
}

target_psql() {
    "${CLIENT[@]}" psql -X -At -v ON_ERROR_STOP=1 "${TARGET[@]}" "$@"
}

echo "1. Checking the target"
version=$(target_psql -c "SHOW server_version") || fail "cannot connect to $1:$2/$DB as $3 (error above)."
[ "$(target_psql -c "SELECT count(*) FROM pg_extension WHERE extname = 'unaccent'")" = 1 ] \
    || fail "unaccent is not installed in $DB. As an admin user: \\c $DB, then CREATE EXTENSION unaccent;"
[ "$(target_psql -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")" = 0 ] \
    || fail "$DB already has tables. Drop and recreate it before copying again."
echo "   - PostgreSQL $version, unaccent installed, database empty."

echo "2. Streaming the dump of $SRC_DB to $1:$2/$DB"
# --no-owner --no-acl: the objects belong to the target user. --no-comments: only the owner of the extension
# (the admin user) can restore its comment.
$COMPOSE_COMMAND exec -T api_db pg_dump -Fc -U "$SRC_USER" "$SRC_DB" \
    | "${CLIENT[@]}" pg_restore "${TARGET[@]}" --no-owner --no-acl --no-comments --single-transaction \
    || fail "the copy failed and was rolled back: $DB is still empty."
"${CLIENT[@]}" vacuumdb --analyze-only --quiet --schema=public "${TARGET[@]}"

echo "3. Comparing row counts"
diff <(source_psql <<< "$COUNT_SQL") <(target_psql <<< "$COUNT_SQL") \
    || fail "row counts differ (-: local, +: remote). Expected if the api was running during the copy."
echo "   - Same row counts in all tables."
