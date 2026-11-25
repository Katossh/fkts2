#!/usr/bin/env bash
set -Eeuo pipefail

FKTS2_INTERNAL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FKTS2_ROOT="$(cd -- "${FKTS2_INTERNAL_DIR}/../.." && pwd)"

fkts2_require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this step as root (for example: sudo bash $0)." >&2
    exit 1
  fi
}

# Read a simple KEY=VALUE entry without sourcing .env as shell code.
fkts2_env_value() {
  local key="$1" fallback="${2:-}"
  local value=""
  if [[ -f "${FKTS2_ROOT}/.env" ]]; then
    value="$(awk -F= -v key="${key}" '$1 == key { sub(/^[^=]*=/, ""); value=$0 } END { print value }' "${FKTS2_ROOT}/.env")"
  fi
  value="${value%$'\r'}"
  value="${value#\"}"; value="${value%\"}"
  value="${value#\'}"; value="${value%\'}"
  printf '%s' "${value:-${fallback}}"
}

fkts2_command_exists() {
  command -v "$1" >/dev/null 2>&1
}

fkts2_die() {
  echo "ERROR: $*" >&2
  exit 1
}
