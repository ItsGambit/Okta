#!/usr/bin/env bash
# ==============================================================================
# db-install.sh
# ==============================================================================
# Description  : Install and configure MySQL, PostgreSQL, and MongoDB on any
#                Linux distribution supported by Okta Privileged Access (OPA).
#                Creates an OPA service account in each database (MySQL +
#                PostgreSQL) for use with the OPA Database Gateway JIT feature.
#
# Version      : 1.3.2
# Supported OS : Ubuntu 20.04 / 22.04 / 24.04
#                Debian 11 (bullseye) / 12 (bookworm)
#                RHEL 8 / 9
#                CentOS Stream 8 / 9
#                Alma Linux 8 / 9
#                Amazon Linux 2 / 2023
#                SUSE Linux Enterprise Server 15
#
# Usage:
#   ./db-install.sh [OPTIONS]
#
#   Database selection (default: all three):
#     -m, --mysql              Install MySQL only
#     -p, --postgresql         Install PostgreSQL only
#     -g, --mongodb            Install MongoDB only
#     -a, --all                Install all three (default)
#
#   Mode:
#     -i, --interactive        Prompt for all settings (default)
#     -n, --non-interactive    Unattended / CI / pipeline mode
#
#   Environment:
#         --production         Configure and enable OS firewall with best-practice
#                              rules (default: lab mode — firewall disabled)
#         --allowed-cidr CIDR  Source CIDR for production firewall rules
#                              (default: 10.1.0.0/20)
#
#   Passwords (auto-generated if omitted):
#         --mysql-root-password   PW   MySQL root password
#         --pg-admin-password     PW   PostgreSQL admin password
#         --mongo-admin-password  PW   MongoDB admin password
#         --opa-svc-password      PW   Shared OPA service-account password
#
#   Seeding (optional — lab data generation):
#         --seed-data              Seed each DB with lab data (default: off)
#         --seed-dbs N             Databases per engine (default: 3)
#         --seed-rows N            Rows per table/collection (default: 1000)
#         --lab-admin-user NAME    Global superuser name (default: lab_admin)
#         --lab-admin-password PW  Global superuser password (auto-generated if omitted)
#
#   Output:
#     -l, --log-file  PATH     Log file path (default: /var/log/db-install.log)
#     -c, --cred-file PATH     Credentials output file
#                              (default: /root/db-credentials.txt)
#
#   Other:
#         --dry-run            Print every action without executing
#         --rollback           Undo a previous installation
#     -v, --verbose            Enable DEBUG-level output
#     -h, --help               Show this help message and exit
# ==============================================================================

set -uo pipefail    # Strict mode: treat unset vars as errors, propagate pipe failures
                    # NOTE: -e (exit on error) is intentionally omitted so each step
                    # can trigger rollback before the script exits.

# ==============================================================================
# SECTION 1: CONSTANTS & VERSION
# ==============================================================================

readonly SCRIPT_VERSION="1.3.2"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_START_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
readonly SCRIPT_PID="$$"

readonly LOG_FILE_DEFAULT="/var/log/db-install.log"
readonly CRED_FILE_DEFAULT="/root/db-credentials.txt"
readonly TEMP_DIR="/tmp/db-install-${SCRIPT_PID}"

# Supported PostgreSQL major version installed from PGDG
readonly PG_VERSION="16"

# ==============================================================================
# SECTION 2: RUNTIME DEFAULTS  (overridden by CLI flags)
# ==============================================================================

INSTALL_MYSQL=false
INSTALL_PG=false
INSTALL_MONGO=false
INTERACTIVE=true
DRY_RUN=false
VERBOSE=false
PRODUCTION_MODE=false
DO_ROLLBACK=false
ALLOWED_CIDR="10.1.0.0/20"

LOG_FILE="$LOG_FILE_DEFAULT"
CRED_FILE="$CRED_FILE_DEFAULT"

# Passwords — empty means "generate randomly at runtime"
MYSQL_ROOT_PW=""
MYSQL_ADMIN_PW=""
PG_ADMIN_PW=""
MONGO_ADMIN_PW=""
OPA_SVC_PW=""

# Seeding (disabled by default)
SEED_DATA=false
SEED_DBS=3
SEED_ROWS=1000
LAB_ADMIN_USER="lab_admin"
LAB_ADMIN_PW=""

# Arrays tracking seeded DBs (populated during seeding) — each element: "db_name:db_user:db_password"
MYSQL_SEEDED_DBS=()
PG_SEEDED_DBS=()
MONGO_SEEDED_DBS=()

# Populated by detect_os()
OS_ID=""
OS_VERSION=""
OS_CODENAME=""
DISTRO_FAMILY=""
PKG_MANAGER=""

# Service names — set by install functions (differ between distro families)
MYSQL_SERVICE=""
PG_SERVICE=""
PG_DATA_DIR=""
PG_HBA_CONF=""
MONGO_SERVICE=""

# ==============================================================================
# SECTION 3: TERMINAL COLOURS
# ==============================================================================

# Only emit colour codes when stdout is a real terminal
if [[ -t 1 ]] && command -v tput &>/dev/null; then
  RED="$(tput setaf 1)"
  GREEN="$(tput setaf 2)"
  YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"
  CYAN="$(tput setaf 6)"
  BOLD="$(tput bold)"
  NC="$(tput sgr0)"
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; NC=""
fi

# ==============================================================================
# SECTION 4: LOGGING
# ==============================================================================

# Internal log writer — appends to log file and prints to stdout
# Args: LEVEL  MESSAGE
_log() {
  local level="$1"; shift
  local message="$*"
  local timestamp; timestamp="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  local line="[${timestamp}] [${level}] ${message}"

  # Append to log file (if it's been initialised)
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "$line" >> "$LOG_FILE" 2>/dev/null || true
  fi

  # Print to stdout with colour
  case "$level" in
    INFO)  echo -e "${GREEN}${line}${NC}" ;;
    WARN)  echo -e "${YELLOW}${line}${NC}" ;;
    ERROR) echo -e "${RED}${BOLD}${line}${NC}" ;;
    DEBUG) echo -e "${CYAN}${line}${NC}" ;;
    STEP)  echo -e "${BLUE}${BOLD}${line}${NC}" ;;
    DRY)   echo -e "${CYAN}[DRY-RUN] ${message}${NC}" ;;
    *)     echo "$line" ;;
  esac
}

log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() { [[ "$VERBOSE" == "true" ]] && _log DEBUG "$@" || true; }
log_dry()   { _log DRY   "$@"; }

# Section-level divider for readability in both terminal and log file
log_step() {
  local msg="$*"
  local line; line="$(printf '=%.0s' {1..70})"
  _log STEP "${line}"
  _log STEP "  ${msg}"
  _log STEP "${line}"
}

# Initialise the log file with a header banner
init_log() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  {
    echo "=============================================================="
    echo "  db-install.sh v${SCRIPT_VERSION}  —  PAT Lab Database Installer"
    echo "  Started : ${SCRIPT_START_TIME}"
    echo "  PID     : ${SCRIPT_PID}"
    echo "  Host    : $(hostname -f 2>/dev/null || hostname)"
    echo "  Cred file will be written to: ${CRED_FILE}"
    echo "=============================================================="
  } >> "$LOG_FILE" 2>/dev/null || true
  log_info "Logging to ${LOG_FILE}"
}

# ==============================================================================
# SECTION 5: EXIT & ERROR TRAPS
# ==============================================================================

# Tracks whether the script completed successfully
INSTALL_SUCCESS=false

# EXIT trap — always runs on script exit
on_exit() {
  local exit_code="${1:-0}"
  local end_time; end_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ "$INSTALL_SUCCESS" == "true" ]]; then
    log_step "INSTALLATION COMPLETE"
    log_info "All selected databases installed and configured successfully."
    log_info "Credentials written to: ${CRED_FILE}"
    log_info "Full log available at:  ${LOG_FILE}"
  elif [[ "$exit_code" -ne 0 ]]; then
    log_step "INSTALLATION FAILED (exit code: ${exit_code})"
    log_error "See ${LOG_FILE} for details."
  fi

  # Remove temp directory
  rm -rf "$TEMP_DIR" 2>/dev/null || true
  log_debug "Cleaned up temp dir: ${TEMP_DIR}"
}

trap 'on_exit $?' EXIT

# ERR trap — fires on any unhandled non-zero exit within a function
on_error() {
  local lineno="${1:-0}"
  log_error "Unexpected error on line ${lineno} — initiating rollback"
  execute_rollback
  exit 1
}

trap 'on_error $LINENO' ERR

# ==============================================================================
# SECTION 6: ROLLBACK STACK  (LIFO)
# ==============================================================================

declare -a ROLLBACK_STACK=()

# Push a shell command string onto the rollback stack.
# The command will be eval'd in reverse order if rollback is triggered.
push_rollback() {
  ROLLBACK_STACK+=("$1")
  log_debug "Rollback registered: $1"
}

