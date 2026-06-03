#!/usr/bin/env bash
# join-ubuntu-to-ad.sh
# Version: 1.1.1
# Release date: 2026-06-02
# Join Ubuntu 24.04.x LTS to an Active Directory domain using realmd + SSSD.
# Supports interactive prompts and non-interactive CLI switches.
# Run as root for all actions except --help and --version.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.1.1"
SCRIPT_VERSION_DATE="2026-06-02"
LOG_FILE="/var/log/ubuntu-ad-join.log"
BACKUP_DIR=""
ROLLBACK_ON_ERROR=1
NON_INTERACTIVE=0
DO_UPDATE=1
DO_ROLLBACK_ONLY=0
VERBOSE=0
XTRACE_WAS_ON=0
DOMAIN=""
REALM=""
JOIN_USER=""
PASSWORD_FILE=""
COMPUTER_OU=""
HOST_FQDN=""
DNS_SERVERS=""
TEST_USER=""
MEMBERSHIP_SOFTWARE="auto"
SHORT_NAMES=0
ALLOW_REBOOT_REQUIRED=0

REQUIRED_PACKAGES=(
  realmd sssd sssd-tools sssd-ad libnss-sss libpam-sss adcli
  samba-common-bin oddjob oddjob-mkhomedir packagekit krb5-user
  chrony dnsutils netcat-openbsd
)

usage() {
  cat <<'EOF'
Usage:
  sudo ./join-ubuntu-to-ad.sh [options]

Interactive example:
  sudo ./join-ubuntu-to-ad.sh

Non-interactive example:
  sudo ./join-ubuntu-to-ad.sh \
    --non-interactive \
    --domain corp.example.com \
    --user join_account \
    --password-file /root/ad_join_password.txt \
    --dns 10.0.0.10,10.0.0.11 \
    --hostname ubuntu01.corp.example.com \
    --membership-software auto \
    --test-user 'someuser@corp.example.com'

Options:
  --domain DOMAIN                 AD DNS domain, e.g. corp.example.com. Required.
  --realm REALM                   Kerberos realm, usually uppercase DOMAIN. Optional.
  --user USER                     AD account permitted to join computers. Required.
  --password-file FILE            File containing AD password. If omitted, prompt securely.
  --computer-ou OU                Optional OU DN, e.g. OU=Linux,OU=Servers,DC=corp,DC=example,DC=com.
  --hostname FQDN                 Optional FQDN to set before joining.
  --dns IP[,IP]                   Optional AD DNS server IPs; persisted via systemd-resolved drop-in.
  --test-user USER                Optional AD user for id/getent validation after join.
  --membership-software VALUE     auto, adcli, or samba. auto tries adcli then samba fallback.
                                  Samba fallback is useful with some Windows Server 2025 domains.
  --short-names                   Configure SSSD use_fully_qualified_names = False.
  --no-update                     Skip apt full-upgrade; still installs required packages.
  --allow-reboot-required         Do not treat /var/run/reboot-required as a validation warning.
  --no-auto-rollback              Do not automatically rollback on error.
  --rollback                      Leave the joined domain and restore latest backup, then exit.
  --non-interactive               Do not prompt; fail if required values are missing.
  -v, --verbose                   Echo non-sensitive commands and log more detail.
  -V, --version                   Show script version. Does not require root.
  -h, --help                      Show help. Does not require root.

Log:
  /var/log/ubuntu-ad-join.log
EOF
}

show_version() {
  echo "${SCRIPT_NAME} version ${SCRIPT_VERSION} (${SCRIPT_VERSION_DATE})"
}

log() {
  local msg
  msg="$(date '+%F %T%z') [$1] ${*:2}"
  if [[ -w "$LOG_FILE" || ( ! -e "$LOG_FILE" && -w "$(dirname "$LOG_FILE")" ) ]]; then
    echo "$msg" | tee -a "$LOG_FILE" >&2
  else
    echo "$msg" >&2
  fi
}
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
err() { log ERROR "$@"; }
fatal() { err "$@"; exit 1; }

run() {
  info "RUN: $*"
  if (( VERBOSE )); then "$@" 2>&1 | tee -a "$LOG_FILE"; else "$@" >>"$LOG_FILE" 2>&1; fi
}

