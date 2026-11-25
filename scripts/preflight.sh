#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[[ -f .env ]] || { echo "Missing .env; run ./scripts/init.sh first." >&2; exit 1; }
command -v ip >/dev/null || { echo "iproute2 (ip) is required on the VPS host." >&2; exit 1; }
command -v docker >/dev/null || { echo "Docker is required." >&2; exit 1; }
docker compose version >/dev/null

python3 config/render.py
read_env() {
  awk -F= -v key="$1" '$1 == key { value=$2; gsub(/\r/, "", value); sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value) } END { print value }' .env
}
ENTRY_IP="$(read_env ENTRY_IP)"
EXIT_IP="$(read_env EXIT_IP)"
INBOUND_PORT="$(read_env INBOUND_PORT)"
SINGLE_IP_MODE="$(read_env SINGLE_IP_MODE)"
SINGLE_IP_MODE="${SINGLE_IP_MODE:-false}"

LOCAL_IPV4="$(ip -o -4 address show | awk '$3 == "inet" { split($4, a, "/"); print a[1] }')"
for address in "$ENTRY_IP" "$EXIT_IP"; do
  if ! grep -Fxq -- "$address" <<< "$LOCAL_IPV4"; then
    echo "ERROR: $address is not assigned to a host IPv4 interface." >&2
    echo "Configured IPv4 addresses:" >&2
    ip -o -4 address show >&2
    echo "Check ENTRY_IP/EXIT_IP in .env and the VPS network configuration." >&2
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
echo "Preflight passed: ENTRY_IP and EXIT_IP are local and the kernel can route using EXIT_IP."
if [[ "${SINGLE_IP_MODE,,}" == "true" ]]; then
  echo "Mode: single-IP staging (entry and exit share ${ENTRY_IP})."
else
  echo "Mode: separate entry/exit IPs."
fi
echo "Planned listener: ${ENTRY_IP}:${INBOUND_PORT} (staging default is 8443)."
