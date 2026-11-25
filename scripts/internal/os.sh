#!/usr/bin/env bash
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

fkts2_detect_os() {
  [[ -r /etc/os-release ]] || fkts2_die "/etc/os-release is missing; cannot identify this operating system."
  # shellcheck disable=SC1091
  source /etc/os-release
  FKTS2_OS_ID="${ID:-unknown}"
  FKTS2_OS_VERSION_ID="${VERSION_ID:-unknown}"
  FKTS2_OS_PRETTY_NAME="${PRETTY_NAME:-${ID:-Linux}}"

  case "${FKTS2_OS_ID}" in
    ubuntu|debian) FKTS2_PACKAGE_MANAGER=apt ;;
    fedora) FKTS2_PACKAGE_MANAGER=dnf ;;
    *) fkts2_die "Unsupported distribution '${FKTS2_OS_ID}'. This setup currently supports Ubuntu, Debian and Fedora." ;;
  esac
  export FKTS2_OS_ID FKTS2_OS_VERSION_ID FKTS2_OS_PRETTY_NAME FKTS2_PACKAGE_MANAGER
  echo "Detected ${FKTS2_OS_PRETTY_NAME} (${FKTS2_PACKAGE_MANAGER})."
}
