#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

bash ./scripts/preflight.sh

command -v curl >/dev/null || {
  echo "curl is required to verify the local Caddy fallback." >&2
  exit 1
}

REALITY_SERVER_NAME="$(sed -n 's/^REALITY_SERVER_NAME=//p' .env | tail -n1)"
if [[ -z "$REALITY_SERVER_NAME" || "$REALITY_SERVER_NAME" == "REPLACE_ME" ]]; then
  echo "Set REALITY_SERVER_NAME in .env." >&2
  exit 1
fi

echo "Building and validating the Caddy self-steal fallback..."
docker compose build caddy
docker compose run --rm --no-deps --entrypoint /usr/bin/caddy caddy validate \
  --config /etc/caddy/Caddyfile --adapter caddyfile

echo "Starting Caddy on 127.0.0.1:9443 and requesting its DNS-01 certificate..."
docker compose up -d caddy

ready=false
for attempt in $(seq 1 60); do
  if curl --noproxy '*' --connect-timeout 2 --max-time 5 \
      --silent --show-error --fail --insecure \
      --resolve "${REALITY_SERVER_NAME}:9443:127.0.0.1" \
      "https://${REALITY_SERVER_NAME}:9443/" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 2
done

if [[ "$ready" != true ]]; then
  echo "ERROR: Caddy did not become ready with a certificate for ${REALITY_SERVER_NAME}." >&2
  echo "Check that the Cloudflare token has Zone:Zone:Read and Zone:DNS:Edit permissions." >&2
  docker compose logs --tail=100 caddy
  exit 1
fi

echo "Caddy fallback is ready. Validating Xray configuration..."
docker compose run --rm --no-deps xray run -test -confdir /usr/local/etc/xray

echo "Starting fkts2-xray..."
docker compose up -d xray
docker compose ps