# Execute all rollback commands in reverse order (LIFO)
execute_rollback() {
  if [[ ${#ROLLBACK_STACK[@]} -eq 0 ]]; then
    log_warn "No rollback actions registered — nothing to undo."
    return 0
  fi

  log_step "ROLLBACK — undoing completed steps"
  local i
  for (( i=${#ROLLBACK_STACK[@]}-1; i>=0; i-- )); do
    log_warn "  Rolling back: ${ROLLBACK_STACK[$i]}"
    if ! eval "${ROLLBACK_STACK[$i]}" 2>&1 | tee -a "$LOG_FILE"; then
      log_warn "  Rollback step returned non-zero — continuing with remaining steps."
    fi
  done
  log_info "Rollback complete."
}

# ==============================================================================
# SECTION 7: UTILITY FUNCTIONS
# ==============================================================================

# Check if a command exists on the PATH
command_exists() { command -v "$1" &>/dev/null; }

# Check if running as root
is_root() { [[ "$(id -u)" -eq 0 ]]; }

# Prompt the user for a yes/no confirmation.
# In non-interactive mode, always returns 0 (yes).
confirm() {
  local prompt="${1:-Continue?}"
  if [[ "$INTERACTIVE" == "false" ]]; then
    log_debug "Non-interactive: auto-confirming '${prompt}'"
    return 0
  fi
  local answer
  while true; do
    read -r -p "${BOLD}${prompt} [y/N]: ${NC}" answer
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no|"") return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

# Prompt for a value with a default
prompt_value() {
  local prompt="$1"
  local default="${2:-}"
  local var_name="$3"
  if [[ "$INTERACTIVE" == "false" ]]; then
    # In non-interactive mode, use the default silently
    printf -v "$var_name" '%s' "$default"
    return
  fi
  local answer
  read -r -p "${BOLD}${prompt}${NC} [${default}]: " answer
  printf -v "$var_name" '%s' "${answer:-$default}"
}

# Generate a cryptographically random 32-character alphanumeric password
generate_password() {
  head -c 48 /dev/urandom | base64 | tr -d '+/=' | head -c 32
}

# Escape single quotes for SQL string literals: ' → '' (ANSI SQL standard)
escape_sql() { printf '%s' "$1" | sed "s/'/''/g"; }

# Escape single quotes for JavaScript string literals passed to mongosh --eval
escape_js()  { printf '%s' "$1" | sed "s/'/\\\\'/g"; }

# Validate IPv4 CIDR notation (e.g. 10.1.0.0/20)
validate_cidr() {
  local cidr="$1"
  if ! echo "$cidr" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; then
    log_error "Invalid CIDR format: '${cidr}'. Expected format: x.x.x.x/n  (e.g. 10.1.0.0/20)"
    return 1
  fi
}

# Pool of app domain names used by seeding to generate realistic-looking DB/user names.
# Shuffled at runtime; names are consumed sequentially without repetition up to pool size.
readonly -a SEED_NAME_POOL=(
  "inventory" "payments" "orders" "customers" "analytics"
  "reporting" "catalog" "warehouse" "shipping" "billing"
  "notifications" "auth" "sessions" "metrics" "audit"
  "accounts" "products" "reviews" "subscriptions" "events"
)

# pick_seed_names N  — prints N newline-separated app-domain names,
# shuffled without repetition up to the pool size; cycles with _2, _3... suffix for overflow.
pick_seed_names() {
  local count="$1"
  local pool_size="${#SEED_NAME_POOL[@]}"

  # Fisher-Yates shuffle on a copy of the pool
  local -a pool=("${SEED_NAME_POOL[@]}")
  local i j tmp
  for (( i = pool_size - 1; i > 0; i-- )); do
    j=$(( RANDOM % (i + 1) ))
    tmp="${pool[$i]}"; pool[$i]="${pool[$j]}"; pool[$j]="$tmp"
  done

  # Emit 'count' names; cycle through the pool with _2, _3... suffix when count > pool_size
  local idx cycle=1
  for (( idx = 0; idx < count; idx++ )); do
    local pool_idx=$(( idx % pool_size ))
    if (( idx < pool_size )); then
      printf '%s\n' "${pool[$pool_idx]}"
    else
      # Overflow: start a second pass through the shuffled pool with suffix
      if (( pool_idx == 0 )); then (( cycle++ )); fi
      printf '%s_%d\n' "${pool[$pool_idx]}" "$cycle"
    fi
  done
}

# Execute a shell command, respecting --dry-run mode.
# Logs the command at DEBUG level. Returns the command's exit code.
run_cmd() {
  log_debug "run_cmd: $*"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "$*"
    return 0
  fi
  "$@"
  return $?
}

# Show usage/help text and exit
usage() {
  grep '^#' "${BASH_SOURCE[0]}" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

# ==============================================================================
# SECTION 8: OS DETECTION
# ==============================================================================

# Reads /etc/os-release and sets:
#   OS_ID, OS_VERSION, OS_CODENAME, DISTRO_FAMILY, PKG_MANAGER
detect_os() {
  log_step "Detecting operating system"

  if [[ ! -f /etc/os-release ]]; then
    log_error "/etc/os-release not found. Cannot determine OS."
    exit 1
  fi

  # shellcheck source=/dev/null
  source /etc/os-release

  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-unknown}"
  OS_CODENAME="${VERSION_CODENAME:-}"

  case "$OS_ID" in
    ubuntu)
      DISTRO_FAMILY="debian"
      PKG_MANAGER="apt"
      # Derive codename from VERSION_ID if not already set
      if [[ -z "$OS_CODENAME" ]]; then
        case "$OS_VERSION" in
          20.04) OS_CODENAME="focal" ;;
          22.04) OS_CODENAME="jammy" ;;
          24.04) OS_CODENAME="noble" ;;
          *) log_warn "Ubuntu ${OS_VERSION} codename unknown — may affect repo setup." ;;
        esac
      fi
      ;;
    debian)
      DISTRO_FAMILY="debian"
      PKG_MANAGER="apt"
      if [[ -z "$OS_CODENAME" ]]; then
        case "$OS_VERSION" in
          11) OS_CODENAME="bullseye" ;;
          12) OS_CODENAME="bookworm" ;;
          *) log_warn "Debian ${OS_VERSION} codename unknown." ;;
        esac
      fi
      ;;
    rhel|centos|almalinux)
      DISTRO_FAMILY="rhel"
      command_exists dnf && PKG_MANAGER="dnf" || PKG_MANAGER="yum"
      ;;
    amzn)
      DISTRO_FAMILY="rhel"
      if [[ "$OS_VERSION" == "2" ]]; then
        PKG_MANAGER="yum"
      else
        PKG_MANAGER="dnf"   # Amazon Linux 2023
      fi
      ;;
    sles|opensuse-leap)
      DISTRO_FAMILY="suse"
      PKG_MANAGER="zypper"
      ;;
    *)
      log_error "Unsupported OS: ${OS_ID} ${OS_VERSION}"
      log_error "Supported: Ubuntu 20.04/22.04/24.04, Debian 11/12, RHEL/CentOS/Alma 8/9,"
      log_error "           Amazon Linux 2/2023, SUSE SLES 15"
      exit 1
      ;;
  esac

  log_info "OS detected  : ${OS_ID} ${OS_VERSION} (${OS_CODENAME:-no codename})"
  log_info "Distro family: ${DISTRO_FAMILY}"
  log_info "Pkg manager  : ${PKG_MANAGER}"
}

# ==============================================================================
# SECTION 9: PREREQUISITE CHECKS
# ==============================================================================

check_prerequisites() {
  log_step "Checking prerequisites"
  local failed=false

  # --- Root access ---
  if ! is_root; then
    log_error "This script must be run as root (or via sudo)."
    failed=true
  else
    log_info "Root access    : OK"
  fi

  # --- Minimum RAM: 1 GB ---
  local mem_kb; mem_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  if [[ "$mem_kb" -lt 1048576 ]]; then
    log_warn "Available RAM: $((mem_kb/1024)) MB — recommended minimum is 1 GB."
  else
    log_info "Available RAM  : $((mem_kb/1024)) MB  OK"
  fi

  # --- Minimum disk space: 5 GB on /var ---
  local disk_avail_kb; disk_avail_kb=$(df -k /var 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
  if [[ "$disk_avail_kb" -lt 5242880 ]]; then
    log_warn "Disk space on /var: $((disk_avail_kb/1024)) MB — recommended minimum is 5 GB."
  else
    log_info "Disk space /var: $((disk_avail_kb/1048576)) GB  OK"
  fi

  # --- Required tools (must come before network check — curl may not be present) ---
  # On minimal OS images (Docker, cloud base images), curl is often absent.
  # Installing it here ensures the network connectivity check below can actually run.
  # On Debian/Ubuntu, the local APT index may be empty on fresh cloud instances.
  # We refresh it once (lazily) only if a tool is actually missing, to avoid a
  # slow unnecessary apt-get update when all tools are already present.
  local tools=("curl" "openssl")
  [[ "$DISTRO_FAMILY" == "debian" ]] && tools+=("gpg")
  local apt_updated=false
  for tool in "${tools[@]}"; do
    if ! command_exists "$tool"; then
      log_warn "Required tool missing: ${tool} — will attempt to install."
      if [[ "$PKG_MANAGER" == "apt" && "$apt_updated" == "false" ]]; then
        log_info "Refreshing APT package index before tool installation…"
        pm_update
        apt_updated=true
      fi
      run_cmd "$PKG_MANAGER" install -y "$tool" || {
        log_error "Could not install ${tool}."
        failed=true
      }
    else
      log_debug "Tool present: ${tool}"
    fi
  done

  # --- Network connectivity (curl is now guaranteed to be present) ---
  if ! curl -fsSL --max-time 5 --output /dev/null https://google.com 2>/dev/null; then
    log_warn "No internet connectivity detected (curl to google.com timed out)."
    log_warn "If packages are available via local/proxy mirrors, the install may still succeed."
    if [[ "$INTERACTIVE" == "true" ]]; then
      if ! confirm "Continue despite no internet access?"; then
        log_info "Aborting."; exit 1
      fi
    else
      log_error "Non-interactive mode requires verified internet access. Ensure connectivity or use --dry-run."
      failed=true
    fi
  else
    log_info "Network        : OK"
  fi

  # --- Port availability checks ---
  local ports=()
  [[ "$INSTALL_MYSQL" == "true" ]]  && ports+=(3306)
  [[ "$INSTALL_PG" == "true" ]]     && ports+=(5432)
  [[ "$INSTALL_MONGO" == "true" ]]  && ports+=(27017)

  for port in "${ports[@]}"; do
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
       netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
      log_warn "Port ${port} is already in use — existing service may conflict."
    else
      log_info "Port ${port}      : available"
    fi
  done

  [[ "$failed" == "true" ]] && { log_error "Prerequisites failed. Resolve the above errors and retry."; exit 1; }
  log_info "All prerequisite checks passed."
}

# ==============================================================================
# SECTION 10: PACKAGE MANAGER ABSTRACTION
# ==============================================================================

# Refresh package metadata for the active package manager
pm_update() {
  log_info "Refreshing package metadata…"
  case "$PKG_MANAGER" in
    apt)    run_cmd apt-get update -y ;;
    dnf)    run_cmd dnf makecache -y ;;
    yum)    run_cmd yum makecache -y ;;
    zypper) run_cmd zypper refresh ;;
  esac
}

# Install one or more packages
pm_install() {
  log_info "Installing packages: $*"
  case "$PKG_MANAGER" in
    apt)    run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf)    run_cmd dnf install -y "$@" ;;
    yum)    run_cmd yum install -y "$@" ;;
    zypper) run_cmd zypper install -y "$@" ;;
  esac
}

# Remove/purge one or more packages (used by rollback)
pm_remove() {
  log_warn "Removing packages: $*"
  case "$PKG_MANAGER" in
    apt)    run_cmd env DEBIAN_FRONTEND=noninteractive apt-get purge -y "$@" && run_cmd apt-get autoremove -y ;;
    dnf)    run_cmd dnf remove -y "$@" ;;
    yum)    run_cmd yum remove -y "$@" ;;
    zypper) run_cmd zypper remove -y "$@" ;;
  esac
}

