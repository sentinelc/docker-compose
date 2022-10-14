#!/usr/bin/env bash

# wait for django migrations to auto-apply after docker-compose up

max_retry=30
counter=0
until docker-compose exec -T api ./manage.py migrate --check
do
   [[ counter -eq $max_retry ]] && echo "Failed!" && exit 1
   echo "Trying again. Try #$counter"
   ((counter++))
   sleep 10
done
