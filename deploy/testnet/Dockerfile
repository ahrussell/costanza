# The Human Fund — Prover Client (testnet, gcp-persistent flow)
#
# Runs the auction prover client locally for testnet, talking to a persistent
# GCP VM for inference. Production deploys use prover/client/Dockerfile instead.
#
# Build from the repo root (the build context must include prover/ + out/):
#   docker build -f deploy/testnet/Dockerfile -t humanfund-prover .
#   docker run --rm \
#     --env-file .env \
#     -v ~/.config/gcloud:/root/.config/gcloud \
#     -v ~/.humanfund:/root/.humanfund \
#     humanfund-prover
#
# Or to pass extra args (e.g. --verbose):
#   docker run --rm --env-file .env \
#     -v ~/.config/gcloud:/root/.config/gcloud \
#     -v ~/.humanfund:/root/.humanfund \
#     humanfund-prover --verbose
#
# Required .env variables:
#   PRIVATE_KEY, RPC_URL, CONTRACT_ADDRESS
#   GCP_PROJECT, GCP_IMAGE, GCP_ZONE
#   TEE_CLIENT=gcp-persistent   (or gcp-gpu for production)
#   VERIFIER_ID=2               (MockVerifier for testnet)
#
# The container includes the full repo so the persistent VM can receive
# enclave code via gcloud scp (SOURCE_DIR is set to /app automatically).

FROM python:3.11-slim

# Install gcloud CLI
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        gnupg \
        apt-transport-https \
        ca-certificates \
        openssh-client \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] \
        https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && apt-get update && apt-get install -y --no-install-recommends google-cloud-cli \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python deps
COPY prover/client/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# Copy the full project (needed so gcloud scp can sync enclave code to the VM)
COPY . .

# SOURCE_DIR tells gcp_persistent.py where to find prover/enclave + prover/prompts
ENV SOURCE_DIR=/app

ENTRYPOINT ["python", "-m", "prover.client"]
