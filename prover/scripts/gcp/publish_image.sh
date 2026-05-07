#!/bin/bash
# Export a GCP image and upload it to Cloudflare R2, using a temporary
# GCE worker VM as the relay. The 60GB tarball never touches your laptop.
#
# Architecture:
#   local                   GCE worker (us-central1)              R2
#   -----                   ----------------------                ---
#   create VM      ────►    boot, install awscli
#   ssh, run        ────►   gcloud images export ──► gs://staging
#                            gsutil cp ──► local disk
#                            sha256
#                            aws s3 cp ──────────────────────► r2 bucket
#                            gsutil rm staging
#   delete VM      ────►    terminate
#
# Why GCE relay:
#   - GCS staging bucket stays private (worker SA reads it)
#   - GCS → GCE is intra-region, free
#   - GCE → R2 internet egress (~$7 per 60GB image) is unavoidable but
#     happens on GCP's outbound, not your home connection
#   - Your local terminal stays available; nothing big touches local disk
#
# Usage:
#   bash prover/scripts/gcp/publish_image.sh <image-name>
#
# Required env (source .env.publish):
#   R2_ACCESS_KEY_ID
#   R2_SECRET_ACCESS_KEY
#   R2_ENDPOINT          — https://<accountid>.r2.cloudflarestorage.com
#   R2_BUCKET            — e.g. costanza-public-images
#   R2_PUBLIC_BASE       — public URL base for the R2 bucket
#
# Optional env:
#   GCP_PROJECT          — default: the-human-fund
#   GCP_ZONE             — default: us-central1-a
#   GCS_TEMP_BUCKET      — default: gs://costanza-image-export-tmp
#   KEEP_WORKER          — set to 1 to skip VM deletion (for debugging)

set -euo pipefail

IMG=${1:-}
if [ -z "$IMG" ]; then
    echo "Usage: $0 <image-name>" >&2
    exit 1
fi

: "${R2_ACCESS_KEY_ID:?source .env.publish}"
: "${R2_SECRET_ACCESS_KEY:?source .env.publish}"
: "${R2_ENDPOINT:?source .env.publish}"
: "${R2_BUCKET:?source .env.publish}"
: "${R2_PUBLIC_BASE:?source .env.publish}"

