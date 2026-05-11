#!/bin/bash
# Export a GCP image and upload it to Cloudflare R2 — direct path, no Daisy.
#
# Architecture:
#   local                 publisher VM (n2-standard-8 + pd-ssd)         R2
#   -----                 -----------------------------------------     ---
#   create disk-from-image
#   create publisher VM with src disk attached read-only
#   ssh, run        ────►  dd /dev/<src> → /var/tmp/disk.raw on pd-ssd
#                          tar - disk.raw | pigz -p 8 |
#                          tee >(sha256sum) | aws s3 cp - ──────────► r2 bucket
#                          metadata.json (sidecar) ───────────────────► r2 bucket
#   delete VM + disk ◄──── self-cleanup via trap
#
# Why no Daisy:
#   - Daisy uses single-threaded gzip on a small worker VM. The v2
#     publish (2026-05-07) took 4h 32m end-to-end vs. ~30-40 min here.
#   - Daisy's gcsfuse buffering produces confusing "where's my data"
#     intermediate states.
#   - One less moving part — we control the worker, the compression,
#     and the streaming pipeline directly.
#
# Why this pipeline (tar | pigz | tee>(sha) | aws s3 cp):
#   - Single read of the local disk.raw — no separate "compute SHA"
#     pass that re-reads the whole file. The v2 publish lost ~75 min
#     to a single-threaded sha256sum on a slow boot disk.
#   - pigz parallelizes compression across all CPUs (~8x speedup on
#     n2-standard-8 vs. single-threaded gzip).
#   - aws CLI v2 with bumped multipart concurrency for ~5x faster
#     upload than the apt-installed v1.
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
#   PUBLISHER_MACHINE    — default: n2-standard-8
#   KEEP_PUBLISHER       — set to 1 to skip VM/disk cleanup (for debugging)

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
PUBLISHER_MACHINE=${PUBLISHER_MACHINE:-n2-standard-8}
PUBLISHER="costanza-publisher-$(date +%s)"
SRC_DISK="${PUBLISHER}-src"

echo "═══ Publishing $IMG via $PUBLISHER ═══"
echo "  GCP project:    $GCP_PROJECT"
echo "  Publisher zone: $GCP_ZONE"
echo "  Publisher VM:   $PUBLISHER_MACHINE + 200GB pd-ssd"
echo "  R2 bucket:      $R2_BUCKET"
echo "  Public URL:     $R2_PUBLIC_BASE/$IMG/disk.tar.gz"
echo ""

cleanup() {
    if [ "${KEEP_PUBLISHER:-0}" = "1" ]; then
        echo "→ KEEP_PUBLISHER=1, leaving VM $PUBLISHER + disk $SRC_DISK alive (delete manually)"
        return
    fi
    echo ""
    echo "→ Cleaning up..."
    gcloud compute instances delete "$PUBLISHER" \
        --zone="$GCP_ZONE" --project="$GCP_PROJECT" --quiet 2>/dev/null || true
    gcloud compute disks delete "$SRC_DISK" \
        --zone="$GCP_ZONE" --project="$GCP_PROJECT" --quiet 2>/dev/null || true
}
trap cleanup EXIT

# Verify source image exists before spending time on VM creation.
if ! gcloud compute images describe "$IMG" --project="$GCP_PROJECT" --quiet >/dev/null 2>&1; then
    echo "ERROR: Source image '$IMG' not found in project '$GCP_PROJECT'." >&2
    exit 1
fi

# Create source disk from the image. This is essentially a snapshot reference
# for the disk we'll attach read-only to the publisher VM.
#
# pd-ssd matters here: dd-ing the disk to local pd-ssd is read-bound on the
# source. v3 publish used the default (pd-balanced) and dd took 1h 40m at
# ~13-27 MB/s; pd-ssd gets 250+ MB/s sustained read, dropping that to ~7 min.
echo "→ Creating source disk from image ($SRC_DISK)..."
gcloud compute disks create "$SRC_DISK" \
    --image="$IMG" \
    --zone="$GCP_ZONE" \
    --type=pd-ssd \
    --project="$GCP_PROJECT" \
    --quiet >/dev/null

# Create the publisher VM:
#  - n2-standard-8 (default): dedicated CPUs, no e2-family burst throttling
#  - pd-ssd 200GB boot disk: ~3x the read throughput of pd-balanced; matters
#    for the dd/tar pass that touches every byte of the 100GB disk image
#  - source disk attached read-only as a non-boot disk
echo "→ Creating publisher VM ($PUBLISHER)..."
gcloud compute instances create "$PUBLISHER" \
    --zone="$GCP_ZONE" \
    --project="$GCP_PROJECT" \
    --machine-type="$PUBLISHER_MACHINE" \
    --boot-disk-size=200GB \
    --boot-disk-type=pd-ssd \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --scopes=cloud-platform \
    --metadata=enable-oslogin=FALSE \
    --disk="name=$SRC_DISK,mode=ro,boot=no,device-name=src" \
    --quiet >/dev/null

# Wait for SSH (debian boot + first-time SSH key propagation).
echo "→ Waiting for SSH..."
for i in $(seq 1 60); do
    if gcloud compute ssh "$PUBLISHER" --zone="$GCP_ZONE" --project="$GCP_PROJECT" \
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
set -o pipefail

IMG="$1"
source ~/.publish.env

log() { printf "[%s] %s\n" "$(date -u +%H:%M:%S)" "$*"; }

