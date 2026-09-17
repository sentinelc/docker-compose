# Upgrading a docker-compose installation from v21 to v22

This guide is for installations deployed with the `docker-compose` project. The all-in-one pod (app library
recipe) is self-contained: upgrading the recipe applies every change below automatically.

v22 ships the api, vpn router, proxy, logger and front as one set: they must be upgraded together. The api
rejects a v21 vpn router, the v22 logger paths are only understood by the v22 api and proxy, and the v22 front
reads a new set of variables.

Expect a short interruption of the management VPN: the new vpn router generates a fresh key pair on its first
start and every appliance reconnects after its next configuration poll (about a minute by default).

## 1. Before you start

1. Take a backup: `scripts/backup.sh`.
2. Pull the new version of the docker-compose project (`git pull`). It brings the updated `docker-compose.yml`
   and `.env`, and the new templates used for fresh installs. Existing `configs/*.env` files are never rewritten:
   the sections below list what to change in them.
3. Keep the `volumes/vpnrouter/` directory until the upgrade is validated: it is the only way to roll the vpn
   router back to v21.

## 2. Image tags (`.env`)

The pulled `.env` sets the five v22 tags and the new dex tag. If you maintain your own `.env`, set them all
at once:

```
API_TAG=v22.0.0
VPNROUTER_TAG=v22.0.0
PROXY_TAG=v22.0.0
LOGGER_TAG=v22.0.0
FRONT_TAG=v22.0.0
DEX_TAG=v2.45.1-sc.3
```

The dex image now serves both deployment modes. Your mounted `volumes/dex/config/config.yaml` is used
unchanged; nothing to edit.

## 3. `configs/api.env`

Add, with `<domain>` being your `SC_BASE_DOMAIN`:

```
DOCS_ENDPOINT=https://docs.<domain>
LOGGER_ENDPOINT=https://logs.<domain>
DEX_ENDPOINT=https://accounts.<domain>
CLOUD_APPS_SUBDOMAIN=apps.<domain>
AUTO_VPNROUTER_NAME=vpnrouter
AUTO_VPNROUTER_TOKEN=<content of credentials/vpnrouter_api_token>
```

Optional: `GUNICORN_LISTEN` (default `0.0.0.0:5000`) and `CELERY_WORKERS` (default `2`) can be set to tune
the containers; the existing `GUNICORN_WORKERS` keeps working.

Remove:

```
MAINTENANCE_PASS
VPNROUTER_HMAC_AUTH_SECRET_KEY
```

Notes:

- `DEX_ENDPOINT` is required. `LOGGER_ENDPOINT`, `DOCS_ENDPOINT` and `CLOUD_APPS_SUBDOMAIN` are optional:
  leaving one unset disables that feature (log collection, documentation links, cloud apps).
- `AUTO_VPNROUTER_NAME` and `AUTO_VPNROUTER_TOKEN` make the api create or update the vpn router at every
  start. The token must be the one already used by the router (`credentials/vpnrouter_api_token`, 40
  alphanumeric characters). The existing router named `vpnrouter` is updated in place. The optional
  `AUTO_VPNROUTER_SUBNET`, `AUTO_VPNROUTER_DEVICE_SUBNET` and `AUTO_VPNROUTER_PRIVILEGED_SUBNET` default to
  `172.28.0.0/15`, `172.29.0.0/24` and `172.28.16.0/24`; set them only if your router was created with other
  subnets (check the VPN routers page of the Django admin).
- The container now refuses to start when a required variable is missing or empty and prints its name.
  Required: `DJANGO_SECRET_KEY`, `DATABASE_URL`, `REDIS_URL`, `ALLOWED_HOSTS`, `CORS_ALLOWED_ORIGINS`,
  `DASHBOARD_ENDPOINT`, `DEX_ENDPOINT`, `OIDC_RP_CLIENT_ID`, `OIDC_RP_CLIENT_SECRET`,
  `OIDC_OP_AUTHORIZATION_ENDPOINT`, `OIDC_OP_TOKEN_ENDPOINT`, `OIDC_OP_USER_ENDPOINT`, `OIDC_OP_JWKS_ENDPOINT`.
  An error in the `AUTO_VPNROUTER_*` step also aborts the start; remove those two variables to bypass it.