# ==============================================================================
# SECTION 11: MYSQL — INSTALL, CONFIGURE, OPA USER
# ==============================================================================

install_mysql() {
  log_step "Installing MySQL (latest stable from MySQL Community repo)"
  # TEMP_DIR is guaranteed to exist by main() before any install function is called

  case "$DISTRO_FAMILY" in
    debian)
      # Add MySQL APT repo manually (GPG key + sources.list) to avoid the
      # mysql-apt-config .deb package, which launches an interactive Debconf dialog
      # that hangs even in DEBIAN_FRONTEND=noninteractive pipelines.
      local mysql_keyring="/usr/share/keyrings/mysql-server.gpg"
      log_info "Adding MySQL Community APT repository (direct GPG + sources.list method)…"
      run_cmd curl -fsSL https://repo.mysql.com/RPM-GPG-KEY-mysql-2023 \
        | gpg --dearmor | run_cmd tee "$mysql_keyring" > /dev/null
      echo "deb [signed-by=${mysql_keyring}] https://repo.mysql.com/apt/${OS_ID} ${OS_CODENAME} mysql-8.4-lts" \
        | run_cmd tee /etc/apt/sources.list.d/mysql.list > /dev/null
      pm_update
      run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-community-server
      MYSQL_SERVICE="mysql"
      ;;

    rhel)
      # RHEL / CentOS / Alma / Amazon Linux
      local el_ver
      case "$OS_ID-$OS_VERSION" in
        amzn-2)        el_ver="el7" ;;
        amzn-2023)     el_ver="el9" ;;
        *-8|*-8.*)     el_ver="el8" ;;
        *)             el_ver="el9" ;;
      esac
      local rpm_pkg="${TEMP_DIR}/mysql-release.rpm"
      log_info "Adding MySQL Community YUM repo for ${el_ver}…"
      run_cmd curl -fsSL -o "$rpm_pkg" \
        "https://dev.mysql.com/get/mysql84-community-release-${el_ver}-1.noarch.rpm"
      run_cmd rpm -ivh --nodeps "$rpm_pkg" || true   # ignore "already installed"
      # Disable the built-in AppStream mysql module on RHEL 8/9 and Alma/CentOS.
      # Without this, dnf modularity filtering may install the OS-provided version
      # instead of the MySQL Community package, or throw a conflict error.
      if command_exists dnf; then
        run_cmd dnf -qy module disable mysql 2>/dev/null || true
      fi
      pm_install mysql-community-server
      MYSQL_SERVICE="mysqld"
      ;;

    suse)
      # SUSE — use MySQL Community SLES repo
      local sles_rpm="${TEMP_DIR}/mysql-release-sles.rpm"
      run_cmd curl -fsSL -o "$sles_rpm" \
        "https://dev.mysql.com/get/mysql84-community-release-sles15-1.noarch.rpm"
      run_cmd rpm -ivh --nodeps "$sles_rpm" || true
      # --gpg-auto-import-keys prevents zypper from pausing to prompt for key trust
      run_cmd zypper --gpg-auto-import-keys refresh
      pm_install mysql-community-server
      MYSQL_SERVICE="mysqld"
      ;;
  esac

  # Enable and start the MySQL service
  run_cmd systemctl enable --now "$MYSQL_SERVICE" || {
    log_error "Failed to enable/start MySQL service: ${MYSQL_SERVICE}"
    return 1
  }
  log_info "MySQL service '${MYSQL_SERVICE}' enabled and started."

  # Register rollback: stop + purge MySQL + wipe data directory
  push_rollback "systemctl stop ${MYSQL_SERVICE} 2>/dev/null || true; \
    pm_remove mysql-server mysql-community-server mysql-community-client 2>/dev/null || true; \
    rm -rf /var/lib/mysql /etc/mysql"
}

configure_mysql() {
  log_step "Configuring MySQL (security hardening + admin user)"

  # On fresh Debian/Ubuntu installs, root uses auth_socket — no password required.
  # On RHEL-family RPM installs, a temp password is written to the error log.
  local connect_opts=()

  if [[ "$DISTRO_FAMILY" == "rhel" || "$DISTRO_FAMILY" == "suse" ]]; then
    # Extract the temp password from mysqld.log (RHEL installs)
    local temp_pw=""
    temp_pw=$(grep 'temporary password' /var/log/mysqld.log 2>/dev/null | tail -1 | awk '{print $NF}' || true)
    if [[ -n "$temp_pw" ]]; then
      log_info "Found MySQL temporary password in mysqld.log."
      connect_opts=(-u root "-p${temp_pw}" --connect-expired-password)
    else
      log_warn "No temporary password found in /var/log/mysqld.log — connecting as root with no password."
      log_warn "If this is a fresh install, authentication may still succeed. If it fails, rollback will trigger."
      connect_opts=(-u root)
    fi
  else
    # Ubuntu/Debian: connect via sudo (auth_socket)
    connect_opts=(-u root)
  fi

  log_info "Running MySQL security configuration…"

  # Escape passwords for safe SQL string interpolation ('' is ANSI SQL escape for ')
  local esc_root_pw; esc_root_pw="$(escape_sql "$MYSQL_ROOT_PW")"
  local esc_admin_pw; esc_admin_pw="$(escape_sql "$MYSQL_ADMIN_PW")"

  # Run all hardening SQL in a single heredoc to avoid multiple connections
  local sql
  sql="$(cat <<SQL
-- Set root password using the default auth plugin (caching_sha2_password in MySQL 8.4).
-- mysql_native_password is disabled by default in MySQL 8.4 and must NOT be specified here.
ALTER USER 'root'@'localhost' IDENTIFIED BY '${esc_root_pw}';

-- Remove anonymous users
DELETE FROM mysql.user WHERE User = '';

-- Disallow remote root login
DELETE FROM mysql.user
  WHERE User = 'root'
  AND Host NOT IN ('localhost', '127.0.0.1', '::1');

-- Remove the test database
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db = 'test' OR Db = 'test\\_%';

-- Create a named admin user (avoids direct root use in applications)
CREATE USER IF NOT EXISTS 'db_admin'@'localhost' IDENTIFIED BY '${esc_admin_pw}';
GRANT ALL PRIVILEGES ON *.* TO 'db_admin'@'localhost' WITH GRANT OPTION;

FLUSH PRIVILEGES;
SQL
)"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "Would execute MySQL hardening SQL block"
  else
    if [[ "$DISTRO_FAMILY" == "debian" ]]; then
      # auth_socket: use sudo mysql
      echo "$sql" | sudo mysql "${connect_opts[@]}" 2>&1 | tee -a "$LOG_FILE" || {
        log_error "MySQL configuration failed."
        return 1
      }
    else
      echo "$sql" | mysql "${connect_opts[@]}" 2>&1 | tee -a "$LOG_FILE" || {
        log_error "MySQL configuration failed."
        return 1
      }
    fi
  fi
  log_info "MySQL hardening complete."
}

create_mysql_opa_user() {
  log_step "Creating MySQL OPA service account (opa_svc)"

  local esc_opa_pw; esc_opa_pw="$(escape_sql "$OPA_SVC_PW")"
  local sql
  sql="$(cat <<SQL
-- OPA service account: used by the OPA DB Gateway for JIT credential management.
-- Grants allow OPA to create/rotate per-session database users.
CREATE USER IF NOT EXISTS 'opa_svc'@'%' IDENTIFIED BY '${esc_opa_pw}';
GRANT SELECT, INSERT, UPDATE, DELETE ON *.* TO 'opa_svc'@'%';
GRANT CREATE USER ON *.* TO 'opa_svc'@'%';
GRANT PROCESS ON *.* TO 'opa_svc'@'%';
FLUSH PRIVILEGES;
SQL
)"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "Would create MySQL opa_svc user"
  else
    echo "$sql" | mysql -u root "-p${MYSQL_ROOT_PW}" 2>&1 | tee -a "$LOG_FILE" || {
      log_error "Failed to create MySQL opa_svc user."
      return 1
    }
  fi
  log_info "MySQL opa_svc user created."
}

# ==============================================================================
# SECTION 12: POSTGRESQL — INSTALL, CONFIGURE, OPA USER
# ==============================================================================

install_postgresql() {
  log_step "Installing PostgreSQL ${PG_VERSION} (from PGDG official repo)"

  case "$DISTRO_FAMILY" in
    debian)
      # Add the PostgreSQL Global Development Group apt repo
      local pgdg_key="/usr/share/keyrings/postgresql-pgdg.gpg"
      log_info "Adding PGDG APT repository…"
      run_cmd curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | gpg --dearmor | run_cmd tee "$pgdg_key" > /dev/null
      echo "deb [signed-by=${pgdg_key}] https://apt.postgresql.org/pub/repos/apt ${OS_CODENAME}-pgdg main" \
        | run_cmd tee /etc/apt/sources.list.d/pgdg.list > /dev/null
      pm_update
      pm_install "postgresql-${PG_VERSION}"
      PG_SERVICE="postgresql"
      PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/main"
      PG_HBA_CONF="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
      ;;

    rhel)
      local el_ver
      case "$OS_ID-$OS_VERSION" in
        amzn-2)    el_ver="7" ;;
        amzn-2023) el_ver="9" ;;
        *-8|*-8.*) el_ver="8" ;;
        *)         el_ver="9" ;;
      esac
      log_info "Adding PGDG YUM/DNF repository for EL${el_ver}…"
      local arch; arch="$(uname -m)"
      run_cmd "$PKG_MANAGER" install -y \
        "https://download.postgresql.org/pub/repos/yum/reporpms/EL-${el_ver}-${arch}/pgdg-redhat-repo-latest.noarch.rpm" \
        || true  # ignore if already installed
      # Disable the built-in PostgreSQL module on RHEL 8+ to avoid conflict
      if [[ "$el_ver" -ge 8 ]] && command_exists dnf; then
        run_cmd dnf -qy module disable postgresql 2>/dev/null || true
      fi
      pm_install "postgresql${PG_VERSION}-server" "postgresql${PG_VERSION}"
      # Initialise the database cluster on RHEL (not done automatically; skip if already done)
      if [[ ! -f "/var/lib/pgsql/${PG_VERSION}/data/PG_VERSION" ]]; then
        run_cmd "/usr/pgsql-${PG_VERSION}/bin/postgresql-${PG_VERSION}-setup" initdb || {
          log_error "PostgreSQL initdb failed."
          return 1
        }
      else
        log_info "PostgreSQL cluster already initialised — skipping initdb."
      fi
      PG_SERVICE="postgresql-${PG_VERSION}"
      PG_DATA_DIR="/var/lib/pgsql/${PG_VERSION}/data"
      PG_HBA_CONF="/var/lib/pgsql/${PG_VERSION}/data/pg_hba.conf"
      ;;

    suse)
      log_info "Adding PGDG zypper repository…"
      run_cmd zypper addrepo --refresh \
        "https://download.postgresql.org/pub/repos/zypp/repo/pgdg-sles-15-pg${PG_VERSION}.repo" \
        || true
      # --gpg-auto-import-keys prevents zypper from pausing to prompt for key trust
      run_cmd zypper --gpg-auto-import-keys refresh
      pm_install "postgresql${PG_VERSION}-server" "postgresql${PG_VERSION}"
      if [[ ! -f "/var/lib/pgsql/${PG_VERSION}/data/PG_VERSION" ]]; then
        run_cmd "/usr/pgsql-${PG_VERSION}/bin/postgresql-${PG_VERSION}-setup" initdb || {
          log_error "PostgreSQL initdb failed."
          return 1
        }
      else
        log_info "PostgreSQL cluster already initialised — skipping initdb."
      fi
      PG_SERVICE="postgresql-${PG_VERSION}"
      PG_DATA_DIR="/var/lib/pgsql/${PG_VERSION}/data"
      PG_HBA_CONF="/var/lib/pgsql/${PG_VERSION}/data/pg_hba.conf"
      ;;
  esac

  run_cmd systemctl enable --now "$PG_SERVICE" || {
    log_error "Failed to enable/start PostgreSQL service: ${PG_SERVICE}"
    return 1
  }
  log_info "PostgreSQL service '${PG_SERVICE}' enabled and started."

  push_rollback "systemctl stop ${PG_SERVICE} 2>/dev/null || true; \
    pm_remove postgresql${PG_VERSION}-server postgresql${PG_VERSION} postgresql-${PG_VERSION} 2>/dev/null || true; \
    rm -rf /var/lib/postgresql /var/lib/pgsql"
}

