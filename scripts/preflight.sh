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
SINGLE_IP_MODE="$(sed -n 's/^SINGLE_IP_MODE=//p' .env | tail -n1)"
SINGLE_IP_MODE="${SINGLE_IP_MODE:-false}"

for address in "$ENTRY_IP" "$EXIT_IP"; do
  # Strip CRLF/accidental surrounding whitespace from .env values.
  address="${address//
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
\r'/}"
  address="$(printf '%s' "$address" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if ! ip -o -4 address show | awk '$3 == "inet" { split($4, a, "/"); print a[1] }' | grep -Fxq -- "$address"; then
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