## 4. `configs/vpnrouter.env`

The file must end up as:

```
ROUTER_NAME=vpnrouter
API_ENDPOINT=http://api:5000
API_TOKEN=<content of credentials/vpnrouter_api_token>
API_ENDPOINT_HOST=api.<domain>
ENDPOINT_IP=<public IP of the server, your EXTERNAL_IP>
VOUCH_ENDPOINT=https://vouch.<domain>
NGINX_LISTEN_ADDRESS=0.0.0.0
```

Added: `ENDPOINT_IP` (required), `VOUCH_ENDPOINT`, `NGINX_LISTEN_ADDRESS`.
Removed: `PRIVATE_KEY`, `SC_BASE_DOMAIN`, `HMAC_AUTH_SECRET_KEY`.

`ENDPOINT_IP` is the address appliances connect to. Use the static public IP. The values `lan` and `public`
exist for evaluation setups only.

## 5. `configs/proxy.env`

The file must end up as:

```
DOMAIN=<domain>
CLOUD_APPS_DOMAIN=apps.<domain>
DOCS_UPSTREAM=docs:80
PORTAL_UPSTREAM=portal:80
MAINTENANCE_ON=<same value as configs/front.env>
MAINTENANCE_PASS=<same value as configs/front.env>
```

`SC_BASE_DOMAIN` still works as an alias of `DOMAIN` with a warning. The cloud apps, documentation and portal
virtual hosts are only generated when their variable is set; remove the line to disable one. Leave
`SINGLE_DOMAIN_MODE` unset: its default (`false`) is the subdomains layout of docker-compose installs.

The maintenance gate moved from the api container to the proxy. With `MAINTENANCE_ON=true`, every backend
(`api.`, `accounts.`, `logs.`, `vouch.`, `*.apps.`, `docs.`, `portal.`) answers 503 unless the request carries
the cookie `maintenance_pass=<MAINTENANCE_PASS>`; the front keeps its own maintenance page. Copy the two
values from `configs/front.env` so the front and the proxy agree. `MAINTENANCE_PASS` is required when
`MAINTENANCE_ON=true`.

Your certificate in `volumes/ssl/` is used unchanged. When no certificate is present, the proxy now generates
a private CA under `/pki` instead of a one-day placeholder certificate; the server certificate covers every
service subdomain. `/pki` is not a volume, so that CA changes whenever the proxy container is recreated: it is
meant for evaluation setups only.

## 6. `configs/logger.env`

The file must end up as:

```
HOST=0.0.0.0
API_URL=https://api.<domain>
REDIS_URL=redis://logger_redis/
```

Added: `HOST=0.0.0.0` (required under docker-compose). The logger now binds to `127.0.0.1` by default,
since it is meant to be reached only through the proxy; under docker-compose the proxy is a separate
container, so the logger must listen on all interfaces of its own network namespace. Without it, the proxy
gets a 502 on `logs.<domain>` and the health page reports the logger as failed.

Removed: `PORT=3030`. The logger always listens on 3030; the variable is no longer read.

## 7. `configs/vouch.env`

Change:

```
VOUCH_COOKIE_SECURE=true
```

The vouch session cookie now carries the `Secure` flag. Everything is served over https, so this has no
functional effect on a working setup; it only prevents the cookie from ever being sent over plain http.

## 8. `configs/front.env`

The file must end up as:

```
DOCS_BASE_URL=https://docs.<domain>
API_BASE_URL=https://api.<domain>
LOGS_BASE_URL=https://logs.<domain>
LOGS_BASE_WSS_URL=wss://logs.<domain>
AUTH_BASE_URL=https://accounts.<domain>
OIDC_AUTHORITY=https://accounts.<domain>/
OIDC_CLIENT_ID=front
MAINTENANCE_ON=<unchanged>
MAINTENANCE_PASS=<unchanged>
```

Added: the seven `*_BASE_URL` and `OIDC_*` variables. The front no longer derives its endpoints from a single
domain; each is given explicitly, which is what allows the same image to run in the all-in-one pod. All eight
are required: the container refuses to start and names the missing one. There is no `APPS_BASE_URL`: the
front never contacts the cloud apps domain (the entry only served the removed filebrowser integration).
Removed: `SENTINELC_DOMAIN`, `ENABLE_ONBOARDING` (no longer read).

