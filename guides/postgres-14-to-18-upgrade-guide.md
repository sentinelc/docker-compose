# Upgrading the api database from PostgreSQL 14 to 18

This guide is for installations deployed with the `docker-compose` project, before they start the first version
that uses PostgreSQL 18. PostgreSQL 14 reaches its end of life on 2026-11-12.

PostgreSQL 18 cannot read the data directory of PostgreSQL 14: the data is migrated once, by dump and restore,
with `scripts/migrate-postgres-18.sh`. The controller is in maintenance mode during the migration. The dump takes
about as long as `scripts/backup.sh`; the restore takes longer, as it rebuilds every index.

The new data lives in `volumes/api/postgresql/` (mounted at `/var/lib/postgresql`, as the PostgreSQL 18 image
requires). The PostgreSQL 14 data in `volumes/api/postgres/` is left as is, for rollback.

**Do not run `docker compose up -d` between `git pull` and the migration script.** It would start PostgreSQL 18
on an empty database, and the api would start as a new, empty controller. Your data would still be in
`volumes/api/postgres/`: see "If you started the new version by mistake" below.

## 1. Before you start

1. Check the free disk space: the migration needs about twice the size of `volumes/api/postgres/`
   (`du -sh volumes/api/postgres`).
2. Take a backup: `scripts/backup.sh`.
3. Note the current commit, to roll back: `git rev-parse HEAD`.
4. Turn maintenance mode on, **before** `git pull`: set `MAINTENANCE_ON=true` in `configs/proxy.env`,
   `configs/front.env` and `configs/api.env`, then `docker compose up -d`. See the maintenance mode page of the
   manual.

## 2. Update the project and migrate

```
git pull
./scripts/check-config-drift.sh
./scripts/migrate-postgres-18.sh
```

Run the migration script as root. It:

1. checks that maintenance mode is on and that `volumes/api/postgres/` holds PostgreSQL 14 data;
2. stops `api`, `celery`, `beat` and `api_db`;
3. dumps the database with PostgreSQL 14 into `backups/api_db-pg14-<date>.pgdump`;
4. creates the PostgreSQL 18 database in `volumes/api/postgresql/`;
5. restores the dump and updates the planner statistics;
6. compares the row count of every table before and after.

It stops at the first error. Maintenance mode is still on when it ends.

If you changed `postgresql.conf` or `pg_hba.conf` in `volumes/api/postgres/`, apply the same changes in
`volumes/api/postgresql/18/docker/`: a dump does not carry them.

## 3. Start and verify

```
docker compose pull
docker compose up -d
scripts/wait-for-migrations.sh
```

Set the `maintenance_pass` cookie in your browser (see the maintenance mode page of the manual), then check:

- `https://api.<domain>/health/` reports no error, and the `db` check shows version 18.
- The admin console works: log in, open the Appliances and Locations lists.

Turn maintenance mode off: `MAINTENANCE_ON=false` in the three files, then `docker compose up -d`.

## Rolling back

Until maintenance mode is turned off, nothing is lost:

```
docker compose down
git checkout <commit noted in step 1>
rm -rf volumes/api/postgresql
docker compose up -d
```

The controller is back on PostgreSQL 14 with its data. Go back to `main` with `git checkout main` before the next
attempt.

After maintenance mode is turned off, the changes made on PostgreSQL 18 are not in `volumes/api/postgres/`:
rolling back loses them.

## If you started the new version by mistake

If `docker compose up -d` ran after `git pull` and before the migration, the controller runs on an empty
PostgreSQL 18 database. Turn maintenance mode on (`MAINTENANCE_ON=true` in the three files, then
`docker compose up -d --no-deps proxy front api`), and:

```
docker compose stop api celery beat api_db
rm -rf volumes/api/postgresql
./scripts/migrate-postgres-18.sh
```

Changes made on the empty controller in the meantime are lost.

## Cleaning up

Once the new version is validated, delete `volumes/api/postgres/` and `backups/api_db-pg14-*`.
