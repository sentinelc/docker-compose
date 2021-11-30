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
export ENABLE_ONBOARDING="false"

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

# Optional Terraform scripts targeting DigitalOcean and DNS Made Easy can be generated if this is set to 1.
export ENABLE_TERRAFORM="false"

#
# VARIABLES BELOW ARE ONLY REQUIRED IF ENABLE_TERRAFORM is 1
#

# Use as the rewriteDomain ssmtp configuration, for OS level automated emails.
export SMTP_DOMAIN=""

# DigitalOcean API token.
export DO_TOKEN=""

# DigitalOcean region where the VM will be created.
export DO_REGION=""

# DNS Made Easy api key.
export DME_API_KEY=""

# DNS Made Easy secret key.
export DME_SECRET_KEY=""

# DNS Made Easy domain ID where subdomains will be created.
export DME_DOMAIN_ID=""

# Enable maintenance mode on the API
export MAINTENANCE_ON="false"
