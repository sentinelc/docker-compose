# SentinelC cloud controller for docker-compose

This project contains the support files to operate the SentinelC cloud-controller using docker-compose.

Please refer to https://sentinelc.com/docs/controller/intro/ for complete instructions.

## Requirements

Docker Compose 2.40.3 or later (the `docker-compose-v2` package of Ubuntu 24.04).

## External database

To use an external PostgreSQL database (for example a managed one) instead of the built-in `api_db` service, set
`EXTERNAL_DATABASE_URL` in `config.sh` before running `scripts/init-environment.sh`.
