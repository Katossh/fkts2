#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ ! -f .env ]]; then
  echo "Missing .env; run bash ./scripts/init.sh first." >&2
  exit 1
fi

# Prepare the persistent Unbound trust-anchor volume before its non-root service starts.
docker compose create --no-deps unbound
docker compose --profile init run --rm --no-deps unbound-data-permissions

# This one-shot API helper depends on the local DNS chain and only manages
# CF_RECORD_NAME; it never changes other DNS records.
docker compose --profile dns run --rm --build cloudflare-dns
