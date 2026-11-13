#!/usr/bin/env bash
set -euo pipefail
cd /app/backend
: "${WEBUI_SECRET_KEY:?Keep the existing WEBUI_SECRET_KEY in open-webui-secrets.}"
if [[ "${UVICORN_WORKERS:-1}" != 1 ]]; then
    echo 'DEWA uses SQLite/embedded Chroma; keep one worker.' >&2
    exit 1
fi
exec python -m uvicorn dewa_app:app \
    --host "${HOST:-0.0.0.0}" \
    --port "${PORT:-8080}" \
    --forwarded-allow-ips "${FORWARDED_ALLOW_IPS:-*}" \
    --workers 1 \
    --ws-per-message-deflate "${UVICORN_WS_PER_MESSAGE_DEFLATE:-true}"