configure_postgresql() {
  log_step "Configuring PostgreSQL (password auth + admin password)"

  # Set the postgres superuser password
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "Would set postgres superuser password via psql"
  else
    run_cmd sudo -u postgres psql -c \
      "ALTER USER postgres WITH ENCRYPTED PASSWORD '${PG_ADMIN_PW}';" \
      2>&1 | tee -a "$LOG_FILE" || {
      log_error "Failed to set postgres admin password."
      return 1
    }
  fi

  # Switch local authentication from peer/ident to scram-sha-256
  # This is required so password-based tools (and OPA) can authenticate.
  if [[ "$DRY_RUN" != "true" && -f "$PG_HBA_CONF" ]]; then
    log_info "Updating pg_hba.conf: switching local auth to scram-sha-256"
    # Back up the original
    run_cmd cp "${PG_HBA_CONF}" "${PG_HBA_CONF}.bak.$(date +%s)"
    # Replace peer/ident with scram-sha-256 for local connections.
    # Use \b.* instead of $ to handle lines with trailing whitespace or inline comments
    # (e.g. "local  all  all  peer  # default" is common in generated pg_hba.conf files).
    sed -i 's/^\(local\s\+all\s\+all\s\+\)peer\b.*/\1scram-sha-256/' "$PG_HBA_CONF"
    sed -i 's/^\(local\s\+all\s\+all\s\+\)ident\b.*/\1scram-sha-256/' "$PG_HBA_CONF"
    # Verify the change took effect
    if grep -qE '^local\s+all\s+all\s+scram-sha-256' "$PG_HBA_CONF"; then
      log_info "pg_hba.conf: local auth method confirmed as scram-sha-256."
    else
      log_warn "pg_hba.conf may not have been updated — scram-sha-256 pattern not found."
      log_warn "Verify ${PG_HBA_CONF} manually and ensure local connections use scram-sha-256."
    fi
    run_cmd systemctl reload "$PG_SERVICE"
    log_info "pg_hba.conf updated and PostgreSQL reloaded."
  fi
}

create_pg_opa_user() {
  log_step "Creating PostgreSQL OPA service account (opa_svc)"

  # opa_svc needs CREATEROLE so the OPA DB Gateway can create per-session JIT users
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "Would create PostgreSQL opa_svc role"
    return 0
  fi

  local esc_opa_pw; esc_opa_pw="$(escape_sql "$OPA_SVC_PW")"

  # Write SQL to a temp file to avoid the bash heredoc-in-pipeline parsing quirk
  # (heredoc body cannot follow a || { } compound command on the same line).
  local sql_file="${TEMP_DIR}/create_pg_opa.sql"
  cat > "$sql_file" <<SQLEOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'opa_svc') THEN
    CREATE ROLE opa_svc WITH LOGIN PASSWORD '${esc_opa_pw}' CREATEROLE;
  ELSE
    ALTER ROLE opa_svc WITH LOGIN PASSWORD '${esc_opa_pw}' CREATEROLE;
  END IF;
END
\$\$;
GRANT CONNECT ON DATABASE postgres TO opa_svc;
SQLEOF

  sudo -u postgres psql -f "$sql_file" 2>&1 | tee -a "$LOG_FILE" || {
    log_error "Failed to create PostgreSQL opa_svc user."
    rm -f "$sql_file"
    return 1
  }
  rm -f "$sql_file"
  log_info "PostgreSQL opa_svc role created."
}

# ==============================================================================
# SECTION 13: MONGODB — INSTALL, CONFIGURE, OPA USER
# ==============================================================================

install_mongodb() {
  log_step "Installing MongoDB 7.x (from official MongoDB repo)"
  local mongo_version="7.0"

  case "$DISTRO_FAMILY" in
    debian)
      local keyring_file="/usr/share/keyrings/mongodb-server-${mongo_version}.gpg"
      log_info "Adding MongoDB APT repository…"
      run_cmd curl -fsSL \
        "https://www.mongodb.org/static/pgp/server-${mongo_version}.asc" \
        | gpg --dearmor | run_cmd tee "$keyring_file" > /dev/null
      local arch="amd64,arm64"
      echo "deb [ arch=${arch} signed-by=${keyring_file} ] \
https://repo.mongodb.org/apt/${OS_ID} ${OS_CODENAME}/mongodb-org/${mongo_version} multiverse" \
        | run_cmd tee /etc/apt/sources.list.d/mongodb-org-${mongo_version}.list > /dev/null
      pm_update
      pm_install mongodb-org
      ;;

    rhel)
      log_info "Adding MongoDB YUM/DNF repository…"
      if [[ "$DRY_RUN" == "true" ]]; then
        log_dry "Would create /etc/yum.repos.d/mongodb-org-${mongo_version}.repo"
      else
        # Amazon Linux uses dedicated repo paths (/yum/amazon/) — not /yum/redhat/.
        # Using the redhat path on Amazon Linux returns HTTP 404 for releasever 2 / 2023.
        local mongo_repo_os
        [[ "$OS_ID" == "amzn" ]] && mongo_repo_os="amazon" || mongo_repo_os="redhat"
        cat > /etc/yum.repos.d/mongodb-org-${mongo_version}.repo <<REPOEOF
[mongodb-org-${mongo_version}]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/${mongo_repo_os}/\$releasever/mongodb-org/${mongo_version}/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-${mongo_version}.asc
REPOEOF
      fi
      pm_install mongodb-org
      ;;

    suse)
      log_info "Adding MongoDB zypper repository for SLES…"
      run_cmd zypper addrepo --refresh \
        "https://repo.mongodb.org/zypper/suse15/mongodb-org/${mongo_version}/x86_64/" \
        "mongodb-org-${mongo_version}" || true
      run_cmd zypper --gpg-auto-import-keys refresh mongodb-org-${mongo_version}
      pm_install mongodb-org
      ;;
  esac

  MONGO_SERVICE="mongod"
  run_cmd systemctl enable --now "$MONGO_SERVICE" || {
    log_error "Failed to enable/start MongoDB service: ${MONGO_SERVICE}"
    return 1
  }
  # Wait for mongod to become active (up to 15 seconds) before attempting connections
  if [[ "$DRY_RUN" != "true" ]]; then
    local attempts=0
    while ! systemctl is-active --quiet "$MONGO_SERVICE" && [[ $attempts -lt 15 ]]; do
      sleep 1
      (( attempts++ ))
    done
    if ! systemctl is-active --quiet "$MONGO_SERVICE"; then
      log_error "MongoDB service failed to become active after 15 seconds."
      return 1
    fi
  fi
  log_info "MongoDB service '${MONGO_SERVICE}' enabled and started."

  push_rollback "systemctl stop ${MONGO_SERVICE} 2>/dev/null || true; \
    pm_remove mongodb-org mongodb-org-server mongodb-org-shell mongodb-org-mongos mongodb-org-tools 2>/dev/null || true; \
    rm -rf /var/lib/mongodb /var/log/mongodb /etc/mongod.conf"
}

configure_mongodb() {
  log_step "Configuring MongoDB (creating admin user then enabling authentication)"

  # Step 1: Create the admin user BEFORE enabling auth (no-auth connection)
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "Would create MongoDB admin user via mongosh"
  else
    local esc_admin_pw; esc_admin_pw="$(escape_js "$MONGO_ADMIN_PW")"
    run_cmd mongosh --quiet --eval "
      db = db.getSiblingDB('admin');
      if (db.getUser('admin') == null) {
        db.createUser({
          user: 'admin',
          pwd: '${esc_admin_pw}',
          roles: [{ role: 'root', db: 'admin' }]
        });
        print('MongoDB admin user created.');
      } else {
        db.updateUser('admin', { pwd: '${esc_admin_pw}' });
        print('MongoDB admin user updated.');
      }
    " 2>&1 | tee -a "$LOG_FILE" || {
      log_error "Failed to create MongoDB admin user."
      return 1
    }
  fi

  # Step 2: Enable authentication in mongod.conf
  if [[ "$DRY_RUN" != "true" ]]; then
    log_info "Enabling MongoDB authentication in /etc/mongod.conf…"
    # Backup the original config
    run_cmd cp /etc/mongod.conf "/etc/mongod.conf.bak.$(date +%s)"

    # Insert security block if not already present
    if ! grep -q '^security:' /etc/mongod.conf; then
      printf '\nsecurity:\n  authorization: enabled\n' >> /etc/mongod.conf
    else
      sed -i '/^security:/,/^[^ ]/{s/^#\?\s*authorization:.*/  authorization: enabled/}' /etc/mongod.conf
    fi

    run_cmd systemctl restart "$MONGO_SERVICE"
    # Wait for mongod to become active after restart (up to 15 seconds)
    local attempts=0
    while ! systemctl is-active --quiet "$MONGO_SERVICE" && [[ $attempts -lt 15 ]]; do
      sleep 1
      (( attempts++ ))
    done
    if ! systemctl is-active --quiet "$MONGO_SERVICE"; then
      log_error "MongoDB failed to restart with authentication enabled."
      return 1
    fi
    log_info "MongoDB restarted with authentication enabled."
  fi
}

