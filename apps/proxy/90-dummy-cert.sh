#!/usr/bin/env bash

CERT_DIR="/etc/letsencrypt/live/app.$SC_BASE_DOMAIN"
CERT_FILE="$CERT_DIR/fullchain.pem"
KEY_FILE="$CERT_DIR/privkey.pem"

if [ -f "$CERT_FILE" ]; then
    echo "TLS certificate already exists, no need to generate a dummy one."
else
    echo "Generating a dummy ssl certificate."
    mkdir -p "$CERT_DIR"
    openssl req -x509 -nodes -newkey rsa:2048 -days 1\
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -subj '/CN=localhost'
    echo "You should run init-letsencrypt.sh next to fetch real certs."
fi
