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

max_retry=10
counter=0

until $COMPOSE_COMMAND exec -T api ./manage.py migrate --check
do
   ((counter++))
   echo "Attempt #$counter failed."
   if [[ $counter -eq $max_retry ]]; then
       echo "Giving up. Check docker logs for errors or relaunch this command to continue waiting."
       exit 1
   fi
   echo "Trying again in 10 seconds..."
   sleep 10
done

echo "SUCCESS: Database is initialized. You can continue with the installation process."
