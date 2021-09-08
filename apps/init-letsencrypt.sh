#!/bin/bash
domains=(app."$SC_BASE_DOMAIN" api."$SC_BASE_DOMAIN" accounts."$SC_BASE_DOMAIN" portal."$SC_BASE_DOMAIN")

domain=app.$SC_BASE_DOMAIN
rsa_key_size=4096
email="${ADMIN_EMAIL}" # Adding a valid address is strongly recommended
staging=$LETSENCRYPT_STAGING # Set to true if you're testing your setup to avoid hitting request limits

echo "### Deleting dummy certificate for $domain ..."
docker-compose run --rm --entrypoint "\
  rm -Rf /etc/letsencrypt/live/$domain && \
  rm -Rf /etc/letsencrypt/archive/$domain && \
  rm -Rf /etc/letsencrypt/renewal/$domain.conf" certbot
echo

echo "### Requesting Let's Encrypt certificate..."
#Join $domains to -d args
domain_args=""
for domain in "${domains[@]}"; do
  domain_args="$domain_args -d $domain"
done

# Select appropriate email arg
case "$email" in
  "") email_arg="--register-unsafely-without-email" ;;
  *) email_arg="--email $email" ;;
esac

# Enable staging mode if needed
if [ "$staging" = "true" ]; then staging_arg="--staging"; fi

docker-compose run --rm --entrypoint "\
  certbot certonly --webroot -w /var/www/certbot \
    $staging_arg \
    $email_arg \
    $domain_args \
    --rsa-key-size $rsa_key_size \
    --agree-tos \
    --non-interactive \
    --force-renewal" certbot
echo

echo "### Reloading nginx ..."
docker-compose exec -T proxy nginx -s reload