create_mongo_opa_user() {
  log_step "Creating MongoDB OPA service account (opa_svc)"
  # Note: MongoDB is NOT natively supported by OPA JIT credential rotation.
  # This account is created for manual/future use.

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "Would create MongoDB opa_svc user"
  else
    local esc_admin_pw; esc_admin_pw="$(escape_js "$MONGO_ADMIN_PW")"
    local esc_opa_pw;   esc_opa_pw="$(escape_js "$OPA_SVC_PW")"
    run_cmd mongosh --quiet -u "admin" -p "${MONGO_ADMIN_PW}" \
      --authenticationDatabase admin --eval "
      db = db.getSiblingDB('admin');
      if (db.getUser('opa_svc') == null) {
        db.createUser({
          user: 'opa_svc',
          pwd: '${esc_opa_pw}',
          roles: [
            { role: 'readWriteAnyDatabase', db: 'admin' },
            { role: 'userAdminAnyDatabase', db: 'admin' }
          ]
        });
        print('MongoDB opa_svc user created.');
      } else {
        db.updateUser('opa_svc', { pwd: '${esc_opa_pw}' });
        print('MongoDB opa_svc user updated.');
      }
    " 2>&1 | tee -a "$LOG_FILE" || {
      log_error "Failed to create MongoDB opa_svc user."
      return 1
    }
  fi
  log_info "MongoDB opa_svc user created."
}

# ==============================================================================
# SECTION 14: FIREWALL MANAGEMENT
# ==============================================================================

# Prompt (interactive) or read flag (non-interactive) to decide firewall mode
determine_firewall_mode() {
  if [[ "$INTERACTIVE" == "true" && "$PRODUCTION_MODE" == "false" ]]; then
    echo ""
    echo -e "${BOLD}Firewall configuration:${NC}"
    echo "  Lab mode    — Disable/skip the OS firewall for easier troubleshooting"
    echo "  Production  — Configure firewall to allow DB ports from ${ALLOWED_CIDR} only"
    echo ""
    if confirm "Is this a PRODUCTION deployment? (no = lab mode)"; then
      PRODUCTION_MODE=true
      # Loop until the user provides a valid CIDR — typos are common (e.g. 10.1.0/20)
      while true; do
        prompt_value "Allowed source CIDR for DB ports" "$ALLOWED_CIDR" ALLOWED_CIDR
        validate_cidr "$ALLOWED_CIDR" && break
        # validate_cidr already prints an error; just loop back to the prompt
      done
    fi
  fi
}

# ==============================================================================
# Prompt (interactive) or accept flags (non-interactive) for seeding options
# ==============================================================================

determine_seed_requirements() {
  if [[ "$INTERACTIVE" == "false" ]]; then return; fi

  echo ""
  echo -e "${BOLD}Database seeding:${NC}"
  echo "  Optionally populate each installed database with test data:"
  echo "    - ${SEED_DBS} database(s) per engine, each with a dedicated user"
  echo "    - ${SEED_ROWS} row(s)/document(s) of random data per database"
  echo "    - A global lab superuser '${LAB_ADMIN_USER}' with full access on all engines"
  echo ""

  if ! confirm "Seed databases with lab data?"; then
    SEED_DATA=false
    return
  fi
  SEED_DATA=true

  local ans
  while true; do
    prompt_value "Number of databases per engine" "$SEED_DBS" ans
    [[ "$ans" =~ ^[1-9][0-9]*$ ]] && SEED_DBS="$ans" && break
    log_warn "Please enter a positive integer (e.g. 3)."
  done

  while true; do
    prompt_value "Number of rows/documents per database" "$SEED_ROWS" ans
    [[ "$ans" =~ ^[1-9][0-9]*$ ]] && SEED_ROWS="$ans" && break
    log_warn "Please enter a positive integer (e.g. 1000)."
  done

  prompt_value "Lab superuser name" "$LAB_ADMIN_USER" LAB_ADMIN_USER
}

configure_firewall() {
  log_step "Configuring firewall (PRODUCTION mode — source: ${ALLOWED_CIDR})"

  local ports=()
  [[ "$INSTALL_MYSQL" == "true" ]]  && ports+=(3306)
  [[ "$INSTALL_PG" == "true" ]]     && ports+=(5432)
  [[ "$INSTALL_MONGO" == "true" ]]  && ports+=(27017)

  case "$DISTRO_FAMILY" in
    debian)
      if ! command_exists ufw; then pm_install ufw; fi
      for port in "${ports[@]}"; do
        run_cmd ufw allow from "$ALLOWED_CIDR" to any port "$port" proto tcp \
          comment "OPA DB Gateway access"
      done
      run_cmd ufw --force enable
      log_info "UFW enabled with rules for ports: ${ports[*]}"
      # Register rollback: disable ufw if a later step fails
      push_rollback "ufw disable 2>/dev/null || true"
      ;;

    rhel)
      if ! command_exists firewall-cmd; then pm_install firewalld; fi
      run_cmd systemctl enable --now firewalld
      for port in "${ports[@]}"; do
        run_cmd firewall-cmd --permanent --add-rich-rule=\
"rule family='ipv4' source address='${ALLOWED_CIDR}' port protocol='tcp' port='${port}' accept"
      done
      run_cmd firewall-cmd --reload
      log_info "firewalld rules applied for ports: ${ports[*]}"
      # Register rollback: stop and disable firewalld if a later step fails
      push_rollback "systemctl stop firewalld 2>/dev/null || true; systemctl disable firewalld 2>/dev/null || true"
      ;;

    suse)
      if command_exists firewall-cmd; then
        run_cmd systemctl enable --now firewalld
        for port in "${ports[@]}"; do
          run_cmd firewall-cmd --permanent --add-rich-rule=\
"rule family='ipv4' source address='${ALLOWED_CIDR}' port protocol='tcp' port='${port}' accept"
        done
        run_cmd firewall-cmd --reload
        push_rollback "systemctl stop firewalld 2>/dev/null || true; systemctl disable firewalld 2>/dev/null || true"
      else
        log_warn "No supported firewall found on SUSE — skipping firewall config."
      fi
      ;;
  esac
}

disable_firewall() {
  log_step "Firewall — LAB mode: disabling OS firewall for easier troubleshooting"

  case "$DISTRO_FAMILY" in
    debian)
      if command_exists ufw; then
        run_cmd ufw disable 2>/dev/null || true
        log_info "UFW disabled."
      else
        log_info "UFW not installed — nothing to disable."
      fi
      ;;
    rhel|suse)
      if systemctl is-active --quiet firewalld 2>/dev/null; then
        run_cmd systemctl stop firewalld
        run_cmd systemctl disable firewalld
        log_info "firewalld stopped and disabled."
      else
        log_info "firewalld not active — nothing to disable."
      fi
      ;;
  esac
}

# ==============================================================================
# SECTION 15: CREDENTIAL OUTPUT FILE
# ==============================================================================

