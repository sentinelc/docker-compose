#!/usr/bin/env bash

# Check if docker-compose is installed
if command -v docker-compose &> /dev/null; then
    COMPOSE_COMMAND="docker-compose"
elif command -v docker &> /dev/null; then
    # Check if docker compose is available as a separate command
    if docker compose --help &> /dev/null; then
        COMPOSE_COMMAND="docker compose"
    else
        echo "Error: docker-compose or docker compose not found. Please make sure Docker and docker-compose are installed." >&2
        exit 1
    fi
else
    echo "Error: Docker not found. Please make sure Docker is installed." >&2
    exit 1
fi


cd "$(dirname "$0")"/..

BACKUP_FILE=./backups/$1

echo "Restoring.."
if [ -f $BACKUP_FILE ]; then
        echo "- Stopping and deconfiguring all running containers.."
        $COMPOSE_COMMAND down -v

        echo "- Deleting configs/ & volumes/"
        rm -rf configs/ volumes/

        echo "- Extracting your backup file: $1"
        tar -xvpf $BACKUP_FILE

        echo "- Restoring postgresql databases"
        $COMPOSE_COMMAND up -d api_db keycloak_db
        sleep 5

        #Wait to be up and ready..
        max_retry=30
        counter=0

        until $COMPOSE_COMMAND exec api_db bash -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB -c 'SELECT 1'"
        do
                [[ counter -eq $max_retry ]] && echo "Failed!" && exit 1
                echo "Trying again. Try #$counter"
                ((counter++))
                sleep 2
        done

        $COMPOSE_COMMAND exec -T api_db bash -c "pg_restore -Fc -U \$POSTGRES_USER -d \$POSTGRES_DB" < data/api_db.pgdump
        $COMPOSE_COMMAND exec -T keycloak_db bash -c "pg_restore -Fc -U \$POSTGRES_USER -d \$POSTGRES_DB" < data/keycloak_db.pgdump

        echo "- Deleting temporary pgdump files."
        rm -rf data/

        echo "- Restarting all containers.."
        $COMPOSE_COMMAND up -d
        echo ""
        echo "Restore complete."

        echo "Applications are currently starting with the restored data. This can take a few minutes."
        echo "Check the logs and health status page to monitor application startup."

else
        echo "No backup file was supplied as an argument"
        echo "Choose one of the following:"
        for FILE in ./backups/*; do echo  "${FILE##*/}"; done
        echo ""
fi
