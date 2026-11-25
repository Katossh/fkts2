#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run deploy.sh as root because it configures the host system resolver." >&2
  exit 1
fi

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

echo "Validating DNSCrypt-proxy configuration..."
docker compose run --rm --no-deps --entrypoint dnscrypt-proxy dnscrypt-proxy \
  -config /config/dnscrypt-proxy.toml -check

echo "Building and validating the Caddy self-steal fallback..."
docker compose build caddy
docker compose run --rm --no-deps --entrypoint /usr/bin/caddy caddy validate \
  --config /etc/caddy/Caddyfile --adapter caddyfile

echo "Preparing Unbound's persistent DNSSEC trust-anchor volume..."
# `docker compose create` has no --no-deps option. Creating the Unbound
# service also creates any missing dependency containers without starting them.
# Docker seeds the empty named volume from the image before the ownership helper runs.
docker compose create unbound
docker compose run --rm --no-deps --entrypoint /usr/sbin/unbound-checkconf unbound \
  /etc/unbound/unbound.conf
docker compose --profile init run --rm --no-deps unbound-data-permissions

echo "Starting the local DNS chain (Unbound -> dnscrypt-proxy -> Cloudflare DoH)..."
docker compose up -d --force-recreate unbound

echo "Reconciling Cloudflare A record with ENTRY_IP..."
# The helper creates the dedicated record when absent, updates records already
# managed by fkts2, and refuses to overwrite an unrelated existing record unless
# CF_ALLOW_EXISTING_RECORD_UPDATE=true was explicitly set after review.
docker compose --profile dns run --rm --build cloudflare-dns

bash ./scripts/dns/configure-system-resolver.sh

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

echo "Caddy fallback is ready. Reloading the active Caddy configuration..."
docker compose exec caddy caddy reload \
  --config /etc/caddy/Caddyfile --adapter caddyfile

echo "Validating Xray configuration..."
docker compose run --rm --no-deps xray run -test -confdir /usr/local/etc/xray

echo "Applying the generated Xray configuration..."
docker compose up -d --no-deps --force-recreate xray
docker compose ps
