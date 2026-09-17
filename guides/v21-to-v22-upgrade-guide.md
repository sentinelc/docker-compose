# Upgrading a docker-compose installation from v21 to v22

This guide is for installations deployed with the `docker-compose` project.

Expect a short interruption of the management VPN: the new vpn router generates a fresh key pair on its first
start and every appliance reconnects after its next configuration poll (about a minute by default).

## 1. Before you start

1. Take a backup: `scripts/backup.sh`.
2. Pull the new version of the docker-compose project (`git pull`).
3. Keep the `volumes/vpnrouter/` directory until the upgrade is validated: it holds the v21 vpn key, the only
   way to roll the router back.

## 2. Reconcile your configuration

The v22 services read a different set of variables than v21. Rather than listing every line, this project now
ships a script that re-renders the templates from your `config.sh` and shows how the files in use differ:

```
scripts/check-config-drift.sh
```

It prints one unified diff per file: `-` lines are what you have, `+` lines are what the v22 templates
produce. Apply the `+` lines and remove the `-` lines in `configs/*.env`, then run the script again until the
only differences left are ones you want to keep.

The script trusts `config.sh`. If the diff shows your domain, mail server or admin address changing, your
`config.sh` is stale: update it first, then rerun.

Differences you should keep:

- Tuning you did on purpose: `GUNICORN_WORKERS`, `CELERY_WORKERS` (new in v22, default `2`), `SLACK_LOGS_WEBHOOK`.
- Everything in `volumes/dex/config/config.yaml`: the dex template did not change in v22, so every difference
  there is a connector or password-database change you made. Keep it.

Differences you should apply, and why they exist:

- `api.env`: `DEX_ENDPOINT` is required; `LOGGER_ENDPOINT`, `DOCS_ENDPOINT`, `CLOUD_APPS_SUBDOMAIN` enable
  their feature. `AUTO_VPNROUTER_NAME` and `AUTO_VPNROUTER_TOKEN` make the api update your existing router
  named `vpnrouter` in place at every start, using the token already in `credentials/vpnrouter_api_token`;
  an error in that step aborts the start, remove the two variables to bypass it. If your router was created
  with other subnets than the defaults (`172.28.0.0/15`, `172.29.0.0/24`, `172.28.16.0/24`; check the VPN
  routers page of the Django admin), also set `AUTO_VPNROUTER_SUBNET`, `AUTO_VPNROUTER_DEVICE_SUBNET` and
  `AUTO_VPNROUTER_PRIVILEGED_SUBNET`. `MAINTENANCE_PASS` and `VPNROUTER_HMAC_AUTH_SECRET_KEY` go away.
  The container refuses to start when a required variable is missing and prints its name.
- `vpnrouter.env`: `ENDPOINT_IP` is the address appliances connect to, your `EXTERNAL_IP`; use the static
  public IP, the values `lan` and `public` exist for evaluation setups only. `VOUCH_ENDPOINT` enables the
  cloud apps. `PRIVATE_KEY`, `SC_BASE_DOMAIN` and `HMAC_AUTH_SECRET_KEY` go away.
- `proxy.env`: `DOMAIN` replaces `SC_BASE_DOMAIN` (still accepted with a warning). The maintenance gate moved
  from the api container to the proxy: `MAINTENANCE_ON` and `MAINTENANCE_PASS` must hold the same values as
  in `front.env`. With `MAINTENANCE_ON=true` every backend answers 503 unless the request carries the cookie
  `maintenance_pass=<MAINTENANCE_PASS>`; the front keeps its own maintenance page.
- `logger.env`: `PORT` is no longer read; the logger always listens on 3030.
- `vouch.env`: `VOUCH_COOKIE_SECURE=true`. Everything is served over https, so this only prevents the session
  cookie from ever being sent over plain http. The client id and OAuth URLs are the dex ones.
- `front.env`: the front no longer derives its endpoints from `SENTINELC_DOMAIN`; each `*_BASE_URL` and the
  two `OIDC_*` variables are given explicitly, which is what lets the same image run in the all-in-one pod.
  All of them are required. `ENABLE_ONBOARDING` is no longer read.

## 3. Start and verify

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
- Appliances come back online in the dashboard after their next poll, and VPN status returns to UP.
- Cloud apps (if used) still open through `https://<app>.apps.<domain>`.

If the health page reports a backend as unreachable with a 502 from the proxy although its container is
running, restart the proxy: `docker compose restart proxy`. nginx resolves the service names once at start and
`docker compose up -d` may have recreated a backend with a new address.

Once validated, `volumes/vpnrouter/` can be deleted.

