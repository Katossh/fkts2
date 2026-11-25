#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root (for example: sudo bash ./scripts/dns/rollback-system-resolver.sh)." >&2
  exit 1
fi

DROPIN="/etc/systemd/resolved.conf.d/90-fkts2-unbound.conf"

if [[ ! -e "${DROPIN}" ]]; then
  echo "fkts2 system resolver drop-in is not installed."
  exit 0
fi

if ! grep -Fxq '# Managed by fkts2. Remove with scripts/dns/rollback-system-resolver.sh.' "${DROPIN}"; then
  echo "ERROR: refusing to remove ${DROPIN}: it is not marked as managed by fkts2." >&2
  exit 1
fi

rm -f "${DROPIN}"
systemctl restart systemd-resolved
resolvectl flush-caches
echo "Removed the fkts2 DNS override. systemd-resolved has returned to its remaining configured DNS sources."
resolvectl status
