# db-install.sh

A production-ready bash script that installs and configures **MySQL 8.x**, **PostgreSQL 16.x**, and **MongoDB 7.x** on any Linux distribution supported by [Okta Privileged Access (OPA)](https://help.okta.com/en-us/content/topics/privileged-access/pam-overview.htm).

The script handles vendor repo setup, service configuration, security hardening, OPA service account creation, firewall management, and outputs a chmod-600 credential summary file at the end.

---

## Table of Contents

- [Supported Operating Systems](#supported-operating-systems)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [CLI Reference](#cli-reference)
- [Modes](#modes)
  - [Interactive vs Non-Interactive](#interactive-vs-non-interactive)
  - [Lab vs Production Firewall](#lab-vs-production-firewall)
- [Dry Run](#dry-run)
- [Output Files](#output-files)
- [OPA Service Accounts](#opa-service-accounts)
- [Rollback](#rollback)
- [Examples](#examples)
- [Changelog](#changelog)

---

## Supported Operating Systems

| Family   | Distributions                                                    | Package Manager |
|----------|------------------------------------------------------------------|-----------------|
| Debian   | Ubuntu 20.04, 22.04, 24.04 · Debian 11 (bullseye), 12 (bookworm) | `apt`           |
| RHEL     | RHEL 8/9 · CentOS Stream 8/9 · Alma Linux 8/9 · Amazon Linux 2 / 2023 | `dnf` / `yum`  |
| SUSE     | SUSE Linux Enterprise Server 15                                  | `zypper`        |

All databases are installed from their **official vendor repositories** (MySQL Community, PGDG, MongoDB) — never distro-bundled packages.

---

## Prerequisites

The following must be satisfied before running the script:

| Requirement        | Detail                                                              |
|--------------------|---------------------------------------------------------------------|
| Root access        | Run as `root` or via `sudo bash db-install.sh`                      |
| RAM                | ≥ 1 GB available (warned, not fatal)                                |
| Disk               | ≥ 5 GB free on `/var` (warned, not fatal)                           |
| Internet access    | Required to download packages from vendor repos                     |
| Tools              | `curl`, `openssl`, `gpg` (Debian family) — installed automatically if missing |
| Ports              | 3306 (MySQL), 5432 (PostgreSQL), 27017 (MongoDB) must be free       |

---

## Quick Start

```bash
# Install all three databases (interactive mode — prompts for confirmation)
sudo bash db-install.sh

# Non-interactive — install all three, auto-generate all passwords
sudo bash db-install.sh --non-interactive --all

# Install MySQL only
sudo bash db-install.sh --mysql

# Dry run — see every action without executing anything
sudo bash db-install.sh --dry-run --all --verbose
```

After a successful run, check the credential file:

```bash
sudo cat /root/db-credentials.txt
```

---

## CLI Reference

```
Usage: db-install.sh [OPTIONS]
```

### Database Selection

| Flag                    | Description                              |
|-------------------------|------------------------------------------|
| `-m`, `--mysql`         | Install MySQL only                       |
| `-p`, `--postgresql`    | Install PostgreSQL only                  |
| `-g`, `--mongodb`       | Install MongoDB only                     |
| `-a`, `--all`           | Install all three (default if no DB flag given) |

### Mode

| Flag                    | Description                              |
|-------------------------|------------------------------------------|
| `-i`, `--interactive`   | Prompt for confirmation and settings (default) |
| `-n`, `--non-interactive` | Unattended / CI / pipeline mode — no prompts |

### Environment

| Flag                    | Default           | Description                                          |
|-------------------------|-------------------|------------------------------------------------------|
| `--production`          | *(off)*           | Enable OS firewall with CIDR-restricted rules        |
| `--allowed-cidr CIDR`   | `10.1.0.0/20`     | Source CIDR allowed through the production firewall  |

### Passwords

All passwords are **auto-generated** (32-char random string via `openssl`) if not supplied.
Supplying them is only needed in non-interactive / CI pipelines.

| Flag                          | Description                             |
|-------------------------------|-----------------------------------------|
| `--mysql-root-password PW`    | MySQL root password                     |
| `--pg-admin-password PW`      | PostgreSQL `postgres` superuser password |
| `--mongo-admin-password PW`   | MongoDB `admin` user password           |
| `--opa-svc-password PW`       | Shared OPA service account password (used across all DBs) |

### Seeding (optional — lab data generation)

| Flag | Default | Description |
|------|---------|-------------|
| `--seed-data` | off | Enable database seeding with lab/test data |
| `--seed-dbs N` | `3` | Number of databases to create per engine |
| `--seed-rows N` | `1000` | Rows/documents per table or collection |
| `--lab-admin-user NAME` | `lab_admin` | Name for the global superuser created on all engines |
| `--lab-admin-password PW` | _(auto-generated)_ | Password for the lab superuser |

### Output Paths

| Flag                    | Default                       | Description             |
|-------------------------|-------------------------------|-------------------------|
| `-l`, `--log-file PATH` | `/var/log/db-install.log`     | Installation log file   |
| `-c`, `--cred-file PATH`| `/root/db-credentials.txt`    | Credential output file  |

### Utilities

| Flag          | Description                                            |
|---------------|--------------------------------------------------------|
| `--dry-run`   | Print every action without executing — safe to run anywhere |
| `--rollback`  | Attempt to uninstall previously installed databases    |
| `-v`, `--verbose` | Enable DEBUG-level logging                         |
| `-h`, `--help`| Show the built-in usage message and exit               |

---

## Modes

### Interactive vs Non-Interactive

**Interactive** (default): The script pauses at key decision points:
- Confirms which databases will be installed and where logs/credentials go
- Asks whether the deployment is Lab or Production (controls firewall)

**Non-interactive** (`--non-interactive`): No prompts — suitable for CI pipelines, Terraform provisioners, and cloud-init scripts. All decisions must be provided via flags; missing passwords are auto-generated.

```bash
# Full unattended example with explicit passwords
sudo bash db-install.sh \
  --non-interactive \
  --all \
  --production \
  --allowed-cidr 10.1.0.0/20 \
  --mysql-root-password 'MyS3cureRootPW!' \
  --pg-admin-password  'PgStr0ngPass!' \
  --mongo-admin-password 'M0ng0AdminPW!' \
  --opa-svc-password   'OpaSharedSvc!' \
  --log-file /var/log/db-install.log \
  --cred-file /root/db-credentials.txt
```

### Lab vs Production Firewall

| Mode        | Behavior                                                                 |
|-------------|--------------------------------------------------------------------------|
| **Lab**     | OS firewall is **disabled** (UFW / firewalld) for easier troubleshooting. Rely on AWS Security Groups at the network level. |
| **Production** | OS firewall is **enabled** with rules that restrict DB ports (3306, 5432, 27017) to the specified `--allowed-cidr` only. |

- In **interactive mode**: You are prompted "Is this a PRODUCTION deployment?" — answer `n` for lab (default).
- In **non-interactive mode**: Add `--production` to enable firewall hardening. Without this flag, lab mode is used.

The credential file documents the exact firewall state and the commands to re-run with production hardening.

#### Firewall implementations by distro

| Family     | Tool         | Lab action                        | Production action                  |
|------------|--------------|-----------------------------------|------------------------------------|
| Debian     | `ufw`        | `ufw disable`                     | `ufw allow from <CIDR> to any port <PORT> proto tcp; ufw enable` |
| RHEL/Amzn  | `firewalld`  | `systemctl stop/disable firewalld`| `firewall-cmd --permanent --add-rich-rule` per port |
| SUSE       | `firewalld`  | `systemctl stop/disable firewalld`| `firewall-cmd` rich rules (if installed) |

---

## Dry Run

`--dry-run` is a first-class mode. Every destructive operation is printed but not executed:

```bash
sudo bash db-install.sh --dry-run --all --verbose
```

Output shows `[DRY-RUN] <command>` for every skipped action. No packages are installed, no files modified, no services started. Safe to run on a production host to preview what the script would do.

---

## Output Files

### Log File — `/var/log/db-install.log`

Every step, INFO/WARN/ERROR/DEBUG message, and executed command is appended to the log file. The log is created at script start with a header banner including timestamp, PID, and hostname.

```bash
tail -f /var/log/db-install.log
```

### Credential File — `/root/db-credentials.txt`

Written at the end of a successful installation. Contains:

- Firewall status and mode
- MySQL: root password, admin password, OPA service account password, test commands
- PostgreSQL: admin password, OPA service account password, connection strings, test commands
- MongoDB: admin password, OPA service account password, connection strings, test commands
- `[LAB DATA — SEEDING]` section (if `--seed-data` was used): seeded database names, service user credentials, and per-database test commands

**Permissions are set to `600` before any secrets are written** (using `install -m 600 /dev/null`) to prevent a race condition where a world-readable file could briefly contain passwords.

> **Security note:** This file contains plaintext credentials. After provisioning, move the secrets to a vault (HashiCorp Vault, AWS Secrets Manager, or OPA Secrets Management) and delete this file.

---

## OPA Service Accounts

The script creates an `opa_svc` service account in each database to support Okta Privileged Access integration.

### MySQL — `opa_svc@'%'`

```sql
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE USER, PROCESS ON *.* TO 'opa_svc'@'%';
```

The `CREATE USER` privilege allows the OPA Database Gateway to create and rotate per-session JIT credentials for end users. MySQL is **fully supported** by OPA JIT.

### PostgreSQL — `opa_svc` role

```sql
CREATE ROLE opa_svc WITH LOGIN CREATEROLE;
GRANT CONNECT ON DATABASE postgres TO opa_svc;
```

`CREATEROLE` allows the OPA Database Gateway to provision per-session JIT users. PostgreSQL is **fully supported** by OPA JIT.

### MongoDB — `opa_svc` in `admin` db

```js
roles: [
  { role: 'readWriteAnyDatabase', db: 'admin' },
  { role: 'userAdminAnyDatabase', db: 'admin' }
]
```

> **Note:** MongoDB is **NOT natively supported** for OPA JIT credential rotation as of the current OPA release. The `opa_svc` account is created for manual credential management or future OPA support. Manage MongoDB credentials out-of-band.

### OPA Database Gateway configuration

After running this script, configure OPA's Database Gateway to point to each database using the `opa_svc` credentials from the credential file. Refer to the [OPA Database Gateway documentation](https://help.okta.com/en-us/content/topics/privileged-access/pam-overview.htm) for the enrollment steps.

---

## Lab Data Seeding

When `--seed-data` is specified, the script populates each installed database engine with realistic-looking test data designed to simulate a production environment.

### What gets created

For each engine, the script generates **N databases** (controlled by `--seed-dbs`), each with:

| Item | Detail |
|------|--------|
| Database name | MySQL/PostgreSQL: `<appname>_db`; MongoDB: `<appname>_data` (e.g. `inventory_db`, `payments_data`), randomly selected from 20 app-domain names |
| Service user | Named `<appname>_svc` (e.g. `inventory_svc`) with full access on its own database |
| Data table | `lab_records` with `id`, `username`, `email`, `score`, `created_at` columns |
| Row count | Controlled by `--seed-rows` (default: 1000) |

A global **lab admin superuser** (default: `lab_admin`) is also created with full access across all three engines.

### Engines and bulk-insert methods

| Engine | Bulk insert method | Notes |
|--------|--------------------|-------|
| MySQL | Recursive CTE with `SET SESSION cte_max_recursion_depth` | Handles SEED_ROWS > 1000 |
| PostgreSQL | `generate_series()` | Single-statement, very fast |
| MongoDB | `insertMany()` in 5000-doc batches | Avoids memory pressure for large counts |

### Non-interactive (CI/pipeline) usage

```bash
sudo ./db-install.sh --non-interactive --all \
  --seed-data \
  --seed-dbs 5 \
  --seed-rows 2000 \
  --lab-admin-user ops_admin \
  --lab-admin-password 'MyS3cret!'
```

### Interactive usage

Run without `--seed-data` or `--non-interactive` to be prompted:

```
Seed databases with lab data? [y/N]:
Number of databases per engine [3]:
Number of rows/documents per database [1000]:
Lab superuser name [lab_admin]:
```

### Seeding is non-fatal

If seeding fails (e.g. due to a network timeout or out-of-disk), the script logs a warning and continues to the credential file. The core database installation is never rolled back for a seeding failure.

### Credentials

All seeded database names, usernames, and passwords are written to the credential file under the `[LAB DATA — SEEDING]` section, with ready-to-run test commands for each database.

---

## Rollback

The script maintains an in-memory LIFO rollback stack. If any installation step fails, rollback is triggered automatically and removes everything installed so far.

You can also trigger rollback manually to uninstall previously installed databases:

```bash
sudo bash db-install.sh --rollback
```

In interactive mode, you will be asked to confirm. The rollback detects which databases are installed (via `mysql`, `psql`, `mongod` on `PATH`) and removes their packages, data directories, and configuration files.

> **Note:** `--rollback` calls `detect_os()` first to determine the package manager. This ensures that OS detection succeeds and `PKG_MANAGER` is set before attempting to remove packages.

> **Warning:** `--rollback` removes data directories (`/var/lib/mysql`, `/var/lib/postgresql`, `/var/lib/mongodb`). This is **destructive and irreversible**. Ensure data is backed up before running.

---

## Examples

```bash
# Install all three databases — interactive, lab mode
sudo bash db-install.sh

# Install MySQL only — interactive
sudo bash db-install.sh --mysql

# Install PostgreSQL only — interactive
sudo bash db-install.sh --postgresql

# Install MongoDB only — interactive
sudo bash db-install.sh --mongodb

# Install all — non-interactive, lab mode, auto-generate passwords
sudo bash db-install.sh --non-interactive --all

# Install all — non-interactive, production firewall, restrict to 10.1.0.0/20
sudo bash db-install.sh --non-interactive --all --production --allowed-cidr 10.1.0.0/20

# Install MySQL + PostgreSQL — explicit passwords, custom log path
sudo bash db-install.sh --mysql --postgresql \
  --mysql-root-password 'RootPW!' \
  --pg-admin-password 'PgPW!' \
  --opa-svc-password 'OpaPW!' \
  --log-file /tmp/db-install.log

# Dry run — preview all actions without executing
sudo bash db-install.sh --dry-run --all --verbose

# Seed lab data — interactive mode (prompts for seeding details)
sudo bash db-install.sh --all

# Seed lab data — non-interactive with custom parameters
sudo bash db-install.sh --non-interactive --all \
  --seed-data --seed-dbs 5 --seed-rows 2000 \
  --lab-admin-user ops_admin --lab-admin-password 'SecurePass!'

# Syntax check only (no execution)
bash -n db-install.sh

# Rollback — uninstall all detected databases
sudo bash db-install.sh --rollback
```

---

## Changelog

### v1.3.2

- Fixed: APT package index is now refreshed (`apt-get update`) lazily — once, only when a required tool is missing — before attempting installation in `check_prerequisites()`. Prevents "Package not found" errors on fresh cloud instances (AWS EC2, Docker) where `/var/lib/apt/lists/` is empty or stale. Refresh is skipped entirely if all tools are already present.

### v1.3.1

- Fixed: mongosh `-p` CLI flag now receives the raw password (not JS-escaped); `escape_js()` is still applied inside `--eval` JS strings where single-quote escaping is required
- Fixed: `db_name` is now passed through `escape_sql()` before being used in the PostgreSQL `datname` existence check in `seed_postgresql_data()`
- Improved: Section 19 comment clarifies that PostgreSQL seeding uses TCP auth because it runs after `configure_postgresql()` has switched `pg_hba.conf` to `scram-sha-256`

### v1.3.0

- Added database seeding feature (`--seed-data`, `--seed-dbs`, `--seed-rows`, `--lab-admin-user`, `--lab-admin-password`)
- Generates production-realistic database and service-account names from a shuffled pool of 20 app-domain names (e.g. `inventory_db`, `payments_svc`)
- Creates a global lab superuser (`lab_admin`) with SUPERUSER / ALL PRIVILEGES / root access on all installed engines
- MySQL seeding: recursive CTE with `SET SESSION cte_max_recursion_depth` for configurable row counts
- PostgreSQL seeding: `generate_series()` for fast bulk inserts; all connections via TCP (`-h 127.0.0.1`) after pg_hba.conf scram-sha-256 update
- MongoDB seeding: `insertMany()` in 5000-doc batches per database
- Seeding failures are non-fatal — warns and continues, never triggers rollback
- Credentials file: new `[LAB DATA — SEEDING]` section with per-DB test commands

### v1.2.2 — 2026-05-07

**Edge case fixes**
- `check_prerequisites`: moved required-tool installation (`curl`, `openssl`, `gpg`) to run *before* the network connectivity check; on minimal base images (Docker, cloud VMs) `curl` is often absent, causing the network check to fail with `command not found` and falsely abort the script in non-interactive mode
- `determine_firewall_mode`: interactive CIDR prompt now loops with `validate_cidr` until a valid CIDR is entered; previously a typo (e.g. `10.1.0/20`) was accepted and only failed later when UFW/firewalld rejected the malformed rule

### v1.2.1 — 2026-05-07

**Polish fixes**
- `write_credentials`: added `-D` flag to `install` so custom `--cred-file` paths with missing parent directories (e.g. `-c /opt/secrets/db-credentials.txt`) are created automatically — previously, a missing parent caused the script to exit after installation with no way to recover the generated passwords
- `install_mysql`: removed redundant `mkdir -p "$TEMP_DIR"` — `main()` already creates the temp directory before any install function is called

### v1.2.0 — 2026-05-07

**Critical breaking fixes**
- **MySQL 8.4 native_password deprecation**: Removed `WITH mysql_native_password` from the `ALTER USER` SQL. MySQL 8.4 disables this plugin by default — the old command would abort with `ERROR 1524: Plugin 'mysql_native_password' is not loaded`. Root authentication now uses the MySQL 8.4 default (`caching_sha2_password`)
- **PostgreSQL auth lockout on RHEL**: Reordered `create_pg_opa_user` to run *before* `configure_postgresql` in `main()`. On RHEL-family systems the default `pg_hba.conf` has a single `local all all peer` line with no postgres-specific override; after switching to `scram-sha-256`, `sudo -u postgres psql` (peer auth) fails — the OPA user creation must happen while peer auth is still active
- **MongoDB Amazon Linux repo 404**: The MongoDB RHEL `.repo` file used `baseurl=…/yum/redhat/$releasever/…`. Amazon Linux's `$releasever` evaluates to `2` or `2023`, which are not valid paths under `/yum/redhat/`. Added `OS_ID` check to use `/yum/amazon/` for Amazon Linux 2 and 2023

**High/Medium fixes**
- **RHEL/Alma/CentOS MySQL AppStream conflict**: Added `dnf -qy module disable mysql` before the `pm_install` step in the RHEL MySQL block; without this, dnf modularity filtering either installs the OS-bundled MySQL or throws a conflict error when the Community repo is also present
- **Debian MySQL interactive hang**: Replaced the `mysql-apt-config.deb` Debconf wrapper (which spawns an interactive dialog that hangs even in `DEBIAN_FRONTEND=noninteractive`) with a direct GPG key download + `/etc/apt/sources.list.d/mysql.list` pointing to the `mysql-8.4-lts` channel
- **SUSE zypper GPG key prompt**: Added `--gpg-auto-import-keys` to all `zypper refresh` calls in the MySQL and PostgreSQL SUSE blocks; without this, zypper pauses indefinitely in non-interactive mode waiting for key-trust confirmation
- **pg_hba.conf regex trailing content**: Changed `peer$` / `ident$` to `peer\b.*` / `ident\b.*` in the sed replacements so lines with trailing whitespace or inline comments (e.g. `local  all  all  peer  # added by pg_hba.conf`) are correctly updated
- **Firewall rollback on failure**: `configure_firewall()` now pushes an undo command onto the LIFO rollback stack after enabling UFW / firewalld; if a subsequent step fails and triggers rollback, the firewall is reverted to its pre-install state

### v1.1.0 — 2026-05-07

**Security fixes**
- Fixed SQL injection: passwords are now escaped via `escape_sql()` before interpolation into MySQL and PostgreSQL SQL heredocs — a `'` in a password no longer breaks queries
- Fixed shell/JS injection: MongoDB passwords are now escaped via `escape_js()` before interpolation into `mongosh --eval` JavaScript strings
- Credential file (`write_credentials`) now returns immediately with a dry-run log entry when `--dry-run` is active — credentials are no longer written to disk during dry-run

**Dry-run bypass fixes**
- MongoDB RHEL/Alma/Amazon Linux `.repo` file creation is now guarded by a `--dry-run` check (was executing unconditionally)
- `write_credentials` is now fully skipped in dry-run mode
- Moved `run_cmd` to `install_mysql`'s temp-dir creation so `mkdir` respects dry-run

**Rollback fix (critical)**
- `detect_os()` is now called before the `--rollback` branch in `main()` — standalone `--rollback` was previously leaving `PKG_MANAGER` empty, causing `pm_remove` to silently do nothing and packages to remain installed

**Logic and correctness fixes**
- `pm_remove` (apt): changed `;` to `&&` between `apt-get purge` and `apt-get autoremove` so purge failure does not silently continue
- Network connectivity check is now non-fatal: prompts to continue in interactive mode; fails with a clear message in non-interactive mode (supports air-gapped/proxy environments)
- MySQL temp-password extraction (`/var/log/mysqld.log`) now emits a visible warning when no password is found, rather than silently connecting without one
- `pg_hba.conf` modification is now verified after `sed` — logs a warning if `scram-sha-256` is not found in the updated file
- PostgreSQL `initdb` is now guarded: skipped if the cluster is already initialised (prevents rollback on second run)
- MongoDB service start replaced fixed `sleep 3` with a 15-second active-wait loop; returns an error if the service does not become active
- `create_pg_opa_user` refactored to write SQL to a temp file instead of piping a heredoc through `|| { }` — fixes a bash heredoc-in-compound-command parsing quirk
- `systemctl enable --now` calls for MySQL, PostgreSQL, and MongoDB now have explicit error checks with `return 1` on failure

**New helpers**
- `escape_sql()` — escapes `'` → `''` for SQL string literals
- `escape_js()` — escapes `'` → `\'` for JavaScript string literals
- `validate_cidr()` — validates IPv4 CIDR format; called automatically when `--allowed-cidr` is provided
- `MONGO_SERVICE` variable added for consistency with `MYSQL_SERVICE` and `PG_SERVICE`

**Minor improvements**
- Password generation now uses `/dev/urandom` directly (`head -c 48 /dev/urandom | base64 | tr -d '+/=' | head -c 32`) for better entropy
- Test connection commands in credential file now use double-quoted passwords for correct shell interpretation
- `validate_cidr` called in `parse_args` — invalid CIDR format now exits immediately with a clear error

### v1.0.0 — 2026-05-07

- Initial release
- Supported databases: MySQL 8.x (MySQL Community repo), PostgreSQL 16.x (PGDG), MongoDB 7.x (official MongoDB repo)
- Supported OS families: Debian (apt), RHEL/Amazon Linux (dnf/yum), SUSE SLES (zypper)
- Interactive and non-interactive (`--non-interactive`) modes
- Dry-run mode (`--dry-run`) — full preview with no state changes
- LIFO rollback stack — automatic on failure, manual via `--rollback`
- Lab mode (default) — OS firewall disabled for easy troubleshooting
- Production mode (`--production`) — UFW / firewalld rules restricted to `--allowed-cidr`
- OPA service accounts: `opa_svc` created in MySQL and PostgreSQL with JIT-required grants; created in MongoDB for future use
- Credential output file at `/root/db-credentials.txt` (chmod 600) with connection strings and test commands
- Structured logging to `/var/log/db-install.log` with timestamps and log levels
- Password auto-generation via `openssl rand` (32-char); all passwords injectable via CLI flags
- MySQL security hardening: removes anonymous users, disables remote root, drops test database
- PostgreSQL: switches `pg_hba.conf` local auth from `peer`/`ident` to `scram-sha-256`
- MongoDB: creates admin user before enabling auth to avoid lock-out
- Section dividers and colour-coded terminal output; colour suppressed in CI/pipe environments
