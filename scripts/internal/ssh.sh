#!/usr/bin/env bash
set -Eeuo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/os.sh"

FKTS2_SSH_CONFIG=/etc/ssh/sshd_config
FKTS2_SSH_DROPIN=/etc/ssh/sshd_config.d/90-fkts2-port.conf
FKTS2_SSH_MARKER="# Managed by fkts2. Do not edit; use scripts/steps/configure-ssh-port.sh."
FKTS2_SSH_STATE_DIR=/var/lib/fkts2/ssh-migration
FKTS2_SSH_PREVIOUS_PORTS=${FKTS2_SSH_STATE_DIR}/previous-ports

fkts2_ssh_target_port() {
  local port
  port="$(fkts2_env_value SSH_PORT 48291)"
  [[ "${port}" =~ ^[0-9]+$ ]] || fkts2_die "SSH_PORT must be an integer from 1 to 65535."
  (( port >= 1 && port <= 65535 )) || fkts2_die "SSH_PORT must be an integer from 1 to 65535."
  printf '%s' "$port"
}

fkts2_ssh_current_ports() {
  sshd -T -f "${FKTS2_SSH_CONFIG}" 2>/dev/null |
    awk 'tolower($1) == "port" { print $2 }' |
    awk '/^[0-9]+$/ && $1 >= 1 && $1 <= 65535' |
    sort -n -u
}

fkts2_ssh_socket_unit() {
  local unit
  for unit in ssh.socket sshd.socket; do
    if systemctl is-active --quiet "$unit"; then
      printf '%s' "$unit"
      return 0
    fi
  done
  return 1
}

fkts2_ssh_socket_ports() {
  local unit="$1" raw
  raw="$(systemctl show "$unit" --property=Listen --value 2>/dev/null || true)"
  grep -oE ':[0-9]{1,5}([^0-9]|$)' <<<"${raw}" |
    tr -d ':' |
    awk '$1 >= 1 && $1 <= 65535' |
    sort -n -u
}

fkts2_ssh_service_unit() {
  local unit
  for unit in ssh.service sshd.service; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
      printf '%s' "$unit"
      return 0
    fi
  done
  fkts2_die "Neither ssh.service nor sshd.service exists after installing openssh-server."
}

fkts2_ssh_firewall_allow() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    if ! ufw status numbered | grep -Eq "[[:space:]]${port}/tcp([[:space:]]|$)"; then
      ufw allow "${port}/tcp" comment 'fkts2 SSH'
    fi
    echo "UFW allows TCP ${port}."
    return 0
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null
    firewall-cmd --add-port="${port}/tcp" >/dev/null
    echo "firewalld allows TCP ${port}."
    return 0
  fi
  echo "WARNING: no active UFW/firewalld instance was detected. Ensure TCP ${port} is allowed by the VPS provider's firewall/security group."
}

fkts2_ssh_selinux_allow() {
  local port="$1" mode existing_type
  command -v getenforce >/dev/null 2>&1 || return 0
  mode="$(getenforce 2>/dev/null || true)"
  [[ "${mode}" == Enforcing ]] || return 0
  command -v semanage >/dev/null 2>&1 || fkts2_die "SELinux is enforcing but semanage is unavailable; install policycoreutils-python-utils first."
  existing_type="$(semanage port -l | awk -v p="${port}" '
    $2 == "tcp" {
      for (i = 3; i <= NF; i++) {
        n = split($i, values, ",")
        for (j = 1; j <= n; j++) if (values[j] == p) { print $1; exit }
      }
    }
  ')"
  if [[ -n "${existing_type}" ]]; then
    [[ "${existing_type}" == ssh_port_t ]] || fkts2_die "TCP ${port} is already assigned SELinux type ${existing_type}, not ssh_port_t; refusing to relabel it."
    return 0
  fi
  semanage port -a -t ssh_port_t -p tcp "${port}"
}

fkts2_ssh_write_sshd_ports() {
  local destination="$1"
  shift
  {
    printf '%s\n' "${FKTS2_SSH_MARKER}"
    printf '%s\n' "# The previous listener is retained until the new port is verified."
    local port
    for port in "$@"; do printf 'Port %s\n' "$port"; done
  } > "$destination"
}

fkts2_ssh_write_socket_ports() {
  local destination="$1"
  shift
  {
    printf '%s\n' "# Managed by fkts2. Do not edit; use scripts/steps/configure-ssh-port.sh."
    printf '%s\n' '[Socket]' 'ListenStream='
    local port
    for port in "$@"; do printf 'ListenStream=%s\n' "$port"; done
  } > "$destination"
}

