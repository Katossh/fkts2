#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root (for example: sudo bash ./scripts/dns/configure-system-resolver.sh)." >&2
  exit 1
fi

command -v systemctl >/dev/null || { echo "systemctl is required." >&2; exit 1; }
command -v resolvectl >/dev/null || { echo "resolvectl is required." >&2; exit 1; }
systemctl is-active --quiet systemd-resolved || {
  echo "systemd-resolved is not active; refusing to overwrite /etc/resolv.conf." >&2
  exit 1
}

# Do not leave libc applications with a public/non-local nameserver in
# /etc/resolv.conf: those applications would bypass systemd-resolved/Unbound.
[[ -r /etc/resolv.conf ]] || {
  echo "ERROR: /etc/resolv.conf is not readable." >&2
  exit 1
}
mapfile -t current_nameservers < <(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf)
if [[ "${#current_nameservers[@]}" -eq 0 ]]; then
  echo "ERROR: /etc/resolv.conf contains no nameserver entries." >&2
  exit 1
fi
for nameserver in "${current_nameservers[@]}"; do
  case "${nameserver}" in
    127.0.0.1|127.0.0.53) ;;
    *)
      echo "ERROR: /etc/resolv.conf contains non-loopback DNS server ${nameserver}." >&2
      echo "Refusing to continue because some applications could bypass the local Unbound resolver." >&2
      echo "Configure /etc/resolv.conf to use the systemd-resolved stub (127.0.0.53) first." >&2
      exit 1
      ;;
  esac
done

echo "Waiting for Unbound -> dnscrypt-proxy -> Cloudflare DoH..."
ready=false
for attempt in $(seq 1 30); do
  if docker compose exec -T unbound /usr/bin/drill-hc cloudflare.com @127.0.0.1 >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 2
done

if [[ "${ready}" != true ]]; then
  echo "ERROR: Unbound did not resolve cloudflare.com through dnscrypt-proxy." >&2
  docker compose ps dnscrypt-proxy unbound >&2 || true
  docker compose logs --tail=80 dnscrypt-proxy unbound >&2 || true
  exit 1
fi

DROPIN_DIR="/etc/systemd/resolved.conf.d"
DROPIN="${DROPIN_DIR}/90-fkts2-unbound.conf"
CONFIG="$(cat <<'EOF'
# Managed by fkts2. Remove with scripts/dns/rollback-system-resolver.sh.
[Resolve]
DNS=
DNS=127.0.0.1
FallbackDNS=
Domains=
Domains=~.
DNSSEC=yes
DNSOverTLS=no
EOF
)"

created=false
if [[ -e "${DROPIN}" ]]; then
  if ! grep -Fxq '# Managed by fkts2. Remove with scripts/dns/rollback-system-resolver.sh.' "${DROPIN}"; then
    echo "ERROR: ${DROPIN} already exists and is not managed by fkts2; leaving it untouched." >&2
    exit 1
  fi
  if ! cmp -s "${DROPIN}" <(printf '%s\n' "${CONFIG}"); then
    echo "ERROR: ${DROPIN} differs from the fkts2 configuration; inspect it before changing it." >&2
    exit 1
  fi
else
  install -d -m 0755 "${DROPIN_DIR}"
  tmp="$(mktemp)"
  trap 'rm -f "${tmp}"' EXIT
  printf '%s\n' "${CONFIG}" > "${tmp}"
  install -o root -g root -m 0644 "${tmp}" "${DROPIN}"
  created=true
fi

systemctl restart systemd-resolved
resolvectl flush-caches

if ! resolvectl query cloudflare.com >/dev/null 2>&1 \
    || ! getent ahostsv4 cloudflare.com >/dev/null 2>&1; then
  if [[ "${created}" == true ]]; then
    rm -f "${DROPIN}"
    systemctl restart systemd-resolved
    resolvectl flush-caches || true
  fi
  echo "ERROR: systemd-resolved could not resolve cloudflare.com through Unbound." >&2
  echo "The newly created fkts2 drop-in was rolled back when applicable." >&2
  exit 1
fi

echo "System DNS now routes through Unbound (127.0.0.1:53) -> dnscrypt-proxy -> Cloudflare DoH."
resolvectl status
