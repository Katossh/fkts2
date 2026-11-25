#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ -f .env ]] || { echo "Missing .env" >&2; exit 1; }
EXIT_IP="$(sed -n 's/^EXIT_IP=//p' .env | tail -n1)"
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

if [[ "$EXIT_IP" == *:* ]]; then
  SEEN_IP="$(curl --noproxy '*' --interface "$EXIT_IP" --fail --silent --show-error https://api64.ipify.org)"
else
  SEEN_IP="$(curl -4 --noproxy '*' --interface "$EXIT_IP" --fail --silent --show-error https://api.ipify.org)"
fi
EXPECTED_IP="$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_address(sys.argv[1]))' "$EXIT_IP")"
OBSERVED_IP="$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_address(sys.argv[1]))' "$SEEN_IP")"
printf 'Configured EXIT_IP: %s\nObserved public IP:  %s\n' "$EXPECTED_IP" "$OBSERVED_IP"
[[ "$OBSERVED_IP" == "$EXPECTED_IP" ]] || {
  echo "Mismatch: provider routing/NAT is not presenting EXIT_IP as the public source address." >&2
  exit 2
}
echo "Outbound source IP verified."
