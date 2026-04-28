#!/bin/bash
# Import a Costanza TEE image from the project's public R2 bucket into your
# own GCP project. After import, run verify_measurements.py to confirm the
# imported image's RTMR measurements match the platform key registered
# on-chain — that's the actual "is this the same image" check.
#
# Usage:
#   bash import_image.sh <image-name>
#
# Example:
#   bash import_image.sh costanza-tdx-prover-v2
#
# Required env:
#   GCP_PROJECT          — your GCP project ID (where the image will land)
#   GCP_STAGING_BUCKET   — gs:// bucket in your project for staging the
#                          tarball before image creation. Must already exist.
#
# Optional env:
#   PUBLIC_BASE          — default: https://images.thehumanfund.com
#                          override if running off a different mirror
#   KEEP_STAGING         — set to 1 to leave the staged tarball in GCS
#                          (default: deleted after image is created)
#
# Cost on the consumer side:
#   - R2 download: free (Cloudflare egress is $0)
#   - GCS storage during staging: ~$0.02 if KEEP_STAGING=0 (script deletes)
#   - Image storage in your project: $0.05/GB/mo (~$3/mo for a 60GB image)
#   - Inference VM cost is separate — see prover/README.md for cost notes

set -euo pipefail

IMG=${1:-}
if [ -z "$IMG" ]; then
    echo "Usage: $0 <image-name>" >&2
    echo "  example: $0 costanza-tdx-prover-v2" >&2
    exit 1
fi

: "${GCP_PROJECT:?Set GCP_PROJECT to your project ID}"
: "${GCP_STAGING_BUCKET:?Set GCP_STAGING_BUCKET to a gs:// bucket in your project}"
PUBLIC_BASE=${PUBLIC_BASE:-https://images.thehumanfund.com}

command -v curl >/dev/null || { echo "ERROR: curl not on PATH" >&2; exit 1; }
command -v gcloud >/dev/null || { echo "ERROR: gcloud not on PATH" >&2; exit 1; }
command -v gsutil >/dev/null || { echo "ERROR: gsutil not on PATH" >&2; exit 1; }
command -v shasum >/dev/null || { echo "ERROR: shasum not on PATH" >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 not on PATH" >&2; exit 1; }

echo "═══ Importing $IMG from $PUBLIC_BASE ═══"
echo "  Project:  $GCP_PROJECT"
echo "  Staging:  $GCP_STAGING_BUCKET/$IMG/"
echo ""

# 0. Verify the GCS staging bucket exists
if ! gsutil ls "$GCP_STAGING_BUCKET" >/dev/null 2>&1; then
    echo "ERROR: $GCP_STAGING_BUCKET does not exist or is not accessible" >&2
    echo "  Create one with: gsutil mb -l us-central1 -p $GCP_PROJECT $GCP_STAGING_BUCKET" >&2
    exit 1
fi

# 1. Verify the image isn't already in your project
if gcloud compute images describe "$IMG" --project="$GCP_PROJECT" >/dev/null 2>&1; then
    echo "Image $IMG already exists in $GCP_PROJECT — nothing to do."
    echo "Delete it first if you want to re-import: gcloud compute images delete $IMG --project=$GCP_PROJECT"
    exit 0
fi

WORKDIR=$(mktemp -d -t costanza-import.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT
LOCAL_TAR="$WORKDIR/disk.tar.gz"
LOCAL_META="$WORKDIR/metadata.json"

# 2. Fetch the metadata sidecar (small JSON — sha256, size, exported_at)
echo "→ Fetching metadata from $PUBLIC_BASE/$IMG/metadata.json..."
if ! curl -fsSL "$PUBLIC_BASE/$IMG/metadata.json" -o "$LOCAL_META"; then
    echo "ERROR: metadata not found — check the image name and PUBLIC_BASE" >&2
    exit 1
fi
EXPECTED_SHA=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['sha256'])" "$LOCAL_META")
EXPECTED_SIZE=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['size_bytes'])" "$LOCAL_META")
echo "  Expected SHA256: $EXPECTED_SHA"
echo "  Expected size:   $EXPECTED_SIZE bytes (~$((EXPECTED_SIZE / 1024 / 1024 / 1024)) GB)"

# 3. Download the tarball from R2 (free egress)
echo "→ Downloading tarball from R2 (free)..."
curl -fSL "$PUBLIC_BASE/$IMG/disk.tar.gz" -o "$LOCAL_TAR"

# 4. Verify the SHA256 before doing anything irreversible
echo "→ Verifying SHA256..."
ACTUAL_SHA=$(shasum -a 256 "$LOCAL_TAR" | awk '{print $1}')
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    echo "ERROR: SHA256 mismatch" >&2
    echo "  expected: $EXPECTED_SHA" >&2
    echo "  actual:   $ACTUAL_SHA" >&2
    echo "Either the upload is corrupt or the metadata is from a different version." >&2
    exit 1
fi
ACTUAL_SIZE=$(wc -c < "$LOCAL_TAR" | tr -d ' ')
if [ "$ACTUAL_SIZE" != "$EXPECTED_SIZE" ]; then
    echo "ERROR: size mismatch ($ACTUAL_SIZE vs $EXPECTED_SIZE)" >&2
    exit 1
fi
echo "  ✓ SHA256 + size match"

# 5. Upload to your GCS staging bucket
GCS_TAR="$GCP_STAGING_BUCKET/$IMG/disk.tar.gz"
echo "→ Uploading to $GCS_TAR..."
gsutil cp "$LOCAL_TAR" "$GCS_TAR"

# 6. Create the GCP image from the tarball
echo "→ Creating image $IMG in $GCP_PROJECT..."
gcloud compute images create "$IMG" \
    --source-uri="$GCS_TAR" \
    --guest-os-features=UEFI_COMPATIBLE \
    --project="$GCP_PROJECT"

# 7. Optionally clean up GCS staging
if [ "${KEEP_STAGING:-0}" != "1" ]; then
    echo "→ Removing staging copy from GCS..."
    gsutil rm "$GCS_TAR"
fi

echo ""
echo "═══ Imported ═══"
echo "  Image: $IMG"
echo ""
echo "Now verify it matches the on-chain platform key — this boots a temporary"
echo "TDX VM and reads RTMR values from the serial console:"
echo ""
echo "  python prover/scripts/gcp/verify_measurements.py \\"
echo "    --image $IMG \\"
echo "    --verifier <TdxVerifier-address> \\"
echo "    --rpc-url <Base RPC URL>"
echo ""
echo "If the platform key matches, you can run as a prover with this image."
echo "If it doesn't match, the publisher has rotated images — re-import the"
echo "current one or build from source."
