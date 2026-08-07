#!/usr/bin/env bash
#===============================================================================
# nis-master-rhel8-installer.sh
# Version: 1.1.0
# Purpose: Install and configure a RHEL 8.x EC2 host as a NIS Master server.
#
# Official documentation references:
# - Red Hat Customer Portal: NIS/ypserv/ypbind on RHEL 5, 6, 7, 8
#   https://access.redhat.com/solutions/47192
# - Red Hat Customer Portal: NIS support status in RHEL 8
#   https://access.redhat.com/solutions/5991271
# - AWS VPC Security Group rules
#   https://docs.aws.amazon.com/vpc/latest/userguide/security-group-rules.html
#
# Security warning:
# NIS is a legacy, non-encrypted identity lookup service. Use only on trusted
# private networks. Do not expose NIS/RPC ports to the Internet.
#===============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.1.0"
SCRIPT_NAME="nis-master-rhel8-installer"
LOG_FILE="/var/log/${SCRIPT_NAME}.log"
BACKUP_BASE="/var/backups/${SCRIPT_NAME}"
BACKUP_DIR=""
ROLLBACK_ON_ERROR="true"
DRY_RUN="false"
NON_INTERACTIVE="false"
ASSUME_YES="false"
FORCE_INIT="false"
CONFIGURE_LOCAL_CLIENT="false"
SKIP_FIREWALL="false"
SKIP_SELINUX="false"
SKIP_PACKAGE_INSTALL="false"

NIS_DOMAIN=""
MASTER_FQDN=""
MASTER_IP=""
ALLOWED_CIDR=""
SET_HOSTNAME="true"

YPSERV_PORT="944"
YPXFRD_PORT="945"
YPPASSWDD_PORT="950"
FIREWALL_PORT_START="944"
FIREWALL_PORT_END="951"

REQUIRED_PACKAGES=(ypserv ypbind yp-tools rpcbind make)
SERVICES_TO_ENABLE=(rpcbind nis-domainname ypserv ypxfrd yppasswdd)
LOCAL_CLIENT_SERVICES=(ypbind)
BACKUP_FILES=(/etc/hosts /etc/sysconfig/network /etc/sysconfig/ypserv /etc/sysconfig/ypxfrd /etc/sysconfig/yppasswdd /var/yp/securenets /etc/yp.conf /etc/nsswitch.conf /etc/authselect/user-nsswitch.conf)

PREVIOUS_SERVICE_STATES_FILE=""
PREVIOUS_AUTHSELECT_FILE=""
CHANGED_FILES=()

usage() {
  cat <<USAGE
${SCRIPT_NAME} v${SCRIPT_VERSION}

Install and configure a RHEL 8.x host as a NIS Master server.

Usage:
  sudo ./${SCRIPT_NAME}.sh [options]

Interactive mode:
  sudo ./${SCRIPT_NAME}.sh

Non-interactive mode example:
  sudo ./${SCRIPT_NAME}.sh \\
    --non-interactive --yes \\
    --nis-domain corpnis \\
    --master-fqdn nis-master.example.internal \\
    --master-ip 10.0.1.10 \\
    --allowed-cidr 10.0.0.0/16

Options:
  --nis-domain VALUE             NIS domain name, for example corpnis.
  --master-fqdn VALUE            Master FQDN, for example nis-master.example.internal.
  --master-ip VALUE              Private IP address of this EC2 instance.
  --allowed-cidr VALUE           Trusted client CIDR, for example 10.0.0.0/16.
  --ypserv-port VALUE            Fixed ypserv RPC port. Default: 944.
  --ypxfrd-port VALUE            Fixed ypxfrd RPC port. Default: 945.
  --yppasswdd-port VALUE         Fixed yppasswdd RPC port. Default: 950.
  --configure-local-client       Configure this server to bind to itself as a NIS client using authselect nis.
  --no-set-hostname              Do not change system hostname.
  --force-init                   Re-run ypinit even when maps already exist.
  --skip-firewall                Do not modify firewalld.
  --skip-selinux                 Do not modify SELinux booleans.
  --skip-package-install         Only validate packages. Do not install missing packages.
  --dry-run                      Print actions without changing the system.
  --non-interactive              Do not prompt. Required values must be passed as flags or env vars.
  --yes                          Assume yes for confirmation prompts.
  --no-rollback                  Do not automatically restore config backups on error.
  --version                      Print version.
  -h, --help                     Show this help.

Environment variable equivalents:
  NIS_DOMAIN, MASTER_FQDN, MASTER_IP, ALLOWED_CIDR

Log file:
  ${LOG_FILE}

Backups:
  ${BACKUP_BASE}/<timestamp>/
USAGE
}