write_credentials() {
  log_step "Writing credentials to ${CRED_FILE}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "Would write credentials to ${CRED_FILE} (chmod 600)"
    return 0
  fi

  # Create the file with restricted permissions BEFORE writing any secrets.
  # -D creates any missing parent directories (handles custom --cred-file paths).
  # 'install' is atomic: the file is created with correct perms from the start.
  install -D -m 600 /dev/null "$CRED_FILE" || {
    log_error "Cannot create credential file: ${CRED_FILE}"
    return 1
  }

  local hostname; hostname="$(hostname -f 2>/dev/null || hostname)"
  local gen_time; gen_time="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

  {
    cat <<HEADER
# ==============================================================================
# PAT Lab Database Credentials
# ==============================================================================
# Generated by : db-install.sh v${SCRIPT_VERSION}
# Date         : ${gen_time}
# Hostname     : ${hostname}
# OS           : ${OS_ID} ${OS_VERSION}
# Log file     : ${LOG_FILE}
# ==============================================================================
#
# SECURITY WARNING:
#   This file contains plaintext database credentials.
#   - Verify permissions:  ls -la ${CRED_FILE}   (should be -rw-------)
#   - After provisioning, move these secrets to a vault (HashiCorp Vault,
#     AWS Secrets Manager, or Okta Privileged Access secrets management).
#   - Delete this file once credentials are stored securely.
#
# ==============================================================================

[INSTALLATION SUMMARY]
Databases installed : $(
  parts=()
  [[ "$INSTALL_MYSQL" == "true" ]]  && parts+=("MySQL 8.x")
  [[ "$INSTALL_PG" == "true" ]]     && parts+=("PostgreSQL ${PG_VERSION}.x")
  [[ "$INSTALL_MONGO" == "true" ]]  && parts+=("MongoDB 7.x")
  echo "${parts[*]}"
)
Deployment mode    : $(  [[ "$PRODUCTION_MODE" == "true" ]] && echo "PRODUCTION" || echo "LAB" )
Dry run            : ${DRY_RUN}

HEADER

    # ── Firewall ──────────────────────────────────────────────────────────────
    cat <<FWSECTION
[FIREWALL STATUS]
FWSECTION

    if [[ "$PRODUCTION_MODE" == "true" ]]; then
      cat <<FWPROD
Mode        : PRODUCTION — firewall ENABLED
Allowed CIDR: ${ALLOWED_CIDR}
Open ports  : $(
  parts=()
  [[ "$INSTALL_MYSQL" == "true" ]]  && parts+=("3306/tcp (MySQL)")
  [[ "$INSTALL_PG" == "true" ]]     && parts+=("5432/tcp (PostgreSQL)")
  [[ "$INSTALL_MONGO" == "true" ]]  && parts+=("27017/tcp (MongoDB)")
  echo "${parts[*]}"
)

FWPROD
    else
      cat <<FWLAB
Mode        : LAB — OS firewall DISABLED for easier troubleshooting
WARNING     : Database ports are accessible to any host that can route to this server.
              Rely on AWS Security Groups to restrict access at the network level.

To harden for production, re-run with:
  ${SCRIPT_NAME} --production --allowed-cidr <YOUR_CIDR> [db flags]
This will configure:
  Ubuntu/Debian  : ufw allow from <CIDR> to any port 3306,5432,27017 proto tcp; ufw enable
  RHEL/Amazon    : firewall-cmd rich-rules restricting the same ports to <CIDR>

FWLAB
    fi

    # ── MySQL ─────────────────────────────────────────────────────────────────
    if [[ "$INSTALL_MYSQL" == "true" ]]; then
      cat <<MYSQLSEC

[MYSQL 8.x]
Service          : ${MYSQL_SERVICE}
Port             : 3306
Data directory   : /var/lib/mysql
Config file      : /etc/mysql/mysql.conf.d/mysqld.cnf  (Debian) | /etc/my.cnf  (RHEL)

Root user        : root
Root password    : ${MYSQL_ROOT_PW}

Admin user       : db_admin
Admin password   : ${MYSQL_ADMIN_PW}
Admin host       : localhost
Admin grants     : ALL PRIVILEGES WITH GRANT OPTION

OPA service user : opa_svc
OPA password     : ${OPA_SVC_PW}
OPA host         : %  (any)
OPA grants       : SELECT, INSERT, UPDATE, DELETE, CREATE USER, PROCESS on *.*
OPA note         : Used by OPA Database Gateway for JIT credential management

Test connections :
  mysql -u db_admin -p"${MYSQL_ADMIN_PW}" -e "SELECT VERSION();"
  mysql -u opa_svc  -p"${OPA_SVC_PW}"  -h localhost -e "SELECT VERSION();"

MYSQLSEC
    fi

    # ── PostgreSQL ────────────────────────────────────────────────────────────
    if [[ "$INSTALL_PG" == "true" ]]; then
      cat <<PGSEC

[POSTGRESQL ${PG_VERSION}.x]
Service          : ${PG_SERVICE}
Port             : 5432
Data directory   : ${PG_DATA_DIR}
Config file      : ${PG_DATA_DIR}/postgresql.conf
pg_hba.conf      : ${PG_HBA_CONF}

Admin user       : postgres
Admin password   : ${PG_ADMIN_PW}
Auth method      : scram-sha-256  (updated in pg_hba.conf)

OPA service user : opa_svc
OPA password     : ${OPA_SVC_PW}
OPA grants       : LOGIN, CREATEROLE, CONNECT on database postgres
OPA note         : CREATEROLE allows OPA Gateway to provision JIT session users

Connection strings:
  Admin     : postgresql://postgres:${PG_ADMIN_PW}@localhost:5432/postgres
  OPA svc   : postgresql://opa_svc:${OPA_SVC_PW}@localhost:5432/postgres

Test connections :
  PGPASSWORD="${PG_ADMIN_PW}" psql -U postgres -c "SELECT version();"
  PGPASSWORD="${OPA_SVC_PW}"  psql -U opa_svc  -d postgres -c "SELECT current_user;"

PGSEC
    fi

    # ── MongoDB ───────────────────────────────────────────────────────────────
    if [[ "$INSTALL_MONGO" == "true" ]]; then
      cat <<MONGOSEC

[MONGODB 7.x]
Service          : mongod
Port             : 27017
Data directory   : /var/lib/mongodb
Config file      : /etc/mongod.conf
Authentication   : enabled (keyfile not required — single-node)

Admin user       : admin
Admin password   : ${MONGO_ADMIN_PW}
Admin roles      : root (on admin db)

OPA service user : opa_svc
OPA password     : ${OPA_SVC_PW}
OPA roles        : readWriteAnyDatabase, userAdminAnyDatabase (on admin db)
OPA note         : MongoDB is NOT natively supported for OPA JIT credential rotation.
                   Manage MongoDB credentials manually or via a custom script.

Connection strings:
  Admin   : mongodb://admin:${MONGO_ADMIN_PW}@localhost:27017/admin
  OPA svc : mongodb://opa_svc:${OPA_SVC_PW}@localhost:27017/admin

Test connections :
  mongosh -u admin    -p "${MONGO_ADMIN_PW}" --authenticationDatabase admin --eval "db.adminCommand({ping:1})"
  mongosh -u opa_svc  -p "${OPA_SVC_PW}"    --authenticationDatabase admin --eval "db.adminCommand({ping:1})"

MONGOSEC
    fi

    # ── Lab Seeding ──────────────────────────────────────────────────────────
    if [[ "$SEED_DATA" == "true" ]]; then
      cat <<SEEDHEADER

[LAB DATA — SEEDING]
Seed databases   : ${SEED_DBS} per engine
Seed rows/docs   : ${SEED_ROWS}
Lab admin user   : ${LAB_ADMIN_USER}
Lab admin pw     : ${LAB_ADMIN_PW}
SEEDHEADER

      if [[ ${#MYSQL_SEEDED_DBS[@]} -gt 0 ]]; then
        echo ""
        echo "MySQL seeded databases:"
        for entry in "${MYSQL_SEEDED_DBS[@]}"; do
          IFS=':' read -r dbn dbu dbp <<< "$entry"
          printf "  %-14s  user: %-14s  pw: %s\n" "$dbn" "$dbu" "$dbp"
          printf "  Test: mysql -u %s -p'%s' %s -e \"SELECT COUNT(*) FROM lab_records;\"\n" \
            "$dbu" "$dbp" "$dbn"
        done
      fi

      if [[ ${#PG_SEEDED_DBS[@]} -gt 0 ]]; then
        echo ""
        echo "PostgreSQL seeded databases:"
        for entry in "${PG_SEEDED_DBS[@]}"; do
          IFS=':' read -r dbn dbu dbp <<< "$entry"
          printf "  %-14s  user: %-14s  pw: %s\n" "$dbn" "$dbu" "$dbp"
          printf "  Test: PGPASSWORD='%s' psql -U %s -d %s -c \"SELECT COUNT(*) FROM lab_records;\"\n" \
            "$dbp" "$dbu" "$dbn"
        done
      fi

      if [[ ${#MONGO_SEEDED_DBS[@]} -gt 0 ]]; then
        echo ""
        echo "MongoDB seeded databases:"
        for entry in "${MONGO_SEEDED_DBS[@]}"; do
          IFS=':' read -r dbn dbu dbp <<< "$entry"
          printf "  %-14s  user: %-14s  pw: %s\n" "$dbn" "$dbu" "$dbp"
          printf "  Test: mongosh -u %s -p '%s' --authenticationDatabase %s %s --eval \"db.lab_records.countDocuments()\"\n" \
            "$dbu" "$dbp" "$dbn" "$dbn"
        done
      fi
    fi

    echo "# =============================================================="
    echo "# End of credential file — keep this secure!"
    echo "# =============================================================="

  } >> "$CRED_FILE"

  log_info "Credentials written to ${CRED_FILE}"
  log_info "Permissions: $(stat -c '%A %U' "$CRED_FILE" 2>/dev/null || ls -la "$CRED_FILE")"
}

# ==============================================================================
# SECTION 16: ARGUMENT PARSING
# ==============================================================================

parse_args() {
  # Default: install all databases if no specific DB flag is given
  local db_flag_set=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--mysql)             INSTALL_MYSQL=true;  db_flag_set=true ;;
      -p|--postgresql)        INSTALL_PG=true;     db_flag_set=true ;;
      -g|--mongodb)           INSTALL_MONGO=true;  db_flag_set=true ;;
      -a|--all)               INSTALL_MYSQL=true; INSTALL_PG=true; INSTALL_MONGO=true; db_flag_set=true ;;
      -i|--interactive)       INTERACTIVE=true ;;
      -n|--non-interactive)   INTERACTIVE=false ;;
      --production)           PRODUCTION_MODE=true ;;
      --allowed-cidr)
        shift
        ALLOWED_CIDR="${1:?'--allowed-cidr requires a CIDR argument'}"
        validate_cidr "$ALLOWED_CIDR" || exit 1
        ;;
      --mysql-root-password)  shift; MYSQL_ROOT_PW="${1:?'--mysql-root-password requires a value'}" ;;
      --pg-admin-password)    shift; PG_ADMIN_PW="${1:?'--pg-admin-password requires a value'}" ;;
      --mongo-admin-password) shift; MONGO_ADMIN_PW="${1:?'--mongo-admin-password requires a value'}" ;;
      --opa-svc-password)     shift; OPA_SVC_PW="${1:?'--opa-svc-password requires a value'}" ;;
      -l|--log-file)          shift; LOG_FILE="${1:?'--log-file requires a path'}" ;;
      -c|--cred-file)         shift; CRED_FILE="${1:?'--cred-file requires a path'}" ;;
      --dry-run)              DRY_RUN=true ;;
      --rollback)             DO_ROLLBACK=true ;;
      -v|--verbose)           VERBOSE=true ;;
      -h|--help)              usage ;;
      --seed-data)            SEED_DATA=true ;;
      --seed-dbs)
        shift; SEED_DBS="${1:?'--seed-dbs requires a value'}"
        [[ "$SEED_DBS" =~ ^[1-9][0-9]*$ ]] || { log_error "--seed-dbs: must be a positive integer"; exit 1; }
        ;;
      --seed-rows)
        shift; SEED_ROWS="${1:?'--seed-rows requires a value'}"
        [[ "$SEED_ROWS" =~ ^[1-9][0-9]*$ ]] || { log_error "--seed-rows: must be a positive integer"; exit 1; }
        ;;
      --lab-admin-user)       shift; LAB_ADMIN_USER="${1:?'--lab-admin-user requires a value'}" ;;
      --lab-admin-password)   shift; LAB_ADMIN_PW="${1:?'--lab-admin-password requires a value'}" ;;
      *)
        log_error "Unknown option: $1"
        echo "Run '${SCRIPT_NAME} --help' for usage."
        exit 1
        ;;
    esac
    shift
  done

  # If no DB flags were given, default to all three
  if [[ "$db_flag_set" == "false" ]]; then
    INSTALL_MYSQL=true
    INSTALL_PG=true
    INSTALL_MONGO=true
  fi
}

# ==============================================================================
# SECTION 17: INTERACTIVE SELECTION CONFIRMATION
# ==============================================================================

