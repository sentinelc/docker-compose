# shellcheck shell=bash disable=SC2034
#
# Helpers shared by the scripts that need to know where the api database lives. Source this file from the
# root of the project.
#
# Two modes:
#   built-in  the api_db service of docker-compose.yml (the default)
#   external  any other PostgreSQL server, for example a managed database. Set EXTERNAL_DATABASE_URL in
#             config.sh before init-environment.sh, or switch an existing installation by hand.
#
# The DATABASE_URL of configs/api.env is the source of truth: it is where the api reads and writes.

BUILTIN_DATABASE_HOST="api_db"

# The compose override that disables the api_db service, copied to docker-compose.override.yml in external mode.
EXTERNAL_DATABASE_OVERRIDE="templates/compose/external-database.override.yml"

# builtin_database_url PASSWORD: the DATABASE_URL of the api_db service
builtin_database_url() {
  echo "postgres://django:$1@${BUILTIN_DATABASE_HOST}:5432/api"
}

# database_url_is_external URL: true when URL points to another server than the api_db service
database_url_is_external() {
  [[ -n "$1" && ! "$1" =~ ^postgres(ql)?://[^@]*@${BUILTIN_DATABASE_HOST}(:[0-9]+)?/ ]]
}

# current_database_url: the DATABASE_URL of configs/api.env (empty when missing)
current_database_url() {
  [[ -f configs/api.env ]] || return 0
  grep -m1 "^DATABASE_URL=" configs/api.env | cut -d= -f2- || true
}

# is_external_database: true when the api of this installation uses an external database
is_external_database() {
  database_url_is_external "$(current_database_url)"
}

# database_ssl_require URL: the DATABASE_SSL_REQUIRE value for URL.
# dj-database-url replaces the sslmode of the URL with "require" when DATABASE_SSL_REQUIRE is True. An sslmode in
# the URL (for example verify-full) is only honored with False.
database_ssl_require() {
  if ! database_url_is_external "$1"; then
    echo "False"
  elif [[ "$1" =~ [?\&]sslmode= ]]; then
    echo "False"
  else
    echo "True"
  fi
}

# check_external_database_url URL: prints why URL cannot be used as DATABASE_URL, returns 1 then
check_external_database_url() {
  local url=$1
  if [[ "$url" =~ [[:space:]\$\"\'\`\\#] ]]; then
    echo "it contains a space or one of \$ \" ' \` \\ #. Percent-encode them in the password (for example # is %23)."
    return 1
  fi
  if [[ "$url" =~ %([^0-9A-Fa-f]|.[^0-9A-Fa-f]|.?$) ]]; then
    echo "it contains a % that is not followed by two hexadecimal digits. Percent-encode % as %25."
    return 1
  fi
  if ! [[ "$url" =~ ^postgres(ql)?://[^:@/]+:[^@/]+@[^:@/?]+(:[0-9]+)?/[^/?]+(\?.*)?$ ]]; then
    echo "expected postgresql://USER:PASSWORD@HOST:PORT/DATABASE[?OPTIONS]. Percent-encode @ / ? : in the password."
    return 1
  fi
  if ! database_url_is_external "$url"; then
    echo "it points to the built-in api_db service. Leave EXTERNAL_DATABASE_URL empty to use it."
    return 1
  fi
}

# env_file_value FILE KEY: value of KEY=... in an env file (empty when the file or key is missing)
env_file_value() {
  [[ -f "$1" ]] || return 0
  grep -m1 "^$2=" "$1" | cut -d= -f2- || true
}

# set_env_value FILE KEY VALUE: replaces KEY=... in an env file, or appends it. VALUE is written as is.
set_env_value() {
  KEY=$2 VALUE=$3 awk -F= '
    BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VALUE"] }
    $1 == k { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }' "$1" > "$1.tmp"
  cat "$1.tmp" > "$1"
  rm -f "$1.tmp"
}

# url_decode STRING: decodes %xx
url_decode() {
  printf '%b' "${1//%/\\x}"
}

# export_libpq_env URL SSL_REQUIRE: exports PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE, PGSSLMODE and
# PGSSLROOTCERT for URL, SSL_REQUIRE being the DATABASE_SSL_REQUIRE of configs/api.env. PG_CLIENT passes them to
# the client container. TLS follows dj-database-url, like the api: SSL_REQUIRE True forces sslmode=require.
export_libpq_env() {
  local url=$1 ssl_require=$2 userinfo hostport query option key value
  if [[ "$url" == *\\* ]] \
      || ! [[ "$url" =~ ^postgres(ql)?://([^@/]+)@([^/?]+)/([^?]+)(\?(.*))?$ ]]; then
    echo "Error: DATABASE_URL is not postgresql://USER:PASSWORD@HOST[:PORT]/DATABASE[?OPTIONS]." >&2
    return 1
  fi
  userinfo=${BASH_REMATCH[2]}
  hostport=${BASH_REMATCH[3]}
  PGDATABASE=$(url_decode "${BASH_REMATCH[4]}")
  query=${BASH_REMATCH[6]}

  PGUSER=$(url_decode "${userinfo%%:*}")
  PGPASSWORD=""
  [[ "$userinfo" != *:* ]] || PGPASSWORD=$(url_decode "${userinfo#*:}")
  if [[ "$hostport" =~ ^(.+):([0-9]+)$ ]]; then
    PGHOST=$(url_decode "${BASH_REMATCH[1]}")
    PGPORT=${BASH_REMATCH[2]}
  else
    PGHOST=$(url_decode "$hostport")
    PGPORT=5432
  fi

  PGSSLMODE=prefer
  unset PGSSLROOTCERT
  local IFS='&'
  for option in $query; do
    key=${option%%=*}
    value=$(url_decode "${option#*=}")
    case $key in
      sslmode) PGSSLMODE=$value ;;
      sslrootcert) PGSSLROOTCERT=$value; export PGSSLROOTCERT ;;
      *) echo "Error: the scripts do not support the option $key of DATABASE_URL." >&2; return 1 ;;
    esac
  done
  [[ "$ssl_require" != "True" ]] || PGSSLMODE=require
  export PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE PGSSLMODE
}

# pg_client_init: sets PG_CLIENT, a temporary PostgreSQL client container (the postgres image of .env) that
# connects with the variables of export_libpq_env, and PG_TOOLS, the same image without them.
pg_client_init() {
  local image
  image="postgres:$(env_file_value .env POSTGRES_TAG)"
  if [[ -n "${PGSSLROOTCERT:-}" ]]; then
    echo "Error: DATABASE_URL sets sslrootcert, a path in the api container. The scripts cannot use it yet." >&2
    return 1
  fi
  PG_CLIENT=(docker run --rm -i -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGDATABASE -e PGSSLMODE "$image")
  PG_TOOLS=(docker run --rm -i "$image")
}

# Drops what the api created in schema public: tables (with their sequences and indexes), views and sequences,
# but not the objects of extensions such as unaccent, which the api user cannot create again on a managed service.
EMPTY_PUBLIC_SQL="
SET client_min_messages = warning;
DO \$\$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT format('%I.%I', n.nspname, c.relname) AS name, c.relkind
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
      AND NOT EXISTS (SELECT 1 FROM pg_depend d
                      WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
    -- Tables first: they take their sequences (serial, identity) with them, which cannot be dropped alone.
    ORDER BY CASE c.relkind WHEN 'p' THEN 0 WHEN 'r' THEN 1 WHEN 'f' THEN 2 WHEN 'm' THEN 3 WHEN 'v' THEN 4 ELSE 5 END
  LOOP
    EXECUTE format('DROP %s IF EXISTS %s CASCADE',
                   CASE r.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' WHEN 'S' THEN 'SEQUENCE'
                                  WHEN 'f' THEN 'FOREIGN TABLE' ELSE 'TABLE' END,
                   r.name);
  END LOOP;
END
\$\$;"

# Number of relations of schema public that EMPTY_PUBLIC_SQL drops
COUNT_PUBLIC_SQL="
SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
  AND NOT EXISTS (SELECT 1 FROM pg_depend d
                  WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e');"

# external_target_problem: checks, with PG_CLIENT, what the api needs in the external database: unaccent, and the
# right to create tables in schema public. Prints the problem and returns 1, or returns 1 silently if psql failed.
external_target_problem() {
  local unaccent create
  unaccent=$("${PG_CLIENT[@]}" psql -X -At -v ON_ERROR_STOP=1 \
    -c "SELECT count(*) FROM pg_extension WHERE extname = 'unaccent'" < /dev/null) || return 1
  if [[ "$unaccent" != 1 ]]; then
    echo "unaccent is not installed in $PGDATABASE, and the api user may not be allowed to create it on a managed
service. As the admin user of the database: \\c $PGDATABASE, then CREATE EXTENSION unaccent;"
    return 1
  fi
  create=$("${PG_CLIENT[@]}" psql -X -At -v ON_ERROR_STOP=1 \
    -c "SELECT has_schema_privilege('public', 'CREATE')" < /dev/null) || return 1
  if [[ "$create" != t ]]; then
    echo "$PGUSER cannot create tables in schema public of $PGDATABASE. As the admin user of the database:
ALTER DATABASE $PGDATABASE OWNER TO $PGUSER;"
    return 1
  fi
}
