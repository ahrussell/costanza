FROM python:3.11-slim

# Install gcloud CLI (needed for GCP TEE VM management)
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl gnupg apt-transport-https ca-certificates \
    && echo "deb https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update && apt-get install -y --no-install-recommends google-cloud-cli \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python dependencies
COPY prover/client/requirements.txt /app/prover/client/requirements.txt
RUN pip install --no-cache-dir -r prover/client/requirements.txt

# Copy prover code, system prompt, and compiled ABIs
COPY prover/ /app/prover/
COPY out/TheHumanFund.sol/ /app/out/TheHumanFund.sol/
COPY out/AuctionManager.sol/ /app/out/AuctionManager.sol/
COPY out/InvestmentManager.sol/ /app/out/InvestmentManager.sol/
COPY out/WorldView.sol/ /app/out/WorldView.sol/

ENTRYPOINT ["python", "-m", "prover.client"]
