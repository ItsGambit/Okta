#!/usr/bin/env bash
# =============================================================================
# Okta Privilege Access (OPA) Setup Script
# =============================================================================
# Description : Installs and configures Okta Privilege Access Agent, Gateway,
#               and/or SQL Server (MySQL / PostgreSQL) on supported Linux
#               systems.  Handles interactive and fully non-interactive
#               (CI/automation) execution via CLI flags.
#
# Supported   : Ubuntu 20.04+, Debian 11+, RHEL/CentOS/Rocky/AlmaLinux 8+,
#               Amazon Linux 2/2023, Oracle Linux 8+
#
# Official documentation references used while building this script:
#   OPA Agent/Gateway repos : https://help.okta.com/pam/en-us/
#   MySQL install guide     : https://dev.mysql.com/doc/refman/8.0/en/linux-installation.html
#   PostgreSQL install guide: https://www.postgresql.org/download/linux/
#
# Usage       : sudo bash opa_setup.sh [OPTIONS]
#               Run  sudo bash opa_setup.sh --help  for full option list.
#
# Version     : 1.0.0
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# SECTION 1 – Global variables, constants, and logging bootstrap
# ---------------------------------------------------------------------------

readonly SCRIPT_VERSION="1.0.1"
readonly SCRIPT_NAME="$(basename "$0")"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly LOG_DIR="/var/log/opa-setup"
readonly LOG_FILE="${LOG_DIR}/opa_setup_${TIMESTAMP}.log"
readonly CREDS_FILE="/root/.opa_credentials_${TIMESTAMP}.txt"
readonly OPA_AGENT_SERVICE="okta-pam-agent"
readonly OPA_GATEWAY_SERVICE="okta-pam-adserver-gateway"

# Minimum required versions (update if Okta releases new minimums)
readonly MIN_UBUNTU_VERSION="20.04"
readonly MIN_DEBIAN_VERSION="11"
readonly MIN_RHEL_VERSION="8"

# Supported distro IDs (values from /etc/os-release ID field)
readonly SUPPORTED_DISTROS=("ubuntu" "debian" "rhel" "centos" "rocky" "almalinux" "amzn" "ol")

# Runtime state – populated during execution
DISTRO_ID=""
DISTRO_VERSION=""
DISTRO_CODENAME=""
PKG_MGR=""            # apt | dnf | yum
PKG_MGR_INSTALL=""    # full install command

# What to install (0=no, 1=yes) – set by CLI flags or menu
INSTALL_AGENT=0
INSTALL_GATEWAY=0
INSTALL_MYSQL=0
INSTALL_POSTGRESQL=0

# Non-interactive mode flag (set via --non-interactive)
NON_INTERACTIVE=0
SKIP_UPDATES=0
FORCE_REINSTALL=0

# Sample-data row count (only relevant when installing a SQL server)
SAMPLE_DATA_ROWS=0   # 0 = ask at runtime

# Okta tenant configuration (can be pre-set via env vars or CLI)
OPA_TEAM="${OPA_TEAM:-}"
OPA_ENROLLMENT_TOKEN="${OPA_ENROLLMENT_TOKEN:-}"
OPA_GATEWAY_TOKEN="${OPA_GATEWAY_TOKEN:-}"

# Database configuration (auto-generated unless overridden)
DB_NAME="opadb"
DB_APP_USER=""           # generated later
DB_APP_PASSWORD=""       # generated later
DB_ADMIN_USER="opaadmin"
DB_ADMIN_PASSWORD=""     # generated later
MYSQL_ROOT_PASSWORD=""   # generated later

# ---------------------------------------------------------------------------
# SECTION 2 – Logging helpers
# ---------------------------------------------------------------------------

# Create log directory early so every subsequent call can log safely.
mkdir -p "${LOG_DIR}"

log() {
    # log LEVEL MESSAGE
    # Levels: INFO WARN ERROR DEBUG SUCCESS
    local level="${1:-INFO}"
    local message="${2:-}"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local formatted="[${timestamp}] [${level}] ${message}"

    # Always write to log file
    echo "${formatted}" >> "${LOG_FILE}"

    # Write to stderr for ERROR / WARN; stdout for everything else
    case "${level}" in
        ERROR)   echo -e "\033[0;31m${formatted}\033[0m" >&2 ;;
        WARN)    echo -e "\033[0;33m${formatted}\033[0m" ;;
        SUCCESS) echo -e "\033[0;32m${formatted}\033[0m" ;;
        DEBUG)   [[ "${VERBOSE:-0}" == "1" ]] && echo "${formatted}" ;;
        *)       echo "${formatted}" ;;
    esac
}

die() {
    log ERROR "$*"
    log ERROR "See ${LOG_FILE} for full details."
    exit 1
}

separator() { log INFO "------------------------------------------------------------"; }

# Run a command, logging it and its output.  Exits on failure unless the
# caller passes  || true  to suppress.
run_cmd() {
    log DEBUG "Running: $*"
    if output=$("$@" 2>&1); then
        log DEBUG "Output: ${output}"
    else
        local exit_code=$?
        log ERROR "Command failed (exit ${exit_code}): $*"
        log ERROR "Output: ${output}"
        return ${exit_code}
    fi
}

# ---------------------------------------------------------------------------
# SECTION 3 – Utility / prompt helpers
# ---------------------------------------------------------------------------

# Prompt helper that respects NON_INTERACTIVE mode.
# Usage: prompt_yn "Question?" [default_y|default_n]
# Returns 0 (yes) or 1 (no).
prompt_yn() {
    local question="${1}"
    local default="${2:-default_y}"
    if [[ "${NON_INTERACTIVE}" == "1" ]]; then
        # In non-interactive mode treat default_y as yes, default_n as no
        [[ "${default}" == "default_y" ]] && return 0 || return 1
    fi
    local yn_prompt="[Y/n]"
    [[ "${default}" == "default_n" ]] && yn_prompt="[y/N]"
    while true; do
        read -r -p "${question} ${yn_prompt}: " yn
        yn="${yn:-}"
        case "${yn}" in
            [Yy]*|"") [[ "${default}" == "default_n" && -z "${yn}" ]] && return 1; return 0 ;;
            [Nn]*)    return 1 ;;
            *)        echo "Please answer y or n." ;;
        esac
    done
}

# Prompt for a value with an optional default.
prompt_value() {
    local question="${1}"
    local default="${2:-}"
    local result=""
    if [[ "${NON_INTERACTIVE}" == "1" ]]; then
        echo "${default}"
        return
    fi
    if [[ -n "${default}" ]]; then
        read -r -p "${question} [${default}]: " result
        result="${result:-${default}}"
    else
        while [[ -z "${result}" ]]; do
            read -r -p "${question}: " result
        done
    fi
    echo "${result}"
}

# Prompt for a secret (no echo).
prompt_secret() {
    local question="${1}"
    local default="${2:-}"
    if [[ "${NON_INTERACTIVE}" == "1" ]]; then
        echo "${default}"
        return
    fi
    local secret=""
    while [[ -z "${secret}" ]]; do
        read -r -s -p "${question}: " secret
        echo "" >&2
    done
    echo "${secret}"
}

# Generate a cryptographically random password.
generate_password() {
    local length="${1:-24}"
    # Temporarily disable pipefail: tr receives SIGPIPE (exit 141) when head
    # closes the pipe after reading enough bytes.  Without this guard,
    # set -o pipefail would treat the pipeline as failed.
    local pass
    set +o pipefail
    pass="$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%^&*()-_=+' < /dev/urandom 2>/dev/null \
            | head -c "${length}")"
    set -o pipefail
    echo "${pass}"
}

# Generate a random lowercase username.
generate_username() {
    local prefix="${1:-opauser}"
    local suffix
    set +o pipefail
    suffix="$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 6)"
    set -o pipefail
    echo "${prefix}_${suffix}"
}

# Write a key=value pair to the credentials file.
save_credential() {
    local key="${1}"
    local value="${2}"
    echo "${key}=${value}" >> "${CREDS_FILE}"
}

# ---------------------------------------------------------------------------
# SECTION 4 – Argument parsing
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: sudo bash ${SCRIPT_NAME} [OPTIONS]

Installs and configures Okta Privilege Access (OPA) components and/or
SQL Server on supported Linux systems.