log() {
  local level="$1"
  shift
  local msg="$*"
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$level" "$msg" | tee -a "$LOG_FILE" >&2
}

info() { log INFO "$*"; }
warn() { log WARN "$*"; }
err() { log ERROR "$*"; }

run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY-RUN: $*"
    return 0
  fi
  info "RUN: $*"
  "$@" >>"$LOG_FILE" 2>&1
}

fail() {
  err "$*"
  exit 1
}

on_error() {
  local exit_code=$?
  err "Installation failed with exit code ${exit_code} at line ${BASH_LINENO[0]}: ${BASH_COMMAND}"
  if [[ "$ROLLBACK_ON_ERROR" == "true" && -n "${BACKUP_DIR}" && "$DRY_RUN" != "true" ]]; then
    rollback || true
  fi
  err "See log: ${LOG_FILE}"
  exit "$exit_code"
}
trap on_error ERR

rollback() {
  warn "Starting rollback from backup directory: ${BACKUP_DIR}"
  if [[ ! -d "$BACKUP_DIR" ]]; then
    warn "Backup directory does not exist. Skipping rollback."
    return 0
  fi

  while IFS= read -r metadata; do
    [[ -z "$metadata" ]] && continue
    local src dest existed
    src="$(cut -d '|' -f 1 <<<"$metadata")"
    dest="$(cut -d '|' -f 2 <<<"$metadata")"
    existed="$(cut -d '|' -f 3 <<<"$metadata")"
    if [[ "$existed" == "yes" && -f "$src" ]]; then
      info "Restoring ${dest}"
      cp -a "$src" "$dest"
    elif [[ "$existed" == "no" && -e "$dest" ]]; then
      info "Removing newly-created ${dest}"
      rm -f "$dest"
    fi
  done < "${BACKUP_DIR}/manifest.txt"

  if [[ -f "$PREVIOUS_SERVICE_STATES_FILE" ]]; then
    while IFS='|' read -r svc was_enabled was_active; do
      [[ -z "$svc" ]] && continue
      if [[ "$was_active" != "active" ]]; then
        systemctl stop "$svc" >>"$LOG_FILE" 2>&1 || true
      fi
      if [[ "$was_enabled" != "enabled" ]]; then
        systemctl disable "$svc" >>"$LOG_FILE" 2>&1 || true
      fi
    done < "$PREVIOUS_SERVICE_STATES_FILE"
  fi

  if [[ -f "$PREVIOUS_AUTHSELECT_FILE" ]] && command -v authselect >/dev/null 2>&1; then
    local prior_profile prior_features feature_args=()
    prior_profile="$(awk -F: '/^Profile ID:/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' "$PREVIOUS_AUTHSELECT_FILE" | head -1)"
    if [[ -n "$prior_profile" ]]; then
      while IFS= read -r feature; do
        [[ -n "$feature" ]] && feature_args+=("$feature")
      done < <(awk '/^Enabled features:/ {in_features=1; next} in_features && /^- / {print $2}' "$PREVIOUS_AUTHSELECT_FILE")
      authselect select "$prior_profile" "${feature_args[@]}" --force >>"$LOG_FILE" 2>&1 || true
      authselect apply-changes >>"$LOG_FILE" 2>&1 || true
    fi
  fi
  warn "Rollback completed. Installed packages are not removed automatically."
}

