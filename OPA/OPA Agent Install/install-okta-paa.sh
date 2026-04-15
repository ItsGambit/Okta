#!/usr/bin/env bash
# =============================================================================
# Okta Privileged Access Agent (PAA) - Installation & Configuration Script
# =============================================================================
#
# DESCRIPTION:
#   Installs and configures the Okta Privileged Access Agent (PAA) on supported
#   Linux distributions using the official Okta/ScaleFT package repositories.
#   The agent (sftd) enables Okta Privileged Access Management on the host,
#   allowing just-in-time SSH/RDP access under policy control.
#
#   On startup the script checks for an existing installation.  If the agent
#   is already present it stops the service, displays the installed version
#   and last-known status, then offers a menu:
#     [a] Exit       — leave the stopped service alone and quit
#     [b] Restart    — start the existing agent and quit
#     [c] Reinstall  — purge the agent and run a full fresh installation
#                      (a new or existing enrollment token is required)
#
#   Supports both interactive (prompts for enrollment token) and non-interactive
#   (token via --token flag) installation modes.
#
# SUPPORTED DISTRIBUTIONS:
#   - Ubuntu  16.04 (Xenial), 18.04 (Bionic), 20.04 (Focal),
#             22.04 (Jammy), 24.04 (Noble)
#   - Debian  10 (Buster), 11 (Bullseye), 12 (Bookworm)
#   - RHEL / CentOS / AlmaLinux / Rocky Linux  8, 9
#   - Amazon Linux  2, 2023
#
# USAGE:
#   Interactive (prompts for enrollment token):
#     sudo ./install-okta-paa.sh
#
#   Non-interactive (token supplied via flag):
#     sudo ./install-okta-paa.sh --token "<ENROLLMENT_TOKEN>"
#
# OPTIONS:
#   -t, --token TOKEN   Enrollment token (skips interactive prompt)
#   -v, --verbose       Enable verbose/debug output
#   -n, --dry-run       Show what would be done; make no changes
#   -h, --help          Print usage and exit
#
# REFERENCE:
#   https://help.okta.com/pam/en-us/content/topics/pam/paa/paa-overview.htm
#
# LOG FILE:
#   /var/log/okta-paa-install.log
# =============================================================================

set -euo pipefail

# =============================================================================
# CONSTANTS
# =============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="1.0.0"
readonly LOG_FILE="/var/log/okta-paa-install.log"

# Okta/ScaleFT package repository details
# The PAA shares the same upstream repository as other Okta PAM components.
readonly OKTA_GPG_KEY_URL="https://dist.scaleft.com/GPG-KEY-OktaPAM-2023"
readonly OKTA_DEB_REPO_BASE="https://dist.scaleft.com/repos/deb"
readonly OKTA_RPM_REPO_BASE="https://dist.scaleft.com/repos/rpm/stable"

# Package / service / path constants
readonly PACKAGE_NAME="scaleft-server-tools"
readonly SERVICE_NAME="sftd"
readonly CONFIG_DIR="/etc/sft"
readonly CONFIG_FILE="${CONFIG_DIR}/sftd.yaml"
readonly TOKEN_DIR="/var/lib/sftd"
readonly TOKEN_FILE="${TOKEN_DIR}/enrollment.token"

# APT-specific paths
readonly KEYRING_DIR="/usr/share/keyrings"
readonly KEYRING_FILE="${KEYRING_DIR}/oktapam-2023-archive-keyring.gpg"
readonly APT_SOURCES_FILE="/etc/apt/sources.list.d/oktapam-stable.list"

# RPM-specific path
readonly YUM_REPO_FILE="/etc/yum.repos.d/oktapam-stable.repo"

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_ERROR=1
readonly EXIT_NO_ROOT=3

# =============================================================================
# MUTABLE GLOBALS
# =============================================================================

ENROLLMENT_TOKEN=""
VERBOSE=false
DRY_RUN=false

# Populated by detect_distro()
DISTRO_ID=""
DISTRO_VERSION=""
DISTRO_CODENAME=""
PKG_MANAGER=""   # "apt" or "rpm"

# =============================================================================
# LOGGING
# =============================================================================

# Create or truncate the log file on startup (best-effort; silently ignores
# failures, e.g. when running non-root in dry-run mode)
_init_logging() {
    local log_dir
    log_dir="$(dirname "$LOG_FILE")"
    mkdir -p "$log_dir" 2>/dev/null || true
    : > "$LOG_FILE" 2>/dev/null || true
}

# Core logging — writes every message to the log file and routes to console
# based on level.
_log() {
    local level="$1"; shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local entry="[${timestamp}] [${level}] ${message}"

    # Always append to log file (suppress errors if the file is not writable)
    echo "$entry" >> "$LOG_FILE" 2>/dev/null || true

    case "$level" in
        ERROR|WARN)
            echo "$entry" >&2
            ;;
        DEBUG)
            [[ "$VERBOSE" == "true" ]] && echo "$entry" || true
            ;;
        *)
            # INFO, STEP — always shown on stdout
            echo "$entry"
            ;;
    esac
}

log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() { _log "ERROR" "$@"; }
log_debug() { _log "DEBUG" "$@"; }

