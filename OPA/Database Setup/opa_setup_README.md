# Okta Privilege Access (OPA) Setup Script

**Version:** 1.1.1
**Script:** `opa_setup.sh`

---

## Table of Contents

1. [Overview](#overview)
2. [What This Script Does](#what-this-script-does)
3. [Supported Linux Distributions](#supported-linux-distributions)
4. [Prerequisites](#prerequisites)
5. [Downloading the Script](#downloading-the-script)
6. [Quick Start](#quick-start)
7. [Interactive Mode (Default)](#interactive-mode-default)
8. [Non-Interactive Mode (Automation / CI)](#non-interactive-mode-automation--ci)
9. [All CLI Options](#all-cli-options)
10. [Environment Variables](#environment-variables)
11. [Component Details](#component-details)
    - [Okta Privilege Access Agent](#okta-privilege-access-agent)
    - [Okta Privilege Access Gateway](#okta-privilege-access-gateway)
    - [MySQL Server](#mysql-server)
    - [PostgreSQL Server](#postgresql-server)
12. [Firewall Port Configuration](#firewall-port-configuration)
13. [Automatic Rollback on Failure](#automatic-rollback-on-failure)
14. [Credentials File](#credentials-file)
15. [Log File](#log-file)
16. [Already-Installed Component Handling](#already-installed-component-handling)
17. [Database Seeding](#database-seeding)
18. [Security Considerations](#security-considerations)
19. [Troubleshooting](#troubleshooting)
20. [Frequently Asked Questions](#frequently-asked-questions)
21. [Changelog](#changelog)

---

## Overview

`opa_setup.sh` automates the installation and initial hardening of:

- **Okta Privilege Access (OPA) Agent** — the daemon installed on target servers that enables Okta-managed privileged access.
- **Okta Privilege Access (OPA) Gateway** — the secure-tunneling proxy that allows Okta to reach private resources without opening inbound firewall rules.
- **MySQL 8** or **PostgreSQL 16** — with database, user creation, hardening, and sample-data seeding.

All components are installed from their official package repositories using distribution-appropriate tooling (`apt`, `dnf`, or `yum`). If the script fails at any point, it automatically uninstalls whatever was partially set up before exiting.

---

## What This Script Does

The script executes the following steps in order:

| Step | Action |
|------|--------|
| 1 | Detect the Linux distribution and verify it is supported |
| 2 | Run a full system update (`apt upgrade` / `dnf update`) |
| 3 | Install common base dependencies (`curl`, `wget`, `gnupg`, `jq`, etc.) |
| 4 | Check whether OPA Agent, OPA Gateway, MySQL, or PostgreSQL are already installed; present options if so |
| 5 | Present an interactive install menu (or use CLI flags in non-interactive mode) |
| 6 | Install and configure selected OPA components |
| 7 | Install and harden the selected SQL server |
| 8 | Create a dedicated database and two database users (admin + application) |
| 9 | Seed the database with a configurable number of sample rows |
| 10 | Open required firewall ports via `ufw` (Ubuntu/Debian) or `firewalld` (RHEL/Rocky/etc.) |
| 11 | Save all generated credentials to a root-only file and print its path |

> If any step fails, the script automatically rolls back all components installed during that run before exiting. See [Automatic Rollback on Failure](#automatic-rollback-on-failure).

---

## Supported Linux Distributions

| Distribution | Minimum Version |
|---|---|
| Ubuntu | 20.04 LTS |
| Debian | 11 (Bullseye) |
| RHEL / CentOS / Rocky Linux / AlmaLinux | 8 |
| Oracle Linux | 8 |
| Amazon Linux | 2 and 2023 |

> **Note:** The script reads `/etc/os-release` for detection. Custom or heavily modified distros may fail the check even if the underlying packages are compatible.

---

## Prerequisites

Before running the script you need:

1. **Root access** — run with `sudo bash opa_setup.sh` or as the `root` user directly.
2. **Internet connectivity** — to reach:
   - `packages.okta.com` (OPA repos)
   - `apt.postgresql.org` or `download.postgresql.org` (PostgreSQL)
   - Distribution mirrors (OS updates)
3. **An Okta tenant with Privileged Access enabled.**
4. **One or both of the following tokens** (only needed if you are installing the respective component):
   - **Agent Enrollment Token** — found in your Okta Admin Console under *Security > Privileged Access > Resources > Agents > Add Agent > Generate Token*.
   - **Gateway Enrollment Token** — found in your Okta Admin Console under *Security > Privileged Access > Gateways > Add Gateway > Generate Token*.

---

## Downloading the Script

The script is hosted on GitHub at:
**https://github.com/ItsGambit/Okta/blob/main/OPA/Database%20Setup/opa_setup.sh**

### Download with curl

```bash
curl -fsSL "https://raw.githubusercontent.com/ItsGambit/Okta/main/OPA/Database%20Setup/opa_setup.sh" \
     -o opa_setup.sh
```

### Download with wget

```bash
wget -q "https://raw.githubusercontent.com/ItsGambit/Okta/main/OPA/Database%20Setup/opa_setup.sh" \
     -O opa_setup.sh
```

### Download and run in a single command

> **Security note:** Piping directly to bash is convenient but means you are executing remote code without reviewing it first. Only do this if you trust the source and have verified the URL.

```bash
# curl
sudo bash <(curl -fsSL "https://raw.githubusercontent.com/ItsGambit/Okta/main/OPA/Database%20Setup/opa_setup.sh")

# wget
sudo bash <(wget -qO- "https://raw.githubusercontent.com/ItsGambit/Okta/main/OPA/Database%20Setup/opa_setup.sh")
```

### Verify the download

After downloading, confirm the script version before running:

```bash
grep 'SCRIPT_VERSION=' opa_setup.sh
# Expected: readonly SCRIPT_VERSION="1.1.1"
```

---

## Quick Start

```bash
# Download the script
curl -fsSL "https://raw.githubusercontent.com/ItsGambit/Okta/main/OPA/Database%20Setup/opa_setup.sh" \
     -o opa_setup.sh

# Run interactively (recommended for first use)
sudo bash opa_setup.sh

# Run with verbose/debug output
sudo bash opa_setup.sh --verbose
```

---

## Interactive Mode (Default)

When run without `--non-interactive`, the script guides you through every step with on-screen prompts.

### Flow

```
1.  Distribution check  →  automatic, no input required
2.  System update       →  automatic
3.  Already-installed?  →  menu prompt (if any component is found)
4.  Install menu        →  choose one or more components:
        1) OPA Agent
        2) OPA Gateway
        3) SQL Server  (sub-menu: MySQL or PostgreSQL)
5.  OPA configuration   →  enter Okta team name and enrollment token(s)
6.  DB seeding          →  enter how many sample rows to create
7.  Firewall rules      →  automatic, based on components installed
8.  Summary printed     →  path to credentials file shown
```

### Already-Installed Menu

If one of the components is already present on the system, you will see:

```
  Okta Privilege Access Agent is already installed on this system.
  What would you like to do?

  a) Exit the script
  b) Show current version and service status
  c) Clean uninstall then reinstall
  d) Skip to install options (keep existing, install other components)
```

---

## Non-Interactive Mode (Automation / CI)

Pass `--non-interactive` and all relevant `--install-*` flags to run with zero prompts.
Sensitive values (tokens, team name) are read from environment variables.

### Basic example — install OPA Agent only

```bash
sudo OPA_TEAM="my-okta-team" \
     OPA_ENROLLMENT_TOKEN="ott_xxxxxxxxxxxxxxxxxxx" \
     bash opa_setup.sh \
     --non-interactive \
     --install-agent
```

### Install Agent + PostgreSQL with 1,000 sample rows

```bash
sudo OPA_TEAM="my-okta-team" \
     OPA_ENROLLMENT_TOKEN="ott_xxxxxxxxxxxxxxxxxxx" \
     bash opa_setup.sh \
     --non-interactive \
     --install-agent \
     --install-postgresql \
     --sample-data-rows=1000
```

### Install Gateway + MySQL; force-reinstall if already present

```bash
sudo OPA_TEAM="my-okta-team" \
     OPA_GATEWAY_TOKEN="ogt_xxxxxxxxxxxxxxxxxxx" \
     bash opa_setup.sh \
     --non-interactive \
     --install-gateway \
     --install-mysql \
     --sample-data-rows=500 \
     --force-reinstall
```

### Install all four components

```bash
sudo OPA_TEAM="my-okta-team" \
     OPA_ENROLLMENT_TOKEN="ott_xxx" \
     OPA_GATEWAY_TOKEN="ogt_xxx" \
     bash opa_setup.sh \
     --non-interactive \
     --install-agent \
     --install-gateway \
     --install-mysql \
     --sample-data-rows=200
```

> **Tip:** In a CI pipeline, store `OPA_ENROLLMENT_TOKEN` and `OPA_GATEWAY_TOKEN` as masked secrets — never hard-code them in pipeline YAML.

---

## All CLI Options

| Flag | Description | Default |
|------|-------------|---------|
| `-h`, `--help` | Print usage and exit | — |
| `-v`, `--verbose` | Enable debug-level log output | off |
| `-n`, `--non-interactive` | Run without any prompts | off |
| `--skip-updates` | Skip the OS package update step | off |
| `--force-reinstall` | Uninstall then reinstall if component already exists | off |
| `--install-agent` | Install the OPA Agent | off |
| `--install-gateway` | Install the OPA Gateway | off |
| `--install-mysql` | Install MySQL Server | off |
| `--install-postgresql` | Install PostgreSQL Server | off |
| `--opa-team=<TEAM>` | Okta PAM team/org name | `$OPA_TEAM` |
| `--enrollment-token=<TOKEN>` | Agent enrollment token | `$OPA_ENROLLMENT_TOKEN` |
| `--gateway-token=<TOKEN>` | Gateway enrollment token | `$OPA_GATEWAY_TOKEN` |
| `--sample-data-rows=<N>` | Rows to seed into the DB | prompt / `100` in non-interactive |

---

## Environment Variables

These variables are read before prompting, so pre-setting them reduces interactive input even when running in interactive mode.

| Variable | Purpose |
|----------|---------|
| `OPA_TEAM` | Okta PAM team/org name (e.g., `"my-company"`) |
| `OPA_ENROLLMENT_TOKEN` | Agent enrollment token from Okta admin console |
| `OPA_GATEWAY_TOKEN` | Gateway enrollment token from Okta admin console |
| `VERBOSE` | Set to `1` to enable debug output (same as `--verbose`) |

---

## Component Details

### Okta Privilege Access Agent

| Item | Detail |
|------|--------|
| Package name | `scaleft-server-tools` |
| Repository | `https://dist.scaleft.com/repos/` |
| Config file | `/etc/sft/sftd.yaml` |
| Log file | `journalctl -u sftd` or `/var/log/sftd.log` |
| Systemd service | `sftd` |

**What the script does:**
1. Adds the official Okta PAM GPG key and package repository.
2. Installs `scaleft-server-tools` (the `sftd` daemon starts automatically).
3. Prompts for the Server Enrollment Token (created in Okta Admin > Privileged Access > Projects > \<project\> > Enrollment).
4. Writes the token to `/var/lib/sftd/enrollment.token` — the path `sftd` reads on startup.
5. Restarts `sftd` to apply the token.
6. Verifies the service is running.

**Post-install steps (manual):**
- In your Okta admin console, navigate to *Security > Privileged Access > Resources* and confirm the agent appears and is marked **Active**.
- Associate the server with the appropriate resource group and access policy.

**Official documentation:**
https://help.okta.com/pam/en-us/content/topics/pam/agent-install.htm

---

### Okta Privilege Access Gateway

| Item | Detail |
|------|--------|
| Package name | `scaleft-gateway` |
| Repository | `https://dist.scaleft.com/repos/` (shared with agent) |
| Config file | `/etc/sft/sftd.yaml` |
| Log file | `journalctl -u sftd` or `/var/log/sftd.log` |
| Systemd service | `sftd` |
| Listen port | `7234/TCP` (inbound — accepts connections from the OPA Client) |

**What the script does:**
1. Adds the Okta PAM repository (if not already added by the agent step).
2. Installs `scaleft-gateway` (the `sftd` daemon starts automatically).
3. Prompts for the Gateway Setup Token (created in Okta Admin > Privileged Access > Gateways > Create Token).
4. Writes the token to `/var/lib/sft-gatewayd/setup.token` and creates `/etc/sft/sft-gatewayd.yaml` pointing to it.
5. Restarts `sftd` to apply the configuration.
6. Verifies the service is running.
7. Opens port `7234/TCP` inbound via the system firewall.

**Post-install steps (manual):**
- In your Okta admin console, navigate to *Security > Privileged Access > Gateways* and confirm the gateway appears and is marked **Active**.
- Add the private resources you want to proxy through the gateway.

**Official documentation:**
https://help.okta.com/pam/en-us/content/topics/pam/gw-configure.htm

---

### MySQL Server

| Item | Detail |
|------|--------|
| Package | `mysql-server` (distro repo) |
| Service | `mysql` or `mysqld` (auto-detected) |
| Version | Latest available from distro (MySQL 8.x recommended) |
| Hardening config | `/etc/mysql/conf.d/opa-hardening.cnf` (Debian/Ubuntu) or `/etc/my.cnf.d/opa-hardening.cnf` (RHEL) |

**What the script does:**
1. Installs `mysql-server` from the distribution's standard repository.
2. Performs the equivalent of `mysql_secure_installation`:
   - Sets a strong random root password.
   - Removes the anonymous user.
   - Disables remote root login.
   - Removes the test database.
3. Creates two users with randomly generated credentials:
   - **Admin user** — `GRANT ALL PRIVILEGES ... WITH GRANT OPTION`.
   - **Application user** — `GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER` on the application database.
4. Creates the `opadb` database with `utf8mb4` charset.
5. Applies a hardening config snippet:
   - `local_infile=0` (prevents `LOAD DATA LOCAL INFILE` attacks).
   - `bind-address=127.0.0.1` (localhost only — no external firewall rule required).
   - Slow query logging enabled.
6. Seeds the `employees` table with your requested number of rows.

---

### PostgreSQL Server

| Item | Detail |
|------|--------|
| Package | `postgresql-16`, `postgresql-client-16` |
| Repository | Official PGDG (`apt.postgresql.org` / `download.postgresql.org`) |
| Service | `postgresql` or `postgresql-16` (auto-detected) |
| Version | PostgreSQL 16 (latest stable at time of writing) |

**What the script does:**
1. Adds the official PostgreSQL Global Development Group (PGDG) repository.
2. Installs `postgresql-16` and `postgresql-client-16`.
3. Initialises the data cluster (`initdb`) on RHEL-based systems.
4. Creates two roles with randomly generated passwords:
   - **Admin role** — `CREATEROLE CREATEDB` (not a superuser by design).
   - **Application role** — restricted `GRANT` on the application database.
5. Creates the `opadb` database owned by the application user.
6. Hardens `postgresql.conf`:
   - `listen_addresses = 'localhost'` (no external firewall rule required).
   - `password_encryption = scram-sha-256`.
   - Connection and disconnection logging enabled.
7. Backs up `pg_hba.conf` (if it exists) and rewrites it to enforce `scram-sha-256` for all local connections.
8. Seeds the `employees` table using `generate_series` for efficient bulk inserts.

---

## Firewall Port Configuration

After all components are installed, the script automatically configures the system firewall using `ufw` (Ubuntu/Debian) or `firewalld` (RHEL/Rocky/AlmaLinux/Oracle Linux/Amazon Linux). If neither is found, the script logs a warning with the ports you must open manually.

Port requirements are sourced from the official Okta documentation:
**https://help.okta.com/en-us/content/topics/privileged-access/pam-default-ports.htm**

### Ports opened automatically

| Component | Port | Direction | Purpose |
|-----------|------|-----------|---------|
| Always | `22/TCP` | Inbound | SSH — kept open to prevent locking out the session when `ufw` is enabled |
| OPA Agent | `4421/TCP` | Inbound | On-demand user provisioning |
| OPA Gateway | `7234/TCP` | Inbound | Incoming connections from the OPA Client |

### Outbound ports (not managed by this script)

Most firewalls allow outbound traffic by default. Ensure the following are **not blocked**:

| Component | Port | Direction | Destination |
|-----------|------|-----------|-------------|
| OPA Agent | `443/TCP` | Outbound | Okta platform |
| OPA Gateway | `443/TCP` | Outbound | Okta platform and cloud storage |

### Database ports

MySQL (3306) and PostgreSQL (5432) are both configured to listen on **localhost only** in this setup. No external firewall rules are required. If you later need remote access, update `bind-address` (MySQL) or `listen_addresses` (PostgreSQL) and open the relevant port manually.

### Manual firewall configuration (if auto-config is unavailable)

```bash
# ufw (Ubuntu/Debian)
sudo ufw allow 22/tcp comment "SSH"
sudo ufw allow 4421/tcp comment "OPA Agent"     # if agent installed
sudo ufw allow 7234/tcp comment "OPA Gateway"   # if gateway installed
sudo ufw --force enable

# firewalld (RHEL/Rocky/etc.)
sudo firewall-cmd --permanent --add-port=22/tcp
sudo firewall-cmd --permanent --add-port=4421/tcp   # if agent installed
sudo firewall-cmd --permanent --add-port=7234/tcp   # if gateway installed
sudo firewall-cmd --reload
```

---

## Automatic Rollback on Failure

The script runs with `set -euo pipefail`, meaning any unexpected error causes an immediate exit. To prevent leaving the system in a partially configured state, an **EXIT trap** is registered at startup.

### How rollback works

1. At the beginning of each install function (`install_opa_agent`, `install_opa_gateway`, `install_mysql`, `install_postgresql`), the script sets a tracking flag.
2. If the script exits with a non-zero status at any point, the EXIT trap fires and calls `rollback_on_error`.
3. `rollback_on_error` checks which flags are set and calls the corresponding uninstall function for each component that was started.
4. After rollback completes, the original exit code is preserved so the caller can see that the run failed.

### What is uninstalled during rollback

| Flag set | What gets removed |
|----------|-------------------|
| OPA Agent started | `okta-pam-agent` package, config, and service |
| OPA Gateway started | `okta-pam-adserver-gateway` package, config, and service |
| MySQL started | `mysql-server` package, `/var/lib/mysql`, `/etc/mysql` |
| PostgreSQL started | `postgresql*` packages, `/var/lib/postgresql`, `/etc/postgresql` |

> **Note:** Firewall rules opened before the failure are **not** rolled back, as removing them could break pre-existing connectivity. Remove them manually if needed.

### Rollback behaviour with `--force-reinstall`

When `--force-reinstall` is passed and a component is already installed, the script first uninstalls it and then reinstalls. If the reinstall fails, rollback will attempt a second uninstall of the same component (safe — the uninstall functions are idempotent).

---

## Credentials File

After the script completes, all generated credentials are saved to:

```
/root/.opa_credentials_<YYYYMMDD_HHMMSS>.txt
```

**Permissions:** `600` (readable by `root` only).

### Example contents

```
# =============================================================================
# Okta Privilege Access Setup – Generated Credentials
# Created   : Wed Apr 16 14:22:01 UTC 2026
# =============================================================================

OPA_AGENT_TEAM=my-okta-team
OPA_AGENT_ENROLLMENT_TOKEN=ott_xxxxxxxxxxxxxxxxxxx
OPA_AGENT_CONFIG=/etc/okta-pam-agent/okta-pam-agent.yaml
OPA_AGENT_LOG=/var/log/okta-pam-agent/agent.log

MYSQL_ROOT_PASSWORD=Xk8#mP2qrN...
MYSQL_ADMIN_USER=opaadmin_a1b2c3
MYSQL_ADMIN_PASSWORD=vT9@wQz...
MYSQL_APP_USER=opaapp_d4e5f6
MYSQL_APP_PASSWORD=uR3!ySx...
MYSQL_DATABASE=opadb
```

> **Important:** Rotate these credentials after the initial setup, and store them in a secrets manager (e.g., HashiCorp Vault, AWS Secrets Manager, or Okta Privileged Access itself). Delete the plaintext file once credentials are securely stored.

---

## Log File

Every action is logged to:

```
/var/log/opa-setup/opa_setup_<YYYYMMDD_HHMMSS>.log
```

Log entries are timestamped and severity-tagged:

```
[2026-04-16 14:22:01] [INFO]    Installing Okta Privilege Access Agent...
[2026-04-16 14:22:03] [SUCCESS] okta-pam-agent package installed.
[2026-04-16 14:22:04] [WARN]    Okta PAM Agent did not start cleanly. ...
[2026-04-16 14:22:05] [ERROR]   Command failed (exit 1): ...
```

Use `--verbose` (or `VERBOSE=1`) to include `[DEBUG]` entries showing every command run and its output.

---

## Already-Installed Component Handling

When the script detects a component is already installed it presents a four-option menu:

| Choice | Action |
|--------|--------|
| **a) Exit** | Stop the script immediately. |
| **b) Show version & status** | Print the installed package version and systemd service status, then ask whether to continue. |
| **c) Clean uninstall + reinstall** | Stop the service, purge the package, remove config/data files, then reinstall from scratch. |
| **d) Skip to install options** | Leave the existing installation untouched and proceed to the install menu to add other components. |

In non-interactive mode:
- Without `--force-reinstall`: already-installed components are **skipped** (option d).
- With `--force-reinstall`: already-installed components are **uninstalled and reinstalled** (option c).

### PostgreSQL detection

The script detects PostgreSQL installations from all sources, including:
- Distro-packaged `postgresql` / `postgresql-server`
- Versioned PGDG packages such as `postgresql-16` (installed via `apt.postgresql.org`)

This prevents the script from running a duplicate install on top of an existing PGDG installation.

---

## Database Seeding

The seeding step creates two tables in the `opadb` database:

### `departments`
| Column | Type | Description |
|--------|------|-------------|
| `id` | Integer (PK) | Auto-increment |
| `name` | VARCHAR(50) | Department name |

Pre-populated with: Engineering, Marketing, Sales, HR, Finance, Operations, Legal, IT.

### `employees`
| Column | Type | Description |
|--------|------|-------------|
| `id` | Integer (PK) | Auto-increment |
| `first_name` | VARCHAR(50) | Random first name |
| `last_name` | VARCHAR(50) | Random last name |
| `email` | VARCHAR(100) | Unique, sequential |
| `department` | VARCHAR(50) | Random department |
| `job_title` | VARCHAR(80) | Random title + department |
| `hire_date` | DATE | Random date 2010–2024 |
| `salary` | Decimal | Random USD 50,000–150,000 |
| `is_active` | Boolean | Defaults to TRUE |
| `created_at` | Timestamp | Insert time |

**Row count options (interactive):** 10, 100, 500, 1,000, 5,000, 10,000, or a custom integer.
**Row count (non-interactive):** Pass `--sample-data-rows=<N>` or defaults to `100`.

---

## Security Considerations

1. **Run as root only on trusted systems.** The script modifies system package repos, firewall state, and service configurations.
2. **Enrollment tokens are sensitive.** They grant the ability to register agents/gateways with your Okta tenant. Treat them like passwords.
3. **Credentials file is plaintext.** `600` permissions reduce exposure, but the file should be moved into a vault immediately after setup.
4. **SQL servers are bound to localhost by default.** If you need remote connections, update `bind-address` (MySQL) or `listen_addresses` (PostgreSQL) and add appropriate firewall rules.
5. **TLS verification is always enabled.** The `insecureSkipVerify: false` setting in agent/gateway configs is intentional and should not be changed.
6. **Rotate all generated passwords** after the initial setup is verified.
7. **Review and tighten `pg_hba.conf` and `my.cnf`** before going to production.
8. **Review firewall rules** after setup. The script opens port `4421` (OPA Agent) and `7234` (OPA Gateway). Restrict source IPs to Okta service planes where your firewall supports it.

---

## Troubleshooting

### OPA Agent/Gateway not starting

```bash
# Check the systemd service status
sudo systemctl status okta-pam-agent
sudo journalctl -u okta-pam-agent -n 50

# Check the agent's own log
sudo tail -f /var/log/okta-pam-agent/agent.log
```

**Common causes:**
- Invalid enrollment token — regenerate one in the Okta admin console.
- DNS resolution failure — verify `*.okta.com` is reachable from the host.
- Clock skew — OPA uses TLS certificate validation which is time-sensitive; ensure NTP is running (`timedatectl status`).

### MySQL won't start

```bash
sudo systemctl status mysql
sudo journalctl -u mysql -n 50
# On RHEL
sudo journalctl -u mysqld -n 50
```

**Common cause:** An existing `/var/lib/mysql` directory with incompatible data files after a failed reinstall. Use `--force-reinstall` which removes `/var/lib/mysql` before reinstalling.

### PostgreSQL initdb fails (RHEL)

```bash
sudo journalctl -u postgresql-16 -n 50
```

**Common cause:** `/var/lib/pgsql/16/data` already exists and is non-empty. Use `--force-reinstall` to clear it.

### PostgreSQL data directory not found

If the script logs `Could not locate PostgreSQL data directory; skipping hardening config`, it means the `SHOW data_directory` query returned empty — usually because the cluster was not fully initialised. Run:

```bash
# Ubuntu/Debian
sudo pg_lsclusters
sudo pg_ctlcluster 16 main start

# RHEL/Rocky
sudo /usr/pgsql-16/bin/postgresql-16-setup initdb
sudo systemctl start postgresql-16
```

Then re-run the script with `--skip-updates --force-reinstall --install-postgresql`.

### Firewall rules not applied

If the script logs `No supported firewall manager (ufw/firewalld) found`, install one first:

```bash
# Ubuntu/Debian
sudo apt-get install -y ufw

# RHEL/Rocky
sudo dnf install -y firewalld
sudo systemctl enable --now firewalld
```

Then apply rules manually — see [Manual firewall configuration](#manual-firewall-configuration-if-auto-config-is-unavailable).

If `firewalld` is installed but not running:

```bash
sudo systemctl start firewalld
sudo firewall-cmd --permanent --add-port=7234/tcp   # gateway
sudo firewall-cmd --permanent --add-port=4421/tcp   # agent
sudo firewall-cmd --reload
```

### Script failed and left a partial installation

The rollback trap should have cleaned up automatically. If it did not, review the log file for what was installed and run the corresponding uninstall commands:

```bash
# View the log to find what was installed
sudo cat /var/log/opa-setup/opa_setup_<TIMESTAMP>.log | grep -E 'ROLLBACK|Installing|installed'

# Manual uninstall — Ubuntu/Debian
sudo apt-get purge -y okta-pam-agent okta-pam-adserver-gateway mysql-server postgresql-16

# Manual uninstall — RHEL/Rocky
sudo dnf remove -y okta-pam-agent okta-pam-adserver-gateway mysql-server postgresql16-server
```

### Package repository unreachable

Verify network access:
```bash
curl -v https://packages.okta.com/okta-pam-agent/gpg
curl -v https://www.postgresql.org/media/keys/ACCC4CF8.asc
```

If behind a proxy, export `http_proxy` / `https_proxy` before running the script:
```bash
export https_proxy=http://proxy.company.com:8080
sudo -E bash opa_setup.sh ...
```

### Re-running the script after a failure

The log file records where the failure occurred. Fix the root cause, then re-run with appropriate flags:

```bash
# Skip updates (already done), force-reinstall the failed component
sudo bash opa_setup.sh --skip-updates --force-reinstall --install-agent
```

---

## Frequently Asked Questions

**Q: Does this script configure Okta Advanced Server Access (ASA)?**
A: No. This script is specifically for the **Okta Privilege Access** product. The ASA `sft` agent is not installed or configured.

**Q: Can I install the Agent and Gateway on the same host?**
A: Yes, though it is not recommended for production. The Agent manages access to the local host while the Gateway proxies access to other downstream resources. In production, the Gateway is typically a dedicated hardened VM.

**Q: Can I install both MySQL and PostgreSQL?**
A: The install menu allows selecting only one SQL server at a time (they would both listen on default ports and could conflict). If you need both, run the script twice — once with `--install-mysql` and once with `--install-postgresql`.

**Q: Where do I find my Okta PAM team name?**
A: In your Okta Admin Console, navigate to *Security > Privileged Access*. The team name is shown in the URL: `https://<your-org>.okta.com/admin/pam/teams/<TEAM-NAME>`.

**Q: The script says the package isn't found — what should I do?**
A: Okta periodically updates package names. Check the current package name at:
https://help.okta.com/pam/en-us/content/topics/pam/agent-install.htm
Update the `OPA_AGENT_SERVICE` and `OPA_GATEWAY_SERVICE` variables at the top of `opa_setup.sh`.

**Q: How do I run this in a Docker container or Kubernetes pod?**
A: The script requires `systemd` for service management, which is not available in standard containers. For containerised OPA Agent deployments, refer to Okta's container-specific documentation.

**Q: The rollback ran but some files are still present — is that normal?**
A: The rollback uses the same uninstall functions as the `--force-reinstall` path. On Debian/Ubuntu, `apt-get purge` removes packages and most config files; on RHEL, `dnf remove` does the same. Data directories (`/var/lib/mysql`, `/var/lib/postgresql`) are explicitly removed. If files remain, they are likely user-created or outside the managed paths.

---

## Changelog

### v1.1.1 — 2026-04-21
- **Fix (Critical):** `OPA_GATEWAY_SERVICE` was incorrectly set to `sftd` (same as the agent). Corrected to `sft-gatewayd` — the actual systemd service name for `scaleft-gateway` per Okta gateway documentation. This prevented gateway service management (start/stop/restart/uninstall) from working correctly and would have caused conflicts when both agent and gateway were installed on the same host.
- **Fix:** Non-interactive mode now fails immediately with a clear error if `OPA_ENROLLMENT_TOKEN` or `OPA_GATEWAY_TOKEN` is not provided, instead of silently writing an empty token file.
- **Fix:** Added `|| die` error handling to all token file and config file write operations (`mkdir`, `echo`, `chmod`, `cat`) in both `configure_opa_agent` and `configure_opa_gateway`.
- **Fix:** Removed stale `OPA_TEAM=myteam` reference from the non-interactive usage example in `--help` output.

### v1.1.0 — 2026-04-21
- **Fix (Critical):** Agent and gateway configuration completely rewritten to match the actual Okta PAM enrollment model for `scaleft-server-tools` and `scaleft-gateway`.
  - **Agent:** Removed the old `team`/`enrollmentToken` YAML config file approach. Enrollment is now done by writing the token to `/var/lib/sftd/enrollment.token` — the exact path `sftd` reads on startup per Okta docs.
  - **Gateway:** Removed the old gateway YAML with `team`/`enrollmentToken`/`listenPort` fields. Setup token is now written to `/var/lib/sft-gatewayd/setup.token` and `/etc/sft/sft-gatewayd.yaml` is written with `SetupTokenFile` pointing to it, per Okta gateway configuration docs.
  - Both services rely on the package installer to enable and start the daemon; the script now `restart`s rather than `enable`+`start`.
- **Change:** Removed `OPA_TEAM` variable, `--opa-team` CLI flag, and all references — the new enrollment model does not use a team name field.

### v1.0.9 — 2026-04-21
- **Fix:** `add_opa_repo_deb` and `add_opa_repo_rpm` rewritten to follow the exact steps from the official Okta documentation instead of a custom download-and-detect approach that was causing `gpg --dearmor` failures.
  - **Debian/Ubuntu:** Now uses `curl -fsSL <gpg-url> | gpg --dearmor | tee <keyring> > /dev/null` and `echo "deb ..." | tee <sources-list> > /dev/null` exactly as documented.
  - **RHEL/Rocky/AlmaLinux/Amazon Linux:** Now uses `rpm --import <gpg-url>` directly as documented.

### v1.0.8 — 2026-04-21
- **Fix (Critical):** `is_installed` was called with `OPA_AGENT_SERVICE`/`OPA_GATEWAY_SERVICE` (`sftd`) instead of the package names — it would never detect an existing agent or gateway installation. Now correctly uses `OPA_AGENT_PACKAGE` (`scaleft-server-tools`) and `OPA_GATEWAY_PACKAGE` (`scaleft-gateway`).
- **Fix (Critical):** All calls to `uninstall_component` and `print_component_status` for Agent and Gateway — in `rollback_on_error`, `check_already_installed`, and `handle_already_installed_menu` — were passing the service name (`sftd`) as both the package and service argument. Now correctly pass the package constant for the `pkg` argument and service constant for `svc`.
- **Fix (Critical):** `DISTRO_CODENAME` can be empty on systems where `/etc/os-release` omits `VERSION_CODENAME`. Added fallback to `lsb_release -cs` and a hard `die` guard in `add_opa_repo_deb` to prevent a malformed APT sources line from being written.
- **Fix:** Removed no-op line `[[ "${DISTRO_ID}" == "amzn" ]] && DISTRO_ID="amzn"` in `detect_distro`.
- **Fix:** MySQL service name detection rewritten as an `if/then/fi` block; the previous `&&` short-circuit form was ambiguous under `set -euo pipefail`.
- **Fix:** All three `postgresql-setup initdb` / `postgresql-XX-setup initdb` calls now include `2>&1` before the pipe to `tee`, ensuring stderr is captured in the log and errors are properly detected under `pipefail`.
- **Fix:** PostgreSQL service name detection now calls `systemctl list-unit-files` once and stores the result, eliminating the duplicate call and the fragile `&&` chain that could leave `pg_svc` empty.
- **Fix:** `mysql_initial_args` array element `--password=...` is now quoted as a single element to prevent word splitting on passwords containing special characters.

### v1.0.7 — 2026-04-21
- **Fix:** Corrected all Okta PAM repository URLs, GPG key URL, and package names to match the official Okta documentation.
  - GPG key URL updated from `https://packages.okta.com/okta-pam-agent/gpg` → `https://dist.scaleft.com/GPG-KEY-OktaPAM-2023`
  - DEB repo URL updated from `https://packages.okta.com/okta-pam-agent/debian` → `https://dist.scaleft.com/repos/deb`
  - DEB sources file renamed to `oktapam-stable.list`; keyring file renamed to `oktapam-2023-archive-keyring.gpg`
  - DEB repo line now uses the distro codename (e.g. `focal`, `jammy`, `bullseye`) and channel `okta` as required by the Okta repo format
  - RPM repo URL updated from `https://packages.okta.com/okta-pam-agent/rhel` → `https://dist.scaleft.com/repos/rpm/stable/<platform>/<version>/$basearch`; repo file renamed to `oktapam-stable.repo` with `repo_gpgcheck=1` added
  - RPM platform key now mapped per distro: `rhel`/`centos`/`rocky`/`ol` → `rhel`, `almalinux` → `alma`, `amzn` → `amazonlinux`
  - Agent package renamed from `okta-pam-agent` → `scaleft-server-tools`; service name updated to `sftd`
  - Gateway package renamed from `okta-pam-adserver-gateway` → `scaleft-gateway`; service name updated to `sftd`

### v1.0.6 — 2026-04-21
- **Fix:** GPG key import rewritten for all distributions to eliminate the silent-failure `curl | gpg --dearmor` pipe pattern.
  - **Debian/Ubuntu (`add_opa_repo_deb`):** Key is now downloaded to a temp file first so `curl` errors are caught independently. The key format is then detected — ASCII-armored keys (beginning with `-----BEGIN PGP`) are passed through `gpg --dearmor`; binary keys are copied directly to the keyring path. This resolves failures on clean installs where `packages.okta.com/okta-pam-agent/gpg` returns a binary `.gpg` file.
  - **RHEL / CentOS / Rocky / AlmaLinux / Oracle Linux / Amazon Linux (`add_opa_repo_rpm`):** Key is now downloaded via `curl` to a temp file with timeout and retry before being passed to `rpm --import`, replacing a bare `rpm --import <url>` call that gave no meaningful error on network failure.
  - **PostgreSQL APT repo (`install_postgresql`):** Same `curl | gpg --dearmor` pipe replaced with the same temp-file + format-detection pattern used for the Okta DEB key.
  - All three download calls now use `--connect-timeout 30 --retry 3 --retry-delay 5` for resilience on slow or flaky networks.
  - Keyring files are explicitly `chmod 644` after creation.

### v1.0.5 — 2026-04-21
- **Fix:** `get_service_status` was outputting both the `systemctl is-active` status text and the fallback string `"inactive/not-found"` when a service was down, causing double-output in the captured variable. Refactored to capture first, fall back on failure.
- **Fix:** `mysql_initial_args` empty-array expansion made safe under `set -u` using the `"${arr[@]+"${arr[@]}"}"`  guard pattern, preventing potential unbound-variable errors on older bash versions.
- **Fix:** PGDG PostgreSQL detection pipeline (`dpkg -l 'postgresql-[0-9]*' | grep -q`) now appends `|| true` to prevent `set -o pipefail` from aborting the script when no matching packages are installed.
- **Fix:** `ufw status | grep -q` in the firewall apply block now redirects stderr (`2>&1`) to prevent a broken pipe from triggering `pipefail`.
- **Fix:** `firewall-cmd --permanent` now checks whether firewalld is actively running before attempting to add rules; logs a manual-command warning if it is stopped.
- **Fix:** Duplicate `SECTION 15` label corrected; section numbers cascaded from 15 → 18.

### v1.0.4 — 2026-04-21
- **Feature:** Added `configure_firewall` function (Section 14). Automatically opens required ports via `ufw` or `firewalld` after installation based on official Okta PAM port documentation (`help.okta.com/en-us/content/topics/privileged-access/pam-default-ports.htm`).
  - OPA Agent: `22/TCP` and `4421/TCP` inbound.
  - OPA Gateway: `7234/TCP` inbound.
  - MySQL/PostgreSQL: no external ports (localhost-bound); informational log only.
  - Falls back to a printed manual-command list if no firewall manager is detected.

### v1.0.3 — 2026-04-21
- **Fix:** `rollback_on_error` replaced `[[ ]] && { }` pattern with `if/then/fi` blocks to prevent `set -e` from aborting rollback when a flag is not set.
- **Fix:** Added `set +e` at the start of `rollback_on_error` so a failing rollback step does not abort cleanup of subsequent components.

### v1.0.2 — 2026-04-21
- **Feature:** Automatic rollback on failure. An EXIT trap calls `rollback_on_error` on any non-zero exit. Each install function sets a tracking flag at the start; rollback uninstalls only the components that were started in the current run.
- **Fix:** PostgreSQL already-installed detection now catches versioned PGDG packages (e.g., `postgresql-16`) using a glob pattern in addition to the generic `postgresql` package name.

### v1.0.1 — 2026-04-21
- **Fix:** `prompt_secret` echoed a blank line to stdout (to move the cursor after hidden input), which was captured into `OPA_ENROLLMENT_TOKEN` and `OPA_GATEWAY_TOKEN` when called via command substitution. Redirected to stderr (`>&2`).
- **Fix:** `get_sample_data_rows` echoed its interactive menu text to stdout, causing the full prompt to be captured into `rows` and injected into SQL, producing a syntax error. All display echoes redirected to stderr.
- **Fix:** `setup_postgresql` backed up `pg_hba.conf` unconditionally with `cp`, which failed on a fresh cluster where the file did not yet exist. Added an existence check before the copy.

### v1.0.0 — initial release
- Initial release: OPA Agent, OPA Gateway, MySQL, PostgreSQL installation and configuration.

---

*Script: `opa_setup.sh` v1.1.1 — https://github.com/ItsGambit/Okta/blob/main/OPA/Database%20Setup/opa_setup.sh*