trim() { local var="$*"; var="${var#${var%%[![:space:]]*}}"; echo "${var%${var##*[![:space:]]}}"; }
upper() { echo "$1" | tr '[:lower:]' '[:upper:]'; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain) DOMAIN="${2:-}"; shift 2 ;;
      --realm) REALM="${2:-}"; shift 2 ;;
      --user) JOIN_USER="${2:-}"; shift 2 ;;
      --password-file) PASSWORD_FILE="${2:-}"; shift 2 ;;
      --computer-ou) COMPUTER_OU="${2:-}"; shift 2 ;;
      --hostname) HOST_FQDN="${2:-}"; shift 2 ;;
      --dns) DNS_SERVERS="${2:-}"; shift 2 ;;
      --test-user) TEST_USER="${2:-}"; shift 2 ;;
      --membership-software) MEMBERSHIP_SOFTWARE="${2:-}"; shift 2 ;;
      --short-names) SHORT_NAMES=1; shift ;;
      --no-update) DO_UPDATE=0; shift ;;
      --allow-reboot-required) ALLOW_REBOOT_REQUIRED=1; shift ;;
      --no-auto-rollback) ROLLBACK_ON_ERROR=0; shift ;;
      --rollback) DO_ROLLBACK_ONLY=1; shift ;;
      --non-interactive) NON_INTERACTIVE=1; shift ;;
      -v|--verbose) VERBOSE=1; shift ;;
      -V|--version) show_version; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      *) fatal "Unknown option: $1. Use --help." ;;
    esac
  done
}

enable_xtrace_if_requested() {
  if (( VERBOSE )); then
    XTRACE_WAS_ON=1
    set -x
  fi
}

prompt_if_needed() {
  if [[ -z "$DOMAIN" ]]; then
    (( NON_INTERACTIVE )) && fatal "--domain is required in non-interactive mode."
    read -r -p "AD DNS domain (e.g. corp.example.com): " DOMAIN
  fi
  DOMAIN="$(trim "$DOMAIN")"
  [[ -z "$DOMAIN" ]] && fatal "Domain cannot be empty."
  [[ "$DOMAIN" =~ ^[A-Za-z0-9._-]+$ ]] || fatal "Domain contains invalid characters."
  [[ -z "$REALM" ]] && REALM="$(upper "$DOMAIN")"

  if [[ -z "$JOIN_USER" ]]; then
    (( NON_INTERACTIVE )) && fatal "--user is required in non-interactive mode."
    read -r -p "AD join user: " JOIN_USER
  fi
  [[ -z "$JOIN_USER" ]] && fatal "Join user cannot be empty."

  if [[ -z "$PASSWORD_FILE" && $NON_INTERACTIVE -eq 0 ]]; then
    set +x
    read -r -s -p "AD password for ${JOIN_USER}: " AD_PASSWORD; echo >&2
    if (( XTRACE_WAS_ON )); then set -x; fi
  elif [[ -n "$PASSWORD_FILE" ]]; then
    [[ -r "$PASSWORD_FILE" ]] || fatal "Password file is not readable: $PASSWORD_FILE"
    set +x
    AD_PASSWORD="$(<"$PASSWORD_FILE")"
    AD_PASSWORD="${AD_PASSWORD%$'\n'}"
    if (( XTRACE_WAS_ON )); then set -x; fi
  else
    fatal "--password-file is required in non-interactive mode."
  fi
  [[ -z "${AD_PASSWORD:-}" ]] && fatal "AD password cannot be empty."

  if [[ -z "$DNS_SERVERS" && $NON_INTERACTIVE -eq 0 ]]; then
    read -r -p "AD DNS server IPs comma-separated [leave blank to keep current DNS]: " DNS_SERVERS
  fi
  if [[ -z "$HOST_FQDN" && $NON_INTERACTIVE -eq 0 ]]; then
    read -r -p "Set host FQDN before join [leave blank to keep current]: " HOST_FQDN
  fi
  if [[ -z "$TEST_USER" && $NON_INTERACTIVE -eq 0 ]]; then
    read -r -p "AD test user for validation [optional, e.g. user@${DOMAIN}]: " TEST_USER
  fi

  case "$MEMBERSHIP_SOFTWARE" in auto|adcli|samba) ;; *) fatal "--membership-software must be auto, adcli, or samba." ;; esac
}

require_root_and_ubuntu() {
  [[ $EUID -eq 0 ]] || fatal "Run as root, e.g. sudo ./$SCRIPT_NAME"
  [[ -r /etc/os-release ]] || fatal "/etc/os-release not found."
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || fatal "This script is intended for Ubuntu; detected ID=${ID:-unknown}."
  [[ "${VERSION_ID:-}" == 24.04 ]] || fatal "This script is intended for Ubuntu 24.04.x LTS; detected VERSION_ID=${VERSION_ID:-unknown}."
  info "Detected Ubuntu ${VERSION_ID} (${VERSION_CODENAME:-unknown})."
}