# ─── Install pigz + awscli v2 ────────────────────────────────────────
# awscli v1 from Debian apt has poor multipart concurrency defaults
# (~10 MB/s upload throughput observed in practice). awscli v2 with
# explicit concurrency tuning gets us closer to network line rate.
log "Installing pigz + awscli v2..."
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq pigz unzip curl >/dev/null
cd /tmp
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscli.zip 2>/dev/null
unzip -oq awscli.zip
sudo ./aws/install --update >/dev/null 2>&1
rm -rf /tmp/aws /tmp/awscli.zip
AWS=$(command -v aws)
log "  $($AWS --version)"

# Bump aws CLI multipart concurrency. Defaults are 10 / 8MB which leaves
# bandwidth on the table on n2-standard-8 (which has ~16 Gbps egress).
$AWS configure set default.s3.max_concurrent_requests 50
$AWS configure set default.s3.multipart_chunksize 64MB

# ─── Identify source disk ────────────────────────────────────────────
# We attached the source disk with device-name=src, so it shows up under
# /dev/disk/by-id/google-src on the VM.
SRC=$(readlink -f /dev/disk/by-id/google-src)
SIZE_BYTES=$(sudo blockdev --getsize64 "$SRC")
log "Source disk: $SRC (${SIZE_BYTES} bytes)"

# ─── Dump source disk to local pd-ssd ────────────────────────────────
# We can't pipe straight from /dev/sd? to tar (tar wants a regular file
# to record metadata). The intermediate disk.raw lives on pd-ssd which
# is fast enough that this isn't a bottleneck (~5-7 min for 100GB).
log "Dumping source disk to local /var/tmp/disk.raw..."
sudo dd if="$SRC" of=/var/tmp/disk.raw bs=4M status=none
sudo chmod 644 /var/tmp/disk.raw
log "  Done ($(stat -c%s /var/tmp/disk.raw) bytes)"

# ─── Stream: tar | pigz | tee >(sha256sum) | aws s3 cp ───────────────
# Single read of disk.raw drives three consumers in parallel:
#   1. pigz parallel-gzips the tar stream across all CPUs
#   2. tee duplicates the gzipped stream to sha256sum AND aws s3 cp
#   3. aws does the multipart upload to R2 directly
# Total wall-time = max(disk read, pigz CPU, network upload), not sum.
log "Compressing + hashing + uploading in single pass..."
SHA_FILE=$(mktemp)

# tar with --transform isn't strictly needed here — the disk.raw inside
# the tarball will be at the path we cd to. The consumer's `gcloud
# compute images create` extracts disk.raw and uses it as the source.
( cd /var/tmp && tar --create disk.raw ) | \
    pigz -p "$(nproc)" | \
    tee >(sha256sum | awk '{print $1}' > "$SHA_FILE") | \
    AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
    "$AWS" s3 cp - "s3://$R2_BUCKET/$IMG/disk.tar.gz" \
        --endpoint-url="$R2_ENDPOINT" \
        --no-progress

SHA=$(cat "$SHA_FILE")
if [ -z "$SHA" ]; then
    log "ERROR: SHA file empty — pipeline failed somewhere"
    exit 1
fi

# Read final upload size back from R2 to confirm the upload succeeded
# end-to-end (catches multipart commits that didn't finalize).
log "Reading R2 object size for verification..."
SIZE=$(AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
       AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
       "$AWS" s3api head-object \
           --bucket "$R2_BUCKET" --key "$IMG/disk.tar.gz" \
           --endpoint-url="$R2_ENDPOINT" \
           --query 'ContentLength' --output text)
log "  SHA256: $SHA"
log "  Size:   $SIZE bytes"

# ─── Metadata sidecar ────────────────────────────────────────────────
log "Writing metadata sidecar..."
META=/tmp/metadata.json
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
"$AWS" s3 cp "$META" "s3://$R2_BUCKET/$IMG/metadata.json" \
    --endpoint-url="$R2_ENDPOINT" \
    --no-progress

log "═══ Done ═══"
log "URL:    $R2_PUBLIC_BASE/$IMG/disk.tar.gz"
log "SHA256: $SHA"
log "Size:   $SIZE bytes"
REMOTE_EOF

# Build env file the publisher will source. Mode 600 + cleaned up on cleanup().
ENV_FILE=$(mktemp)
chmod 600 "$ENV_FILE"
cat > "$ENV_FILE" <<EOF
R2_ACCESS_KEY_ID='$R2_ACCESS_KEY_ID'
R2_SECRET_ACCESS_KEY='$R2_SECRET_ACCESS_KEY'
R2_ENDPOINT='$R2_ENDPOINT'
R2_BUCKET='$R2_BUCKET'
R2_PUBLIC_BASE='$R2_PUBLIC_BASE'
EOF

trap '{ cleanup; rm -f "$REMOTE_RUNNER" "$ENV_FILE"; }' EXIT

echo "→ Uploading runner + credentials to publisher..."
gcloud compute scp "$REMOTE_RUNNER" "$PUBLISHER:~/run.sh" \
    --zone="$GCP_ZONE" --project="$GCP_PROJECT" --quiet
gcloud compute scp "$ENV_FILE" "$PUBLISHER:~/.publish.env" \
    --zone="$GCP_ZONE" --project="$GCP_PROJECT" --quiet
gcloud compute ssh "$PUBLISHER" --zone="$GCP_ZONE" --project="$GCP_PROJECT" \
    --command="chmod 600 ~/.publish.env ~/run.sh" --quiet

echo "→ Running export + upload on publisher (output streams below)..."
echo ""
gcloud compute ssh "$PUBLISHER" --zone="$GCP_ZONE" --project="$GCP_PROJECT" \
    --command="bash ~/run.sh '$IMG'"

echo ""
echo "═══ Publish complete ═══"