# Print a clearly-visible section separator to both log and console
log_step() {
    echo ""
    _log "STEP" ">>> $*"
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

# ERR trap — fires whenever set -e would terminate the script due to an
# unhandled non-zero exit code.  Logs the offending line number.
_on_error() {
    log_error "Unexpected failure at line ${BASH_LINENO[0]} (exit code: $?)."
    log_error "See full log for details: ${LOG_FILE}"
}
trap '_on_error' ERR

# Print an error message and exit immediately with EXIT_ERROR
die() {
    log_error "$*"
    exit "$EXIT_ERROR"
}

# =============================================================================
# USAGE
# =============================================================================

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

Installs and configures the Okta Privileged Access Agent (PAA) on supported
Linux distributions.

USAGE:
    sudo ${SCRIPT_NAME} [OPTIONS]

OPTIONS:
    -t, --token TOKEN   Enrollment token (non-interactive mode)
    -v, --verbose       Enable verbose/debug output
    -n, --dry-run       Simulate all steps without making any system changes
    -h, --help          Show this help message and exit

EXAMPLES:
    # Interactive — script prompts for the enrollment token:
    sudo ./${SCRIPT_NAME}

    # Non-interactive — token supplied directly (CI/CD, automation):
    sudo ./${SCRIPT_NAME} --token "YOUR_ENROLLMENT_TOKEN_HERE"

    # Verbose + non-interactive:
    sudo ./${SCRIPT_NAME} --token "YOUR_ENROLLMENT_TOKEN_HERE" --verbose

    # Dry-run — preview every step without changing anything:
    sudo ./${SCRIPT_NAME} --token "placeholder" --dry-run

    # Display this help:
    ./${SCRIPT_NAME} --help

NOTES:
    - Must be run as root or via sudo.
    - Obtain an enrollment token from the Okta PAM console:
        Resources > Servers > Enroll Server
    - Full install log is written to: ${LOG_FILE}

SUPPORTED DISTRIBUTIONS:
    Ubuntu      : 16.04 (xenial), 18.04 (bionic), 20.04 (focal),
                  22.04 (jammy), 24.04 (noble)
    Debian      : 10 (buster), 11 (bullseye), 12 (bookworm)
    RHEL        : 8, 9
    AlmaLinux   : 8, 9
    Rocky Linux : 8, 9
    Amazon Linux: 2, 2023
EOF
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--token)
                [[ -z "${2:-}" ]] && die "Option '$1' requires a non-empty argument."
                ENROLLMENT_TOKEN="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                usage
                exit "$EXIT_SUCCESS"
                ;;
            --)
                shift
                break
                ;;
            -*)
                die "Unknown option: '$1'. Use --help for usage."
                ;;
            *)
                die "Unexpected argument: '$1'. Use --help for usage."
                ;;
        esac
    done
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

check_root() {
    log_step "Checking for root privileges"
    if [[ "$EUID" -ne 0 ]]; then
        log_error "This script must be run as root or with sudo."
        log_error "  Example: sudo ./${SCRIPT_NAME}"
        exit "$EXIT_NO_ROOT"
    fi
    log_info "Running as root: OK"
}

# Verify that curl and gpg are present; install them if missing.
check_dependencies() {
    log_step "Checking required dependencies"
    local missing=()

    for dep in curl gpg; do
        if command -v "$dep" &>/dev/null; then
            log_debug "Dependency found: ${dep} ($(command -v "$dep"))"
        else
            log_warn "Required dependency not found: ${dep}"
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_info "All required dependencies are present."
        return
    fi

    log_info "Attempting to install missing dependencies: ${missing[*]}"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install: ${missing[*]}"
        return
    fi

    if command -v apt-get &>/dev/null; then
        apt-get install -y "${missing[@]}" >> "$LOG_FILE" 2>&1 \
            || die "Failed to install dependencies: ${missing[*]}. See: ${LOG_FILE}"
    elif command -v dnf &>/dev/null; then
        dnf install -y "${missing[@]}" >> "$LOG_FILE" 2>&1 \
            || die "Failed to install dependencies: ${missing[*]}. See: ${LOG_FILE}"
    elif command -v yum &>/dev/null; then
        yum install -y "${missing[@]}" >> "$LOG_FILE" 2>&1 \
            || die "Failed to install dependencies: ${missing[*]}. See: ${LOG_FILE}"
    else
        die "No supported package manager found to install: ${missing[*]}"
    fi

    log_info "Dependencies installed: ${missing[*]}"
}

# =============================================================================
# DISTRIBUTION DETECTION
# =============================================================================