GENERAL OPTIONS
  -h, --help                  Show this help and exit
  -v, --verbose               Enable verbose/debug output
  -n, --non-interactive       Run without prompts (uses defaults / env vars)
  --skip-updates              Skip OS package update step
  --force-reinstall           Uninstall existing components before reinstalling

INSTALL SELECTION (combine freely; at least one required in non-interactive mode)
  --install-agent             Install the Okta Privilege Access Agent
  --install-gateway           Install the Okta Privilege Access Gateway
  --install-mysql             Install MySQL Server
  --install-postgresql        Install PostgreSQL Server

OKTA CONFIGURATION (or set matching env vars)
  --opa-team=<TEAM>           Okta PAM team/org name       (env: OPA_TEAM)
  --enrollment-token=<TOKEN>  Agent enrollment token        (env: OPA_ENROLLMENT_TOKEN)
  --gateway-token=<TOKEN>     Gateway enrollment token      (env: OPA_GATEWAY_TOKEN)

SQL / DATABASE OPTIONS
  --sample-data-rows=<N>      Number of sample rows to seed (default: prompt)

EXAMPLES
  # Fully interactive (recommended for first run)
  sudo bash ${SCRIPT_NAME}

  # Non-interactive: install agent + MySQL with 500 sample rows
  sudo OPA_TEAM=myteam OPA_ENROLLMENT_TOKEN=tok_xxx \\
    bash ${SCRIPT_NAME} --non-interactive --install-agent --install-mysql \\
    --sample-data-rows=500

  # Show version + status of installed components then exit
  sudo bash ${SCRIPT_NAME}   # choose option b) in the already-installed menu

LOG FILE     : ${LOG_FILE}
CREDENTIALS  : /root/.opa_credentials_<TIMESTAMP>.txt  (created at end of run)
EOF
}

parse_args() {
    for arg in "$@"; do
        case "${arg}" in
            -h|--help)              usage; exit 0 ;;
            -v|--verbose)           export VERBOSE=1 ;;
            -n|--non-interactive)   NON_INTERACTIVE=1 ;;
            --skip-updates)         SKIP_UPDATES=1 ;;
            --force-reinstall)      FORCE_REINSTALL=1 ;;
            --install-agent)        INSTALL_AGENT=1 ;;
            --install-gateway)      INSTALL_GATEWAY=1 ;;
            --install-mysql)        INSTALL_MYSQL=1 ;;
            --install-postgresql)   INSTALL_POSTGRESQL=1 ;;
            --opa-team=*)           OPA_TEAM="${arg#*=}" ;;
            --enrollment-token=*)   OPA_ENROLLMENT_TOKEN="${arg#*=}" ;;
            --gateway-token=*)      OPA_GATEWAY_TOKEN="${arg#*=}" ;;
            --sample-data-rows=*)   SAMPLE_DATA_ROWS="${arg#*=}" ;;
            *)                      log WARN "Unknown argument: ${arg}. Use --help for usage." ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# SECTION 5 – Distribution detection and support check
# ---------------------------------------------------------------------------

detect_distro() {
    log INFO "Detecting Linux distribution..."

    if [[ ! -f /etc/os-release ]]; then
        die "/etc/os-release not found. Cannot determine distribution."
    fi

    # Source the os-release file to get standardised variables
    # shellcheck disable=SC1091
    source /etc/os-release

    DISTRO_ID="${ID,,}"          # lowercase
    DISTRO_VERSION="${VERSION_ID:-unknown}"
    DISTRO_CODENAME="${VERSION_CODENAME:-}"

    log INFO "Detected: ID=${DISTRO_ID}  VERSION=${DISTRO_VERSION}  CODENAME=${DISTRO_CODENAME}"

    # Normalise Amazon Linux ID
    [[ "${DISTRO_ID}" == "amzn" ]] && DISTRO_ID="amzn"

    # Verify distro is in supported list
    local supported=0
    for d in "${SUPPORTED_DISTROS[@]}"; do
        [[ "${DISTRO_ID}" == "${d}" ]] && supported=1 && break
    done
    [[ "${supported}" == "0" ]] && die "Distribution '${DISTRO_ID}' is not supported. Supported: ${SUPPORTED_DISTROS[*]}"

    # Version-specific minimum checks
    case "${DISTRO_ID}" in
        ubuntu)
            if [[ "$(echo "${DISTRO_VERSION} ${MIN_UBUNTU_VERSION}" | awk '{print ($1 < $2)}')" == "1" ]]; then
                die "Ubuntu ${DISTRO_VERSION} is below the minimum required version ${MIN_UBUNTU_VERSION}."
            fi
            PKG_MGR="apt"
            PKG_MGR_INSTALL="apt-get install -y"
            ;;
        debian)
            if [[ "${DISTRO_VERSION%%.*}" -lt "${MIN_DEBIAN_VERSION}" ]]; then
                die "Debian ${DISTRO_VERSION} is below the minimum required version ${MIN_DEBIAN_VERSION}."
            fi
            PKG_MGR="apt"
            PKG_MGR_INSTALL="apt-get install -y"
            ;;
        rhel|centos|rocky|almalinux|ol)
            if [[ "${DISTRO_VERSION%%.*}" -lt "${MIN_RHEL_VERSION}" ]]; then
                die "${DISTRO_ID} ${DISTRO_VERSION} is below the minimum required major version ${MIN_RHEL_VERSION}."
            fi
            # Prefer dnf over yum on RHEL 8+
            if command -v dnf &>/dev/null; then
                PKG_MGR="dnf"
                PKG_MGR_INSTALL="dnf install -y"
            else
                PKG_MGR="yum"
                PKG_MGR_INSTALL="yum install -y"
            fi
            ;;
        amzn)
            case "${DISTRO_VERSION}" in
                2|2023) ;;
                *) die "Amazon Linux ${DISTRO_VERSION} is not supported. Supported: 2, 2023." ;;
            esac
            if command -v dnf &>/dev/null; then
                PKG_MGR="dnf"
                PKG_MGR_INSTALL="dnf install -y"
            else
                PKG_MGR="yum"
                PKG_MGR_INSTALL="yum install -y"
            fi
            ;;
    esac

    log SUCCESS "Distribution check passed: ${DISTRO_ID} ${DISTRO_VERSION}"
}

# ---------------------------------------------------------------------------
# SECTION 6 – System update and dependency installation
# ---------------------------------------------------------------------------

update_system() {
    if [[ "${SKIP_UPDATES}" == "1" ]]; then
        log WARN "Skipping system update (--skip-updates specified)."
        return
    fi

    log INFO "Updating system packages..."
    case "${PKG_MGR}" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update -qq \
                | tee -a "${LOG_FILE}" \
                || die "apt-get update failed."
            DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq \
                | tee -a "${LOG_FILE}" \
                || die "apt-get upgrade failed."
            ;;
        dnf|yum)
            ${PKG_MGR} update -y \
                | tee -a "${LOG_FILE}" \
                || die "${PKG_MGR} update failed."
            ;;
    esac
    log SUCCESS "System packages updated."
}

install_dependencies() {
    log INFO "Installing base dependencies..."

    local common_deps=("curl" "wget" "gnupg" "ca-certificates" "lsb-release" "jq" "openssl" "net-tools" "unzip")

    case "${PKG_MGR}" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                "${common_deps[@]}" \
                apt-transport-https \
                software-properties-common \
                | tee -a "${LOG_FILE}" \
                || die "Failed to install base dependencies."
            ;;
        dnf|yum)
            ${PKG_MGR} install -y \
                "${common_deps[@]}" \
                | tee -a "${LOG_FILE}" \
                || die "Failed to install base dependencies."
            ;;
    esac

    log SUCCESS "Base dependencies installed."
}

# ---------------------------------------------------------------------------
# SECTION 7 – Already-installed detection and handling
# ---------------------------------------------------------------------------

# Returns 0 if a service/package exists, 1 if not.
is_installed() {
    local name="${1}"
    case "${PKG_MGR}" in
        apt)  dpkg -l "${name}" &>/dev/null && return 0 ;;
        dnf|yum)
              rpm -q "${name}" &>/dev/null && return 0 ;;
    esac
    # Fallback: check if binary/service exists
    command -v "${name}" &>/dev/null && return 0
    systemctl list-units --type=service --all 2>/dev/null | grep -q "${name}" && return 0
    return 1
}