parse_args() {
  NIS_DOMAIN="${NIS_DOMAIN:-}"
  MASTER_FQDN="${MASTER_FQDN:-}"
  MASTER_IP="${MASTER_IP:-}"
  ALLOWED_CIDR="${ALLOWED_CIDR:-}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --nis-domain) NIS_DOMAIN="${2:-}"; shift 2 ;;
      --master-fqdn) MASTER_FQDN="${2:-}"; shift 2 ;;
      --master-ip) MASTER_IP="${2:-}"; shift 2 ;;
      --allowed-cidr) ALLOWED_CIDR="${2:-}"; shift 2 ;;
      --ypserv-port) YPSERV_PORT="${2:-}"; shift 2 ;;
      --ypxfrd-port) YPXFRD_PORT="${2:-}"; shift 2 ;;
      --yppasswdd-port) YPPASSWDD_PORT="${2:-}"; shift 2 ;;
          --configure-local-client) CONFIGURE_LOCAL_CLIENT="true"; shift ;;
      --no-set-hostname) SET_HOSTNAME="false"; shift ;;
      --force-init) FORCE_INIT="true"; shift ;;
      --skip-firewall) SKIP_FIREWALL="true"; shift ;;
      --skip-selinux) SKIP_SELINUX="true"; shift ;;
      --skip-package-install) SKIP_PACKAGE_INSTALL="true"; shift ;;
      --dry-run) DRY_RUN="true"; shift ;;
      --non-interactive) NON_INTERACTIVE="true"; shift ;;
      --yes) ASSUME_YES="true"; shift ;;
      --no-rollback) ROLLBACK_ON_ERROR="false"; shift ;;
      --version) echo "$SCRIPT_VERSION"; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      *) fail "Unknown option: $1" ;;
    esac
  done
}

prompt_if_missing() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="${3:-}"
  local current_value="${!var_name:-}"

  if [[ -n "$current_value" ]]; then
    return 0
  fi

  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    fail "Missing required value: ${var_name}. Provide it by flag or environment variable."
  fi

  local input=""
  if [[ -n "$default_value" ]]; then
    read -r -p "${prompt_text} [${default_value}]: " input
    input="${input:-$default_value}"
  else
    read -r -p "${prompt_text}: " input
  fi
  printf -v "$var_name" '%s' "$input"
}

confirm() {
  local message="$1"
  if [[ "$ASSUME_YES" == "true" || "$NON_INTERACTIVE" == "true" ]]; then
    return 0
  fi
  local answer=""
  read -r -p "${message} [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || fail "Run as root, for example: sudo ./${SCRIPT_NAME}.sh"
}

validate_rhel() {
  [[ -r /etc/os-release ]] || fail "/etc/os-release not found. This script supports RHEL 8.x only."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "rhel" ]] || fail "Unsupported OS ID '${ID:-unknown}'. This script expects RHEL 8.x."
  [[ "${VERSION_ID:-}" == 8.* ]] || fail "Unsupported RHEL version '${VERSION_ID:-unknown}'. This script expects RHEL 8.x, including RHEL 8.10."
  info "Detected ${PRETTY_NAME:-RHEL}."
}

