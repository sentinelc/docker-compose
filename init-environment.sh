#!/usr/bin/env bash

set -e

fail() {
  echo "$1"
  exit 1
}

checkIfSet() {
  if ! [[ -v $1 ]]; then
    fail "Error: environment variable $1 is unset. Please see https://docs.sentinelc.com/docs/controller/config-reference#${1,,}"
  fi
}

checkForString() {
  checkIfSet "$1"
  if [[ -z ${!1} ]]; then
    fail "Error: environment variable $1 is empty. Please see https://docs.sentinelc.com/docs/controller/config-reference#${1,,}"
  fi
}

checkForBool() {
  checkIfSet "$1"
  if [[ ${!1} != "true" && ${!1} != "false" && ${!1} != "" ]]; then
    fail "Error: environment variable $1 should be set to true, false or left empty. Please see https://docs.sentinelc.com/docs/controller/config-reference#${1,,}"
  fi
}

cd "${0%/*}"

checkForString "SC_DISPLAY_NAME"
checkForString "SC_ENV_NAME"
checkForString "SC_BASE_DOMAIN"
checkForString "EXTERNAL_IP"
checkForBool "ENABLE_ONBOARDING"
checkForString "SMTP_HOST"
checkForString "SMTP_PORT"
checkForBool "SMTP_USE_SSL"
checkForBool "SMTP_USE_TLS"
checkIfSet "SMTP_USER"
checkIfSet "SMTP_PASS"
checkForString "ADMIN_EMAIL"
checkForBool "MAINTENANCE_ON"

if [[ -n $SMTP_USER && -z $SMTP_PASS ]]; then
  fail "Error: SMTP_USER is set but SMTP_PASS is empty."
fi

if [[ -n $SMTP_PASS && -z $SMTP_USER ]]; then
  fail "Error: SMTP_PASS is set but SMTP_USER is empty."
fi

SMTP_AUTH="false"
if [[ -n $SMTP_USER ]]; then
  SMTP_AUTH="true"
  export SMTP_AUTH
fi

VM_HOSTNAME="api.${SC_BASE_DOMAIN}"
export VM_HOSTNAME

KEYCLOAK_ADMIN_PASS=$(pwgen --capitalize --symbols --numerals -r \'\"\\/\`\{\}\~\(\)\[\]\*\&\|\$ 32 1)
export KEYCLOAK_ADMIN_PASS

DJANGO_SECRET_KEY=$(pwgen --capitalize --symbols --numerals -r \'\"\\/\`\{\}\~\(\)\[\]\*\&\|\$ 50 1)
export DJANGO_SECRET_KEY

API_OIDC_RP_CLIENT_SECRET=$(uuidgen)
export API_OIDC_RP_CLIENT_SECRET

KEYCLOAK_APICLIENT_PASS=$(pwgen --capitalize --symbols --numerals -r \'\"\\/\`\{\}\~\(\)\[\]\*\&\|\$ 32 1)
export KEYCLOAK_APICLIENT_PASS

API_DB_PASSWORD=$(pwgen 64 1)
export API_DB_PASSWORD

KEYCLOAK_DB_PASSWORD=$(pwgen 64 1)
export KEYCLOAK_DB_PASSWORD

VPNROUTER_API_TOKEN=$(pwgen 40 1)
export VPNROUTER_API_TOKEN

FIRST_USER_TEMP_PASS=$(pwgen --capitalize --symbols --numerals -r \'\"\\/\`\{\}\~\(\)\[\]\*\&\|\$ 32 1)
export FIRST_USER_TEMP_PASS

MAINTENANCE_PASS=$(pwgen 8 1)
export MAINTENANCE_PASS

echo "Generating random credentials..."
mkdir credentials

echo " - credentials/keycloak"
echo "$KEYCLOAK_ADMIN_PASS" > credentials/keycloak

echo " - credentials/vpnrouter_api_token"
echo "$VPNROUTER_API_TOKEN" > credentials/vpnrouter_api_token

echo " - credentials/login-instructions.txt"
envsubst < templates/login-instructions.txt.tpl > credentials/login-instructions.txt
echo ""

echo "Generating docker-compose environment..."

echo " - Creating empty volumes"
echo "   - apps/volumes/ssl"
mkdir -p apps/volumes/ssl
echo "   - apps/volumes/vpnrouter"
mkdir -p apps/volumes/vpnrouter
echo "   - apps/volumes/keycloak_db/backup"
mkdir -p apps/volumes/keycloak_db/backup
echo "   - apps/volumes/keycloak_db/data"
mkdir -p apps/volumes/keycloak_db/data
echo "   - apps/volumes/api_db/backup"
mkdir -p apps/volumes/api_db/backup
echo "   - apps/volumes/api_db/data"
mkdir -p apps/volumes/api_db/data

echo " - Generating docker-compose config files from templates"
envsubst < apps/api_db.env.template > apps/api_db.env
envsubst < apps/keycloak_db.env.template > apps/keycloak_db.env
envsubst < apps/api.env.template > apps/api.env
envsubst < apps/front.env.template > apps/front.env
envsubst < apps/portal.env.template > apps/portal.env
envsubst < apps/keycloak.env.template > apps/keycloak.env
envsubst < apps/proxy.env.template > apps/proxy.env
envsubst < apps/vpnrouter.env.template > apps/vpnrouter.env
envsubst < apps/logger.env.template > apps/logger.env

echo " - Generating keycloak JSON import file from template"
envsubst < apps/keycloak/sentinelc.json.template > apps/keycloak/sentinelc.json
echo ""

echo "Generating wireguard server key pair..."
cd apps/vpnrouter/ || exit
./gen-wg-keys.py
echo ""

echo "docker-compose.yml and supporting files have been created in the $SC_ENV_NAME directory."
echo "SUCCESS"