initialize_log() {
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  info "Starting ${SCRIPT_NAME} version ${SCRIPT_VERSION} (${SCRIPT_VERSION_DATE})."
}

create_backup() {
  BACKUP_DIR="/var/backups/ubuntu-ad-join/$(date '+%Y%m%d-%H%M%S')"
  run mkdir -p "$BACKUP_DIR"
  for p in /etc/sssd/sssd.conf /etc/krb5.conf /etc/nsswitch.conf /etc/pam.d/common-session /etc/systemd/resolved.conf; do
    [[ -e "$p" ]] && run cp -a "$p" "$BACKUP_DIR/$(basename "$p").bak"
  done
  [[ -d /etc/systemd/resolved.conf.d ]] && run cp -a /etc/systemd/resolved.conf.d "$BACKUP_DIR/resolved.conf.d.bak" || true
  echo "$BACKUP_DIR" > /var/backups/ubuntu-ad-join/latest
  info "Backup created at $BACKUP_DIR"
}

rollback() {
  warn "Starting rollback."
  local latest=""
  [[ -f /var/backups/ubuntu-ad-join/latest ]] && latest="$(cat /var/backups/ubuntu-ad-join/latest)"
  if command -v realm >/dev/null 2>&1 && [[ -n "${DOMAIN:-}" ]]; then
    realm leave "$DOMAIN" >>"$LOG_FILE" 2>&1 || warn "realm leave failed or host was not joined."
  elif command -v realm >/dev/null 2>&1; then
    realm leave >>"$LOG_FILE" 2>&1 || true
  fi
  if [[ -n "$latest" && -d "$latest" ]]; then
    for p in sssd.conf krb5.conf nsswitch.conf common-session resolved.conf; do
      [[ -e "$latest/$p.bak" ]] && cp -a "$latest/$p.bak" "/etc/${p}" || true
    done
    rm -f /etc/systemd/resolved.conf.d/90-ad-domain-join.conf || true
    if [[ -d "$latest/resolved.conf.d.bak" ]]; then
      mkdir -p /etc/systemd/resolved.conf.d
      cp -a "$latest/resolved.conf.d.bak/." /etc/systemd/resolved.conf.d/
    fi
    systemctl restart systemd-resolved sssd oddjobd >>"$LOG_FILE" 2>&1 || true
    info "Restored backup from $latest"
  else
    warn "No backup found to restore."
  fi
}

on_error() {
  local line="$1" code="$2"
  set +x
  err "Failure at line $line with exit code $code. See $LOG_FILE."
  if (( ROLLBACK_ON_ERROR )); then rollback; else warn "Auto-rollback disabled."; fi
  exit "$code"
}
trap 'on_error $LINENO $?' ERR

update_and_install() {
  export DEBIAN_FRONTEND=noninteractive
  run apt-get update
  if (( DO_UPDATE )); then
    run apt-get -y full-upgrade
  else
    warn "Skipping full-upgrade because --no-update was specified."
  fi
  info "Installing chrony for Kerberos-friendly time sync. This may disable systemd-timesyncd, which is normal on Ubuntu when chrony is installed."
  run apt-get install -y "${REQUIRED_PACKAGES[@]}"
  run systemctl enable --now chrony
  run systemctl enable --now oddjobd
}

wait_for_resolved() {
  info "Waiting for systemd-resolved to initialize..."
  local i
  for i in {1..10}; do
    if resolvectl status >>"$LOG_FILE" 2>&1; then
      sleep 1
      return 0
    fi
    sleep 1
  done
  fatal "systemd-resolved did not become ready after restart."
}

configure_hostname_dns_time() {
  if [[ -n "$HOST_FQDN" ]]; then
    run hostnamectl set-hostname "$HOST_FQDN"
  fi
  if [[ -n "$DNS_SERVERS" ]]; then
    local dns_space="${DNS_SERVERS//,/ }"
    run mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/90-ad-domain-join.conf <<EOF
[Resolve]
DNS=${dns_space}
Domains=${DOMAIN}
EOF
    run systemctl restart systemd-resolved
    wait_for_resolved
  fi
  if ! grep -qiE "^server[[:space:]]+${DOMAIN//./\.}[[:space:]]" /etc/chrony/chrony.conf; then
    echo "server ${DOMAIN} iburst prefer" >> /etc/chrony/chrony.conf
    run systemctl restart chrony
  fi
}