get_installed_version() {
    local pkg="${1}"
    case "${PKG_MGR}" in
        apt)  dpkg -l "${pkg}" 2>/dev/null | awk '/^ii/ {print $3}' | head -1 ;;
        dnf|yum)
              rpm -q --queryformat '%{VERSION}-%{RELEASE}' "${pkg}" 2>/dev/null ;;
    esac
}

get_service_status() {
    local svc="${1}"
    systemctl is-active "${svc}" 2>/dev/null || echo "inactive/not-found"
}

print_component_status() {
    local label="${1}"
    local pkg="${2}"
    local svc="${3}"
    local version
    version="$(get_installed_version "${pkg}" 2>/dev/null || echo "unknown")"
    local status
    status="$(get_service_status "${svc}")"
    log INFO "${label}:"
    log INFO "  Package : ${pkg}"
    log INFO "  Version : ${version}"
    log INFO "  Service : ${svc} — ${status}"
}

# Cleanly removes an OPA Agent or Gateway installation.
uninstall_component() {
    local label="${1}"
    local pkg="${2}"
    local svc="${3}"

    log INFO "Uninstalling ${label}..."
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
        systemctl stop "${svc}"  || log WARN "Could not stop ${svc}."
        systemctl disable "${svc}" || log WARN "Could not disable ${svc}."
    fi

    case "${PKG_MGR}" in
        apt)  DEBIAN_FRONTEND=noninteractive apt-get purge -y "${pkg}" 2>&1 | tee -a "${LOG_FILE}" ;;
        dnf|yum) ${PKG_MGR} remove -y "${pkg}" 2>&1 | tee -a "${LOG_FILE}" ;;
    esac

    log SUCCESS "${label} uninstalled."
}

# Presents the already-installed menu and returns an action code:
#   0 = exit, 1 = show status, 2 = reinstall, 3 = continue to install options
handle_already_installed_menu() {
    local label="${1}"
    local pkg="${2}"
    local svc="${3}"

    log WARN "${label} appears to be already installed."

    if [[ "${NON_INTERACTIVE}" == "1" ]]; then
        if [[ "${FORCE_REINSTALL}" == "1" ]]; then
            log INFO "Non-interactive: --force-reinstall set, proceeding with clean reinstall."
            return 2
        else
            # Return 3 (skip/continue) rather than 0 (exit) so the script
            # carries on installing any other requested components.
            log INFO "Non-interactive: ${label} already installed. Skipping (use --force-reinstall to reinstall)."
            return 3
        fi
    fi

    echo ""
    echo "  ${label} is already installed on this system."
    echo "  What would you like to do?"
    echo ""
    echo "  a) Exit the script"
    echo "  b) Show current version and service status"
    echo "  c) Clean uninstall then reinstall"
    echo "  d) Skip to install options (keep existing, install other components)"
    echo ""

    local choice=""
    while true; do
        read -r -p "  Enter your choice [a/b/c/d]: " choice
        case "${choice,,}" in
            a) return 0 ;;
            b) return 1 ;;
            c) return 2 ;;
            d) return 3 ;;
            *) echo "  Please enter a, b, c, or d." ;;
        esac
    done
}

check_already_installed() {
    local agent_installed=0
    local gateway_installed=0
    local mysql_installed=0
    local pgsql_installed=0

    is_installed "${OPA_AGENT_SERVICE}"        && agent_installed=1
    is_installed "${OPA_GATEWAY_SERVICE}"      && gateway_installed=1
    is_installed "mysql-server"                && mysql_installed=1
    is_installed "mysqld"                      && mysql_installed=1
    is_installed "postgresql"                  && pgsql_installed=1
    is_installed "postgresql-server"           && pgsql_installed=1

    # ----- OPA Agent -----
    if [[ "${agent_installed}" == "1" ]] && [[ "${INSTALL_AGENT}" == "1" || "${NON_INTERACTIVE}" == "0" ]]; then
        local rc=0
        handle_already_installed_menu "Okta Privilege Access Agent" \
            "${OPA_AGENT_SERVICE}" "${OPA_AGENT_SERVICE}" || rc=$?
        case "${rc}" in
            0) log INFO "Exiting at user request."; exit 0 ;;
            1) print_component_status "OPA Agent" "${OPA_AGENT_SERVICE}" "${OPA_AGENT_SERVICE}"
               echo ""
               if ! prompt_yn "Continue with install options?"; then exit 0; fi ;;
            2) uninstall_component "OPA Agent" "${OPA_AGENT_SERVICE}" "${OPA_AGENT_SERVICE}" ;;
            3) INSTALL_AGENT=0 ;; # skip agent, continue to menu
        esac
    fi

    # ----- OPA Gateway -----
    if [[ "${gateway_installed}" == "1" ]] && [[ "${INSTALL_GATEWAY}" == "1" || "${NON_INTERACTIVE}" == "0" ]]; then
        local rc=0
        handle_already_installed_menu "Okta Privilege Access Gateway" \
            "${OPA_GATEWAY_SERVICE}" "${OPA_GATEWAY_SERVICE}" || rc=$?
        case "${rc}" in
            0) log INFO "Exiting at user request."; exit 0 ;;
            1) print_component_status "OPA Gateway" "${OPA_GATEWAY_SERVICE}" "${OPA_GATEWAY_SERVICE}"
               echo ""
               if ! prompt_yn "Continue with install options?"; then exit 0; fi ;;
            2) uninstall_component "OPA Gateway" "${OPA_GATEWAY_SERVICE}" "${OPA_GATEWAY_SERVICE}" ;;
            3) INSTALL_GATEWAY=0 ;;
        esac
    fi

    # ----- MySQL -----
    if [[ "${mysql_installed}" == "1" ]] && [[ "${INSTALL_MYSQL}" == "1" || "${NON_INTERACTIVE}" == "0" ]]; then
        local rc=0
        handle_already_installed_menu "MySQL Server" "mysql-server" "mysql" || rc=$?
        case "${rc}" in
            0) log INFO "Exiting at user request."; exit 0 ;;
            1) print_component_status "MySQL" "mysql-server" "mysql"
               echo ""
               if ! prompt_yn "Continue?"; then exit 0; fi ;;
            2) uninstall_mysql ;;
            3) INSTALL_MYSQL=0 ;;
        esac
    fi

    # ----- PostgreSQL -----
    if [[ "${pgsql_installed}" == "1" ]] && [[ "${INSTALL_POSTGRESQL}" == "1" || "${NON_INTERACTIVE}" == "0" ]]; then
        local rc=0
        handle_already_installed_menu "PostgreSQL Server" "postgresql" "postgresql" || rc=$?
        case "${rc}" in
            0) log INFO "Exiting at user request."; exit 0 ;;
            1) print_component_status "PostgreSQL" "postgresql" "postgresql"
               echo ""
               if ! prompt_yn "Continue?"; then exit 0; fi ;;
            2) uninstall_postgresql ;;
            3) INSTALL_POSTGRESQL=0 ;;
        esac
    fi
}

# ---------------------------------------------------------------------------
# SECTION 8 – Interactive install-options menu
# ---------------------------------------------------------------------------

interactive_install_menu() {
    # Skip if at least one install flag was already set from CLI
    if [[ "${INSTALL_AGENT}" == "1" || "${INSTALL_GATEWAY}" == "1" || \
          "${INSTALL_MYSQL}" == "1" || "${INSTALL_POSTGRESQL}" == "1" ]]; then
        log INFO "Install targets set via CLI flags – skipping interactive menu."
        return
    fi

    if [[ "${NON_INTERACTIVE}" == "1" ]]; then
        die "Non-interactive mode requires at least one --install-* flag."
    fi

    separator
    echo ""
    echo "  What would you like to install? (select all that apply)"
    echo ""
    echo "  1) Okta Privilege Access Agent"
    echo "  2) Okta Privilege Access Gateway"
    echo "  3) SQL Server"
    echo ""
    echo "  Enter numbers separated by spaces (e.g. '1 3' or '1 2 3'):"
    echo ""

    local choices=""
    local -a tokens=()
    while [[ -z "${choices}" ]]; do
        read -r -p "  Your selection: " choices
        # Split on spaces using read -ra (safe regardless of global IFS setting)
        IFS=' ' read -ra tokens <<< "${choices}"
        # Validate each token is 1, 2, or 3
        local valid=1
        for tok in "${tokens[@]+"${tokens[@]}"}"; do
            [[ "${tok}" =~ ^[123]$ ]] || { valid=0; break; }
        done
        if [[ "${valid}" == "0" || "${#tokens[@]}" -eq 0 ]]; then
            echo "  Please enter one or more of: 1 2 3"
            choices=""
            tokens=()
        fi
    done

    for tok in "${tokens[@]}"; do
        case "${tok}" in
            1) INSTALL_AGENT=1 ;;
            2) INSTALL_GATEWAY=1 ;;
            3) sql_server_submenu ;;
        esac
    done
}