detect_distro() {
    log_step "Detecting Linux distribution"

    [[ -f /etc/os-release ]] || die "/etc/os-release not found. Cannot determine OS."

    # Source /etc/os-release to obtain ID, VERSION_ID, VERSION_CODENAME, etc.
    # shellcheck disable=SC1091
    source /etc/os-release

    # Normalise to lowercase for case-insensitive comparisons below
    DISTRO_ID="${ID,,}"
    DISTRO_VERSION="${VERSION_ID:-}"
    DISTRO_CODENAME="${VERSION_CODENAME:-}"

    log_info "Detected: ID=${DISTRO_ID}  VERSION_ID=${DISTRO_VERSION}  CODENAME=${DISTRO_CODENAME}"

    case "$DISTRO_ID" in

        # ------------------------------------------------------------------
        # Ubuntu  (apt)
        # ------------------------------------------------------------------
        ubuntu)
            PKG_MANAGER="apt"

            # Fall back to lsb_release if VERSION_CODENAME is absent
            if [[ -z "$DISTRO_CODENAME" ]]; then
                if command -v lsb_release &>/dev/null; then
                    DISTRO_CODENAME="$(lsb_release -cs)"
                    log_debug "Codename resolved via lsb_release: ${DISTRO_CODENAME}"
                else
                    die "Cannot determine Ubuntu codename. Install lsb-release and retry."
                fi
            fi

            case "$DISTRO_CODENAME" in
                xenial|bionic|focal|jammy|noble)
                    log_info "Supported Ubuntu release: ${DISTRO_CODENAME}"
                    ;;
                *)
                    die "Unsupported Ubuntu codename '${DISTRO_CODENAME}'. " \
                        "Supported: xenial (16.04), bionic (18.04), focal (20.04), " \
                        "jammy (22.04), noble (24.04)."
                    ;;
            esac
            ;;

        # ------------------------------------------------------------------
        # Debian  (apt)
        # ------------------------------------------------------------------
        debian)
            PKG_MANAGER="apt"

            # Map version number → codename when VERSION_CODENAME is absent
            if [[ -z "$DISTRO_CODENAME" ]]; then
                case "$DISTRO_VERSION" in
                    10) DISTRO_CODENAME="buster"   ;;
                    11) DISTRO_CODENAME="bullseye" ;;
                    12) DISTRO_CODENAME="bookworm" ;;
                    *)
                        die "Unsupported Debian version '${DISTRO_VERSION}'. " \
                            "Supported: 10 (buster), 11 (bullseye), 12 (bookworm)."
                        ;;
                esac
                log_debug "Debian codename resolved from version: ${DISTRO_CODENAME}"
            fi

            case "$DISTRO_CODENAME" in
                buster|bullseye|bookworm)
                    log_info "Supported Debian release: ${DISTRO_CODENAME}"
                    ;;
                *)
                    die "Unsupported Debian codename '${DISTRO_CODENAME}'. " \
                        "Supported: buster (10), bullseye (11), bookworm (12)."
                    ;;
            esac
            ;;

        # ------------------------------------------------------------------
        # RHEL-family  (rpm)
        # ------------------------------------------------------------------
        rhel|centos|almalinux|rocky)
            PKG_MANAGER="rpm"

            # Keep only the major version number (e.g. "8.7" → "8")
            DISTRO_VERSION="${DISTRO_VERSION%%.*}"

            case "$DISTRO_VERSION" in
                8|9)
                    log_info "Supported RHEL-compatible release: ${DISTRO_ID} ${DISTRO_VERSION}"
                    ;;
                *)
                    die "Unsupported ${DISTRO_ID} version '${DISTRO_VERSION}'. Supported: 8, 9."
                    ;;
            esac
            ;;

        # ------------------------------------------------------------------
        # Amazon Linux  (rpm)
        # ------------------------------------------------------------------
        amzn)
            PKG_MANAGER="rpm"

            case "$DISTRO_VERSION" in
                2|2023)
                    log_info "Supported Amazon Linux release: ${DISTRO_VERSION}"
                    ;;
                *)
                    die "Unsupported Amazon Linux version '${DISTRO_VERSION}'. Supported: 2, 2023."
                    ;;
            esac
            ;;

        *)
            die "Unsupported distribution: '${DISTRO_ID}'. " \
                "Supported: ubuntu, debian, rhel, centos, almalinux, rocky, amzn."
            ;;
    esac

    log_info "Package manager: ${PKG_MANAGER}"
}

# =============================================================================
# REPOSITORY SETUP
# =============================================================================

# Add the official Okta APT repository for Debian / Ubuntu
setup_apt_repo() {
    log_step "Configuring Okta APT repository"

    log_info "Importing Okta GPG signing key: ${OKTA_GPG_KEY_URL}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would import GPG key    → ${KEYRING_FILE}"
        log_info "[DRY RUN] Would write APT sources → ${APT_SOURCES_FILE}"
        log_info "[DRY RUN] Would run: apt-get update"
        return
    fi

    # Create the keyring directory if it doesn't already exist
    mkdir -p "$KEYRING_DIR"

    # Download the ASCII-armored key, convert to binary (--dearmor), and save
    curl -fsSL "$OKTA_GPG_KEY_URL" \
        | gpg --dearmor \
        | tee "$KEYRING_FILE" > /dev/null \
        || die "Failed to import Okta GPG key. Check connectivity to: ${OKTA_GPG_KEY_URL}"

    log_info "GPG key saved: ${KEYRING_FILE}"

    # Write a signed APT source entry for this distribution's codename
    local repo_line="deb [signed-by=${KEYRING_FILE}] ${OKTA_DEB_REPO_BASE} ${DISTRO_CODENAME} okta"
    echo "$repo_line" | tee "$APT_SOURCES_FILE" > /dev/null \
        || die "Failed to write APT sources file: ${APT_SOURCES_FILE}"

    log_info "APT repository configured: ${APT_SOURCES_FILE}"
    log_debug "Repo entry: ${repo_line}"

    log_info "Refreshing APT package index..."
    apt-get update >> "$LOG_FILE" 2>&1 \
        || die "apt-get update failed. Check connectivity and review: ${LOG_FILE}"

    log_info "APT index refreshed."
}

