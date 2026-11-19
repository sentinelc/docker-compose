# Using an external PostgreSQL database for the api

This guide is for installations deployed with the `docker-compose` project that move the api database out of the
built-in `api_db` service, to an external PostgreSQL server such as a managed database (Digital Ocean, AWS RDS…).
The other services and their data stay on the server.

An installation uses one of two modes:

- **built-in** (default): the `api_db` service of `docker-compose.yml`, data in `volumes/api/postgresql/`.
- **external**: `configs/api.env` points the api to another server, and `docker-compose.override.yml` (ignored by
  git) disables `api_db`. `scripts/backup.sh`, `scripts/restore.sh` and `scripts/check-config-drift.sh` read the
  mode from the `DATABASE_URL` of `configs/api.env`.

Requirements:

- Docker Compose 2.40.3 or later on the server (`docker compose version`).
- PostgreSQL 18 on the external server, with the `unaccent` extension.

An installation still on the built-in PostgreSQL 14 can move directly to an external PostgreSQL 18 database. It
does not need `scripts/migrate-postgres-18.sh` first.

## 1. Prepare the database

1. Create a user for the api, for example `sentinelc`, and a database `api`. On Digital Ocean, use the
   *Users & Databases* tab of the cluster: this is the tested way. Do not use the admin user (`doadmin`) for the
   api.
2. As the admin user, with `psql`, make sure that `unaccent` exists in the database. The api user may not be
   allowed to create it on a managed service:

   ```
   \c api
   CREATE EXTENSION IF NOT EXISTS unaccent;
   ```

   The api user must also be able to create tables in schema `public`. The scripts check both before they write
   anything (see the connection check below). If the check reports that the api user cannot create tables, make
   it the owner of the database, as the admin user: `ALTER DATABASE api OWNER TO sentinelc;`. On other services,
   this can fail with `must be able to SET ROLE` if the admin user did not create the api user.
3. Allow connections from the public IP address of the server only (*Trusted sources* on Digital Ocean).
4. Check the connection limit of the plan. The api keeps its connections open (up to 10 minutes): one per gunicorn
   worker (`GUNICORN_WORKERS`, 3), one per celery worker (`CELERY_WORKERS`, 2) plus one, and one for beat. Count
   about ten connections with the default settings, as the migrations at startup, `backup.sh` and `manage.py`
   commands open their own.

Write the connection URL of the api user:

```
postgresql://sentinelc:PASSWORD@HOST:PORT/api
```

Percent-encode the special characters of the password: `@` is `%40`, `#` is `%23`, `%` is `%25`, `/` is `%2F`,
`:` is `%3A`, `?` is `%3F`, `$` is `%24`. The scripts refuse a URL with unencoded `$ " ' \` \ #` or spaces.