sql_server_submenu() {
    echo ""
    echo "  Which SQL server would you like to install?"
    echo ""
    echo "  1) MySQL"
    echo "  2) PostgreSQL"
    echo ""

    local sql_choice=""
    while [[ -z "${sql_choice}" ]]; do
        read -r -p "  Your selection [1/2]: " sql_choice
        case "${sql_choice}" in
            1) INSTALL_MYSQL=1 ;;
            2) INSTALL_POSTGRESQL=1 ;;
            *) echo "  Please enter 1 or 2."; sql_choice="" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# SECTION 9 – OPA Repository helpers
# ---------------------------------------------------------------------------
# NOTE: Okta periodically updates repository URLs and GPG keys.
#       Always verify against:  https://help.okta.com/pam/en-us/
# ---------------------------------------------------------------------------

readonly OPA_REPO_GPG_URL="https://packages.okta.com/okta-pam-agent/gpg"
readonly OPA_REPO_DEB_URL="https://packages.okta.com/okta-pam-agent/debian"
readonly OPA_REPO_RPM_URL="https://packages.okta.com/okta-pam-agent/rhel"

add_opa_repo_deb() {
    log INFO "Adding Okta PAM APT repository..."

    local keyring="/usr/share/keyrings/okta-pam-agent.gpg"
    local sources_file="/etc/apt/sources.list.d/okta-pam-agent.list"

    # Import GPG key
    curl -fsSL "${OPA_REPO_GPG_URL}" \
        | gpg --dearmor -o "${keyring}" \
        || die "Failed to import Okta PAM GPG key."

    # Add repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=${keyring}] ${OPA_REPO_DEB_URL} stable main" \
        > "${sources_file}"

    DEBIAN_FRONTEND=noninteractive apt-get update -qq \
        || die "apt-get update failed after adding Okta PAM repo."

    log SUCCESS "Okta PAM APT repository added."
}

add_opa_repo_rpm() {
    log INFO "Adding Okta PAM RPM repository..."

    local releasever
    releasever="${DISTRO_VERSION%%.*}"
    local basearch
    basearch="$(uname -m)"

    # Import GPG key
    rpm --import "${OPA_REPO_GPG_URL}" \
        || die "Failed to import Okta PAM GPG key."

    # Write repo file
    cat > /etc/yum.repos.d/okta-pam-agent.repo <<EOF
[okta-pam-agent]
name=Okta PAM Agent - \$basearch
baseurl=${OPA_REPO_RPM_URL}/${releasever}/\$basearch
enabled=1
gpgcheck=1
gpgkey=${OPA_REPO_GPG_URL}
EOF

    log SUCCESS "Okta PAM RPM repository added."
}

add_opa_repo() {
    case "${PKG_MGR}" in
        apt)      add_opa_repo_deb ;;
        dnf|yum)  add_opa_repo_rpm ;;
    esac
}

# ---------------------------------------------------------------------------
# SECTION 10 – OPA Agent installation and setup
# ---------------------------------------------------------------------------

install_opa_agent() {
    separator
    log INFO "Installing Okta Privilege Access Agent..."

    add_opa_repo

    case "${PKG_MGR}" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get install -y okta-pam-agent \
                | tee -a "${LOG_FILE}" \
                || die "Failed to install okta-pam-agent."
            ;;
        dnf|yum)
            ${PKG_MGR} install -y okta-pam-agent \
                | tee -a "${LOG_FILE}" \
                || die "Failed to install okta-pam-agent."
            ;;
    esac

    log SUCCESS "okta-pam-agent package installed."
    configure_opa_agent
}

configure_opa_agent() {
    log INFO "Configuring Okta Privilege Access Agent..."

    # Collect Okta team and enrollment token
    if [[ -z "${OPA_TEAM}" ]]; then
        OPA_TEAM="$(prompt_value "Enter your Okta PAM team name (visible in Okta Admin > Privileged Access)")"
    fi

    if [[ -z "${OPA_ENROLLMENT_TOKEN}" ]]; then
        OPA_ENROLLMENT_TOKEN="$(prompt_secret "Enter the Agent Enrollment Token (from Okta Admin > Privileged Access > Gateway/Agent > Create Token)")"
    fi

    # The agent configuration directory (adjust path if Okta changes it)
    local agent_config_dir="/etc/okta-pam-agent"
    local agent_config_file="${agent_config_dir}/okta-pam-agent.yaml"

    mkdir -p "${agent_config_dir}"

    # Write the agent configuration
    # NOTE: Exact keys may differ across Okta PAM Agent versions.
    #       Cross-reference with: https://help.okta.com/pam/en-us/content/topics/pam/agent-config-reference.htm
    cat > "${agent_config_file}" <<EOF
# Okta Privilege Access Agent Configuration
# Generated by ${SCRIPT_NAME} v${SCRIPT_VERSION} on $(date)
#
# Full reference: https://help.okta.com/pam/en-us/

team: "${OPA_TEAM}"
enrollmentToken: "${OPA_ENROLLMENT_TOKEN}"

# Logging configuration
log:
  level: info
  output: /var/log/okta-pam-agent/agent.log

# TLS – always use system CA bundle; do not disable certificate verification
tls:
  insecureSkipVerify: false
EOF

    chmod 600 "${agent_config_file}"
    log SUCCESS "Agent configuration written to ${agent_config_file}"

    # Create log directory for the agent
    mkdir -p /var/log/okta-pam-agent

    # Enable and start the service
    log INFO "Enabling and starting ${OPA_AGENT_SERVICE}..."
    systemctl daemon-reload
    systemctl enable "${OPA_AGENT_SERVICE}"  || die "Failed to enable ${OPA_AGENT_SERVICE}."
    systemctl start  "${OPA_AGENT_SERVICE}"  || die "Failed to start ${OPA_AGENT_SERVICE}."

    # Allow the service a moment to initialise before checking status
    sleep 3

    if systemctl is-active --quiet "${OPA_AGENT_SERVICE}"; then
        log SUCCESS "Okta PAM Agent is running."
    else
        log WARN "Okta PAM Agent did not start cleanly. Check: journalctl -u ${OPA_AGENT_SERVICE}"
        log WARN "This may indicate an invalid enrollment token or network connectivity issue."
    fi

    save_credential "OPA_AGENT_TEAM"             "${OPA_TEAM}"
    save_credential "OPA_AGENT_ENROLLMENT_TOKEN" "${OPA_ENROLLMENT_TOKEN}"
    save_credential "OPA_AGENT_CONFIG"           "${agent_config_file}"
    save_credential "OPA_AGENT_LOG"              "/var/log/okta-pam-agent/agent.log"
}

# ---------------------------------------------------------------------------
# SECTION 11 – OPA Gateway installation and setup
# ---------------------------------------------------------------------------

install_opa_gateway() {
    separator
    log INFO "Installing Okta Privilege Access Gateway..."

    # The gateway uses the same Okta PAM repository as the agent
    # (repo may already have been added if the agent was installed first)
    if [[ ! -f /etc/apt/sources.list.d/okta-pam-agent.list ]] && \
       [[ ! -f /etc/yum.repos.d/okta-pam-agent.repo ]]; then
        add_opa_repo
    fi

    case "${PKG_MGR}" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get install -y okta-pam-adserver-gateway \
                | tee -a "${LOG_FILE}" \
                || die "Failed to install okta-pam-adserver-gateway."
            ;;
        dnf|yum)
            ${PKG_MGR} install -y okta-pam-adserver-gateway \
                | tee -a "${LOG_FILE}" \
                || die "Failed to install okta-pam-adserver-gateway."
            ;;
    esac

    log SUCCESS "okta-pam-adserver-gateway package installed."
    configure_opa_gateway
}