GCP_PROJECT=${GCP_PROJECT:-the-human-fund}
GCP_ZONE=${GCP_ZONE:-us-central1-a}
GCS_TEMP_BUCKET=${GCS_TEMP_BUCKET:-gs://costanza-image-export-tmp}
WORKER="costanza-publish-$(date +%s)"
REGION="${GCP_ZONE%-*}"

echo "═══ Publishing $IMG via GCE worker $WORKER ═══"
echo "  GCP project:    $GCP_PROJECT"
echo "  Worker zone:    $GCP_ZONE"
echo "  GCS staging:    $GCS_TEMP_BUCKET (private)"
echo "  R2 bucket:      $R2_BUCKET"
echo "  Public URL:     $R2_PUBLIC_BASE/$IMG/disk.tar.gz"
echo ""

cleanup() {
    if [ "${KEEP_WORKER:-0}" = "1" ]; then
        echo "→ KEEP_WORKER=1, leaving VM $WORKER alive (delete manually)"
        return
    fi
    echo "→ Deleting worker VM $WORKER..."
    gcloud compute instances delete "$WORKER" \
        --zone="$GCP_ZONE" --project="$GCP_PROJECT" --quiet 2>/dev/null || true
}
trap cleanup EXIT

# Ensure GCS staging bucket exists (private)
if ! gsutil ls "$GCS_TEMP_BUCKET" >/dev/null 2>&1; then
    echo "→ Creating private staging bucket $GCS_TEMP_BUCKET..."
    gsutil mb -l "$REGION" -p "$GCP_PROJECT" "$GCS_TEMP_BUCKET"
fi

# Create the worker VM. cloud-platform scope = full SA access including GCS.
echo "→ Creating worker VM ($WORKER)..."
gcloud compute instances create "$WORKER" \
    --zone="$GCP_ZONE" \
    --project="$GCP_PROJECT" \
    --machine-type=e2-standard-4 \
    --boot-disk-size=120GB \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --scopes=cloud-platform \
    --metadata=enable-oslogin=FALSE \
    --quiet >/dev/null

# Wait for SSH to come up (debian boot + first-time SSH key propagation)
echo "→ Waiting for SSH..."
for i in $(seq 1 60); do
    if gcloud compute ssh "$WORKER" --zone="$GCP_ZONE" --project="$GCP_PROJECT" \
        --command="echo ready" --quiet >/dev/null 2>&1; then
        break
    fi
    sleep 5
done

# Build the remote runner. Heredoc → file → SCP, so we don't have to escape
# anything when invoking it via SSH.
REMOTE_RUNNER=$(mktemp)
cat > "$REMOTE_RUNNER" <<'REMOTE_EOF'
#!/bin/bash
set -euo pipefail

IMG="$1"

# Required env (passed from controller via env file at ~/.publish.env)
source ~/.publish.env

GCS_TAR="$GCS_TEMP_BUCKET/$IMG/disk.tar.gz"
LOCAL_TAR="/var/tmp/disk.tar.gz"

log() { printf "[%s] %s\n" "$(date -u +%H:%M:%S)" "$*"; }

log "Installing awscli..."
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq awscli >/dev/null

if gsutil -q stat "$GCS_TAR" 2>/dev/null; then
    log "Image already exported to $GCS_TAR (skipping export)"
else
    log "Exporting $IMG → GCS (~30-60 min)..."
    # Pin --zone so Daisy's export worker doesn't auto-pick a busy zone.
    # Without this, Daisy defaults to us-central1-c (or whatever it picks
    # internally), and we hit ZONE_RESOURCE_POOL_EXHAUSTED on busy days.
    # us-central1-a is fine because it's the same zone the publisher VM
    # is in (less network hop) and has historically had headroom.
    gcloud compute images export \
        --image="$IMG" \
        --destination-uri="$GCS_TAR" \
        --project="$GCP_PROJECT" \
        --zone="$GCP_ZONE"
fi

log "Downloading tarball from GCS to local disk..."
gsutil cp "$GCS_TAR" "$LOCAL_TAR"

log "Computing SHA256..."
SHA=$(sha256sum "$LOCAL_TAR" | awk '{print $1}')
SIZE=$(stat -c%s "$LOCAL_TAR")
log "  SHA256: $SHA"
log "  Size:   $SIZE bytes"

log "Uploading tarball to R2..."
AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
aws s3 cp "$LOCAL_TAR" "s3://$R2_BUCKET/$IMG/disk.tar.gz" \
    --endpoint-url="$R2_ENDPOINT" \
    --no-progress

log "Writing metadata sidecar..."
META=/var/tmp/metadata.json
cat > "$META" <<META_EOF
{
  "image": "$IMG",
  "sha256": "$SHA",
  "size_bytes": $SIZE,
  "url": "$R2_PUBLIC_BASE/$IMG/disk.tar.gz",
  "exported_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
META_EOF
AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
aws s3 cp "$META" "s3://$R2_BUCKET/$IMG/metadata.json" \
    --endpoint-url="$R2_ENDPOINT" \
    --no-progress

log "Verifying R2 upload size..."
R2_SIZE=$(AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
    aws s3api head-object \
        --bucket "$R2_BUCKET" --key "$IMG/disk.tar.gz" \
        --endpoint-url="$R2_ENDPOINT" \
        --query 'ContentLength' --output text)
if [ "$R2_SIZE" != "$SIZE" ]; then
    log "ERROR: R2 size $R2_SIZE != local size $SIZE"
    exit 1
fi
log "  ✓ R2 size matches local"

log "Deleting GCS staging copy..."
gsutil rm "$GCS_TAR"

log "═══ Done ═══"
log "URL:    $R2_PUBLIC_BASE/$IMG/disk.tar.gz"
log "SHA256: $SHA"
log "Size:   $SIZE bytes"
REMOTE_EOF

# Build env file the worker will source. Mode 600 + cleaned up on cleanup().
ENV_FILE=$(mktemp)
chmod 600 "$ENV_FILE"
cat > "$ENV_FILE" <<EOF
R2_ACCESS_KEY_ID='$R2_ACCESS_KEY_ID'
R2_SECRET_ACCESS_KEY='$R2_SECRET_ACCESS_KEY'
R2_ENDPOINT='$R2_ENDPOINT'
R2_BUCKET='$R2_BUCKET'
R2_PUBLIC_BASE='$R2_PUBLIC_BASE'
GCP_PROJECT='$GCP_PROJECT'
GCS_TEMP_BUCKET='$GCS_TEMP_BUCKET'
EOF

trap '{ cleanup; rm -f "$REMOTE_RUNNER" "$ENV_FILE"; }' EXIT

echo "→ Uploading runner + credentials to worker..."
gcloud compute scp "$REMOTE_RUNNER" "$WORKER:~/run.sh" \
    --zone="$GCP_ZONE" --project="$GCP_PROJECT" --quiet
gcloud compute scp "$ENV_FILE" "$WORKER:~/.publish.env" \
    --zone="$GCP_ZONE" --project="$GCP_PROJECT" --quiet
gcloud compute ssh "$WORKER" --zone="$GCP_ZONE" --project="$GCP_PROJECT" \
    --command="chmod 600 ~/.publish.env ~/run.sh" --quiet

echo "→ Running export + upload on worker (output streams below)..."
echo ""
gcloud compute ssh "$WORKER" --zone="$GCP_ZONE" --project="$GCP_PROJECT" \
    --command="bash ~/run.sh '$IMG'"

echo ""
echo "═══ Publish complete ═══"
