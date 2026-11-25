#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run the complete setup as root: sudo bash ./scripts/setup.sh" >&2
  exit 1
fi
if [[ ! -f .env ]]; then
  echo "Missing .env. Initialize and configure the project first: bash ./scripts/init.sh" >&2
  exit 1
fi

steps=(
  "scripts/steps/update-system.sh"
  "scripts/steps/install-dependencies.sh"
  "scripts/steps/configure-ssh-port.sh"
  "scripts/steps/deploy-vpn.sh"
)

for step in "${steps[@]}"; do
  echo
  echo "============================================================"
  echo "Running ${step}"
  echo "============================================================"
  bash "${ROOT}/${step}"
done

echo
echo "fkts2 full setup completed."
echo "Check the generated client profile at runtime/client-config.json."
echo "If SSH was migrated from another port, open a NEW SSH session on SSH_PORT before running:"
echo "  sudo bash ./scripts/steps/finalize-ssh-port.sh"
echo "The previous SSH port is intentionally retained until that separate login is verified."
