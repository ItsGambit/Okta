# Okta Privileged Access Gateway (PAG) — Install Script

`install-okta-pag.sh` is a bash script that automates the installation and
initial configuration of the
[Okta Privileged Access Gateway (PAG)](https://help.okta.com/pam/en-us/content/topics/pam/pag/pag-install.htm)
on supported Linux distributions.

---

## Contents

- [What the script does](#what-the-script-does)
- [Supported distributions](#supported-distributions)
- [Prerequisites](#prerequisites)
- [Getting an enrollment token](#getting-an-enrollment-token)
- [Usage](#usage)
- [Options](#options)
- [Examples](#examples)
- [What happens after the script runs](#what-happens-after-the-script-runs)
- [File locations](#file-locations)
- [Troubleshooting](#troubleshooting)
- [Uninstalling](#uninstalling)

---

## What the script does

The script performs the following steps in order:

| Step | Action |
|------|--------|
| 1 | Verifies it is running as **root** (or via `sudo`). |
| 2 | Checks for required tools (`curl`, `gpg`) and installs them if missing. |
| 3 | Detects the Linux distribution and version. |
| 4 | Adds the **official Okta package repository** and imports the Okta GPG signing key. |
| 5 | Installs the **`scaleft-gateway`** package via `apt-get` (Debian/Ubuntu) or `dnf`/`yum` (RHEL/Amazon Linux). |
| 6 | Prompts for (or accepts via `--token`) the **enrollment token** obtained from the Okta PAM console. |
| 7 | Writes the enrollment token to `/var/lib/sft-gatewayd/setup.token` with secure permissions (`640`, owned `root:sft-gatewayd`). |
| 8 | Creates a minimal **`/etc/sft/sft-gatewayd.yaml`** configuration file pointing to the token file (skipped if the file already exists). |
| 9 | **Enables and starts** the `sft-gatewayd` systemd service. |
| 10 | Runs **post-install verification** — checks service status, confirms the token file was consumed, and reports the installed package version. |
| 11 | Prints a summary with useful diagnostic commands. |

All output is also written to **`/var/log/okta-pag-install.log`** for post-run review.

---

## Supported distributions

| Distribution | Supported versions |
|---|---|
| Ubuntu | 16.04 (Xenial), 18.04 (Bionic), 20.04 (Focal), 22.04 (Jammy), 24.04 (Noble) |
| Debian | 11 (Bullseye), 12 (Bookworm) |
| RHEL | 8, 9 |
| AlmaLinux | 8, 9 |
| Rocky Linux | 8, 9 |
| Amazon Linux | 2, 2023 |

> **RDP sessions:** Only Ubuntu 20.04/22.04 and RHEL 8/9 are supported for
> RDP gateway connections. All distributions listed above support SSH.

---

## Prerequisites

- The target Linux host must be running one of the supported distributions above.
- The script must be run as **root** or via **`sudo`**.
- The host requires **outbound internet access** to:
  - `dist.scaleft.com` — to download the package and repository GPG key.
  - Okta PAM cloud services — for gateway enrollment and operation.
- **`curl`** and **`gpg`** are required. The script will attempt to install them
  automatically if they are missing.
- **systemd** must be the init system (`systemctl` must be available).

---

## Getting an enrollment token

The enrollment token is a one-time secret that registers this gateway with your
Okta tenant. To obtain one:

1. Log in to the **Okta Admin Console**.
2. Go to **Infrastructure** → **Gateways**.
3. Click **Create Gateway**.
4. Copy the displayed **enrollment token** — you will need it during installation.

> The token is consumed and deleted by the service after successful enrollment.
> If you need to re-enrol, generate a new token from the console.

---

## Usage

### 1. Transfer the script to your Linux host

```bash
scp install-okta-pag.sh user@your-linux-host:~
```

### 2. Make it executable

```bash
chmod +x install-okta-pag.sh
```

### 3. Run the script

**Interactive** — the script will prompt you to paste the enrollment token:

```bash
sudo ./install-okta-pag.sh
```

**Non-interactive** — supply the token via `--token` (suitable for CI/CD or
automated provisioning):

```bash
sudo ./install-okta-pag.sh --token "YOUR_ENROLLMENT_TOKEN_HERE"
```

---

## Options

| Flag | Short | Description |
|---|---|---|
| `--token TOKEN` | `-t` | Enrollment token. Skips the interactive prompt. |
| `--verbose` | `-v` | Prints debug-level messages to the console (all levels always go to the log file). |
| `--dry-run` | `-n` | Shows every action that *would* be taken without making any changes to the system. |
| `--help` | `-h` | Prints usage information and exits. |

---

## Examples

```bash
# Interactive install — script prompts for token
sudo ./install-okta-pag.sh

# Non-interactive install (automation / CI)
sudo ./install-okta-pag.sh --token "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9..."

# Verbose output + non-interactive
sudo ./install-okta-pag.sh --token "eyJ..." --verbose

# Dry-run to preview all steps without making changes
sudo ./install-okta-pag.sh --token "placeholder" --dry-run

# Show help
./install-okta-pag.sh --help
```

---

## What happens after the script runs

After the script completes successfully:

1. **`sft-gatewayd` is running** and enabled to start automatically on reboot.
2. The service reads the enrollment token file, contacts Okta to register the
   gateway, and **deletes the token file** once enrollment succeeds.
3. The enrolled gateway will appear in the Okta PAM console under
   **Infrastructure → Gateways** with an *Active* status.
4. You can then assign the gateway to projects and configure access policies
   in the Okta PAM console.

### Checking enrollment status

```bash
# View service status
systemctl status sft-gatewayd

# Stream live service logs
journalctl -u sft-gatewayd -f

# View recent service logs (last 50 lines)
journalctl -u sft-gatewayd -n 50 --no-pager

# Confirm the token file was removed (enrollment complete)
ls -la /var/lib/sft-gatewayd/setup.token
```

---

## File locations

| Path | Description |
|---|---|
| `/etc/sft/sft-gatewayd.yaml` | Gateway configuration file |
| `/etc/sft/sft-gatewayd.sample.yaml` | Full sample config with all options (installed by package) |
| `/var/lib/sft-gatewayd/setup.token` | Enrollment token (deleted after enrollment) |
| `/var/log/okta-pag-install.log` | Installation script log |
| `/etc/apt/sources.list.d/oktapam-stable.list` | APT repo entry (Debian/Ubuntu only) |
| `/usr/share/keyrings/oktapam-2023-archive-keyring.gpg` | Okta GPG key (Debian/Ubuntu only) |
| `/etc/yum.repos.d/oktapam-stable.repo` | YUM/DNF repo file (RHEL/Amazon Linux only) |

---

## Troubleshooting

### Service fails to start

```bash
# Check detailed service status
systemctl status sft-gatewayd --no-pager

# Check the systemd journal for errors
journalctl -u sft-gatewayd -n 100 --no-pager

# Check the install log
cat /var/log/okta-pag-install.log
```

### Enrollment fails / gateway not appearing in console

- Verify the host has outbound connectivity to Okta PAM services.
- Confirm the enrollment token is valid and has not already been used or expired.
  Generate a new one from **Infrastructure → Gateways → Create Gateway**.
- Re-run the script with a new token (it will skip re-creating the config file
  but will overwrite the token file):

  ```bash
  sudo ./install-okta-pag.sh --token "NEW_ENROLLMENT_TOKEN"
  ```

- Check if the token file still exists:
  ```bash
  ls -la /var/lib/sft-gatewayd/setup.token
  ```
  If it is still present after the service starts, enrollment has not yet
  completed. Check connectivity and service logs.

### GPG key import fails

Ensure the host can reach `dist.scaleft.com` on port 443:

```bash
curl -v https://dist.scaleft.com/GPG-KEY-OktaPAM-2023
```

### Package installation fails

Run the script with `--verbose` to see detailed output, and inspect the log:

```bash
sudo ./install-okta-pag.sh --token "YOUR_TOKEN" --verbose 2>&1 | tee /tmp/pag-debug.log
```

### Config file already exists warning

If you re-run the script and the config file already exists, the script will
**not overwrite it** (to avoid losing customisations). Manually verify that
`/etc/sft/sft-gatewayd.yaml` contains the correct `SetupTokenFile` path:

```bash
grep SetupTokenFile /etc/sft/sft-gatewayd.yaml
# Expected output:
# SetupTokenFile: /var/lib/sft-gatewayd/setup.token
```

---

## Uninstalling

To remove the Okta PAG from a host:

**Debian / Ubuntu:**

```bash
sudo systemctl stop sft-gatewayd
sudo systemctl disable sft-gatewayd
sudo apt-get remove --purge scaleft-gateway
sudo rm -f /etc/apt/sources.list.d/oktapam-stable.list
sudo rm -f /usr/share/keyrings/oktapam-2023-archive-keyring.gpg
sudo apt-get update
```

**RHEL / Amazon Linux:**

```bash
sudo systemctl stop sft-gatewayd
sudo systemctl disable sft-gatewayd
sudo dnf remove scaleft-gateway   # or: sudo yum remove scaleft-gateway
sudo rm -f /etc/yum.repos.d/oktapam-stable.repo
```

> After uninstalling, remember to also decommission the gateway in the Okta PAM
> console under **Infrastructure → Gateways**.

---

## Reference

- [Okta PAG Overview](https://help.okta.com/pam/en-us/content/topics/pam/pag/pag-overview.htm)
- [Okta PAG Installation Guide](https://help.okta.com/pam/en-us/content/topics/pam/pag/pag-install.htm)
- [Okta PAG Configuration Reference](https://help.okta.com/pam/en-us/content/topics/pam/pag/pag-install.htm)