# Add the official Okta YUM/DNF repository for RHEL-family and Amazon Linux
setup_rpm_repo() {
    log_step "Configuring Okta RPM repository"

    # Determine the correct OS subdirectory in the Okta repository tree
    local repo_os_path
    if [[ "$DISTRO_ID" == "amzn" ]]; then
        repo_os_path="amazonlinux/${DISTRO_VERSION}"
    else
        # RHEL, CentOS, AlmaLinux, Rocky — all share the 'rhel' path
        repo_os_path="rhel/${DISTRO_VERSION}"
    fi

    # Store a literal "$basearch" in the variable (escaped with \$) so that
    # yum/dnf can expand it at runtime to the actual architecture
    # (e.g. x86_64, aarch64).
    local baseurl="${OKTA_RPM_REPO_BASE}/${repo_os_path}/\$basearch/"
    log_debug "Repo baseurl: ${baseurl}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run: rpm --import ${OKTA_GPG_KEY_URL}"
        log_info "[DRY RUN] Would write repo file: ${YUM_REPO_FILE}"
        log_info "[DRY RUN] Baseurl: ${baseurl}"
        return
    fi

    log_info "Importing Okta GPG key via rpm: ${OKTA_GPG_KEY_URL}"
    rpm --import "$OKTA_GPG_KEY_URL" \
        || die "Failed to import Okta GPG key. Check connectivity to: ${OKTA_GPG_KEY_URL}"
    log_info "GPG key imported."

    log_info "Writing RPM repository file: ${YUM_REPO_FILE}"
    # Note: \$basearch in the heredoc (unquoted delimiter REPO) is intentionally
    # escaped so the literal string "$basearch" appears in the repo file for
    # yum/dnf to resolve at install time.
    cat > "$YUM_REPO_FILE" <<REPO
[oktapam-stable]
name=Okta Privileged Access Management (Stable) - \$basearch
baseurl=${baseurl}
gpgcheck=1
gpgkey=${OKTA_GPG_KEY_URL}
enabled=1
REPO

    log_info "RPM repository file created: ${YUM_REPO_FILE}"
}

# =============================================================================
# PACKAGE INSTALLATION
# =============================================================================

install_package() {
    log_step "Installing package: ${PACKAGE_NAME}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install: ${PACKAGE_NAME}"
        return
    fi

    case "$PKG_MANAGER" in
        apt)
            log_info "Running: DEBIAN_FRONTEND=noninteractive apt-get install -y ${PACKAGE_NAME}"
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$PACKAGE_NAME" >> "$LOG_FILE" 2>&1 \
                || die "apt-get install failed for '${PACKAGE_NAME}'. See: ${LOG_FILE}"
            ;;
        rpm)
            if command -v dnf &>/dev/null; then
                log_info "Running: dnf install -y ${PACKAGE_NAME}"
                dnf install -y "$PACKAGE_NAME" >> "$LOG_FILE" 2>&1 \
                    || die "dnf install failed for '${PACKAGE_NAME}'. See: ${LOG_FILE}"
            elif command -v yum &>/dev/null; then
                log_info "Running: yum install -y ${PACKAGE_NAME}"
                yum install -y "$PACKAGE_NAME" >> "$LOG_FILE" 2>&1 \
                    || die "yum install failed for '${PACKAGE_NAME}'. See: ${LOG_FILE}"
            else
                die "Neither dnf nor yum was found. Cannot install the package."
            fi
            ;;
        *)
            die "Unknown package manager: '${PKG_MANAGER}'"
            ;;
    esac

    log_info "Package installed successfully: ${PACKAGE_NAME}"
}

# =============================================================================
# ENROLLMENT TOKEN
# =============================================================================

# Interactively prompt for the enrollment token if one was not provided via
# the --token flag.
prompt_for_token() {
    # Skip the prompt when --token was supplied or when in dry-run mode
    if [[ -n "$ENROLLMENT_TOKEN" ]]; then
        log_info "Enrollment token provided via command-line flag (prompt skipped)."
        return
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would prompt for enrollment token; using placeholder."
        ENROLLMENT_TOKEN="DRY_RUN_PLACEHOLDER"
        return
    fi

    log_step "Enrollment token required"
    echo ""
    echo "================================================================="
    echo "  Okta PAA Enrollment Token"
    echo "================================================================="
    echo ""
    echo "  Obtain the enrollment token from the Okta PAM console:"
    echo "    1. Log in to the Okta Admin Console."
    echo "    2. Navigate to:  Resources  >  Servers"
    echo "    3. Click 'Enroll Server' and copy the enrollment token."
    echo ""
    echo "================================================================="

    while true; do
        # -r = raw input  -s = silent (characters not echoed) for security
        read -rsp "  Paste enrollment token: " ENROLLMENT_TOKEN
        echo ""   # Newline after the hidden-input line

        if [[ -z "$ENROLLMENT_TOKEN" ]]; then
            echo "  [ERROR] Token cannot be empty. Please try again."
        else
            # Mask the token for on-screen confirmation
            # Show the first 4 and last 4 characters; asterisk-fill the middle.
            local token_len="${#ENROLLMENT_TOKEN}"
            local masked
            if [[ "$token_len" -gt 8 ]]; then
                local stars
                stars="$(printf '*%.0s' $(seq 1 $((token_len - 8))))"
                masked="${ENROLLMENT_TOKEN:0:4}${stars}${ENROLLMENT_TOKEN: -4}"
            else
                masked="$(printf '*%.0s' $(seq 1 "$token_len"))"
            fi
            echo "  Token received (masked): ${masked}"
            log_info "Enrollment token received interactively (value not stored in log)."
            break
        fi
    done
}

