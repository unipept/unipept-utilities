#!/usr/bin/env bash

set -e

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <version>"
    exit 1
fi

# The GitHub SHA-tag that should be deployed.
sha="$1"

# Clone the Unipept repository in the temp folder (remove old versions of the unipept repository)
cd /tmp && rm -rf unipept
git clone https://github.com/unipept/unipept.git

# Build the Unipept Web application
cd unipept
git checkout "$sha"

# Install the dependencies
npm install

# Consume the application's code and build a ready-to-deploy version of the application.
npm run build

# Copy the latest version of the Unipept Web application to the server.
scp -r /tmp/unipept/dist unipept@unipeptweb.ugent.be:/home/unipept/web/dist
