#!/usr/bin/env bash

set -e

# when using the command=... directive in the authorized_keys file, we cannot
# pass arguments, so we send our input through stdin and use read to expose them
# as variables
read ARG1 ARG2 ARG3

if [ "$ARG1" = "deploy" ] && [ "$ARG2" = "web" ]; then
  echo "Deploying Unipept Web Application $ARG3 to web VM."
  /home/unipept/unipept-utilities/scripts/deploy/deploy-web.sh "$ARG3"
else
  echo "Error: unknown args $ARG1 $ARG2 $ARG3."
  exit 1
fi