configure_opa_gateway() {
    log INFO "Configuring Okta Privilege Access Gateway..."

    if [[ -z "${OPA_TEAM}" ]]; then
        OPA_TEAM="$(prompt_value "Enter your Okta PAM team name")"
    fi

    if [[ -z "${OPA_GATEWAY_TOKEN}" ]]; then
        OPA_GATEWAY_TOKEN="$(prompt_secret "Enter the Gateway Enrollment Token (from Okta Admin > Privileged Access > Gateways > Add Gateway > Generate Token)")"
    fi

    local gw_config_dir="/etc/okta-pam-adserver-gateway"
    local gw_config_file="${gw_config_dir}/gateway.yaml"

    mkdir -p "${gw_config_dir}"

    # Write gateway configuration
    # NOTE: Cross-reference with Okta PAM Gateway documentation:
    #       https://help.okta.com/pam/en-us/content/topics/pam/gw-configure.htm
    cat > "${gw_config_file}" <<EOF
# Okta Privilege Access Gateway Configuration
# Generated by ${SCRIPT_NAME} v${SCRIPT_VERSION} on $(date)
#
# Full reference: https://help.okta.com/pam/en-us/

team: "${OPA_TEAM}"
enrollmentToken: "${OPA_GATEWAY_TOKEN}"

# Gateway listens on this port for PAM traffic; ensure it is firewalled
# and only accessible by the Okta service planes.
listenPort: 7234

# Logging
log:
  level: info
  output: /var/log/okta-pam-gateway/gateway.log

# TLS – always verify; do not set insecureSkipVerify: true in production
tls:
  insecureSkipVerify: false
EOF

    chmod 600 "${gw_config_file}"
    log SUCCESS "Gateway configuration written to ${gw_config_file}"

    mkdir -p /var/log/okta-pam-gateway

    log INFO "Enabling and starting ${OPA_GATEWAY_SERVICE}..."
    systemctl daemon-reload
    systemctl enable "${OPA_GATEWAY_SERVICE}"  || die "Failed to enable ${OPA_GATEWAY_SERVICE}."
    systemctl start  "${OPA_GATEWAY_SERVICE}"  || die "Failed to start ${OPA_GATEWAY_SERVICE}."

    sleep 3

    if systemctl is-active --quiet "${OPA_GATEWAY_SERVICE}"; then
        log SUCCESS "Okta PAM Gateway is running."
    else
        log WARN "Okta PAM Gateway did not start cleanly. Check: journalctl -u ${OPA_GATEWAY_SERVICE}"
    fi

    save_credential "OPA_GATEWAY_TEAM"         "${OPA_TEAM}"
    save_credential "OPA_GATEWAY_TOKEN"        "${OPA_GATEWAY_TOKEN}"
    save_credential "OPA_GATEWAY_CONFIG"       "${gw_config_file}"
    save_credential "OPA_GATEWAY_LOG"          "/var/log/okta-pam-gateway/gateway.log"
    save_credential "OPA_GATEWAY_LISTEN_PORT"  "7234"
}

# ---------------------------------------------------------------------------
# SECTION 12 – MySQL installation and setup
# ---------------------------------------------------------------------------

uninstall_mysql() {
    log INFO "Uninstalling MySQL..."
    case "${PKG_MGR}" in
        apt)
            systemctl stop mysql 2>/dev/null || true
            DEBIAN_FRONTEND=noninteractive apt-get purge -y mysql-server mysql-client mysql-common \
                "mysql-server-*" "mysql-client-*" 2>&1 | tee -a "${LOG_FILE}"
            DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>&1 | tee -a "${LOG_FILE}"
            rm -rf /etc/mysql /var/lib/mysql /var/log/mysql
            ;;
        dnf|yum)
            systemctl stop mysqld 2>/dev/null || true
            ${PKG_MGR} remove -y mysql-server mysql 2>&1 | tee -a "${LOG_FILE}"
            rm -rf /var/lib/mysql /var/log/mysql /etc/my.cnf.d
            ;;
    esac
    log SUCCESS "MySQL uninstalled."
}

install_mysql() {
    separator
    log INFO "Installing MySQL Server..."

    # MySQL 8.x is installed from the distribution's official repo or the
    # MySQL community repo.  Using the distro repo is preferred for security.
    # Reference: https://dev.mysql.com/doc/refman/8.0/en/linux-installation.html

    case "${PKG_MGR}" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                mysql-server \
                | tee -a "${LOG_FILE}" \
                || die "Failed to install mysql-server."
            ;;
        dnf|yum)
            # On RHEL 8+ the module may need to be enabled first
            ${PKG_MGR} module enable -y mysql 2>/dev/null || true
            ${PKG_MGR} install -y mysql-server \
                | tee -a "${LOG_FILE}" \
                || die "Failed to install mysql-server."
            ;;
    esac

    log SUCCESS "MySQL Server installed."

    # Determine correct service name (varies by distro)
    local mysql_svc="mysql"
    systemctl list-unit-files --type=service 2>/dev/null | grep -q "^mysqld.service" \
        && mysql_svc="mysqld"

    log INFO "Enabling and starting MySQL..."
    systemctl enable "${mysql_svc}"
    systemctl start  "${mysql_svc}" || die "Failed to start MySQL."
    sleep 2

    if ! systemctl is-active --quiet "${mysql_svc}"; then
        die "MySQL failed to start. Check: journalctl -u ${mysql_svc}"
    fi
    log SUCCESS "MySQL is running."

    setup_mysql "${mysql_svc}"
}