fkts2_ssh_restore_file() {
  local backup="$1" destination="$2" absent_marker="$3"
  if [[ -f "${backup}" ]]; then
    cp -a "${backup}" "${destination}"
  elif [[ -f "${absent_marker}" ]]; then
    rm -f "${destination}"
  fi
}

fkts2_configure_ssh_port() {
  fkts2_require_root
  fkts2_detect_os
  command -v sshd >/dev/null 2>&1 || fkts2_die "sshd is not installed; run scripts/steps/install-dependencies.sh first."
  [[ -f "${FKTS2_SSH_CONFIG}" ]] || fkts2_die "${FKTS2_SSH_CONFIG} does not exist."
  grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf([[:space:]]|$)' "${FKTS2_SSH_CONFIG}" ||
    fkts2_die "${FKTS2_SSH_CONFIG} does not include /etc/ssh/sshd_config.d/*.conf; refusing to rewrite the main SSH configuration."

  local target inbound socket_unit service_unit port state_ports_tmp
  target="$(fkts2_ssh_target_port)"
  inbound="$(fkts2_env_value INBOUND_PORT 443)"
  [[ "${inbound}" != "${target}" ]] || fkts2_die "SSH_PORT and INBOUND_PORT are both ${target}; choose distinct ports."

  local -a current_ports=() socket_ports=() active_ports=() desired_ports=() desired_socket_ports=() previous_ports=()
  mapfile -t current_ports < <(fkts2_ssh_current_ports)
  (("${#current_ports[@]}" > 0)) || fkts2_die "Could not determine the currently configured sshd port(s)."

  socket_unit=""
  if socket_unit="$(fkts2_ssh_socket_unit)"; then
    mapfile -t socket_ports < <(fkts2_ssh_socket_ports "${socket_unit}")
    if (("${#socket_ports[@]}" > 0)); then
      active_ports=("${socket_ports[@]}")
      current_ports+=("${socket_ports[@]}")
      desired_socket_ports=("${socket_ports[@]}")
    else
      active_ports=("${current_ports[@]}")
      desired_socket_ports=("${current_ports[@]}")
    fi
  else
    active_ports=("${current_ports[@]}")
  fi

  mapfile -t current_ports < <(printf '%s\n' "${current_ports[@]}" | awk 'NF && $1 ~ /^[0-9]+$/ {print $1}' | sort -n -u)
  mapfile -t active_ports < <(printf '%s\n' "${active_ports[@]}" | awk 'NF && $1 ~ /^[0-9]+$/ {print $1}' | sort -n -u)
  mapfile -t desired_socket_ports < <(printf '%s\n' "${desired_socket_ports[@]}" | awk 'NF && $1 ~ /^[0-9]+$/ {print $1}' | sort -n -u)

  for port in "${current_ports[@]}"; do desired_ports+=("${port}"); done
  for port in "${active_ports[@]}"; do
    [[ "${port}" == "${target}" ]] || previous_ports+=("${port}")
  done
  if ! printf '%s\n' "${desired_ports[@]}" | grep -Fxq -- "${target}"; then desired_ports+=("${target}"); fi
  if [[ -n "${socket_unit}" ]] && ! printf '%s\n' "${desired_socket_ports[@]}" | grep -Fxq -- "${target}"; then
    desired_socket_ports+=("${target}")
  fi
  mapfile -t desired_ports < <(printf '%s\n' "${desired_ports[@]}" | sort -n -u)

  fkts2_ssh_firewall_allow "${target}"
  fkts2_ssh_selinux_allow "${target}"

  if ((${#current_ports[@]} == 1)) && [[ "${current_ports[0]}" == "${target}" ]] \\
      && ((${#active_ports[@]} == 1)) && [[ "${active_ports[0]}" == "${target}" ]]; then
    echo "SSH is already configured and listening only on TCP ${target}; no change is needed."
    return 0
  fi

  service_unit="$(fkts2_ssh_service_unit)"
  local socket_dropin="" socket_dir="" backup_dir
  backup_dir="$(mktemp -d)"
  trap 'status=$?; if [[ $status -ne 0 ]]; then fkts2_ssh_restore_file "'" ${backup_dir}"'/sshd" "'" ${FKTS2_SSH_DROPIN}"'" "'" ${backup_dir}"'/sshd.absent"; if [[ -n "'" ${socket_dropin}"'" ]]; then fkts2_ssh_restore_file "'" ${backup_dir}"'/socket" "'" ${socket_dropin}"'" "'" ${backup_dir}"'/socket.absent"; fi; if [[ -n "'" ${socket_unit}"'" ]]; then systemctl daemon-reload >/dev/null 2>&1 || true; systemctl restart "'" ${socket_unit}"'" >/dev/null 2>&1 || true; else systemctl reload "'" ${service_unit}"'" >/dev/null 2>&1 || true; fi; fi; rm -rf "'" ${backup_dir}"'"' EXIT

  if [[ -e "${FKTS2_SSH_DROPIN}" ]]; then
    grep -Fxq "${FKTS2_SSH_MARKER}" "${FKTS2_SSH_DROPIN}" ||
      fkts2_die "${FKTS2_SSH_DROPIN} already exists and is not managed by fkts2; refusing to overwrite it."
    cp -a "${FKTS2_SSH_DROPIN}" "${backup_dir}/sshd"
  else
    touch "${backup_dir}/sshd.absent"
  fi

  fkts2_ssh_write_sshd_ports "${backup_dir}/sshd.new" "${desired_ports[@]}"
  install -o root -g root -m 0644 "${backup_dir}/sshd.new" "${FKTS2_SSH_DROPIN}"
  sshd -t -f "${FKTS2_SSH_CONFIG}" || fkts2_die "sshd rejected the new configuration; the previous configuration will be restored."

  local -a effective_ports=()
  mapfile -t effective_ports < <(fkts2_ssh_current_ports)
  printf '%s\n' "${effective_ports[@]}" | grep -Fxq -- "${target}" ||
    fkts2_die "The sshd Include order prevents SSH_PORT=${target} from taking effect. Previous configuration will be restored."

  if [[ -n "${socket_unit}" ]]; then
    socket_dir="/etc/systemd/system/${socket_unit}.d"
    socket_dropin="${socket_dir}/90-fkts2-port.conf"
    install -d -m 0755 "${socket_dir}"
    if [[ -e "${socket_dropin}" ]]; then
      grep -Fq 'Managed by fkts2.' "${socket_dropin}" ||
        fkts2_die "${socket_dropin} exists and is not managed by fkts2; refusing to overwrite it."
      cp -a "${socket_dropin}" "${backup_dir}/socket"
    else
      touch "${backup_dir}/socket.absent"
    fi
    fkts2_ssh_write_socket_ports "${backup_dir}/socket.new" "${desired_socket_ports[@]}"
    install -o root -g root -m 0644 "${backup_dir}/socket.new" "${socket_dropin}"
  fi

  install -d -o root -g root -m 0700 "${FKTS2_SSH_STATE_DIR}"
  state_ports_tmp="${backup_dir}/previous-ports.new"
  {
    if [[ -s "${FKTS2_SSH_PREVIOUS_PORTS}" ]]; then cat "${FKTS2_SSH_PREVIOUS_PORTS}"; fi
    printf '%s\n' "${previous_ports[@]}"
  } | awk 'NF && $1 ~ /^[0-9]+$/ {print $1}' | sort -n -u > "${state_ports_tmp}"

  if [[ -n "${socket_unit}" ]]; then
    systemctl daemon-reload
    systemctl restart "${socket_unit}"
  elif systemctl is-active --quiet "${service_unit}"; then
    systemctl reload "${service_unit}" || systemctl restart "${service_unit}"
  else
    systemctl enable --now "${service_unit}"
  fi

  local attempt
  for attempt in $(seq 1 10); do
    ss -H -lnt "sport = :${target}" 2>/dev/null | grep -q . && break
    sleep 1
  done
  ss -H -lnt "sport = :${target}" 2>/dev/null | grep -q . ||
    fkts2_die "SSH did not begin listening on TCP ${target}; inspect systemctl status ${service_unit}."

  if [[ -s "${state_ports_tmp}" ]]; then
    install -o root -g root -m 0600 "${state_ports_tmp}" "${FKTS2_SSH_PREVIOUS_PORTS}"
  fi
  trap - EXIT
  rm -rf "${backup_dir}"
  echo "SSH now listens on TCP ${target}. Previous port(s) remain enabled: ${previous_ports[*]:-(none)}."
  if (("${#previous_ports[@]}" > 0)); then
    echo "Reconnect in a NEW SSH session using port ${target}, then run: bash ./scripts/steps/finalize-ssh-port.sh"
  fi
}

fkts2_finalize_ssh_port() {
  fkts2_require_root
  command -v sshd >/dev/null 2>&1 || fkts2_die "sshd is not installed."
  local target socket_unit service_unit socket_dropin backup_dir
  target="$(fkts2_ssh_target_port)"

  [[ -s "${FKTS2_SSH_PREVIOUS_PORTS}" ]] || {
    echo "There are no previous SSH ports recorded for cleanup."
    return 0
  }

  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    local _client_ip _client_port _server_ip session_port
    read -r _client_ip _client_port _server_ip session_port <<<"${SSH_CONNECTION}"
    [[ "${session_port:-}" == "${target}" ]] ||
      fkts2_die "Your current SSH session uses port ${session_port:-unknown}, not the new port ${target}. Open a NEW SSH session on ${target} before finalizing."
  else
    echo "WARNING: SSH_CONNECTION is unavailable (possibly running from a console). Confirm you have tested a separate login on port ${target}."
    read -r -p "Type the new SSH port ${target} to continue: " confirmation
    [[ "${confirmation}" == "${target}" ]] || fkts2_die "Confirmation did not match; no changes made."
  fi

  ss -H -lnt "sport = :${target}" 2>/dev/null | grep -q . ||
    fkts2_die "Nothing is listening on TCP ${target}; refusing to remove the previous SSH ports."
  grep -Fxq "${FKTS2_SSH_MARKER}" "${FKTS2_SSH_DROPIN}" ||
    fkts2_die "The fkts2 sshd drop-in is missing or has been modified; refusing to finalize."

  socket_unit=""
  if socket_unit="$(fkts2_ssh_socket_unit)"; then
    socket_dropin="/etc/systemd/system/${socket_unit}.d/90-fkts2-port.conf"
    grep -Fq 'Managed by fkts2.' "${socket_dropin}" ||
      fkts2_die "The fkts2 systemd socket drop-in is missing or has been modified."
  else
    socket_dropin=""
  fi
  service_unit="$(fkts2_ssh_service_unit)"

  backup_dir="$(mktemp -d)"
  cp -a "${FKTS2_SSH_DROPIN}" "${backup_dir}/sshd"
  if [[ -n "${socket_dropin}" ]]; then cp -a "${socket_dropin}" "${backup_dir}/socket"; fi
  trap 'status=$?; if [[ $status -ne 0 ]]; then cp -a "'" ${backup_dir}"'/sshd" "'" ${FKTS2_SSH_DROPIN}"'"; if [[ -n "'" ${socket_dropin}"'" ]]; then cp -a "'" ${backup_dir}"'/socket" "'" ${socket_dropin}"'"; systemctl daemon-reload >/dev/null 2>&1 || true; systemctl restart "'" ${socket_unit}"'" >/dev/null 2>&1 || true; else systemctl reload "'" ${service_unit}"'" >/dev/null 2>&1 || true; fi; fi; rm -rf "'" ${backup_dir}"'"' EXIT

  fkts2_ssh_write_sshd_ports "${backup_dir}/sshd.new" "${target}"
  install -o root -g root -m 0644 "${backup_dir}/sshd.new" "${FKTS2_SSH_DROPIN}"
  if [[ -n "${socket_dropin}" ]]; then
    fkts2_ssh_write_socket_ports "${backup_dir}/socket.new" "${target}"
    install -o root -g root -m 0644 "${backup_dir}/socket.new" "${socket_dropin}"
  fi

  sshd -t -f "${FKTS2_SSH_CONFIG}"
  local -a effective_ports=()
  mapfile -t effective_ports < <(fkts2_ssh_current_ports)
  [[ "${#effective_ports[@]}" -eq 1 && "${effective_ports[0]}" == "${target}" ]] ||
    fkts2_die "Other Port directives remain in sshd_config; previous listeners have not been removed. Inspect sshd -T before proceeding."

  if [[ -n "${socket_unit}" ]]; then
    systemctl daemon-reload
    systemctl restart "${socket_unit}"
  else
    systemctl reload "${service_unit}" || systemctl restart "${service_unit}"
  fi

  ss -H -lnt "sport = :${target}" 2>/dev/null | grep -q . ||
    fkts2_die "SSH port ${target} did not remain active after finalization. Configuration will be rolled back."

  rm -f "${FKTS2_SSH_PREVIOUS_PORTS}"
  trap - EXIT
  rm -rf "${backup_dir}"
  echo "SSH now listens only on TCP ${target} according to sshd configuration."
  echo "Existing firewall rules for previous ports were not removed; inspect UFW/firewalld separately if you want to close them."
}