# Write the enrollment token to the token file and secure its permissions.
configure_enrollment_token() {
    log_step "Writing enrollment token to disk"

    [[ -n "$ENROLLMENT_TOKEN" ]] || die "Enrollment token is empty; cannot configure agent."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create token directory : ${TOKEN_DIR}"
        log_info "[DRY RUN] Would write token to         : ${TOKEN_FILE}"
        log_info "[DRY RUN] Would set permissions 600    : ${TOKEN_FILE}"
        return
    fi

    # The package typically creates /var/lib/sftd at install time; create it
    # here as a safety net in case it is absent.
    if [[ ! -d "$TOKEN_DIR" ]]; then
        log_info "Creating token directory: ${TOKEN_DIR}"
        mkdir -p "$TOKEN_DIR" \
            || die "Failed to create directory: ${TOKEN_DIR}"
    fi

    # Write the token using printf to avoid appending a trailing newline, which
    # could cause the agent to reject the token.
    log_info "Writing enrollment token: ${TOKEN_FILE}"
    printf '%s' "$ENROLLMENT_TOKEN" > "$TOKEN_FILE" \
        || die "Failed to write token file: ${TOKEN_FILE}"

    # Restrict access — only root should be able to read or write the token file.
    # The sftd daemon runs as root, so 600 is correct and sufficient.
    chmod 600 "$TOKEN_FILE" \
        || die "Failed to set permissions on: ${TOKEN_FILE}"

    log_info "Enrollment token written and secured (permissions 600): ${TOKEN_FILE}"
    log_info "Note: sftd deletes this file automatically after successful enrollment."
}

# =============================================================================
# AGENT CONFIGURATION FILE
# =============================================================================

configure_agent() {
    log_step "Configuring agent"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would ensure config directory: ${CONFIG_DIR}"
        log_info "[DRY RUN] Would write minimal config   : ${CONFIG_FILE}"
        return
    fi

    mkdir -p "$CONFIG_DIR" \
        || die "Failed to create config directory: ${CONFIG_DIR}"

    # Do not overwrite an existing config file — the admin may have customised it.
    if [[ -f "$CONFIG_FILE" ]]; then
        log_warn "Config file already exists: ${CONFIG_FILE}"
        log_warn "Skipping config generation to preserve existing settings."
        log_warn "Ensure the file contains:  EnrollmentTokenFile: ${TOKEN_FILE}"
        return
    fi

    log_info "Writing minimal agent configuration: ${CONFIG_FILE}"

    # Write a minimal config. The only setting required for initial enrollment
    # is EnrollmentTokenFile — sftd reads this path on startup, enrolls itself,
    # and then deletes the token file.
    cat > "$CONFIG_FILE" <<EOF
# =============================================================================
# Okta Privileged Access Agent (PAA) - Configuration File
# Generated by : ${SCRIPT_NAME} v${SCRIPT_VERSION}
# Generated at : $(date '+%Y-%m-%d %H:%M:%S')
#
# For the full list of configuration keys see the sample file installed at:
#   ${CONFIG_DIR}/sftd.sample.yaml   (if present)
#
# Reference:
#   https://help.okta.com/pam/en-us/content/topics/pam/paa/paa-overview.htm
# =============================================================================

# Path to the file containing the one-time enrollment token.
# sftd reads this file on first startup, enrolls the server with Okta PAM,
# and then removes the file automatically upon successful enrollment.
EnrollmentTokenFile: ${TOKEN_FILE}

# Log verbosity for the sftd daemon.
# Options: trace | debug | info | warn | error
LogLevel: info
EOF

    # Owner root, readable only by root (the daemon runs as root)
    chmod 600 "$CONFIG_FILE" \
        || die "Failed to set permissions on config file: ${CONFIG_FILE}"

    log_info "Config file created: ${CONFIG_FILE}"
}

# =============================================================================
# SERVICE MANAGEMENT
# =============================================================================

enable_and_start_service() {
    log_step "Enabling and starting service: ${SERVICE_NAME}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run: systemctl daemon-reload"
        log_info "[DRY RUN] Would run: systemctl enable ${SERVICE_NAME}"
        log_info "[DRY RUN] Would run: systemctl start  ${SERVICE_NAME}"
        return
    fi

    command -v systemctl &>/dev/null \
        || die "systemctl not found. This script requires a systemd-based Linux system."

    log_info "Reloading systemd unit files..."
    systemctl daemon-reload >> "$LOG_FILE" 2>&1 \
        || log_warn "systemctl daemon-reload returned non-zero (may be non-fatal)."

    log_info "Enabling ${SERVICE_NAME} to start automatically on boot..."
    systemctl enable "$SERVICE_NAME" >> "$LOG_FILE" 2>&1 \
        || die "systemctl enable failed for '${SERVICE_NAME}'. See: ${LOG_FILE}"

    log_info "Starting ${SERVICE_NAME}..."
    systemctl start "$SERVICE_NAME" >> "$LOG_FILE" 2>&1 \
        || die "systemctl start failed for '${SERVICE_NAME}'. " \
               "Run: systemctl status ${SERVICE_NAME}"

    log_info "Service started: ${SERVICE_NAME}"
}

