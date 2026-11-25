#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[[ -f .env ]] || { echo "Missing .env; run ./scripts/init.sh first." >&2; exit 1; }
command -v ip >/dev/null || { echo "iproute2 (ip) is required on the VPS host." >&2; exit 1; }
command -v docker >/dev/null || { echo "Docker is required." >&2; exit 1; }
docker compose version >/dev/null

python3 config/render.py
ENTRY_IP="$(sed -n 's/^ENTRY_IP=//p' .env | tail -n1)"
EXIT_IP="$(sed -n 's/^EXIT_IP=//p' .env | tail -n1)"
INBOUND_PORT="$(sed -n 's/^INBOUND_PORT=//p' .env | tail -n1)"

for address in "$ENTRY_IP" "$EXIT_IP"; do
  if ! ip -o address show | grep -Fq " $address/"; then
    echo "ERROR: $address is not assigned to a host interface." >&2
    echo "Do not start Xray yet. Ask the VPS provider how the additional IP must be configured." >&2
    exit 2
  fi
done

if [[ "$EXIT_IP" == *:* ]]; then
  ROUTE_TEST_DEST="2606:4700:4700::1111"
  ROUTE_TEST_CMD=(ip -6 route get "$ROUTE_TEST_DEST" from "$EXIT_IP")
else
  ROUTE_TEST_DEST="1.1.1.1"
  ROUTE_TEST_CMD=(ip -4 route get "$ROUTE_TEST_DEST" from "$EXIT_IP")
fi
if ! "${ROUTE_TEST_CMD[@]}" >/dev/null 2>&1; then
  echo "ERROR: the host has no usable route with source $EXIT_IP." >&2
  echo "The provider may require a source-specific route or gateway configuration." >&2
  exit 2
fi

docker compose config -q
echo "Preflight passed: both addresses are local and the kernel can route using EXIT_IP."
echo "Planned listener: ${ENTRY_IP}:${INBOUND_PORT} (staging default is 8443)."
