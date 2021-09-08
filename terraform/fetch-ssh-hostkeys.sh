#!/usr/bin/env bash

# There does not seem to be a way with DigitalOcean/terraform to get the
# ssh host keys of the new droplet. This script waits for the ssh service
# to be up and running and downloads the host keys. We assume an attacker
# is not man-in-the-middle already right after droplet creation.

max_retry=30
counter=0
until ssh-keyscan "$1" > ../credentials/droplet-ssh-hostkeys
do
   [[ counter -eq $max_retry ]] && echo "Failed!" && exit 1
   echo "Trying again. Try #$counter"
   ((counter++))
   sleep 10
done
