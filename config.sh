#!/usr/bin/env bash

# Display name for the environment.
export SC_DISPLAY_NAME="SentinelC demo"

# Short name for the environment. Lowercase alphanumeric only.
export SC_ENV_NAME="my-sentinelc"

# The parent domain name under which app-specific sub-domains will be created.
export SC_BASE_DOMAIN="sentinelc.example.com"

# Public IP address where the environment is installed.
export EXTERNAL_IP=""

# Set to True to allow anonymous users to create an account and take ownership of available devices.
# At this moment, setting this to false causes the front-end application to crash. Leave true.
export ENABLE_ONBOARDING="true"

# Outgoing mail server address.
export SMTP_HOST=""

# Outgoing mail server port. Common ports are 25, 465 (SSL) and 587 (TLS).
export SMTP_PORT="25"

# Outgoing mail server user. Leave empty to disable authentification.
export SMTP_USER=""

# Outgoing mail server password. Leave empty to disable authentification.
export SMTP_PASS=""

# SMTP server requires automatic (implicit) encryption. This is commonly used on the 465 port.
export SMTP_USE_SSL="false"

# SMTP server supports STARTTLS (explicit) encryption. This is commonly used on the 587 port.
export SMTP_USE_TLS="false"

# Valid email address where automated messages and security notices will be sent. This is also used for the initial admin user.
export ADMIN_EMAIL=""

# Firstname of the initial admin user
export ADMIN_FIRSTNAME=""

# Lastname of the initial admin user
export ADMIN_LASTNAME=""

# Enable maintenance mode on the API
export MAINTENANCE_ON="false"
