#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
DEWA_IMAGE=${DEWA_IMAGE:-registry.bercalab.my.id/chatbot/open-webui:v0.13.3-dewa1}
BASE_IMAGE=${BASE_IMAGE:-ghcr.io/open-webui/open-webui:v0.13.3}
docker build --pull=false \
    --build-arg "BASE_IMAGE=$BASE_IMAGE" \
    --file "$ROOT/branding/Dockerfile" \
    --tag "$DEWA_IMAGE" "$ROOT"
printf 'Built %s\n' "$DEWA_IMAGE"