## 9. `docker-compose.yml`

Provided by the pulled project. Compared to v21:

- `celery` and `beat` run `/app/scripts/celery-worker.sh` and `/app/scripts/celery-beat.sh`.
- The `vpnrouter` service no longer mounts `./volumes/vpnrouter:/etc/wireguard`.
- The `vouch` service no longer publishes port 9090 on the host. The proxy and the vpn router reach it over
  the internal docker network; the host port was an oversight.

## 10. Start and verify

```
docker compose pull
docker compose up -d
scripts/wait-for-migrations.sh
```

Delete the existing user sessions. Sessions created by v21 refer to an authentication backend module that
no longer exists and would fail every request of a logged-in user; everyone logs in again:

```
docker compose exec api ./manage.py shell -c "from django.contrib.sessions.models import Session; Session.objects.all().delete()"
```

Then check:

- `https://api.<domain>/health` reports no error. A warning that the VPN router "has not reported its public
  key and endpoint yet" is normal for the first minute.
- `docker compose logs api` shows `Updated VPN router vpnrouter` or `VPN router vpnrouter is up to date`.
- `docker compose logs vpnrouter` shows the generated public key, the resolved endpoint, and no 400 from the
  api.
- Appliances come back online in the dashboard after their next poll, and VPN status returns to UP.
- `docker compose logs logger` shows appliance log posts arriving (`/logs/post/<device_id>`).
- Cloud apps (if used) still open through `https://<app>.apps.<domain>`.

Once validated, `volumes/vpnrouter/` can be deleted.

## 11. Rollback

Restore the previous image tags in `.env`, revert the five env files, restore the backup with
`scripts/restore.sh` if the database must be rolled back, and run `docker compose up -d`. The v21 vpn router
reads its key from `volumes/vpnrouter/`, so appliances reconnect with the previous key.

## Reference: behaviour changes in v22

VPN:

- The vpn router generates its wireguard key pair in memory at every container start and reports its public
  key and endpoint to the api on every poll. Nothing is written to disk, no volume is needed. Every restart or
  upgrade of the router rotates the key: appliances reconnect after their next poll. A key or endpoint change
  is recorded as a configuration change for each appliance of the router but is not pushed to them.
- `manage.py add_vpn_router` is idempotent (keyed on `--name`) and no longer takes `--public-key` or
  `--endpoint-ip`.
- `POST /vpn/routers/<name>/` requires `public_key` and `endpoint_ip`; a v21 router is rejected with 400.
- The api reaches the router's http proxy on port 4000 (was 80).
- The appliance configuration omits a router that has not reported its key yet.

Proxy:

- A single image serves both deployment modes, selected by `SINGLE_DOMAIN_MODE` (default `false`: subdomains).
- Old firmwares that post logs to `/post/<device_id>` are rewritten to `/logs/post/<device_id>`.

Logger and api:

- The appliance log endpoint is `<LOGGER_ENDPOINT>/logs/post/<device_id>`; the logger also serves
  `/logs/version`, used by the health page.
- The logger binds to `127.0.0.1:3030` by default. `HOST=0.0.0.0` is required under docker-compose; `PORT`
  is no longer read.
- `MAINTENANCE_ON` no longer gates traffic in the api, which only uses it to alter its behaviour;
  `MAINTENANCE_PASS` is removed from `api.env`. The gate now lives in the proxy (`MAINTENANCE_ON` and
  `MAINTENANCE_PASS` in `proxy.env`) and covers every backend, not only the api.
- The custom SMTP backend with legacy cipher support is removed. Mail providers that only offer old ciphers
  will fail.
- `STATIC_URL` moved from `/static/` to `/_static/`.
- The filebrowser feature (`<device>-files` cloud app, `deviceVolumeRequestAccess` mutation,
  `DeviceCommunicationError` enum, HMAC secret) is removed.
- `GET /sentinelc/stats/` is removed. Bearer JWT is only honoured on `/graphql`; device and task endpoints
  accept only `Token` authentication.
- `/health/`: a missing VPN router, portal, logger or docs is a warning rather than an error; the update report
  only lists configured apps; every OIDC URL must be https.
