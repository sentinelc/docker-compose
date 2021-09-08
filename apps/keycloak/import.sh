#!/usr/bin/env bash

java -jar keycloak-config-cli-13.0.0.jar \
    --keycloak.url=https://accounts."${SC_BASE_DOMAIN}"/auth \
    --keycloak.ssl-verify=false \
    --keycloak.user=admin \
    --keycloak.password="$(cat ../../credentials/keycloak)" \
    --import.path=./sentinelc.json