confirm_selections() {
  if [[ "$INTERACTIVE" == "false" ]]; then return; fi

  echo ""
  echo -e "${BOLD}===== Installation Summary =====${NC}"
  echo -e "  MySQL        : $( [[ "$INSTALL_MYSQL" == "true" ]] && echo "${GREEN}YES${NC}" || echo "no" )"
  echo -e "  PostgreSQL   : $( [[ "$INSTALL_PG" == "true" ]]    && echo "${GREEN}YES${NC}" || echo "no" )"
  echo -e "  MongoDB      : $( [[ "$INSTALL_MONGO" == "true" ]] && echo "${GREEN}YES${NC}" || echo "no" )"
  echo -e "  Seed data    : $( [[ "$SEED_DATA" == "true" ]] && echo "${GREEN}YES — ${SEED_DBS} DBs, ${SEED_ROWS} rows/docs each${NC}" || echo "no" )"
  echo -e "  Dry run      : $( [[ "$DRY_RUN" == "true" ]]       && echo "${YELLOW}YES — no changes will be made${NC}" || echo "no" )"
  echo -e "  Log file     : ${LOG_FILE}"
  echo -e "  Cred file    : ${CRED_FILE}"
  echo ""

  if ! confirm "Proceed with installation?"; then
    log_info "Installation cancelled by user."
    exit 0
  fi
}

# ==============================================================================
# SECTION 19: DATABASE SEEDING — LAB ADMIN + DATA POPULATION
# ==============================================================================

# ── MySQL ────────────────────────────────────────────────────────────────────

create_mysql_lab_admin() {
  log_step "MySQL — creating lab superuser '${LAB_ADMIN_USER}'"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "Would create MySQL user '${LAB_ADMIN_USER}'@'%' WITH GRANT OPTION"
    return 0
  fi
  local esc_user; esc_user="$(escape_sql "$LAB_ADMIN_USER")"
  local esc_pw;   esc_pw="$(escape_sql "$LAB_ADMIN_PW")"
  local sql_file="${TEMP_DIR}/mysql_lab_admin.sql"
  cat > "$sql_file" <<SQL
CREATE USER IF NOT EXISTS '${esc_user}'@'%' IDENTIFIED BY '${esc_pw}';
GRANT ALL PRIVILEGES ON *.* TO '${esc_user}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
  mysql -u root -p"${MYSQL_ROOT_PW}" < "$sql_file" 2>&1 | tee -a "$LOG_FILE" || {
    log_error "Failed to create MySQL lab admin user."
    rm -f "$sql_file"; return 1
  }
  rm -f "$sql_file"
  log_info "MySQL lab admin '${LAB_ADMIN_USER}' created."
}

