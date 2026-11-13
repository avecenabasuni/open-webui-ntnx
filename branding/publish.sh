#!/usr/bin/env bash
set -euo pipefail
DEWA_IMAGE=${DEWA_IMAGE:-registry.bercalab.my.id/chatbot/open-webui:v0.13.3-dewa1}
HARBOR_URL=${HARBOR_URL:-registry.bercalab.my.id}
HARBOR_TLS_VERIFY=${HARBOR_TLS_VERIFY:-true}
case "$HARBOR_TLS_VERIFY" in true|false) ;; *) echo 'HARBOR_TLS_VERIFY must be true or false.' >&2; exit 1 ;; esac
umask 077
TRANSFER_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dewa-publish.XXXXXX")
trap 'rm -rf -- "$TRANSFER_DIR"' EXIT
echo 'Saving the local image to a temporary archive; allow space for the full uncompressed image.'
docker save --output "$TRANSFER_DIR/image.tar" "$DEWA_IMAGE"
# Archive transport avoids the old Skopeo docker-daemon API incompatibility.
skopeo login --tls-verify="$HARBOR_TLS_VERIFY" \
    --authfile "$TRANSFER_DIR/auth.json" "$HARBOR_URL"
skopeo copy --dest-tls-verify="$HARBOR_TLS_VERIFY" \
    --authfile "$TRANSFER_DIR/auth.json" \
    "docker-archive:$TRANSFER_DIR/image.tar" "docker://$DEWA_IMAGE"
printf 'Published %s\n' "$DEWA_IMAGE"
