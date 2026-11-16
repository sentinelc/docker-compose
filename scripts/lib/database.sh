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