# =============================================================================
# POST-INSTALL VERIFICATION
# =============================================================================

verify_installation() {
    log_step "Verifying installation"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would check: systemctl is-active ${SERVICE_NAME}"
        log_info "[DRY RUN] Would check for token file removal and config file presence."
        return
    fi

    # Allow the daemon a moment to start and attempt enrollment before querying
    sleep 3

    # --- Service status ---
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_info "Service is RUNNING: ${SERVICE_NAME}"
    else
        log_warn "Service is NOT currently active: ${SERVICE_NAME}"
        log_warn "Capturing service status into the log file..."
        systemctl status "$SERVICE_NAME" --no-pager >> "$LOG_FILE" 2>&1 || true
        log_warn "Diagnostics commands:"
        log_warn "  systemctl status ${SERVICE_NAME}"
        log_warn "  journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
        log_warn "  cat ${LOG_FILE}"
        # Not calling die() — enrollment may be in progress; let the admin
        # check the service status after the script finishes.
    fi

    # --- Enrollment token file ---
    # A missing token file confirms the agent has completed enrollment.
    if [[ -f "$TOKEN_FILE" ]]; then
        log_info "Enrollment token file still present: ${TOKEN_FILE}"
        log_info "  The agent may still be enrolling or awaiting Okta connectivity."
        log_info "  sftd removes this file automatically once enrollment succeeds."
    else
        log_info "Enrollment token file removed — server enrolled successfully."
    fi

    # --- Config file ---
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "Config file present: ${CONFIG_FILE}"
    else
        log_warn "Config file not found: ${CONFIG_FILE}"
    fi

    # --- Installed package version ---
    log_info "Installed package version:"
    case "$PKG_MANAGER" in
        apt)
            dpkg -l "$PACKAGE_NAME" 2>/dev/null | grep -E "^ii" \
                | tee -a "$LOG_FILE" \
                || log_warn "Could not query package version via dpkg."
            ;;
        rpm)
            rpm -q "$PACKAGE_NAME" 2>/dev/null \
                | tee -a "$LOG_FILE" \
                || log_warn "Could not query package version via rpm."
            ;;
    esac
}

# =============================================================================
# SUMMARY
# =============================================================================

print_summary() {
    echo ""
    echo "================================================================="
    echo "  Okta PAA Installation Complete"
    echo "================================================================="
    echo "  Package     : ${PACKAGE_NAME}"
    echo "  Service     : ${SERVICE_NAME}"
    echo "  Config file : ${CONFIG_FILE}"
    echo "  Token file  : ${TOKEN_FILE}  (removed after enrollment)"
    echo "  Install log : ${LOG_FILE}"
    echo ""
    echo "  Useful commands:"
    echo "    Service status  :  systemctl status ${SERVICE_NAME}"
    echo "    Service logs    :  journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
    echo "    Install log     :  cat ${LOG_FILE}"
    echo "    Restart service :  systemctl restart ${SERVICE_NAME}"
    echo "================================================================="
    echo ""
    log_info "Installation summary printed."
}

# =============================================================================
# EXISTING INSTALLATION MANAGEMENT
# =============================================================================

# Return 0 (true) when the PAA package is currently installed, 1 otherwise.
# Uses PKG_MANAGER set by detect_distro().
_is_package_installed() {
    case "$PKG_MANAGER" in
        apt)
            dpkg -l "$PACKAGE_NAME" 2>/dev/null | grep -qE "^ii"
            ;;
        rpm)
            rpm -q "$PACKAGE_NAME" &>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

# Print the installed package version to stdout.
_get_installed_version() {
    local version=""
    case "$PKG_MANAGER" in
        apt)
            version="$(dpkg -l "$PACKAGE_NAME" 2>/dev/null \
                | awk '/^ii/ {print $3}' \
                | head -1)"
            ;;
        rpm)
            version="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' \
                "$PACKAGE_NAME" 2>/dev/null || true)"
            ;;
    esac
    echo "${version:-unknown}"
}

# Start the already-installed agent, display the new service status, and exit.
# Called when the user selects option [b] from the management menu.
_restart_existing_service() {
    log_step "Restarting service: ${SERVICE_NAME}"

    systemctl start "$SERVICE_NAME" >> "$LOG_FILE" 2>&1 \
        || die "Failed to start ${SERVICE_NAME}. Check: systemctl status ${SERVICE_NAME}"

    # Brief pause to let the service settle into a stable state
    sleep 2

    local new_status
    new_status="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "inactive")"

    log_info "Service restart complete. Status: ${new_status}"

    echo ""
    echo "================================================================="
    echo "  Restart Complete"
    echo "================================================================="
    printf "  Service  :  %s\n" "$SERVICE_NAME"
    printf "  Status   :  %s\n" "$new_status"
    echo ""
    echo "  Useful commands:"
    echo "    Check status  :  systemctl status ${SERVICE_NAME}"
    echo "    View logs     :  journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
    echo "================================================================="
    echo ""
}

