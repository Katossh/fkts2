#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/os.sh"

fkts2_configure_docker_apt_repo() {
  local keyring=/etc/apt/keyrings/docker.asc source_file=/etc/apt/sources.list.d/docker.sources
  local suite arch repo_url
  # shellcheck disable=SC1091
  source /etc/os-release
  suite="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  [[ -n "${suite}" ]] || fkts2_die "Cannot determine the APT suite for Docker's official repository."
  arch="$(dpkg --print-architecture)"
  repo_url="https://download.docker.com/linux/${FKTS2_OS_ID}"

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -s "${keyring}" ]]; then
    curl -fsSL "${repo_url}/gpg" -o "${keyring}.tmp"
    install -o root -g root -m 0644 "${keyring}.tmp" "${keyring}"
    rm -f "${keyring}.tmp"
  fi
  if [[ -e "${source_file}" ]] && ! grep -Fq "${repo_url}" "${source_file}"; then
    fkts2_die "${source_file} already exists but does not point to ${repo_url}; inspect it instead of overwriting it."
  fi
  if ! grep -RqsF "${repo_url}" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    cat > "${source_file}.tmp" <<SOURCES
Types: deb
URIs: ${repo_url}
Suites: ${suite}
Components: stable
Architectures: ${arch}
Signed-By: ${keyring}
SOURCES
    install -o root -g root -m 0644 "${source_file}.tmp" "${source_file}"
    rm -f "${source_file}.tmp"
  fi
  apt-get update
}

fkts2_configure_docker_dnf_repo() {
  local repo_file=/etc/yum.repos.d/docker-ce.repo
  if [[ -e "${repo_file}" ]] && ! grep -Fq 'download.docker.com/linux/fedora' "${repo_file}"; then
    fkts2_die "${repo_file} already exists but is not Docker's Fedora repository; refusing to overwrite it."
  fi
  if [[ ! -e "${repo_file}" ]]; then
    if dnf --version 2>/dev/null | head -n1 | grep -q '^5'; then
      dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
    else
      dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
    fi
  fi
}

fkts2_install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "Docker Engine and the Compose plugin are already installed; preserving the existing installation."
  else
    echo "Docker Engine or the Compose plugin is missing; configuring Docker's official package repository."
    case "${FKTS2_PACKAGE_MANAGER}" in
      apt)
        fkts2_configure_docker_apt_repo
        if command -v docker >/dev/null 2>&1; then
          DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin
        else
          local conflicts
          conflicts="$(dpkg-query -W -f='${db:Status-Status} ${binary:Package}\n' docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc 2>/dev/null | awk '$1 == "installed" { print $2 }' || true)"
          [[ -z "${conflicts}" ]] || fkts2_die "Conflicting container packages are installed: ${conflicts//$'\n'/, }. Review them first; this script will not remove packages or touch /var/lib/docker."
          DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        fi
        ;;
      dnf)
        if ! dnf config-manager --help >/dev/null 2>&1; then
          dnf install -y dnf5-plugins || dnf install -y dnf-plugins-core
        fi
        fkts2_configure_docker_dnf_repo
        if command -v docker >/dev/null 2>&1; then
          dnf install -y docker-compose-plugin
        else
          dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        fi
        ;;
    esac
  fi

  systemctl enable --now docker
  docker compose version >/dev/null 2>&1 || fkts2_die "Docker Compose plugin is still unavailable after dependency installation."
  docker info >/dev/null 2>&1 || fkts2_die "Docker daemon is not responding. Check: systemctl status docker"
  echo "Docker Engine and Docker Compose are ready."
}

fkts2_install_dependencies() {
  fkts2_detect_os
  echo "Installing base dependencies..."
  case "${FKTS2_PACKAGE_MANAGER}" in
    apt)
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git python3 iproute2 dnsutils openssh-server openssh-client gnupg
      ;;
    dnf)
      dnf install -y ca-certificates curl git python3 iproute bind-utils openssh-server openssh-clients policycoreutils-python-utils dnf-plugins-core
      ;;
  esac
  fkts2_install_docker
  echo "Base dependencies installed."
}
