#!/usr/bin/env bash

if command -v docker-compose &> /dev/null; then
    COMPOSE_COMMAND="docker-compose"
elif command -v docker &> /dev/null; then
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


# wait for django migrations to auto-apply after docker-compose up

max_retry=30
counter=0
until $COMPOSE_COMMAND exec -T api ./manage.py migrate --check
do
   [[ counter -eq $max_retry ]] && echo "Failed!" && exit 1
   echo "Trying again. Try #$counter"
   ((counter++))
   sleep 10
done
