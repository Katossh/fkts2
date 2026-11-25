#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/os.sh"

fkts2_update_system() {
  fkts2_detect_os
  echo "Updating package metadata and installed packages..."
  case "${FKTS2_PACKAGE_MANAGER}" in
    apt)
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
      ;;
    dnf)
      dnf upgrade --refresh -y
      ;;
  esac

  if [[ -e /var/run/reboot-required ]]; then
    echo "NOTICE: the system reports that a reboot is required. Reboot manually after confirming that your SSH access is safe."
  elif [[ "${FKTS2_PACKAGE_MANAGER}" == dnf ]] && command -v needs-restarting >/dev/null 2>&1; then
    if ! needs-restarting -r >/dev/null 2>&1; then
      echo "NOTICE: updated packages may require a reboot. Review: needs-restarting -r"
    fi
  fi
  echo "System package update completed. No automatic reboot was performed."
}
