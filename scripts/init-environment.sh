#!/usr/bin/env bash

set -e

fail() {
  echo "$1"
  exit 1
}

checkIfSet() {
  if ! [[ -v $1 ]]; then
    fail "Error: environment variable $1 is unset. Please see https://sentinelc.com/docs/controller/config-reference#${1,,}"
  fi
}

checkForString() {
  checkIfSet "$1"
  if [[ -z ${!1} ]]; then
    fail "Error: environment variable $1 is empty. Please see https://sentinelc.com/docs/controller/config-reference#${1,,}"
  fi
}

checkForBool() {
  checkIfSet "$1"
  if [[ ${!1} != "true" && ${!1} != "false" && ${!1} != "" ]]; then
    fail "Error: environment variable $1 should be set to true, false or left empty. Please see https://sentinelc.com/docs/controller/config-reference#${1,,}"
  fi
}

createVolume() {
  echo "   - volumes/$1/$2"
  mkdir -p volumes/$1/$2
}

# cd to root of project
cd "${0%/*}"/..

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

VOUCH_OIDC_RP_CLIENT_SECRET=$(uuidgen)
export VOUCH_OIDC_RP_CLIENT_SECRET

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
envsubst < templates/instructions/login-instructions.txt.tpl > credentials/login-instructions.txt
echo ""

echo "Generating docker-compose environment..."

echo " - Creating empty volumes"
createVolume "ssl"
createVolume "vpnrouter"
createVolume "keycloak" "postgres"
createVolume "keycloak" "import"
createVolume "api" "media"
createVolume "api" "postgres"
createVolume "logger" "redis"


echo " - Generating docker-compose config files from templates under ./configs"
mkdir -p configs/
envsubst < templates/api/api_db.env.template > configs/api_db.env
envsubst < templates/keycloak/keycloak_db.env.template > configs/keycloak_db.env
envsubst < templates/api/api.env.template > configs/api.env
envsubst < templates/front/front.env.template > configs/front.env
envsubst < templates/portal/portal.env.template > configs/portal.env
envsubst < templates/keycloak/keycloak.env.template > configs/keycloak.env
envsubst < templates/proxy/proxy.env.template > configs/proxy.env
envsubst < templates/vpnrouter/vpnrouter.env.template > configs/vpnrouter.env
envsubst < templates/logger/logger.env.template > configs/logger.env
envsubst < templates/vouch/vouch.env.template > configs/vouch.env
envsubst < templates/docs/docs.env.template > configs/docs.env
envsubst < templates/keycloak/keycloak-config.json.template > volumes/keycloak/import/sentinelc-realm.json

echo ""
echo "Generating wireguard server key pair"
python3 scripts/gen-wg-keys.py
echo ""

echo "SUCCESS"
echo "Follow the next steps in the cloud controller installation guide to finish your installation."