preflight_checks() {
  info "Running preflight DNS and network checks."
  run resolvectl status
  run dig +short "$DOMAIN"
  run dig +short SRV "_ldap._tcp.${DOMAIN}"
  run realm -v discover "$DOMAIN"
  if [[ -n "$DNS_SERVERS" ]]; then
    local first_dns="${DNS_SERVERS%%,*}"
    nc -z -w 3 "$first_dns" 53 >>"$LOG_FILE" 2>&1 || warn "Could not verify TCP/53 to first DNS server $first_dns. UDP DNS may still work."
  fi
  chronyc tracking >>"$LOG_FILE" 2>&1 || warn "chronyc tracking failed; verify time sync if Kerberos errors occur."
}

join_domain_once() {
  local method="$1"
  local args=(realm join -v --user="$JOIN_USER" --membership-software="$method")
  [[ -n "$COMPUTER_OU" ]] && args+=(--computer-ou="$COMPUTER_OU")
  args+=("$DOMAIN")
  info "Attempting domain join using membership software: $method"

  # Do not allow set -x to print AD_PASSWORD. This protects console, logs, and terminal scrollback.
  set +x
  printf '%s\n' "$AD_PASSWORD" | "${args[@]}" >>"$LOG_FILE" 2>&1
  local rc=$?
  if (( XTRACE_WAS_ON )); then set -x; fi
  return "$rc"
}

join_domain() {
  if realm list | grep -qiE "^${DOMAIN}[[:space:]]*$"; then
    info "System already appears joined to $DOMAIN. Skipping join."
    return 0
  fi
  if [[ "$MEMBERSHIP_SOFTWARE" == "auto" ]]; then
    if join_domain_once adcli; then
      info "Domain join succeeded using adcli."
    else
      warn "adcli join failed; trying samba fallback. This can help with Windows Server 2025 domain controllers."
      join_domain_once samba
      info "Domain join succeeded using samba."
    fi
  else
    join_domain_once "$MEMBERSHIP_SOFTWARE"
    info "Domain join succeeded using $MEMBERSHIP_SOFTWARE."
  fi
}

post_configure() {
  run pam-auth-update --enable mkhomedir --force
  if [[ -f /etc/sssd/sssd.conf ]]; then
    run chmod 600 /etc/sssd/sssd.conf
    if (( SHORT_NAMES )); then
      if grep -q '^use_fully_qualified_names' /etc/sssd/sssd.conf; then
        sed -i 's/^use_fully_qualified_names.*/use_fully_qualified_names = False/' /etc/sssd/sssd.conf
      else
        sed -i '/^\[domain\//a use_fully_qualified_names = False' /etc/sssd/sssd.conf
      fi
    fi
  fi
  run systemctl enable --now sssd
  run systemctl restart sssd
}

validate_join() {
  info "Running post-join validation."
  run realm list
  realm list | grep -qi "configured: kerberos-member" || fatal "realm list does not show configured: kerberos-member."
  getent passwd "${JOIN_USER}@${DOMAIN}" >>"$LOG_FILE" 2>&1 || warn "Could not resolve ${JOIN_USER}@${DOMAIN}; this may be expected if join account is not a normal user or short-names are enabled."
  if [[ -n "$TEST_USER" ]]; then
    run id "$TEST_USER"
    getent passwd "$TEST_USER" >>"$LOG_FILE" 2>&1 || warn "getent passwd failed for $TEST_USER, but id may have succeeded."
  fi
  if [[ -f /var/run/reboot-required && $ALLOW_REBOOT_REQUIRED -eq 0 ]]; then
    warn "A reboot is required due to package updates: /var/run/reboot-required exists."
  fi
  info "Validation complete. Domain join finished successfully."
}

main() {
  parse_args "$@"
  require_root_and_ubuntu
  initialize_log
  enable_xtrace_if_requested
  if (( DO_ROLLBACK_ONLY )); then rollback; exit 0; fi
  prompt_if_needed
  create_backup
  update_and_install
  configure_hostname_dns_time
  preflight_checks
  join_domain
  post_configure
  validate_join
  info "Success. ${SCRIPT_NAME} version ${SCRIPT_VERSION}. Log file: $LOG_FILE"
}

main "$@"
