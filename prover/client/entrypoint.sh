#!/bin/bash
set -e

# Activate the GCP service account for the gcloud CLI.
# GOOGLE_APPLICATION_CREDENTIALS is used by Python client libraries,
# but gcloud CLI has its own credential store and needs explicit activation.
if [ -n "$GOOGLE_APPLICATION_CREDENTIALS" ] && [ -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
    gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS" --quiet
fi

exec python -m prover.client "$@"
