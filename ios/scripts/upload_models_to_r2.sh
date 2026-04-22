#!/usr/bin/env bash
#
# upload_models_to_r2.sh
# Downloads model files from mlx-community on Hugging Face, verifies
# their SHA-256 against what's pinned in MLXModelSpec.swift, and uploads
# to our Cloudflare R2 bucket at the matching versioned path.
#
# Run once per model we want to host. Re-running on an already-uploaded
# model is a no-op (R2's `--checksum-algorithm SHA256` catches identical
# bytes and skips the transfer). Hash mismatch bails before any upload —
# means the HF repo's content changed since we pinned the manifest; open
# an issue and update MLXModelSpec.swift before re-running.
#
# Usage:
#   ./upload_models_to_r2.sh <model-id>
#   where <model-id> is one of:
#     qwen35_4b              (mlx-community/Qwen3.5-4B-4bit)
#     gemma4_e2b_text        (mlx-community/Gemma4-E2B-IT-Text-int4)
#
# Env:
#   R2_BUCKET              (required)  e.g. "nod-models"
#   R2_ENDPOINT            (required)  e.g. "https://<account>.r2.cloudflarestorage.com"
#   AWS_ACCESS_KEY_ID      (required)  your R2 S3 access key id
#   AWS_SECRET_ACCESS_KEY  (required)  your R2 S3 secret
#
# Reads pinned SHA-256s + file lists from MLXModelSpec.swift via grep so
# the script + the app code stay in lockstep.

set -euo pipefail

MODEL_ID="${1:-}"

case "$MODEL_ID" in
  qwen35_4b)
    HF_REPO="mlx-community/Qwen3.5-4B-4bit"
    R2_PATH="qwen3.5-4b-4bit/v1"
    SWIFT_STATIC="qwen35_4b"
    ;;
  gemma4_e2b_text)
    HF_REPO="mlx-community/Gemma4-E2B-IT-Text-int4"
    R2_PATH="gemma4-e2b-text-int4/v1"
    SWIFT_STATIC="gemma4_e2b_text"
    ;;
  *)
    echo "Usage: $0 <qwen35_4b|gemma4_e2b_text>" >&2
    exit 1
    ;;
esac

: "${R2_BUCKET:?set R2_BUCKET}"
: "${R2_ENDPOINT:?set R2_ENDPOINT}"
: "${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY}"

# R2 requires the AWS SDK to use region "auto". Without this, if the
# user has a different default region in ~/.aws/config (e.g.
# "ap-south-1") every put-object call fails with "InvalidRegionName".
# Forcing it here beats silently inheriting from the user's env.
export AWS_DEFAULT_REGION=auto

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SPEC_FILE="$ROOT_DIR/ios/Nod/Inference/MLXModelSpec.swift"
WORK_DIR="$(mktemp -d)"
trap "rm -rf $WORK_DIR" EXIT

echo "Model: $MODEL_ID ($HF_REPO)"
echo "R2 path: $R2_BUCKET/$R2_PATH/"
echo "Working dir: $WORK_DIR"
echo ""

# Extract pinned (name, sha, size) triples for this model from the
# Swift spec file. Using Python (not awk) because macOS ships BSD awk,
# which doesn't support 3-arg match() for array capture.
pinned_manifest=$(
  python3 - "$SPEC_FILE" "$SWIFT_STATIC" <<'PY'
import re, sys
path, target = sys.argv[1], sys.argv[2]
src = open(path).read()
# Find the `static let <target> = MLXModelSpec(` block up to the
# closing `)` of that constructor. Swift's indentation (matching `    )`
# at line start) delimits the block.
pat = re.compile(
    r"static let " + re.escape(target) + r" = MLXModelSpec\(.*?\n    \)",
    re.S
)
m = pat.search(src)
if not m:
    sys.exit(f"couldn't find MLXModelSpec block for {target}")
block = m.group(0)
# Each FileSpec entry spans multiple lines. Collapse whitespace so one
# regex per entry pulls name/sha/size.
flat = re.sub(r"\s+", " ", block)
entry = re.compile(
    r'\.init\(name:\s*"([^"]+)"\s*,\s*sha256:\s*"([^"]+)"\s*,\s*size:\s*([0-9_]+)'
)
for name, sha, size in entry.findall(flat):
    print(f"{name}\t{sha}\t{size.replace('_', '')}")
PY
)

if [ -z "$pinned_manifest" ]; then
  echo "ERROR: couldn't parse manifest for $SWIFT_STATIC from $SPEC_FILE" >&2
  exit 1
fi

echo "Pinned manifest:"
echo "$pinned_manifest" | column -t -s $'\t'
echo ""

# Download each file from HF, verify hash, then upload to R2.
mkdir -p "$WORK_DIR/$MODEL_ID"
while IFS=$'\t' read -r name expected_sha expected_size; do
  [ -z "$name" ] && continue
  local_path="$WORK_DIR/$MODEL_ID/$name"

  echo "→ $name"
  echo "  fetching from hf..."
  curl -sfL "https://huggingface.co/$HF_REPO/resolve/main/$name" -o "$local_path"

  actual_size=$(stat -f%z "$local_path" 2>/dev/null || stat -c%s "$local_path")
  actual_sha=$(shasum -a 256 "$local_path" | awk '{print $1}')

  if [ "$actual_size" != "$expected_size" ]; then
    echo "  SIZE MISMATCH: got $actual_size, expected $expected_size" >&2
    exit 1
  fi
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "  SHA MISMATCH: got $actual_sha, expected $expected_sha" >&2
    echo "  The HF source has changed since MLXModelSpec was pinned." >&2
    echo "  Fix: run scripts/hash_models.sh and update MLXModelSpec.swift." >&2
    exit 1
  fi
  echo "  verified ($actual_size bytes)"

  echo "  uploading to r2..."
  aws s3 cp \
    --endpoint-url "$R2_ENDPOINT" \
    --checksum-algorithm SHA256 \
    "$local_path" \
    "s3://$R2_BUCKET/$R2_PATH/$name"
  echo "  done"
  echo ""
done <<< "$pinned_manifest"

echo "All files uploaded to s3://$R2_BUCKET/$R2_PATH/"
echo ""
echo "Verify with:"
echo "  curl -sI https://pub-6cf269f2cf044828b0b016d58295da25.r2.dev/$R2_PATH/model.safetensors"
