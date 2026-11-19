#!/usr/bin/env bash
#
# check-config-drift.sh
#
# Helps an operator spot mistakes or drift in the generated configuration of a docker-compose installation.
#
# It sources the config.sh written at install time, recovers the random secrets from the files currently in
# use (they cannot be regenerated), re-renders every template under a temporary directory exactly like
# init-environment.sh does, and diffs the result against the files in use:
#
#   configs/*.env               <- templates/*/*.env.template
#   volumes/dex/config/config.yaml <- templates/dex/config.yaml.template
#   docker-compose.override.yml <- templates/compose/external-database.override.yml (external database only)
#
# The database mode (built-in api_db service or external) is read from the DATABASE_URL of configs/api.env, so
# an installation switched to an external database by hand is checked as such.
#
# A difference is not necessarily a mistake: it can be a deliberate customization (a dex connector, a tuned
# worker count) or a template that changed in a newer version of this project. Review each hunk.
#
# Exit status: 0 when nothing differs, 1 when at least one file differs or is missing, 2 on usage errors.

set -eo pipefail

# cd to root of project
cd "${0%/*}"/..

fail() {
  echo "Error: $1" >&2
  exit 2
}

[[ -f config.sh ]] || fail "config.sh not found. This script must run from an installed docker-compose project."
[[ -d configs ]] || fail "configs/ not found. Has init-environment.sh been run?"

# shellcheck disable=1091
source ./config.sh
# shellcheck source=scripts/lib/database.sh
source scripts/lib/database.sh

# --- recover the secrets generated at install time from the files in use -------------------------------
# read_value FILE KEY: value of KEY=... in an env file (empty when the file or key is missing)
read_value() {
  [[ -f "$1" ]] || return 0
  grep -m1 "^$2=" "$1" | cut -d= -f2- || true
}

# read_yaml_quoted FILE KEY: value of the first `KEY: "..."` line of a yaml file
read_yaml_quoted() {
  [[ -f "$1" ]] || return 0
  grep -m1 "^\s*$2: \"" "$1" | sed -E 's/^[^"]*"([^"]*)".*$/\1/' || true
}

DJANGO_SECRET_KEY=$(read_value configs/api.env DJANGO_SECRET_KEY)
API_OIDC_RP_CLIENT_SECRET=$(read_value configs/api.env OIDC_RP_CLIENT_SECRET)
API_DB_PASSWORD=$(read_value configs/api_db.env POSTGRES_PASSWORD)
VOUCH_OIDC_RP_CLIENT_SECRET=$(read_value configs/vouch.env OAUTH_CLIENT_SECRET)
MAINTENANCE_PASS=$(read_value configs/front.env MAINTENANCE_PASS)
VPNROUTER_API_TOKEN=$(cat credentials/vpnrouter_api_token 2>/dev/null || read_value configs/vpnrouter.env API_TOKEN)
ADMIN_PASS_HASH=$(read_yaml_quoted volumes/dex/config/config.yaml hash)
ADMIN_USER_UUID=$(read_yaml_quoted volumes/dex/config/config.yaml userID)

# DATABASE_URL: the built-in one is rebuilt from its password, an external one holds its own password.
DATABASE_URL=$(current_database_url)
if database_url_is_external "$DATABASE_URL"; then
  external_database=true
  # config.sh wins when it names the external database, to catch a configs/api.env that was not updated.
  [[ -z "${EXTERNAL_DATABASE_URL:-}" ]] || DATABASE_URL=$EXTERNAL_DATABASE_URL
  # As init-environment.sh: sslmode=require is added when the URL sets none, so a URL without TLS shows as drift.
  database_url_problem=$(check_external_database_url "$DATABASE_URL") || true
  DATABASE_URL=$(external_database_url "$DATABASE_URL")
else
  external_database=false
  [[ -z "$API_DB_PASSWORD" ]] || DATABASE_URL=$(builtin_database_url "$API_DB_PASSWORD")
fi

# A secret that could not be recovered renders as a visible marker so the diff points at it.
for var in DJANGO_SECRET_KEY API_OIDC_RP_CLIENT_SECRET API_DB_PASSWORD VOUCH_OIDC_RP_CLIENT_SECRET \
           MAINTENANCE_PASS VPNROUTER_API_TOKEN ADMIN_PASS_HASH ADMIN_USER_UUID DATABASE_URL; do
  [[ -n "${!var}" ]] || printf -v "$var" '%s' "<unrecovered secret: $var>"
  export "$var"
done

# --- render every template like init-environment.sh -----------------------------------------------------
RENDER_DIR=$(mktemp -d /tmp/sentinelc-config-drift.XXXXXX)
trap 'rm -rf "$RENDER_DIR"' EXIT
mkdir -p "$RENDER_DIR/configs" "$RENDER_DIR/volumes/dex/config"

# template -> file in use
declare -A PAIRS=(
  [templates/api/api_db.env.template]=configs/api_db.env
  [templates/api/api.env.template]=configs/api.env
  [templates/front/front.env.template]=configs/front.env
  [templates/portal/portal.env.template]=configs/portal.env
  [templates/proxy/proxy.env.template]=configs/proxy.env
  [templates/vpnrouter/vpnrouter.env.template]=configs/vpnrouter.env
  [templates/logger/logger.env.template]=configs/logger.env
  [templates/vouch/vouch.env.template]=configs/vouch.env
  [templates/docs/docs.env.template]=configs/docs.env
  [templates/dex/config.yaml.template]=volumes/dex/config/config.yaml
)

if $external_database; then
  # init-environment.sh does not write configs/api_db.env for an external database. One left from the built-in
  # database (kept for a rollback) is still checked.
  [[ -f configs/api_db.env ]] || unset 'PAIRS[templates/api/api_db.env.template]'
  PAIRS[$EXTERNAL_DATABASE_OVERRIDE]=docker-compose.override.yml
fi

drifted=0
clean=0

if [[ -n "${database_url_problem:-}" ]]; then
  echo "DRIFT    the DATABASE_URL of the external database cannot be used: $database_url_problem"
  echo
  drifted=$((drifted + 1))
fi

if ! $external_database && [[ -f docker-compose.override.yml ]] \
    && diff -q "$EXTERNAL_DATABASE_OVERRIDE" docker-compose.override.yml > /dev/null; then
  echo "DRIFT    docker-compose.override.yml disables the api_db service, but configs/api.env uses it."
  echo "         Delete docker-compose.override.yml, or set the DATABASE_URL of the external database."
  echo
  drifted=$((drifted + 1))
fi
for template in $(printf '%s\n' "${!PAIRS[@]}" | sort); do
  current=${PAIRS[$template]}
  expected="$RENDER_DIR/$current"
  envsubst < "$template" > "$expected"

  if [[ ! -f "$current" ]]; then
    echo "MISSING  $current (expected from $template)"
    drifted=$((drifted + 1))
    continue
  fi

  if diff -q "$current" "$expected" > /dev/null; then
    clean=$((clean + 1))
    continue
  fi

  drifted=$((drifted + 1))
  echo "DRIFT    $current"
  echo "         --- in use    +++ expected from config.sh and $template"
  # diff exits 1 on differences, which is the expected case here
  diff -u --label "$current (in use)" --label "$current (expected)" "$current" "$expected" | tail -n +3 | sed 's/^/         /' || true
  echo
done

echo "$clean file(s) match, $drifted file(s) differ or are missing."
if (( drifted > 0 )); then
  echo "A difference is not necessarily a mistake: keep deliberate customizations, fix the rest."
  exit 1
fi
