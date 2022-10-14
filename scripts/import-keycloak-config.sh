#!/usr/bin/env bash
set -e

KEYCLOAK_CONFIG_CLI_JAR="keycloak-config-cli-13.0.0.jar"
KEYCLOAK_CONFIG_CLI_URL="https://github.com/adorsys/keycloak-config-cli/releases/download/v3.4.0/keycloak-config-cli-13.0.0.jar"

cd "${0%/*}"


if [ -f "$KEYCLOAK_CONFIG_CLI_JAR" ]; then
    echo "$KEYCLOAK_CONFIG_CLI_JAR already exists, skipping download."
else
  echo "Downloading $KEYCLOAK_CONFIG_CLI_URL"
  wget $KEYCLOAK_CONFIG_CLI_URL
fi

if sha256sum --check $KEYCLOAK_CONFIG_CLI_JAR.sha256; then
  echo "$KEYCLOAK_CONFIG_CLI_JAR is valid"
else
  echo "$KEYCLOAK_CONFIG_CLI_JAR does not match expected checksum. Delete it and try again."
  exit 1
fi


java -jar keycloak-config-cli-13.0.0.jar \
    --keycloak.url=https://accounts."${SC_BASE_DOMAIN}"/auth \
    --keycloak.ssl-verify=false \
    --keycloak.user=admin \
    --keycloak.password="$(cat ../credentials/keycloak)" \
    --import.path=../tmp/keycloak-config.json