seed_mysql_data() {
  log_step "MySQL — seeding ${SEED_DBS} database(s), ${SEED_ROWS} row(s) each"
  local esc_lab_user sql_file
  esc_lab_user="$(escape_sql "$LAB_ADMIN_USER")"

  # Generate all names up front
  local -a seed_names
  mapfile -t seed_names < <(pick_seed_names "$SEED_DBS")

  local i db_name db_user db_user_pw esc_db_user esc_db_pw
  for i in $(seq 1 "$SEED_DBS"); do
    local app_name="${seed_names[$((i-1))]}"
    db_name="${app_name}_db"
    db_user="${app_name}_svc"
    db_user_pw="$(generate_password)"
    esc_db_user="$(escape_sql "$db_user")"
    esc_db_pw="$(escape_sql "$db_user_pw")"

    if [[ "$DRY_RUN" == "true" ]]; then
      log_dry "Would create MySQL DB '${db_name}', user '${db_user}', ${SEED_ROWS} rows"
      continue
    fi

    sql_file="${TEMP_DIR}/mysql_seed_${i}.sql"
    cat > "$sql_file" <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\`;
CREATE USER IF NOT EXISTS '${esc_db_user}'@'%' IDENTIFIED BY '${esc_db_pw}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${esc_db_user}'@'%';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${esc_lab_user}'@'%';
USE \`${db_name}\`;
CREATE TABLE IF NOT EXISTS lab_records (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  username   VARCHAR(64)   NOT NULL,
  email      VARCHAR(128)  NOT NULL,
  score      DECIMAL(10,2) NOT NULL,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
SET SESSION cte_max_recursion_depth = ${SEED_ROWS};
INSERT INTO lab_records (username, email, score)
WITH RECURSIVE gen(n) AS (
  SELECT 1
  UNION ALL SELECT n + 1 FROM gen WHERE n < ${SEED_ROWS}
)
SELECT CONCAT('user_',n), CONCAT('user_',n,'@lab.example.com'), ROUND(RAND()*1000,2)
FROM gen;
FLUSH PRIVILEGES;
SQL
    mysql -u root -p"${MYSQL_ROOT_PW}" < "$sql_file" 2>&1 | tee -a "$LOG_FILE" || {
      log_error "Failed to seed MySQL database '${db_name}'."
      rm -f "$sql_file"; return 1
    }
    rm -f "$sql_file"
    MYSQL_SEEDED_DBS+=("${db_name}:${db_user}:${db_user_pw}")
    log_info "MySQL: created ${db_name} with ${SEED_ROWS} rows (user: ${db_user})"
  done
}

# ── PostgreSQL ────────────────────────────────────────────────────────────────
# NOTE: All psql calls here use TCP (-h 127.0.0.1) with PGPASSWORD= because seeding
# runs AFTER configure_postgresql() has switched pg_hba.conf to scram-sha-256.
# Unlike create_pg_opa_user() (which runs before configure_postgresql and uses peer auth),
# peer auth is no longer available at seeding time.

create_pg_lab_admin() {
  log_step "PostgreSQL — creating lab superuser '${LAB_ADMIN_USER}'"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "Would create PostgreSQL SUPERUSER role '${LAB_ADMIN_USER}'"
    return 0
  fi
  local esc_user; esc_user="$(escape_sql "$LAB_ADMIN_USER")"
  local esc_pw;   esc_pw="$(escape_sql "$LAB_ADMIN_PW")"
  local sql_file="${TEMP_DIR}/pg_lab_admin.sql"
  cat > "$sql_file" <<SQLEOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${esc_user}') THEN
    CREATE ROLE "${esc_user}" WITH LOGIN SUPERUSER PASSWORD '${esc_pw}';
  ELSE
    ALTER  ROLE "${esc_user}" WITH LOGIN SUPERUSER PASSWORD '${esc_pw}';
  END IF;
END
\$\$;
SQLEOF
  PGPASSWORD="$PG_ADMIN_PW" psql -U postgres -h 127.0.0.1 -f "$sql_file" \
    2>&1 | tee -a "$LOG_FILE" || {
    log_error "Failed to create PostgreSQL lab admin role."
    rm -f "$sql_file"; return 1
  }
  rm -f "$sql_file"
  log_info "PostgreSQL lab admin role '${LAB_ADMIN_USER}' created."
}

seed_postgresql_data() {
  log_step "PostgreSQL — seeding ${SEED_DBS} database(s), ${SEED_ROWS} row(s) each"
  local esc_lab_user
  esc_lab_user="$(escape_sql "$LAB_ADMIN_USER")"

  # Generate all names up front
  local -a seed_names
  mapfile -t seed_names < <(pick_seed_names "$SEED_DBS")

  local i db_name db_user db_user_pw esc_db_user esc_db_pw
  for i in $(seq 1 "$SEED_DBS"); do
    local app_name="${seed_names[$((i-1))]}"
    db_name="${app_name}_db"
    db_user="${app_name}_svc"
    db_user_pw="$(generate_password)"
    esc_db_user="$(escape_sql "$db_user")"
    esc_db_pw="$(escape_sql "$db_user_pw")"

    if [[ "$DRY_RUN" == "true" ]]; then
      log_dry "Would create PG database '${db_name}', user '${db_user}', ${SEED_ROWS} rows"
      continue
    fi

    # Step 1: Create role (idempotent via DO block)
    local role_file="${TEMP_DIR}/pg_seed_role_${i}.sql"
    cat > "$role_file" <<SQLEOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${esc_db_user}') THEN
    CREATE ROLE "${esc_db_user}" WITH LOGIN PASSWORD '${esc_db_pw}';
  ELSE
    ALTER  ROLE "${esc_db_user}" WITH LOGIN PASSWORD '${esc_db_pw}';
  END IF;
END
\$\$;
SQLEOF
    PGPASSWORD="$PG_ADMIN_PW" psql -U postgres -h 127.0.0.1 -f "$role_file" \
      2>&1 | tee -a "$LOG_FILE" || {
      log_error "PG role creation failed for '${db_user}'."
      rm -f "$role_file"; return 1
    }
    rm -f "$role_file"

    # Step 2: Create database (skip if already exists)
    local esc_db_name; esc_db_name="$(escape_sql "$db_name")"
    if ! PGPASSWORD="$PG_ADMIN_PW" psql -U postgres -h 127.0.0.1 \
        -tAc "SELECT 1 FROM pg_database WHERE datname='${esc_db_name}'" | grep -q 1; then
      PGPASSWORD="$PG_ADMIN_PW" psql -U postgres -h 127.0.0.1 \
        -c "CREATE DATABASE \"${db_name}\" OWNER \"${esc_db_user}\";" \
        2>&1 | tee -a "$LOG_FILE" || {
        log_error "PG database creation failed for '${db_name}'."
        return 1
      }
    fi

    # Step 3: Create table + seed data via generate_series() + grant access
    local seed_file="${TEMP_DIR}/pg_seed_data_${i}.sql"
    cat > "$seed_file" <<SQLEOF
CREATE TABLE IF NOT EXISTS lab_records (
  id         SERIAL PRIMARY KEY,
  username   VARCHAR(64)  NOT NULL,
  email      VARCHAR(128) NOT NULL,
  score      NUMERIC(10,2) NOT NULL,
  created_at TIMESTAMPTZ   DEFAULT now()
);
INSERT INTO lab_records (username, email, score)
SELECT
  'user_' || n,
  'user_' || n || '@lab.example.com',
  ROUND((RANDOM() * 1000)::NUMERIC, 2)
FROM generate_series(1, ${SEED_ROWS}) AS n;
GRANT ALL ON ALL TABLES IN SCHEMA public TO "${esc_db_user}";
GRANT ALL ON ALL TABLES IN SCHEMA public TO "${esc_lab_user}";
SQLEOF
    PGPASSWORD="$PG_ADMIN_PW" psql -U postgres -h 127.0.0.1 -d "$db_name" \
      -f "$seed_file" 2>&1 | tee -a "$LOG_FILE" || {
      log_error "PG data seeding failed for '${db_name}'."
      rm -f "$seed_file"; return 1
    }
    rm -f "$seed_file"
    PG_SEEDED_DBS+=("${db_name}:${db_user}:${db_user_pw}")
    log_info "PostgreSQL: created ${db_name} with ${SEED_ROWS} rows (user: ${db_user})"
  done
}

# ── MongoDB ───────────────────────────────────────────────────────────────────

create_mongo_lab_admin() {
  log_step "MongoDB — creating lab superuser '${LAB_ADMIN_USER}'"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_dry "Would create MongoDB root user '${LAB_ADMIN_USER}'"
    return 0
  fi
  local esc_admin_pw; esc_admin_pw="$(escape_js "$MONGO_ADMIN_PW")"
  local esc_lab_user; esc_lab_user="$(escape_js "$LAB_ADMIN_USER")"
  local esc_lab_pw;   esc_lab_pw="$(escape_js "$LAB_ADMIN_PW")"
  mongosh --quiet -u "admin" -p "${MONGO_ADMIN_PW}" \
    --authenticationDatabase admin --eval "
    db = db.getSiblingDB('admin');
    if (db.getUser('${esc_lab_user}') == null) {
      db.createUser({ user: '${esc_lab_user}', pwd: '${esc_lab_pw}',
                      roles: [{role:'root', db:'admin'}] });
      print('MongoDB lab admin created.');
    } else {
      db.updateUser('${esc_lab_user}', { pwd: '${esc_lab_pw}' });
      print('MongoDB lab admin updated.');
    }
  " 2>&1 | tee -a "$LOG_FILE" || {
    log_error "Failed to create MongoDB lab admin user."
    return 1
  }
  log_info "MongoDB lab admin '${LAB_ADMIN_USER}' created."
}

seed_mongodb_data() {
  log_step "MongoDB — seeding ${SEED_DBS} database(s), ${SEED_ROWS} document(s) each"
  local esc_admin_pw esc_lab_user
  esc_admin_pw="$(escape_js "$MONGO_ADMIN_PW")"
  esc_lab_user="$(escape_js "$LAB_ADMIN_USER")"

  # Generate all names up front
  local -a seed_names
  mapfile -t seed_names < <(pick_seed_names "$SEED_DBS")

  local i db_name db_user db_user_pw esc_db_user esc_db_pw
  for i in $(seq 1 "$SEED_DBS"); do
    local app_name="${seed_names[$((i-1))]}"
    db_name="${app_name}_data"
    db_user="${app_name}_svc"
    db_user_pw="$(generate_password)"
    esc_db_user="$(escape_js "$db_user")"
    esc_db_pw="$(escape_js "$db_user_pw")"

    if [[ "$DRY_RUN" == "true" ]]; then
      log_dry "Would create MongoDB database '${db_name}', user '${db_user}', ${SEED_ROWS} docs"
      continue
    fi

    # Create DB user + grant lab_admin readWrite on this DB
    mongosh --quiet -u "admin" -p "${MONGO_ADMIN_PW}" \
      --authenticationDatabase admin --eval "
      db = db.getSiblingDB('${db_name}');
      if (db.getUser('${esc_db_user}') == null) {
        db.createUser({ user: '${esc_db_user}', pwd: '${esc_db_pw}',
                        roles: [{role:'readWrite', db:'${db_name}'}] });
      } else {
        db.updateUser('${esc_db_user}', { pwd: '${esc_db_pw}' });
      }
      db = db.getSiblingDB('admin');
      db.grantRolesToUser('${esc_lab_user}', [{role:'readWrite', db:'${db_name}'}]);
      print('DB ${db_name}: user and lab_admin grants applied.');
    " 2>&1 | tee -a "$LOG_FILE" || {
      log_error "MongoDB user creation failed for '${db_name}'."
      return 1
    }

    # Insert documents in 5000-doc batches to avoid memory pressure
    local batch_size=5000
    local inserted=0 batches b batch_count
    batches=$(( (SEED_ROWS + batch_size - 1) / batch_size ))
    for b in $(seq 1 "$batches"); do
      batch_count=$(( SEED_ROWS - inserted ))
      (( batch_count > batch_size )) && batch_count=$batch_size
      mongosh --quiet -u "admin" -p "${MONGO_ADMIN_PW}" \
        --authenticationDatabase admin --eval "
        db = db.getSiblingDB('${db_name}');
        let offset = ${inserted};
        let docs = [];
        for (let j = 0; j < ${batch_count}; j++) {
          let n = offset + j + 1;
          docs.push({ username: 'user_' + n,
                      email: 'user_' + n + '@lab.example.com',
                      score: Math.round(Math.random() * 1000 * 100) / 100,
                      createdAt: new Date() });
        }
        db.lab_records.insertMany(docs);
        print('Batch ${b}/${batches}: ${batch_count} docs inserted into ${db_name}');
      " 2>&1 | tee -a "$LOG_FILE" || {
        log_error "MongoDB seeding batch ${b} failed for '${db_name}'."
        return 1
      }
      (( inserted += batch_count ))
    done

    MONGO_SEEDED_DBS+=("${db_name}:${db_user}:${db_user_pw}")
    log_info "MongoDB: created ${db_name} with ${SEED_ROWS} docs (user: ${db_user})"
  done
}

# ==============================================================================
# SECTION 20: MAIN ENTRY POINT
# ==============================================================================

main() {
  parse_args "$@"
  init_log

  log_step "PAT Lab Database Installer v${SCRIPT_VERSION}"
  log_info "Started: ${SCRIPT_START_TIME}"
  log_info "Log:     ${LOG_FILE}"

  # OS detection must run before rollback so PKG_MANAGER is set when pm_remove is called
  detect_os

  # Handle explicit --rollback request
  if [[ "$DO_ROLLBACK" == "true" ]]; then
    log_warn "--rollback flag set. This will attempt to uninstall all selected databases."
    if ! confirm "Are you sure you want to rollback?"; then
      log_info "Rollback cancelled."
      exit 0
    fi
    # Rebuild the rollback stack based on what's currently installed
    command_exists mysql   && INSTALL_MYSQL=true
    command_exists psql    && INSTALL_PG=true
    command_exists mongod  && INSTALL_MONGO=true
    [[ "$INSTALL_MYSQL" == "true" ]] && push_rollback "pm_remove mysql-server mysql-community-server 2>/dev/null; rm -rf /var/lib/mysql"
    [[ "$INSTALL_PG" == "true" ]]    && push_rollback "pm_remove postgresql${PG_VERSION}-server postgresql-${PG_VERSION} 2>/dev/null; rm -rf /var/lib/postgresql /var/lib/pgsql"
    [[ "$INSTALL_MONGO" == "true" ]] && push_rollback "pm_remove mongodb-org 2>/dev/null; rm -rf /var/lib/mongodb"
    execute_rollback
    exit 0
  fi

  # --- Prerequisites (skipped in rollback mode) ---
  check_prerequisites

  # --- Interactive confirmation & firewall decision ---
  confirm_selections
  determine_firewall_mode
  determine_seed_requirements

  # --- Generate any missing passwords ---
  log_step "Generating passwords"
  [[ -z "$MYSQL_ROOT_PW" ]]  && MYSQL_ROOT_PW="$(generate_password)"
  [[ -z "$MYSQL_ADMIN_PW" ]] && MYSQL_ADMIN_PW="$(generate_password)"
  [[ -z "$PG_ADMIN_PW" ]]    && PG_ADMIN_PW="$(generate_password)"
  [[ -z "$MONGO_ADMIN_PW" ]] && MONGO_ADMIN_PW="$(generate_password)"
  [[ -z "$OPA_SVC_PW" ]]     && OPA_SVC_PW="$(generate_password)"
  [[ "$SEED_DATA" == "true" && -z "$LAB_ADMIN_PW" ]] && LAB_ADMIN_PW="$(generate_password)"
  log_info "All passwords ready (generated or provided via flags)."

  # --- Create temp directory ---
  run_cmd mkdir -p "$TEMP_DIR"

  # --- Install databases ---
  if [[ "$INSTALL_MYSQL" == "true" ]]; then
    install_mysql    || { execute_rollback; exit 1; }
    configure_mysql  || { execute_rollback; exit 1; }
    create_mysql_opa_user || { execute_rollback; exit 1; }
  fi

  if [[ "$INSTALL_PG" == "true" ]]; then
    install_postgresql    || { execute_rollback; exit 1; }
    # create_pg_opa_user MUST run before configure_postgresql.
    # configure_postgresql switches pg_hba.conf local auth to scram-sha-256 and reloads,
    # after which 'sudo -u postgres psql' (peer auth) no longer works on RHEL-family systems.
    # Creating the role first ensures peer auth is still in effect for the psql connection.
    create_pg_opa_user    || { execute_rollback; exit 1; }
    configure_postgresql  || { execute_rollback; exit 1; }
  fi

  if [[ "$INSTALL_MONGO" == "true" ]]; then
    install_mongodb       || { execute_rollback; exit 1; }
    configure_mongodb     || { execute_rollback; exit 1; }
    create_mongo_opa_user || { execute_rollback; exit 1; }
  fi

  # --- Firewall ---
  if [[ "$PRODUCTION_MODE" == "true" ]]; then
    configure_firewall || log_warn "Firewall configuration encountered an error — check log."
  else
    disable_firewall
  fi

  # --- Seed lab data (non-fatal: warn and continue on failure) ---
  if [[ "$SEED_DATA" == "true" ]]; then
    log_step "Seeding lab data (SEED_DBS=${SEED_DBS}, SEED_ROWS=${SEED_ROWS})"
    if [[ "$INSTALL_MYSQL" == "true" ]]; then
      create_mysql_lab_admin || log_warn "MySQL lab admin creation failed — skipping."
      seed_mysql_data        || log_warn "MySQL seeding failed — skipping."
    fi
    if [[ "$INSTALL_PG" == "true" ]]; then
      create_pg_lab_admin    || log_warn "PostgreSQL lab admin creation failed — skipping."
      seed_postgresql_data   || log_warn "PostgreSQL seeding failed — skipping."
    fi
    if [[ "$INSTALL_MONGO" == "true" ]]; then
      create_mongo_lab_admin || log_warn "MongoDB lab admin creation failed — skipping."
      seed_mongodb_data      || log_warn "MongoDB seeding failed — skipping."
    fi
  fi

  # --- Write credentials ---
  write_credentials || { log_error "Failed to write credentials file."; exit 1; }

  # Mark success so the EXIT trap prints the right summary
  INSTALL_SUCCESS=true
}

# --- Script entrypoint ---
main "$@"
