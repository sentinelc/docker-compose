#!/usr/bin/env bash

# shellcheck disable=2016

envsubst '$SC_BASE_DOMAIN' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