# Ask the user to type 'yes' before proceeding with the destructive reinstall.
# Returns 0 when confirmed, 1 when cancelled (so callers can use 'if').
_confirm_reinstall() {
    echo ""
    echo "================================================================="
    echo "  !! WARNING — Uninstall and Reinstall"
    echo "================================================================="
    echo ""
    echo "  This action will:"
    echo "    • Stop and completely remove the ${PACKAGE_NAME} package"
    echo "    • Delete the agent configuration file  (${CONFIG_FILE})"
    echo "    • Remove any pending token file        (${TOKEN_FILE})"
    echo "    • De-enroll this server from Okta Privileged Access"
    echo ""
    echo "  An enrollment token is required to re-enroll this server."
    echo "  You may use:"
    echo "    • A NEW token generated from the Okta PAM console, OR"
    echo "    • An EXISTING unused token previously issued for this server"
    echo ""
    echo "  Where to get a token:"
    echo "    Okta PAM console → Resources → Servers → Enroll Server"
    echo ""
    echo "================================================================="

    while true; do
        read -rp "  Type 'yes' to confirm reinstall, or 'no' to cancel: " confirm
        case "${confirm,,}" in
            yes)
                log_info "User confirmed reinstall."
                return 0
                ;;
            no)
                log_info "User cancelled reinstall."
                echo ""
                echo "  Reinstall cancelled. Returning to menu."
                return 1
                ;;
            *)
                echo "  Please type 'yes' to confirm or 'no' to cancel."
                ;;
        esac
    done
}

# Display the management menu and act on the user's choice.
#   [a] Exit       — quit the script (service remains stopped)
#   [b] Restart    — start the service and quit
#   [c] Reinstall  — confirm, then uninstall; returns 0 so caller continues
#                    with the full fresh-install flow
_show_existing_install_menu() {
    while true; do
        echo ""
        echo "  What would you like to do?"
        echo ""
        echo "    [a]  Exit the script"
        echo "         (the ${SERVICE_NAME} service will remain stopped)"
        echo ""
        echo "    [b]  Restart the agent"
        echo "         (start ${SERVICE_NAME} and exit)"
        echo ""
        echo "    [c]  Uninstall and reinstall"
        echo "         !! Requires a new or existing enrollment token"
        echo "            from the Okta PAM console (Resources > Servers)"
        echo ""
        read -rp "  Enter choice [a/b/c]: " menu_choice

        case "${menu_choice,,}" in
            a)
                log_info "User chose: exit."
                echo ""
                echo "  Exiting. The ${SERVICE_NAME} service remains stopped."
                echo "  To restart it manually:  systemctl start ${SERVICE_NAME}"
                echo ""
                exit "$EXIT_SUCCESS"
                ;;
            b)
                log_info "User chose: restart agent."
                _restart_existing_service
                exit "$EXIT_SUCCESS"
                ;;
            c)
                log_info "User chose: uninstall and reinstall."
                # Use 'if' so set -e does not trap the non-zero return from
                # _confirm_reinstall when the user types 'no'.
                if _confirm_reinstall; then
                    return 0   # Caller should proceed with the reinstall flow
                fi
                # User typed 'no' — loop and show the menu again
                ;;
            *)
                echo "  Invalid choice '${menu_choice}'. Please enter a, b, or c."
                log_debug "Invalid menu input received: '${menu_choice}'"
                ;;
        esac
    done
}

# Remove the package and clean up files in preparation for a clean reinstall.
uninstall_package() {
    log_step "Uninstalling ${PACKAGE_NAME}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would stop and disable : ${SERVICE_NAME}"
        log_info "[DRY RUN] Would purge package    : ${PACKAGE_NAME}"
        log_info "[DRY RUN] Would remove config    : ${CONFIG_FILE}"
        log_info "[DRY RUN] Would remove token     : ${TOKEN_FILE} (if present)"
        return
    fi

    # Stop the service (may already be stopped; || true prevents set -e exit)
    log_info "Stopping service: ${SERVICE_NAME}"
    systemctl stop "$SERVICE_NAME" >> "$LOG_FILE" 2>&1 || true

    # Disable so it does not start again if the purge is interrupted
    log_info "Disabling service: ${SERVICE_NAME}"
    systemctl disable "$SERVICE_NAME" >> "$LOG_FILE" 2>&1 || true

    # Remove the package
    case "$PKG_MANAGER" in
        apt)
            log_info "Purging package via apt-get: ${PACKAGE_NAME}"
            DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y "$PACKAGE_NAME" \
                >> "$LOG_FILE" 2>&1 \
                || die "apt-get remove --purge failed for '${PACKAGE_NAME}'. See: ${LOG_FILE}"
            ;;
        rpm)
            if command -v dnf &>/dev/null; then
                log_info "Removing package via dnf: ${PACKAGE_NAME}"
                dnf remove -y "$PACKAGE_NAME" >> "$LOG_FILE" 2>&1 \
                    || die "dnf remove failed for '${PACKAGE_NAME}'. See: ${LOG_FILE}"
            else
                log_info "Removing package via yum: ${PACKAGE_NAME}"
                yum remove -y "$PACKAGE_NAME" >> "$LOG_FILE" 2>&1 \
                    || die "yum remove failed for '${PACKAGE_NAME}'. See: ${LOG_FILE}"
            fi
            ;;
        *)
            die "Unknown package manager: '${PKG_MANAGER}'"
            ;;
    esac

    log_info "Package removed: ${PACKAGE_NAME}"

    # Remove configuration and token files that the package manager's own purge
    # step may not clean up (they live outside the package's declared file list).
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "Removing configuration file: ${CONFIG_FILE}"
        rm -f "$CONFIG_FILE" \
            || log_warn "Could not remove config file: ${CONFIG_FILE}"
    fi

    if [[ -f "$TOKEN_FILE" ]]; then
        log_info "Removing stale token file: ${TOKEN_FILE}"
        rm -f "$TOKEN_FILE" \
            || log_warn "Could not remove token file: ${TOKEN_FILE}"
    fi

    log_info "Uninstall complete."
    echo ""
    echo "  Package removed. Proceeding with fresh installation..."
    echo ""
}