validate_inputs() {
  local ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
  local cidr_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$'
  local host_regex='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'
  local domain_regex='^[A-Za-z0-9._-]+$'
  local port_regex='^[0-9]+$'

  [[ "$NIS_DOMAIN" =~ $domain_regex ]] || fail "Invalid NIS domain: $NIS_DOMAIN"
  [[ "$MASTER_FQDN" =~ $host_regex ]] || fail "Invalid master FQDN: $MASTER_FQDN"
  [[ "$MASTER_IP" =~ $ip_regex ]] || fail "Invalid master IP: $MASTER_IP"
  [[ "$ALLOWED_CIDR" =~ $cidr_regex ]] || fail "Invalid CIDR: $ALLOWED_CIDR"

  for octet in ${MASTER_IP//./ }; do
    (( octet >= 0 && octet <= 255 )) || fail "Invalid IP octet in ${MASTER_IP}"
  done
  for port in "$YPSERV_PORT" "$YPXFRD_PORT" "$YPPASSWDD_PORT"; do
    [[ "$port" =~ $port_regex ]] || fail "Invalid port: $port"
    (( port >= 1 && port <= 65535 )) || fail "Port out of range: $port"
  done
}

cidr_to_netmask() {
  local cidr_bits="$1"
  local mask=""
  local full_octets=$((cidr_bits / 8))
  local partial_bits=$((cidr_bits % 8))
  local i
  for i in 0 1 2 3; do
    if (( i < full_octets )); then
      mask+="255"
    elif (( i == full_octets )); then
      mask+="$(( 256 - 2 ** (8 - partial_bits) ))"
    else
      mask+="0"
    fi
    [[ $i -lt 3 ]] && mask+="."
  done
  echo "$mask"
}

ip_to_int() {
  local ip="$1"
  local a b c d
  IFS=. read -r a b c d <<< "$ip"
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

int_to_ip() {
  local int="$1"
  echo "$(( (int >> 24) & 255 )).$(( (int >> 16) & 255 )).$(( (int >> 8) & 255 )).$(( int & 255 ))"
}

cidr_network() {
  local cidr="$1"
  local ip="${cidr%/*}"
  local bits="${cidr#*/}"
  local ip_int mask_int network_int
  ip_int="$(ip_to_int "$ip")"
  if (( bits == 0 )); then
    mask_int=0
  else
    mask_int=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  fi
  network_int=$(( ip_int & mask_int ))
  int_to_ip "$network_int"
}

prepare_logging_and_backup() {
  if [[ "$DRY_RUN" == "true" ]]; then
    info "Dry-run mode enabled. No backup directory will be created."
    return 0
  fi
  touch "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
  BACKUP_DIR="${BACKUP_BASE}/$(date '+%Y%m%d%H%M%S')"
  mkdir -p "$BACKUP_DIR"
  : > "${BACKUP_DIR}/manifest.txt"
  PREVIOUS_SERVICE_STATES_FILE="${BACKUP_DIR}/service-states.txt"
  PREVIOUS_AUTHSELECT_FILE="${BACKUP_DIR}/authselect-current.txt"
  : > "$PREVIOUS_SERVICE_STATES_FILE"
  if command -v authselect >/dev/null 2>&1; then
    authselect current > "$PREVIOUS_AUTHSELECT_FILE" 2>&1 || true
  fi

  for svc in "${SERVICES_TO_ENABLE[@]}" "${LOCAL_CLIENT_SERVICES[@]}"; do
    local enabled_state active_state
    enabled_state="$(systemctl is-enabled "$svc" 2>/dev/null || true)"
    active_state="$(systemctl is-active "$svc" 2>/dev/null || true)"
    printf '%s|%s|%s\n' "$svc" "$enabled_state" "$active_state" >> "$PREVIOUS_SERVICE_STATES_FILE"
  done

  for file in "${BACKUP_FILES[@]}"; do
    local backup_name
    backup_name="${BACKUP_DIR}/$(echo "$file" | sed 's#/#_#g')"
    if [[ -e "$file" ]]; then
      cp -a "$file" "$backup_name"
      printf '%s|%s|yes\n' "$backup_name" "$file" >> "${BACKUP_DIR}/manifest.txt"
    else
      printf '%s|%s|no\n' "$backup_name" "$file" >> "${BACKUP_DIR}/manifest.txt"
    fi
  done
  info "Backups created under ${BACKUP_DIR}"
}

check_packages() {
  local missing=()
  for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! rpm -q "$pkg" >>"$LOG_FILE" 2>&1; then
      missing+=("$pkg")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    info "All required packages are installed: ${REQUIRED_PACKAGES[*]}"
    return 0
  fi

  warn "Missing packages: ${missing[*]}"
  if [[ "$SKIP_PACKAGE_INSTALL" == "true" ]]; then
    fail "Required packages are missing and --skip-package-install was specified."
  fi
  run_cmd dnf install -y "${missing[@]}"
}

set_kv_file() {
  local file="$1" key="$2" value="$3"
  if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY-RUN: set ${key} in ${file}"
    return 0
  fi
  touch "$file"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

configure_hostname_and_hosts() {
  if [[ "$SET_HOSTNAME" == "true" ]]; then
    run_cmd hostnamectl set-hostname "$MASTER_FQDN"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY-RUN: ensure ${MASTER_IP} ${MASTER_FQDN} ${MASTER_FQDN%%.*} exists in /etc/hosts"
    return 0
  fi

  if grep -qE "^[[:space:]]*${MASTER_IP}[[:space:]]+" /etc/hosts; then
    sed -i "s|^[[:space:]]*${MASTER_IP}[[:space:]].*|${MASTER_IP} ${MASTER_FQDN} ${MASTER_FQDN%%.*}|" /etc/hosts
  elif grep -qE "[[:space:]]${MASTER_FQDN}([[:space:]]|$)" /etc/hosts; then
    sed -i "s|^.*[[:space:]]${MASTER_FQDN}\([[:space:]].*\)\?$|${MASTER_IP} ${MASTER_FQDN} ${MASTER_FQDN%%.*}|" /etc/hosts
  else
    printf '%s %s %s\n' "$MASTER_IP" "$MASTER_FQDN" "${MASTER_FQDN%%.*}" >> /etc/hosts
  fi
}

configure_nis_domain_and_ports() {
  run_cmd ypdomainname "$NIS_DOMAIN"
  # RHEL still uses /etc/sysconfig/network for the persistent NIS domain.
  set_kv_file /etc/sysconfig/network NISDOMAIN "$NIS_DOMAIN"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY-RUN: write service-specific sysconfig files for ypserv, ypxfrd, and yppasswdd"
  else
    cat > /etc/sysconfig/ypserv <<EOF
# Managed by ${SCRIPT_NAME} v${SCRIPT_VERSION}
YPSERV_ARGS="-p ${YPSERV_PORT}"
EOF
    cat > /etc/sysconfig/ypxfrd <<EOF
# Managed by ${SCRIPT_NAME} v${SCRIPT_VERSION}
YPXFRD_ARGS="-p ${YPXFRD_PORT}"
EOF
    cat > /etc/sysconfig/yppasswdd <<EOF
# Managed by ${SCRIPT_NAME} v${SCRIPT_VERSION}
YPPASSWDD_ARGS="--port ${YPPASSWDD_PORT}"
EOF
  fi
}

validate_service_environment_files() {
  if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY-RUN: skip systemd EnvironmentFile validation."
    return 0
  fi

  # Production guardrail: warn if the packaged service units do not reference
  # the expected service-specific sysconfig files or variables. Runtime port
  # validation after service start is still authoritative.
  if systemctl cat ypserv 2>/dev/null | grep -Eq '/etc/sysconfig/ypserv|YPSERV_ARGS'; then
    info "ypserv unit appears to support pinned arguments from sysconfig."
  else
    warn "ypserv unit does not visibly reference /etc/sysconfig/ypserv or YPSERV_ARGS. Runtime validation will confirm port binding."
  fi

  if systemctl cat ypxfrd 2>/dev/null | grep -Eq '/etc/sysconfig/ypxfrd|YPXFRD_ARGS'; then
    info "ypxfrd unit appears to support pinned arguments from sysconfig."
  else
    warn "ypxfrd unit does not visibly reference /etc/sysconfig/ypxfrd or YPXFRD_ARGS. Runtime validation will confirm port binding."
  fi
}

configure_securenets() {
  local bits netmask network
  bits="${ALLOWED_CIDR#*/}"
  netmask="$(cidr_to_netmask "$bits")"
  network="$(cidr_network "$ALLOWED_CIDR")"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY-RUN: write /var/yp/securenets for ${network}/${bits}"
    return 0
  fi

  mkdir -p /var/yp
  cat > /var/yp/securenets <<EOF
# Managed by ${SCRIPT_NAME} v${SCRIPT_VERSION}
# Restrict NIS access to localhost and the approved trusted client network.
host            127.0.0.1
${netmask}      ${network}
EOF
  chmod 0644 /var/yp/securenets
}

configure_selinux() {
  [[ "$SKIP_SELINUX" == "true" ]] && { info "Skipping SELinux configuration."; return 0; }
  command -v getenforce >/dev/null 2>&1 || { info "SELinux tools not found. Skipping."; return 0; }
  command -v setsebool >/dev/null 2>&1 || { warn "setsebool not found. Skipping SELinux booleans."; return 0; }
  run_cmd setsebool -P nis_enabled on
  run_cmd setsebool -P domain_can_mmap_files on
}

configure_firewall() {
  [[ "$SKIP_FIREWALL" == "true" ]] && { info "Skipping firewalld configuration."; return 0; }
  if ! systemctl list-unit-files firewalld.service >/dev/null 2>&1; then
    info "firewalld unit not found. Skipping host firewall configuration."
    return 0
  fi
  if ! systemctl is-active --quiet firewalld; then
    info "firewalld is not active. Skipping host firewall configuration."
    return 0
  fi
  command -v firewall-cmd >/dev/null 2>&1 || { warn "firewall-cmd not found. Skipping."; return 0; }
  run_cmd firewall-cmd --add-service=rpc-bind --permanent
  run_cmd firewall-cmd --add-port="${FIREWALL_PORT_START}-${FIREWALL_PORT_END}/tcp" --permanent
  run_cmd firewall-cmd --add-port="${FIREWALL_PORT_START}-${FIREWALL_PORT_END}/udp" --permanent
  run_cmd firewall-cmd --reload
}

enable_services() {
  run_cmd systemctl enable --now "${SERVICES_TO_ENABLE[@]}"
  run_cmd systemctl restart "${SERVICES_TO_ENABLE[@]}"
}

initialize_maps() {
  local map_dir="/var/yp/${NIS_DOMAIN}"
  if [[ -d "$map_dir" && "$FORCE_INIT" != "true" ]]; then
    info "NIS maps already exist at ${map_dir}. Skipping ypinit. Use --force-init to rebuild initial maps."
    run_cmd make -C /var/yp
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY-RUN: initialize NIS master maps with ypinit -m"
    return 0
  fi

  info "Initializing NIS master maps."
  printf '%s\n' "$MASTER_FQDN" | /usr/lib64/yp/ypinit -m >>"$LOG_FILE" 2>&1
  run_cmd make -C /var/yp
}

configure_local_client() {
  [[ "$CONFIGURE_LOCAL_CLIENT" == "true" ]] || { info "Local NIS client configuration not requested."; return 0; }
  command -v authselect >/dev/null 2>&1 || fail "authselect is required for RHEL 8 local client NSS/PAM configuration."

  if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY-RUN: configure yp.conf and select authselect nis profile for local client binding"
    return 0
  fi

  cat > /etc/yp.conf <<EOF
# Managed by ${SCRIPT_NAME} v${SCRIPT_VERSION}
domain ${NIS_DOMAIN} server ${MASTER_FQDN}
EOF

  # RHEL 8 manages /etc/nsswitch.conf through authselect. Do not modify it
  # directly; selecting the nis profile applies the NIS-compatible NSS/PAM set.
  authselect select nis --force >>"$LOG_FILE" 2>&1
  authselect apply-changes >>"$LOG_FILE" 2>&1

  run_cmd systemctl enable --now ypbind
  run_cmd systemctl restart ypbind
}

validate_runtime() {
  info "Running post-install validation."
  run_cmd systemctl is-active rpcbind
  run_cmd systemctl is-active ypserv
  run_cmd systemctl is-active ypxfrd
  run_cmd systemctl is-active yppasswdd

  if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY-RUN: skip rpcinfo and map validation."
    return 0
  fi

  rpcinfo -p localhost >>"$LOG_FILE" 2>&1 || fail "rpcinfo validation failed."
  if ! rpcinfo -p localhost | grep -qE 'ypserv|ypprog'; then
    fail "ypserv RPC program not visible in rpcinfo output."
  fi
  if ! rpcinfo -p localhost | awk -v p="$YPSERV_PORT" '$3 == "tcp" || $3 == "udp" { if ($4 == p) found=1 } END { exit(found ? 0 : 1) }'; then
    fail "ypserv does not appear to be bound to the requested pinned port ${YPSERV_PORT}. Check systemd unit EnvironmentFile handling."
  fi
  if ! rpcinfo -p localhost | awk -v p="$YPXFRD_PORT" '$3 == "tcp" || $3 == "udp" { if ($4 == p) found=1 } END { exit(found ? 0 : 1) }'; then
    fail "ypxfrd does not appear to be bound to the requested pinned port ${YPXFRD_PORT}. Check systemd unit EnvironmentFile handling."
  fi
  [[ -d "/var/yp/${NIS_DOMAIN}" ]] || fail "Expected map directory /var/yp/${NIS_DOMAIN} was not created."
  info "Validation passed."
}

print_aws_security_group_notice() {
  cat <<EOF | tee -a "$LOG_FILE"

AWS Security Group reminder:
  Allow inbound traffic only from trusted NIS clients or their security group:
    TCP 111, UDP 111
    TCP ${FIREWALL_PORT_START}-${FIREWALL_PORT_END}, UDP ${FIREWALL_PORT_START}-${FIREWALL_PORT_END}
  Do not expose these ports to 0.0.0.0/0.

EOF
}

main() {
  parse_args "$@"
  require_root
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  prompt_if_missing NIS_DOMAIN "Enter NIS domain, for example corpnis"
  prompt_if_missing MASTER_FQDN "Enter this server's private FQDN" "$(hostname -f 2>/dev/null || hostname)"
  prompt_if_missing MASTER_IP "Enter this server's private IP address"
  prompt_if_missing ALLOWED_CIDR "Enter trusted client CIDR, for example 10.0.0.0/16"

  validate_inputs
  validate_rhel

  cat <<SUMMARY | tee -a "$LOG_FILE"

Configuration summary:
  Script version:          ${SCRIPT_VERSION}
  NIS domain:              ${NIS_DOMAIN}
  Master FQDN:             ${MASTER_FQDN}
  Master IP:               ${MASTER_IP}
  Allowed CIDR:            ${ALLOWED_CIDR}
  Set hostname:            ${SET_HOSTNAME}
  Configure local client:  ${CONFIGURE_LOCAL_CLIENT}
  ypserv port:             ${YPSERV_PORT}
  ypxfrd port:             ${YPXFRD_PORT}
  yppasswdd port:          ${YPPASSWDD_PORT}
  Dry run:                 ${DRY_RUN}
  Rollback on error:       ${ROLLBACK_ON_ERROR}

SUMMARY

  confirm "Proceed with NIS Master installation and configuration?" || fail "User cancelled."

  prepare_logging_and_backup
  check_packages
  configure_hostname_and_hosts
  configure_nis_domain_and_ports
  validate_service_environment_files
  configure_securenets
  configure_selinux
  configure_firewall
  enable_services
  initialize_maps
  configure_local_client
  validate_runtime
  print_aws_security_group_notice

  info "NIS Master installation completed successfully."
  info "Log file: ${LOG_FILE}"
  [[ -n "$BACKUP_DIR" ]] && info "Backup directory: ${BACKUP_DIR}"
}

main "$@"