The connection uses TLS: the scripts add `?sslmode=require` to a URL that sets no `sslmode`, and refuse
`sslmode=disable`, `allow` and `prefer`. `require` encrypts the connection, but does not verify the server
certificate: it does not detect a server that impersonates the database. `verify-full`, with the CA certificate of
the cluster, is not supported yet (sentinel-c/gestion#2001).

Check the connection from the server. On an empty database, this prints the server version and checks `unaccent`
and the right to create tables, then prints `Nothing to do.`. It asks for the URL without echoing it:

```
./scripts/move-local-db-to-remote.sh --empty-target
```

## 2. New installation

Set `EXTERNAL_DATABASE_URL` in `config.sh` before `scripts/init-environment.sh`. The script writes the URL into
`configs/api.env`, creates `docker-compose.override.yml`, and creates neither `configs/api_db.env` nor
`volumes/api/postgresql/`. Continue with the installation guide of the manual.

## 3. Rehearsal (existing installation)

Before the switch, copy the database once while the controller runs normally. This checks the network access, TLS,
`unaccent` and the copy itself, and measures how long the copy takes: the switch takes that long, plus a few
minutes.

```
git rev-parse HEAD                              # note the current commit
git pull
time ./scripts/move-local-db-to-remote.sh       # asks for the URL
./scripts/move-local-db-to-remote.sh --empty-target
git checkout <commit noted above>
```

**Do not run `docker compose up -d` while the new version is checked out.** On an installation still on
PostgreSQL 14, it would start `api_db` on an empty PostgreSQL 18 database. The script only reads the running
`api_db`, or the PostgreSQL 14 data in `volumes/api/postgres/` if `api_db` was stopped or recreated on an empty
database.

The api keeps writing during the rehearsal, so the row counts at the end may differ for some tables: that is
expected. `--empty-target` asks you to type the database name, then empties schema `public` of the external
database. `unaccent` is kept.

## 4. Switch an existing installation

The controller is in maintenance mode during the switch.

### 4.1 Before you start

1. Check the Docker Compose version: `docker compose version` (2.40.3 or later).
2. Take a backup: `scripts/backup.sh`.
3. Note the current commit, to roll back: `git rev-parse HEAD`.
4. Turn maintenance mode on, **before** `git pull`: set `MAINTENANCE_ON=true` in `configs/proxy.env`,
   `configs/front.env` and `configs/api.env`, then `docker compose up -d`. See the maintenance mode page of the
   manual.

### 4.2 Copy the database

```
git pull
./scripts/check-config-drift.sh
docker compose stop api celery beat
./scripts/move-local-db-to-remote.sh
```

The copy must end with `Same row counts in all ... tables.` If it fails, the external database is left empty:
fix the cause and run it again, or roll back.

### 4.3 Switch the configuration

1. Stop the built-in database: `docker compose stop api_db`. `docker compose up -d` does not stop an `api_db`
   container that is already running.
2. Keep a copy of the current configuration, for a rollback: `cp configs/api.env configs/api.env.builtin`.
3. In `configs/api.env`, set `DATABASE_URL`, with `sslmode=require`:

   ```
   DATABASE_URL=postgresql://sentinelc:PASSWORD@HOST:PORT/api?sslmode=require
   ```

   Leave `DATABASE_SSL_REQUIRE=False`: `True` would replace the `sslmode` of the URL.
4. In `config.sh`, set `EXTERNAL_DATABASE_URL` to the same URL. `check-config-drift.sh` compares them, and reports
   a `DATABASE_URL` without `sslmode`.
5. Disable `api_db`:

   ```
   cp templates/compose/external-database.override.yml docker-compose.override.yml
   ```

### 4.4 Start and verify

```
docker compose pull
docker compose up -d
./scripts/wait-for-migrations.sh
./scripts/check-config-drift.sh
```

`docker compose ps` must not list `api_db`. `check-config-drift.sh` must report nothing but `MAINTENANCE_ON` in the
three files of maintenance mode.

Set the `maintenance_pass` cookie in your browser (see the maintenance mode page of the manual), then check:

- `https://api.<domain>/health/` reports no error, and the `db` check shows version 18.
- The admin console works: log in, open the Appliances and Locations lists.

Turn maintenance mode off: `MAINTENANCE_ON=false` in the three files, then `docker compose up -d`.

Take a backup in the new mode, to check it works: `scripts/backup.sh`.

## Rolling back

The built-in database is not modified by the switch: `volumes/api/postgres/` (PostgreSQL 14) or
`volumes/api/postgresql/` (PostgreSQL 18) is left as is. Until maintenance mode is turned off, nothing is lost:

```
docker compose down
rm docker-compose.override.yml
cp configs/api.env.builtin configs/api.env
git checkout <commit noted in 4.1>           # only if the installation was on PostgreSQL 14
docker compose up -d
```

Set `EXTERNAL_DATABASE_URL=""` back in `config.sh`. The controller is back on the built-in database with its
data. Before the next attempt, go back to `main` with `git checkout main` if you checked out the old commit (do
not run `docker compose up -d` then), and empty the external database with
`scripts/move-local-db-to-remote.sh --empty-target`.

After maintenance mode is turned off, the changes made in the external database are not in the built-in one:
rolling back loses them.

## Backups and restore

- `scripts/backup.sh` dumps the external database with a temporary PostgreSQL client container. The archive has
  the same format as in built-in mode. Also enable the backups of your database provider.
- `scripts/restore.sh` restores into the external database of the installation, including a backup made in
  built-in mode. It checks the connection and `unaccent` first. If schema `public` is not empty, it asks you to
  type the database name. The restore runs in one transaction: if it fails, the database is left as it was. It
  keeps `volumes/api/postgres*`.
- A built-in installation cannot restore a backup made in external mode.

## Cleaning up

Once the external database is validated, delete the built-in database: the stopped `api_db` container
(`docker ps -a`, then `docker rm`), `volumes/api/postgres/`, `volumes/api/postgresql/`, `configs/api_db.env` and
`configs/api.env.builtin`. You can no longer roll back after this.