# Top-level check run early in main().
# If the PAA is NOT installed → returns immediately (proceed with fresh install).
# If the PAA IS installed    → stops the service, reports version and status,
#                              then presents the management menu.
#   Menu option [a] or [b] will exit the script directly from inside this function.
#   Menu option [c] will call uninstall_package() and then return 0, allowing
#   the caller to continue with the full installation flow.
check_existing_installation() {
    log_step "Checking for existing installation"

    # No package found — nothing to do here
    if ! _is_package_installed; then
        log_info "No existing ${PACKAGE_NAME} installation found. Proceeding with fresh install."
        return 0
    fi

    # -------------------------------------------------------------------------
    # Package is installed — gather information before touching anything
    # -------------------------------------------------------------------------
    local installed_version
    installed_version="$(_get_installed_version)"

    # Capture the pre-stop service state for the display panel
    local svc_active svc_sub svc_display
    svc_active="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "inactive")"
    svc_sub="$(systemctl show -p SubState --value "$SERVICE_NAME" 2>/dev/null || echo "")"

    # Build a readable "active (running)" or "inactive (dead)" style string
    if [[ -n "$svc_sub" && "$svc_sub" != "$svc_active" ]]; then
        svc_display="${svc_active} (${svc_sub})"
    else
        svc_display="${svc_active}"
    fi

    log_info "Existing installation detected."
    log_info "  Installed version : ${installed_version}"
    log_info "  Service status    : ${svc_display}"

    # Stop the service now, before any further action
    log_info "Stopping ${SERVICE_NAME} before proceeding..."
    if [[ "$DRY_RUN" == "false" ]]; then
        systemctl stop "$SERVICE_NAME" >> "$LOG_FILE" 2>&1 || true
        log_info "Service stopped."
    fi

    # -------------------------------------------------------------------------
    # Display the existing-installation summary panel
    # -------------------------------------------------------------------------
    echo ""
    echo "================================================================="
    echo "  Okta Privileged Access Agent — Already Installed"
    echo "================================================================="
    printf "  Installed version : %s\n" "$installed_version"
    printf "  Service status    : %s\n" "$svc_display"
    echo "  (service has been stopped)"
    echo "================================================================="

    # -------------------------------------------------------------------------
    # Handle non-interactive / dry-run cases without blocking on stdin
    # -------------------------------------------------------------------------
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would present management menu [a/b/c]."
        log_info "[DRY RUN] Continuing install simulation."
        return 0
    fi

    # If stdin is not a terminal (piped/automated run) we cannot show an
    # interactive menu — exit cleanly rather than hanging indefinitely.
    if [[ ! -t 0 ]]; then
        log_warn "Non-interactive session detected; cannot display management menu."
        log_warn "Exiting without changes. Run the script in an interactive terminal"
        log_warn "to restart, reinstall, or otherwise manage the existing installation."
        exit "$EXIT_SUCCESS"
    fi

    # -------------------------------------------------------------------------
    # Show the interactive management menu
    # -------------------------------------------------------------------------
    # Returns 0 when the user chooses [c] and confirms reinstall.
    # Options [a] and [b] call exit() directly, so we only return here for [c].
    _show_existing_install_menu

    # User chose [c] and confirmed — run the uninstall before the install flow
    uninstall_package
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    _init_logging

    log_info "========================================================"
    log_info " ${SCRIPT_NAME} v${SCRIPT_VERSION}"
    log_info " Started: $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "========================================================"

    parse_args "$@"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY-RUN MODE ENABLED — no changes will be made to this system."
    fi

    # 1. Verify the script is running as root
    check_root

    # 2. Ensure curl and gpg are available (install if missing)
    check_dependencies

    # 3. Detect the Linux distribution and choose the package manager
    detect_distro

    # 4. Check for an existing agent installation.
    #    If found: stops the service, shows version + status, presents menu.
    #    Exits here if user chooses [a] exit or [b] restart.
    #    Uninstalls and falls through if user chooses [c] reinstall.
    #    Returns immediately (no-op) if the agent is not installed.
    check_existing_installation

    # 5. Add the official Okta package repository and GPG key
    case "$PKG_MANAGER" in
        apt) setup_apt_repo ;;
        rpm) setup_rpm_repo ;;
        *)   die "Unsupported package manager: '${PKG_MANAGER}'" ;;
    esac

    # 6. Install the scaleft-server-tools package
    install_package

    # 7. Obtain the enrollment token (interactively or from --token flag)
    prompt_for_token

    # 8. Write the enrollment token to disk at the expected path
    configure_enrollment_token

    # 9. Create a minimal /etc/sft/sftd.yaml configuration file
    configure_agent

    # 10. Enable and start the sftd systemd service
    enable_and_start_service

    # 11. Run post-install checks and report status
    verify_installation

    # 12. Print a human-readable summary with useful commands
    print_summary

    log_info "${SCRIPT_NAME} finished successfully."
    exit "$EXIT_SUCCESS"
}

main "$@"