setup_mysql() {
    local mysql_svc="${1}"

    log INFO "Hardening and configuring MySQL..."

    # Generate credentials
    MYSQL_ROOT_PASSWORD="$(generate_password 32)"
    DB_ADMIN_USER="$(generate_username "opaadmin")"
    DB_ADMIN_PASSWORD="$(generate_password 28)"
    DB_APP_USER="$(generate_username "opaapp")"
    DB_APP_PASSWORD="$(generate_password 28)"

    # On RHEL/CentOS/RPM-based systems MySQL 8 writes a temporary root password
    # to the error log at first start.  We must use it for the initial connection
    # before we can set our own password.
    # On Debian/Ubuntu, MySQL uses auth_socket so no password is needed initially.
    local mysql_initial_args=()
    if [[ "${PKG_MGR}" != "apt" ]]; then
        local mysql_tmp_pass=""
        local mysql_log="/var/log/mysqld.log"
        if [[ -f "${mysql_log}" ]]; then
            mysql_tmp_pass="$(grep -oP '(?<=temporary password is generated for root@localhost: )\S+' \
                              "${mysql_log}" 2>/dev/null | tail -1 || true)"
        fi
        if [[ -n "${mysql_tmp_pass}" ]]; then
            log INFO "Using temporary MySQL root password from ${mysql_log}."
            mysql_initial_args=(--connect-expired-password --password="${mysql_tmp_pass}")
        else
            log INFO "No temporary MySQL root password found; attempting passwordless initial connection."
        fi
    fi

    # Set root password and apply mysql_secure_installation steps non-interactively.
    # Reference: https://dev.mysql.com/doc/refman/8.0/en/mysql-secure-installation.html
    mysql --user=root "${mysql_initial_args[@]}" <<-SQL_EOF
        -- Set root password with caching_sha2_password (MySQL 8 default)
        ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${MYSQL_ROOT_PASSWORD}';

        -- Remove anonymous users
        DELETE FROM mysql.user WHERE User='';

        -- Disallow remote root login
        DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');

        -- Remove test database
        DROP DATABASE IF EXISTS test;
        DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

        -- Flush privileges
        FLUSH PRIVILEGES;
SQL_EOF

    log SUCCESS "MySQL root account secured."

    # Create admin and application users
    mysql --user=root --password="${MYSQL_ROOT_PASSWORD}" <<-SQL_EOF
        CREATE USER '${DB_ADMIN_USER}'@'localhost' IDENTIFIED BY '${DB_ADMIN_PASSWORD}';
        GRANT ALL PRIVILEGES ON *.* TO '${DB_ADMIN_USER}'@'localhost' WITH GRANT OPTION;

        CREATE USER '${DB_APP_USER}'@'localhost'  IDENTIFIED BY '${DB_APP_PASSWORD}';
        FLUSH PRIVILEGES;
SQL_EOF

    log SUCCESS "MySQL admin and application users created."

    # Create application database and grant privileges
    mysql --user=root --password="${MYSQL_ROOT_PASSWORD}" <<-SQL_EOF
        CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
            CHARACTER SET utf8mb4
            COLLATE utf8mb4_unicode_ci;

        GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER
            ON \`${DB_NAME}\`.*
            TO '${DB_APP_USER}'@'localhost';

        FLUSH PRIVILEGES;
SQL_EOF

    log SUCCESS "Database '${DB_NAME}' created and privileges granted."

    # Write a minimal my.cnf hardening snippet
    local cnf_snippet="/etc/mysql/conf.d/opa-hardening.cnf"
    [[ "${PKG_MGR}" != "apt" ]] && cnf_snippet="/etc/my.cnf.d/opa-hardening.cnf"
    mkdir -p "$(dirname "${cnf_snippet}")"
    cat > "${cnf_snippet}" <<EOF
# OPA Setup – MySQL Hardening
# Reference: https://dev.mysql.com/doc/refman/8.0/en/server-configuration.html
[mysqld]
# Disable local file loading to mitigate LOAD DATA INFILE attacks
local_infile=0

# Bind only to localhost unless you need remote connections
bind-address=127.0.0.1

# Enable general query log to a dedicated file (disable in high-throughput production)
# general_log=1
# general_log_file=/var/log/mysql/general.log

# Enable slow query log
slow_query_log=1
slow_query_log_file=/var/log/mysql/slow.log
long_query_time=2
EOF

    systemctl restart "${mysql_svc}" || log WARN "MySQL restart failed after applying hardening config."
    log SUCCESS "MySQL hardening configuration applied."

    save_credential "MYSQL_ROOT_PASSWORD"   "${MYSQL_ROOT_PASSWORD}"
    save_credential "MYSQL_ADMIN_USER"      "${DB_ADMIN_USER}"
    save_credential "MYSQL_ADMIN_PASSWORD"  "${DB_ADMIN_PASSWORD}"
    save_credential "MYSQL_APP_USER"        "${DB_APP_USER}"
    save_credential "MYSQL_APP_PASSWORD"    "${DB_APP_PASSWORD}"
    save_credential "MYSQL_DATABASE"        "${DB_NAME}"

    seed_mysql_database
}

seed_mysql_database() {
    local rows
    rows="$(get_sample_data_rows)"
    log INFO "Seeding MySQL database '${DB_NAME}' with ${rows} sample rows..."

    # Create schema
    mysql --user=root --password="${MYSQL_ROOT_PASSWORD}" "${DB_NAME}" <<-SQL_EOF
        CREATE TABLE IF NOT EXISTS employees (
            id            INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
            first_name    VARCHAR(50)  NOT NULL,
            last_name     VARCHAR(50)  NOT NULL,
            email         VARCHAR(100) NOT NULL UNIQUE,
            department    VARCHAR(50)  NOT NULL,
            job_title     VARCHAR(80)  NOT NULL,
            hire_date     DATE         NOT NULL,
            salary        DECIMAL(10,2) NOT NULL,
            is_active     TINYINT(1)   NOT NULL DEFAULT 1,
            created_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

        CREATE TABLE IF NOT EXISTS departments (
            id   INT         NOT NULL AUTO_INCREMENT PRIMARY KEY,
            name VARCHAR(50) NOT NULL UNIQUE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

        INSERT IGNORE INTO departments (name) VALUES
            ('Engineering'),('Marketing'),('Sales'),('HR'),
            ('Finance'),('Operations'),('Legal'),('IT');
SQL_EOF

    # Insert rows in batches of 200 for performance
    local batch=200
    local inserted=0

    # Arrays for random data generation
    local first_names=("Alice" "Bob" "Carol" "David" "Emma" "Frank" "Grace" "Henry"
                        "Iris" "Jack" "Karen" "Liam" "Mia" "Noah" "Olivia" "Paul"
                        "Quinn" "Rachel" "Sam" "Tina" "Ursula" "Victor" "Wendy" "Xander")
    local last_names=("Smith" "Johnson" "Williams" "Brown" "Jones" "Garcia" "Miller"
                      "Davis" "Wilson" "Moore" "Taylor" "Anderson" "Thomas" "Jackson")
    local departments=("Engineering" "Marketing" "Sales" "HR" "Finance" "Operations" "Legal" "IT")
    local titles=("Engineer" "Manager" "Analyst" "Coordinator" "Director" "Lead" "Associate" "Specialist")

    while [[ "${inserted}" -lt "${rows}" ]]; do
        local current_batch=$(( rows - inserted < batch ? rows - inserted : batch ))
        local sql="INSERT INTO employees (first_name, last_name, email, department, job_title, hire_date, salary) VALUES"
        local values=()

        for (( i=0; i<current_batch; i++ )); do
            local fn="${first_names[$((RANDOM % ${#first_names[@]}))]}"
            local ln="${last_names[$((RANDOM % ${#last_names[@]}))]}"
            local dept="${departments[$((RANDOM % ${#departments[@]}))]}"
            local title="${titles[$((RANDOM % ${#titles[@]}))]}"
            local email
            email="${fn,,}.${ln,,}.${inserted}_${i}@example.com"
            local year=$(( 2010 + RANDOM % 14 ))
            local month=$(( 1 + RANDOM % 12 ))
            local day=$(( 1 + RANDOM % 28 ))
            local hire_date
            hire_date="$(printf '%04d-%02d-%02d' "${year}" "${month}" "${day}")"
            local salary
            salary="$(( 50000 + RANDOM % 100000 )).$(( RANDOM % 100 ))"

            values+=("('${fn}','${ln}','${email}','${dept}','${title} ${dept}','${hire_date}',${salary})")
        done

        local values_str
        values_str="$(printf '%s,' "${values[@]}")"
        values_str="${values_str%,}"   # strip trailing comma

        mysql --user=root --password="${MYSQL_ROOT_PASSWORD}" "${DB_NAME}" \
            -e "${sql} ${values_str};" \
            2>>"${LOG_FILE}" \
            || log WARN "Batch insert failed (inserted so far: ${inserted})"

        (( inserted += current_batch ))
        log DEBUG "Inserted ${inserted}/${rows} rows..."
    done

    log SUCCESS "Seeded ${rows} rows into ${DB_NAME}.employees."
}

# ---------------------------------------------------------------------------
# SECTION 13 – PostgreSQL installation and setup
# ---------------------------------------------------------------------------

uninstall_postgresql() {
    log INFO "Uninstalling PostgreSQL..."
    case "${PKG_MGR}" in
        apt)
            systemctl stop postgresql 2>/dev/null || true
            DEBIAN_FRONTEND=noninteractive apt-get purge -y postgresql postgresql-* 2>&1 | tee -a "${LOG_FILE}"
            DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>&1 | tee -a "${LOG_FILE}"
            rm -rf /etc/postgresql /var/lib/postgresql /var/log/postgresql
            ;;
        dnf|yum)
            systemctl stop postgresql 2>/dev/null || true
            ${PKG_MGR} remove -y postgresql-server postgresql 2>&1 | tee -a "${LOG_FILE}"
            rm -rf /var/lib/pgsql
            ;;
    esac
    log SUCCESS "PostgreSQL uninstalled."
}

install_postgresql() {
    separator
    log INFO "Installing PostgreSQL Server..."

    # Install via the official PostgreSQL APT/RPM repository for the latest stable.
    # Reference: https://www.postgresql.org/download/linux/
    case "${PKG_MGR}" in
        apt)
            # Add PostgreSQL PGDG APT repository
            local pg_keyring="/usr/share/keyrings/postgresql.gpg"
            curl -fsSL "https://www.postgresql.org/media/keys/ACCC4CF8.asc" \
                | gpg --dearmor -o "${pg_keyring}" \
                || die "Failed to import PostgreSQL GPG key."

            echo "deb [arch=$(dpkg --print-architecture) signed-by=${pg_keyring}] \
https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
                > /etc/apt/sources.list.d/pgdg.list

            DEBIAN_FRONTEND=noninteractive apt-get update -qq \
                || die "apt-get update failed after adding PGDG repo."

            # Install latest PostgreSQL 16 (change version as needed)
            local pg_ver="16"
            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                "postgresql-${pg_ver}" \
                "postgresql-client-${pg_ver}" \
                | tee -a "${LOG_FILE}" \
                || die "Failed to install PostgreSQL ${pg_ver}."
            ;;

        dnf|yum)
            local pg_ver="16"

            # Amazon Linux uses a separate PGDG repo URL and its own package naming.
            # Reference: https://www.postgresql.org/download/linux/redhat/
            if [[ "${DISTRO_ID}" == "amzn" ]]; then
                if [[ "${DISTRO_VERSION}" == "2023" ]]; then
                    # Amazon Linux 2023 ships PostgreSQL 15 natively; use it.
                    pg_ver="15"
                    ${PKG_MGR} install -y postgresql15-server postgresql15 \
                        | tee -a "${LOG_FILE}" \
                        || die "Failed to install PostgreSQL on Amazon Linux 2023."
                    postgresql-setup --initdb \
                        | tee -a "${LOG_FILE}" \
                        || die "PostgreSQL initdb failed on Amazon Linux 2023."
                else
                    # Amazon Linux 2: enable postgresql extra and install
                    amazon-linux-extras enable postgresql14 \
                        | tee -a "${LOG_FILE}" \
                        || die "Failed to enable PostgreSQL extra on Amazon Linux 2."
                    pg_ver="14"
                    ${PKG_MGR} install -y postgresql-server \
                        | tee -a "${LOG_FILE}" \
                        || die "Failed to install PostgreSQL on Amazon Linux 2."
                    postgresql-setup initdb \
                        | tee -a "${LOG_FILE}" \
                        || die "PostgreSQL initdb failed on Amazon Linux 2."
                fi
            else
                # RHEL/CentOS/Rocky/AlmaLinux/Oracle Linux – use PGDG RPM repo.
                # The repo URL uses the major OS version (e.g. EL-8, EL-9).
                local pg_repo_rpm="https://download.postgresql.org/pub/repos/yum/reporpms/EL-${DISTRO_VERSION%%.*}-x86_64/pgdg-redhat-repo-latest.noarch.rpm"

                ${PKG_MGR} install -y "${pg_repo_rpm}" \
                    | tee -a "${LOG_FILE}" \
                    || die "Failed to add PGDG RPM repository."

                # Disable the built-in PostgreSQL module on RHEL 8+ to prevent conflicts
                ${PKG_MGR} module disable -y postgresql 2>/dev/null || true

                ${PKG_MGR} install -y \
                    "postgresql${pg_ver}-server" \
                    "postgresql${pg_ver}" \
                    | tee -a "${LOG_FILE}" \
                    || die "Failed to install PostgreSQL ${pg_ver}."

                # Initialise the database cluster
                "/usr/pgsql-${pg_ver}/bin/postgresql-${pg_ver}-setup" initdb \
                    | tee -a "${LOG_FILE}" \
                    || die "PostgreSQL initdb failed."
            fi
            ;;
    esac

    log SUCCESS "PostgreSQL installed."

    # Determine service name
    local pg_svc="postgresql"
    systemctl list-unit-files --type=service 2>/dev/null | grep -q "^postgresql-[0-9]" \
        && pg_svc="$(systemctl list-unit-files --type=service 2>/dev/null \
                     | grep "^postgresql-[0-9]" | awk '{print $1}' | head -1)"
    # Strip .service suffix if present
    pg_svc="${pg_svc%.service}"

    log INFO "Enabling and starting ${pg_svc}..."
    systemctl enable "${pg_svc}"
    systemctl start  "${pg_svc}" || die "Failed to start PostgreSQL."
    sleep 2

    if ! systemctl is-active --quiet "${pg_svc}"; then
        die "PostgreSQL failed to start. Check: journalctl -u ${pg_svc}"
    fi
    log SUCCESS "PostgreSQL is running (service: ${pg_svc})."

    setup_postgresql "${pg_svc}"
}

setup_postgresql() {
    local pg_svc="${1}"

    log INFO "Hardening and configuring PostgreSQL..."

    # Generate credentials
    DB_ADMIN_USER="$(generate_username "opaadmin")"
    DB_ADMIN_PASSWORD="$(generate_password 28)"
    DB_APP_USER="$(generate_username "opaapp")"
    DB_APP_PASSWORD="$(generate_password 28)"

    # Run commands as the postgres system user
    # Create admin role
    sudo -u postgres psql -v ON_ERROR_STOP=1 <<-PSQL_EOF
        -- Create dedicated admin user (not a superuser for principle of least privilege)
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${DB_ADMIN_USER}') THEN
                CREATE ROLE "${DB_ADMIN_USER}" WITH LOGIN PASSWORD '${DB_ADMIN_PASSWORD}' CREATEROLE CREATEDB;
            END IF;
        END
        \$\$;

        -- Create application user
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${DB_APP_USER}') THEN
                CREATE ROLE "${DB_APP_USER}" WITH LOGIN PASSWORD '${DB_APP_PASSWORD}';
            END IF;
        END
        \$\$;

        -- Create application database
        SELECT 'CREATE DATABASE ${DB_NAME} OWNER ${DB_APP_USER}'
        WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}')\gexec

        -- Revoke default CREATE privilege on public schema from all users
        REVOKE CREATE ON SCHEMA public FROM PUBLIC;
PSQL_EOF

    # Grant privileges to app user on the new database
    sudo -u postgres psql -v ON_ERROR_STOP=1 -d "${DB_NAME}" <<-PSQL_EOF
        GRANT CONNECT ON DATABASE "${DB_NAME}" TO "${DB_APP_USER}";
        GRANT USAGE ON SCHEMA public TO "${DB_APP_USER}";
        ALTER DEFAULT PRIVILEGES IN SCHEMA public
            GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "${DB_APP_USER}";
        ALTER DEFAULT PRIVILEGES IN SCHEMA public
            GRANT USAGE, SELECT ON SEQUENCES TO "${DB_APP_USER}";
PSQL_EOF

    log SUCCESS "PostgreSQL users and database created."

    # Apply pg_hba.conf and postgresql.conf hardening
    # Find the data directory
    local pg_data
    pg_data="$(sudo -u postgres psql -t -c 'SHOW data_directory;' 2>/dev/null | xargs)"

    if [[ -n "${pg_data}" && -d "${pg_data}" ]]; then
        local pg_conf="${pg_data}/postgresql.conf"
        local hba_conf="${pg_data}/pg_hba.conf"

        # postgresql.conf hardening
        # Reference: https://www.postgresql.org/docs/current/runtime-config.html
        cat >> "${pg_conf}" <<EOF

# OPA Setup – hardening additions ($(date))
# Listen on localhost only unless remote access is needed
listen_addresses = 'localhost'

# Log connections and disconnections for auditing
log_connections = on
log_disconnections = on
log_duration = off
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '

# Password encryption (scram-sha-256 is default in PG 14+)
password_encryption = scram-sha-256
EOF

        # pg_hba.conf – enforce scram-sha-256 for all local connections
        # Prepend the rule before any trust entries
        local tmp_hba
        tmp_hba="$(mktemp)"
        cat > "${tmp_hba}" <<EOF
# OPA Setup – updated by ${SCRIPT_NAME} on $(date)
# TYPE  DATABASE        USER            ADDRESS         METHOD
local   all             postgres                        peer
local   all             all                             scram-sha-256
host    all             all             127.0.0.1/32    scram-sha-256
host    all             all             ::1/128         scram-sha-256
EOF
        [[ -f "${hba_conf}" ]] && cp "${hba_conf}" "${hba_conf}.bak_${TIMESTAMP}"
        mv "${tmp_hba}" "${hba_conf}"
        chown postgres:postgres "${hba_conf}"
        chmod 600 "${hba_conf}"

        systemctl reload "${pg_svc}" || log WARN "PostgreSQL reload failed."
        log SUCCESS "PostgreSQL hardening configuration applied."
    else
        log WARN "Could not locate PostgreSQL data directory; skipping hardening config."
    fi

    save_credential "POSTGRESQL_ADMIN_USER"     "${DB_ADMIN_USER}"
    save_credential "POSTGRESQL_ADMIN_PASSWORD" "${DB_ADMIN_PASSWORD}"
    save_credential "POSTGRESQL_APP_USER"       "${DB_APP_USER}"
    save_credential "POSTGRESQL_APP_PASSWORD"   "${DB_APP_PASSWORD}"
    save_credential "POSTGRESQL_DATABASE"       "${DB_NAME}"

    seed_postgresql_database
}

seed_postgresql_database() {
    local rows
    rows="$(get_sample_data_rows)"
    log INFO "Seeding PostgreSQL database '${DB_NAME}' with ${rows} sample rows..."

    # Create schema
    sudo -u postgres psql -v ON_ERROR_STOP=1 -d "${DB_NAME}" <<-PSQL_EOF
        CREATE TABLE IF NOT EXISTS departments (
            id   SERIAL       PRIMARY KEY,
            name VARCHAR(50)  NOT NULL UNIQUE
        );

        INSERT INTO departments (name)
        VALUES ('Engineering'),('Marketing'),('Sales'),('HR'),
               ('Finance'),('Operations'),('Legal'),('IT')
        ON CONFLICT DO NOTHING;

        CREATE TABLE IF NOT EXISTS employees (
            id          SERIAL          PRIMARY KEY,
            first_name  VARCHAR(50)     NOT NULL,
            last_name   VARCHAR(50)     NOT NULL,
            email       VARCHAR(100)    NOT NULL UNIQUE,
            department  VARCHAR(50)     NOT NULL,
            job_title   VARCHAR(80)     NOT NULL,
            hire_date   DATE            NOT NULL,
            salary      NUMERIC(10,2)   NOT NULL,
            is_active   BOOLEAN         NOT NULL DEFAULT TRUE,
            created_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW()
        );
PSQL_EOF

    # Seed using a generate_series query for performance (no shell loop needed)
    sudo -u postgres psql -v ON_ERROR_STOP=1 -d "${DB_NAME}" <<-PSQL_EOF
        INSERT INTO employees (first_name, last_name, email, department, job_title, hire_date, salary)
        SELECT
            (ARRAY['Alice','Bob','Carol','David','Emma','Frank','Grace','Henry',
                    'Iris','Jack','Karen','Liam','Mia','Noah','Olivia','Paul'])[floor(random()*16+1)::int],
            (ARRAY['Smith','Johnson','Williams','Brown','Jones','Garcia','Miller',
                    'Davis','Wilson','Moore','Taylor','Anderson'])[floor(random()*12+1)::int],
            'user_' || gs.n || '@example.com',
            (ARRAY['Engineering','Marketing','Sales','HR','Finance','Operations','Legal','IT'])[floor(random()*8+1)::int],
            (ARRAY['Engineer','Manager','Analyst','Coordinator','Director','Lead','Associate','Specialist'])[floor(random()*8+1)::int],
            DATE '2010-01-01' + floor(random() * 3650)::int,
            (50000 + floor(random() * 100000))::numeric + (floor(random() * 100)::numeric / 100)
        FROM generate_series(1, ${rows}) AS gs(n);
PSQL_EOF

    log SUCCESS "Seeded ${rows} rows into ${DB_NAME}.employees."
}

# ---------------------------------------------------------------------------
# SECTION 14 – Sample-data row count helper
# ---------------------------------------------------------------------------

get_sample_data_rows() {
    if [[ "${SAMPLE_DATA_ROWS}" -gt 0 ]]; then
        echo "${SAMPLE_DATA_ROWS}"
        return
    fi

    if [[ "${NON_INTERACTIVE}" == "1" ]]; then
        # Default to 100 rows in non-interactive mode if not specified
        echo "100"
        return
    fi

    echo "" >&2
    echo "  How many sample rows would you like to seed into the database?" >&2
    echo "  Options: 10 | 100 | 500 | 1000 | 5000 | 10000  (or enter a custom number)" >&2
    echo "" >&2

    local rows=""
    while ! [[ "${rows}" =~ ^[0-9]+$ && "${rows}" -gt 0 ]]; do
        read -r -p "  Row count [default: 100]: " rows
        rows="${rows:-100}"
        if ! [[ "${rows}" =~ ^[0-9]+$ ]] || [[ "${rows}" -lt 1 ]]; then
            echo "  Please enter a positive integer." >&2
            rows=""
        fi
    done

    SAMPLE_DATA_ROWS="${rows}"
    echo "${rows}"
}

# ---------------------------------------------------------------------------
# SECTION 15 – Credentials file and final summary
# ---------------------------------------------------------------------------

initialise_credentials_file() {
    log INFO "Initialising credentials file: ${CREDS_FILE}"

    # The credentials file must be root-readable only
    install -m 600 /dev/null "${CREDS_FILE}"

    cat >> "${CREDS_FILE}" <<EOF
# =============================================================================
# Okta Privilege Access Setup – Generated Credentials
# Created   : $(date)
# Script    : ${SCRIPT_NAME} v${SCRIPT_VERSION}
# Log file  : ${LOG_FILE}
#
# IMPORTANT : This file contains sensitive credentials.
#             Restrict access, rotate passwords, and delete after use.
# =============================================================================

EOF
}

print_summary() {
    separator
    log SUCCESS "======================================================"
    log SUCCESS " Okta Privilege Access Setup Completed"
    log SUCCESS "======================================================"
    log INFO ""
    log INFO "  Log file       : ${LOG_FILE}"
    log INFO "  Credentials    : ${CREDS_FILE}"
    log INFO "  File perms     : 600 (root only)"
    log INFO ""

    [[ "${INSTALL_AGENT}"   == "1" ]] && log SUCCESS "  OPA Agent    : installed and configured"
    [[ "${INSTALL_GATEWAY}" == "1" ]] && log SUCCESS "  OPA Gateway  : installed and configured"
    [[ "${INSTALL_MYSQL}"   == "1" ]] && log SUCCESS "  MySQL        : installed, hardened, and seeded"
    [[ "${INSTALL_POSTGRESQL}" == "1" ]] && log SUCCESS "  PostgreSQL   : installed, hardened, and seeded"

    log INFO ""
    log INFO "  Credentials are stored in:"
    log INFO "  ${CREDS_FILE}"
    log INFO ""
    log INFO "  SECURITY REMINDER:"
    log INFO "    - Review and rotate all credentials."
    log INFO "    - Store the credentials file in a vault (e.g. HashiCorp Vault, AWS Secrets Manager)."
    log INFO "    - Remove the plaintext credentials file once stored securely."
    log INFO "    - Register the OPA Agent/Gateway in your Okta admin console:"
    log INFO "      https://help.okta.com/pam/en-us/"
    separator
}

# ---------------------------------------------------------------------------
# SECTION 16 – Root / privilege check
# ---------------------------------------------------------------------------

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "This script must be run as root.  Use: sudo bash ${SCRIPT_NAME}"
    fi
}

# ---------------------------------------------------------------------------
# SECTION 17 – Main execution
# ---------------------------------------------------------------------------

main() {
    # Parse CLI arguments first so flags affect all subsequent steps
    parse_args "$@"

    separator
    log INFO "Okta Privilege Access Setup Script v${SCRIPT_VERSION}"
    log INFO "Log file: ${LOG_FILE}"
    separator

    # Root check
    check_root

    # Initialise credentials file early so any subsequent save_credential calls work
    initialise_credentials_file

    # Step 1: Detect and validate the Linux distribution
    detect_distro

    # Step 2: Ensure the system is fully updated and has base dependencies
    update_system
    install_dependencies

    # Step 3: Check for already-installed components and handle user response
    check_already_installed

    # Step 4: Present install options if none were specified via CLI
    interactive_install_menu

    # Validate that at least one install target is selected
    if [[ "${INSTALL_AGENT}" == "0" && "${INSTALL_GATEWAY}" == "0" && \
          "${INSTALL_MYSQL}" == "0" && "${INSTALL_POSTGRESQL}" == "0" ]]; then
        log WARN "No install targets selected. Nothing to do."
        exit 0
    fi

    # Step 5: Install and configure selected components
    [[ "${INSTALL_AGENT}"      == "1" ]] && install_opa_agent
    [[ "${INSTALL_GATEWAY}"    == "1" ]] && install_opa_gateway
    [[ "${INSTALL_MYSQL}"      == "1" ]] && install_mysql
    [[ "${INSTALL_POSTGRESQL}" == "1" ]] && install_postgresql

    # Step 6: Print final summary and credentials location
    print_summary
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main "$@"
