#!/usr/bin/env bash

set -euo pipefail
set +x

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${RELEASE_PAYLOAD_KEY:?RELEASE_PAYLOAD_KEY is required}"

payload="$RUNNER_TEMP/release-payload"
archive="$RUNNER_TEMP/release-payload.tar.gz"

cleanup() {
  rm -f -- "$archive"
}
trap cleanup EXIT

openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -pass env:RELEASE_PAYLOAD_KEY \
  -in tool/release_payload.enc \
  -out "$archive"
python3 tool/restore_release_payload.py "$archive" "$payload"
python3 tool/apply_release_overlay.py \
  --root . \
  --manifest "$payload/manifest.json" \
  --icon "$payload/icon-master.png" \
  --github-env "$GITHUB_ENV"
python3 tool/generate_branding_assets.py
