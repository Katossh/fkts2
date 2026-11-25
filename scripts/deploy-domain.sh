#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ ! -f .env ]]; then
  echo "Missing .env; run bash ./scripts/init.sh first." >&2
  exit 1
fi

# One-shot container. It only manages CF_RECORD_NAME and never changes other DNS records.
docker compose --profile dns run --rm --build cloudflare-dns
