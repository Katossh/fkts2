#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ ! -f .env ]]; then
  echo "Missing .env; run bash ./scripts/init.sh first." >&2
  exit 1
fi

IP="${1:-}"
if [[ -z "$IP" ]]; then
  echo "Usage: bash ./scripts/set-single-ip.sh PUBLIC_IPV4" >&2
  exit 2
fi

python3 - "$IP" <<'PY'
import ipaddress
from pathlib import Path
import sys

try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError as exc:
    raise SystemExit(f"Invalid IP address: {exc}")

if address.version != 4 or not address.is_global:
    raise SystemExit("Expected a globally routable public IPv4 address.")

path = Path(".env")
lines = path.read_text().splitlines()
record_name = next(
    (line.split("=", 1)[1].strip() for line in lines
     if line.strip().startswith("CF_RECORD_NAME=")),
    "xray.katossh.dpdns.org",
).rstrip(".").lower()

updates = {
    "SINGLE_IP_MODE": "true",
    "ENTRY_IP": str(address),
    "EXIT_IP": str(address),
    "ENTRY_ADDRESS": record_name,
    "REALITY_TARGET": "127.0.0.1:9443",
    "REALITY_SERVER_NAME": record_name,
}
seen = set()
output = []

for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith("#") or "=" not in line:
        output.append(line)
        continue
    key = line.split("=", 1)[0].strip()
    if key in updates:
        output.append(f"{key}={updates[key]}")
        seen.add(key)
    else:
        output.append(line)

for key, value in updates.items():
    if key not in seen:
        output.append(f"{key}={value}")

path.write_text("\n".join(output) + "\n")
path.chmod(0o600)
print("Enabled single-IP staging mode.")
print(f"ENTRY_IP = {address}")
print(f"EXIT_IP  = {address}")
print(f"ENTRY_ADDRESS = {record_name}")
print("REALITY_TARGET = 127.0.0.1:9443")
print(f"REALITY_SERVER_NAME = {record_name}")
print("Other .env values and credentials were preserved.")
PY
