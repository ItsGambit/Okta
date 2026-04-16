# Okta Privilege Access (OPA) Setup Script

**Version:** 1.0.0
**Script:** `opa_setup.sh`

---

## Table of Contents

1. [Overview](#overview)
2. [What This Script Does](#what-this-script-does)
3. [Supported Linux Distributions](#supported-linux-distributions)
4. [Prerequisites](#prerequisites)
5. [Quick Start](#quick-start)
6. [Interactive Mode (Default)](#interactive-mode-default)
7. [Non-Interactive Mode (Automation / CI)](#non-interactive-mode-automation--ci)
8. [All CLI Options](#all-cli-options)
9. [Environment Variables](#environment-variables)
10. [Component Details](#component-details)
    - [Okta Privilege Access Agent](#okta-privilege-access-agent)
    - [Okta Privilege Access Gateway](#okta-privilege-access-gateway)
    - [MySQL Server](#mysql-server)
    - [PostgreSQL Server](#postgresql-server)
11. [Credentials File](#credentials-file)
12. [Log File](#log-file)
13. [Already-Installed Component Handling](#already-installed-component-handling)
14. [Database Seeding](#database-seeding)
15. [Security Considerations](#security-considerations)
16. [Troubleshooting](#troubleshooting)
17. [Frequently Asked Questions](#frequently-asked-questions)

---

## Overview

`opa_setup.sh` automates the installation and initial hardening of:

- **Okta Privilege Access (OPA) Agent** — the daemon installed on target servers that enables Okta-managed privileged access.
- **Okta Privilege Access (OPA) Gateway** — the secure-tunneling proxy that allows Okta to reach private resources without opening inbound firewall rules.
- **MySQL 8** or **PostgreSQL 16** — with database, user creation, hardening, and sample-data seeding.

All components are installed from their official package repositories using distribution-appropriate tooling (`apt`, `dnf`, or `yum`).

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
| 10 | Save all generated credentials to a root-only file and print its path |

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
4. **One or both of the following tokens** (only needed if you're installing the respective component):
   - **Agent Enrollment Token** — found in your Okta Admin Console under *Security > Privileged Access > Resources > Agents > Add Agent > Generate Token*.
   - **Gateway Enrollment Token** — found in your Okta Admin Console under *Security > Privileged Access > Gateways > Add Gateway > Generate Token*.

---

## Quick Start

```bash
# Download and make executable
chmod +x opa_setup.sh

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
7.  Summary printed     →  path to credentials file shown
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

### Install Agent + PostgreSQL with 1 000 sample rows

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
| Package name | `okta-pam-agent` |
| Repository | `https://packages.okta.com/okta-pam-agent/` |
| Config file | `/etc/okta-pam-agent/okta-pam-agent.yaml` |
| Log file | `/var/log/okta-pam-agent/agent.log` |
| Systemd service | `okta-pam-agent` |

**What the script does:**
1. Adds the official Okta PAM GPG key and package repository.
2. Installs `okta-pam-agent`.
3. Writes a minimal YAML configuration file with your team name, enrollment token, and secure TLS settings.
4. Enables and starts the `okta-pam-agent` systemd service.
5. Verifies the service is running.

**Post-install steps (manual):**
- In your Okta admin console, navigate to *Security > Privileged Access > Resources* and confirm the agent appears and is marked **Active**.
- Associate the server with the appropriate resource group and access policy.

**Official documentation:**
https://help.okta.com/pam/en-us/content/topics/pam/agent-install.htm

---

### Okta Privilege Access Gateway

| Item | Detail |
|------|--------|
| Package name | `okta-pam-adserver-gateway` |
| Repository | `https://packages.okta.com/okta-pam-agent/` (shared with agent) |
| Config file | `/etc/okta-pam-adserver-gateway/gateway.yaml` |
| Log file | `/var/log/okta-pam-gateway/gateway.log` |
| Systemd service | `okta-pam-adserver-gateway` |
| Listen port | `7234` (TCP, outbound-only by design) |

**What the script does:**
1. Adds the Okta PAM repository (if not already added by the agent step).
2. Installs `okta-pam-adserver-gateway`.
3. Writes a YAML configuration file with your team name, gateway enrollment token, listen port, and secure TLS settings.
4. Enables and starts the `okta-pam-adserver-gateway` systemd service.

**Post-install steps (manual):**
- In your Okta admin console, navigate to *Security > Privileged Access > Gateways* and confirm the gateway appears and is marked **Active**.
- Add the private resources you want to proxy through the gateway.

> **Firewall note:** The OPA Gateway makes **outbound** connections only. No inbound port needs to be opened on the gateway host. Do ensure outbound TCP 443 to `*.okta.com` is not blocked.

**Official documentation:**
https://help.okta.com/pam/en-us/content/topics/pam/gw-configure.htm

---

### MySQL Server

| Item | Detail |
|------|--------|
| Package | `mysql-server` (distro repo) |
| Service | `mysql` or `mysqld` (auto-detected) |
| Version | Latest available from distro (MySQL 8.x recommended) |
| Hardening config | `/etc/mysql/conf.d/opa-hardening.cnf` (Debian) or `/etc/my.cnf.d/opa-hardening.cnf` (RHEL) |

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
   - `bind-address=127.0.0.1` (localhost only).
   - Slow query logging enabled.
6. Seeds the `employees` table with your requested number of rows.

---

### PostgreSQL Server

| Item | Detail |
|------|--------|
| Package | `postgresql-16`, `postgresql-client-16` |
| Repository | Official PGDG (`apt.postgresql.org` / `download.postgresql.org`) |
| Service | `postgresql` or `postgresql-16` (auto-detected) |
| Version | PostgreSQL 16 (latest stable) |

**What the script does:**
1. Adds the official PostgreSQL Global Development Group (PGDG) repository.
2. Installs `postgresql-16` and `postgresql-client-16`.
3. Initialises the data cluster (`initdb`) on RHEL-based systems.
4. Creates two roles with randomly generated passwords:
   - **Admin role** — `CREATEROLE CREATEDB` (not a superuser by default).
   - **Application role** — restricted `GRANT` on the application database.
5. Creates the `opadb` database owned by the application user.
6. Hardens `postgresql.conf`:
   - `listen_addresses = 'localhost'`
   - `password_encryption = scram-sha-256`
   - Connection and disconnection logging enabled.
7. Rewrites `pg_hba.conf` to enforce `scram-sha-256` for all local connections (backs up the original).
8. Seeds the `employees` table using `generate_series` for efficient bulk inserts.

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
7. **Review and tighten pg_hba.conf and my.cnf** before going to production.

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

---

*Generated by `opa_setup.sh` v1.0.0*
