# Okta Privileged Access Agent (PAA) — Install Script

`install-okta-paa.sh` is a bash script that automates the installation and
initial enrollment of the
[Okta Privileged Access Agent (PAA)](https://help.okta.com/pam/en-us/content/topics/pam/paa/paa-overview.htm)
on supported Linux servers.

The agent (`sftd`) is the component installed on each **target server** that
you want to bring under Okta Privileged Access Management control. Once enrolled,
the server is discoverable in the Okta PAM console and access can be managed
with just-in-time, policy-driven SSH (and optionally RDP) sessions.

---

## Contents

- [What the script does](#what-the-script-does)
- [Existing installation detection](#existing-installation-detection)
- [How the PAA differs from the PAG](#how-the-paa-differs-from-the-pag)
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
- [Image / AMI builds (preventing auto-enrollment)](#image--ami-builds-preventing-auto-enrollment)

---

## What the script does

The script performs the following steps in order:

| Step | Action |
|------|--------|
| 1 | Verifies it is running as **root** (or via `sudo`). |
| 2 | Checks for required tools (`curl`, `gpg`) and installs them if missing. |
| 3 | Detects the Linux distribution and version from `/etc/os-release`. |
| 4 | **Checks for an existing installation.** If the agent is already installed, stops the service, reports the installed version and service status, then presents an interactive menu (see [Existing installation detection](#existing-installation-detection)). |
| 5 | Adds the **official Okta/ScaleFT package repository** and imports the Okta GPG signing key. |
| 6 | Installs the **`scaleft-server-tools`** package via `apt-get` (Debian/Ubuntu) or `dnf`/`yum` (RHEL/Amazon Linux). |
| 7 | Prompts for (or accepts via `--token`) the **enrollment token** from the Okta PAM console. |
| 8 | Writes the enrollment token to `/var/lib/sftd/enrollment.token` with secure permissions (`600`, root-only). |
| 9 | Creates a minimal **`/etc/sft/sftd.yaml`** configuration file pointing to the token file (skipped if a config already exists). |
| 10 | **Enables and starts** the `sftd` systemd service. |
| 11 | Runs **post-install verification** — checks service status, confirms the token file was consumed, and reports the installed package version. |
| 12 | Prints a summary with useful diagnostic commands. |

All output is also written to **`/var/log/okta-paa-install.log`** for review.

---

## Existing installation detection

When the script detects that `scaleft-server-tools` is already installed on the
host it takes the following actions automatically:

1. **Stops** the `sftd` service.
2. **Reports** the installed version and the pre-stop service status.
3. **Presents a menu** with three choices:

```
=================================================================
  Okta Privileged Access Agent — Already Installed
=================================================================
  Installed version : 1.103.2-1
  Service status    : active (running)
  (service has been stopped)
=================================================================

  What would you like to do?

    [a]  Exit the script
         (the sftd service will remain stopped)

    [b]  Restart the agent
         (start sftd and exit)

    [c]  Uninstall and reinstall
         !! Requires a new or existing enrollment token
            from the Okta PAM console (Resources > Servers)

  Enter choice [a/b/c]:
```

### Menu options

| Option | What it does |
|---|---|
| **[a] Exit** | Quits the script. The `sftd` service remains stopped. You can restart it manually with `systemctl start sftd`. |
| **[b] Restart** | Starts the `sftd` service, prints a status confirmation, and exits. Use this to recover a stopped or failed agent without reinstalling. |
| **[c] Reinstall** | Shows a detailed warning, asks you to type `yes` to confirm, then: purges the package, removes `/etc/sft/sftd.yaml` and any stale token file, and runs a full fresh installation (repo setup → package install → enrollment → service start). **Requires an enrollment token.** |

### Enrollment token for reinstall

Choosing **[c]** will de-enroll the server from Okta PAM as part of the
package removal. You must supply an enrollment token for re-enrollment:

- **New token** — generate one from **Resources → Servers → Enroll Server**
  in the Okta PAM console.
- **Existing token** — you may reuse an enrollment token that was previously
  issued for this server, provided it has not already been consumed by a
  prior successful enrollment.

### Non-interactive sessions

If the script is run without a terminal (e.g. piped, run via `sudo` in a
CI pipeline with no TTY), and an existing installation is found, the script
**exits cleanly with status 0** rather than blocking on input. A warning is
logged to `/var/log/okta-paa-install.log`. Run the script interactively to
use the management menu.

---

## How the PAA differs from the PAG

| Component | Package | Service | Role |
|---|---|---|---|
| **Privileged Access Agent (PAA)** | `scaleft-server-tools` | `sftd` | Installed on **each target server** to enable managed access |
| **Privileged Access Gateway (PAG)** | `scaleft-gateway` | `sft-gatewayd` | Optional network proxy for servers not directly reachable by clients |

In a typical deployment you install the **PAA on every server** you want to
manage. The **PAG** is only required when clients cannot connect directly to
those servers (e.g., servers inside a private network).

---

## Supported distributions

| Distribution | Supported versions |
|---|---|
| Ubuntu | 16.04 (Xenial), 18.04 (Bionic), 20.04 (Focal), 22.04 (Jammy), 24.04 (Noble) |
| Debian | 10 (Buster), 11 (Bullseye), 12 (Bookworm) |
| RHEL | 8, 9 |
| AlmaLinux | 8, 9 |
| Rocky Linux | 8, 9 |
| Amazon Linux | 2, 2023 |

---

## Prerequisites

- The target server must run one of the supported Linux distributions above.
- The script must be run as **root** or via **`sudo`**.
- The server requires **outbound internet access** to:
  - `dist.scaleft.com` — to download the package and repository GPG key.
  - Okta PAM cloud services — for agent enrollment and ongoing operation.
- **`curl`** and **`gpg`** are required. The script installs them automatically
  if missing.
- **systemd** must be the init system (`systemctl` must be present).

---

## Getting an enrollment token

An enrollment token is a single-use secret that registers the server with your
Okta PAM tenant.

1. Log in to the **Okta Admin Console**.
2. Navigate to **Resources** → **Servers**.
3. Click **Enroll Server** (or **Add Server**).
4. Select your **Project** and copy the displayed **enrollment token**.

> The token is consumed and automatically deleted by `sftd` after successful
> enrollment. If you need to re-enroll, generate a new token.

---

## Usage

### 1. Transfer the script to the target Linux server

```bash
scp install-okta-paa.sh user@your-linux-server:~
```

### 2. Make it executable

```bash
chmod +x install-okta-paa.sh
```

### 3. Run the script

**Interactive** — the script will prompt you to paste the enrollment token:

```bash
sudo ./install-okta-paa.sh
```

**Non-interactive** — supply the token via `--token` (suitable for CI/CD,
Terraform, Ansible, or other automation tools):

```bash
sudo ./install-okta-paa.sh --token "YOUR_ENROLLMENT_TOKEN_HERE"
```

---

## Options

| Flag | Short | Description |
|---|---|---|
| `--token TOKEN` | `-t` | Enrollment token. Skips the interactive prompt. |
| `--verbose` | `-v` | Prints debug-level messages to the console (all levels always go to the log file). |
| `--dry-run` | `-n` | Shows every action that *would* be taken without making any system changes. |
| `--help` | `-h` | Prints usage information and exits. |

---

## Examples

```bash
# Interactive install — script prompts for the enrollment token
sudo ./install-okta-paa.sh

# Non-interactive install (Ansible, Terraform, CI/CD)
sudo ./install-okta-paa.sh --token "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9..."

# Verbose + non-interactive (useful for debugging during first deployment)
sudo ./install-okta-paa.sh --token "eyJ..." --verbose

# Dry-run — preview all actions without touching the system
sudo ./install-okta-paa.sh --token "placeholder" --dry-run

# Show help
./install-okta-paa.sh --help
```

---

## What happens after the script runs

After the script completes successfully:

1. **`sftd` is running** and enabled to start automatically on every reboot.
2. On startup, `sftd` reads `/var/lib/sftd/enrollment.token`, contacts Okta PAM
   to enroll the server, and **deletes the token file** once enrollment succeeds.
3. The enrolled server will appear in the Okta PAM console under
   **Resources → Servers** with an *Active* or *Enrolled* status.
4. You can then assign users/groups to the server via **Projects** in the
   Okta PAM console and enforce policy-based access.

### Checking enrollment status

```bash
# View service status
systemctl status sftd

# Stream live service logs
journalctl -u sftd -f

# View recent service logs (last 50 lines)
journalctl -u sftd -n 50 --no-pager

# Confirm the token file was consumed (enrollment complete)
ls -la /var/lib/sftd/enrollment.token
# File should NOT exist after successful enrollment
```

---

## File locations

| Path | Description |
|---|---|
| `/etc/sft/sftd.yaml` | Agent configuration file |
| `/etc/sft/sftd.sample.yaml` | Full sample config with all options (installed with package, if present) |
| `/var/lib/sftd/enrollment.token` | One-time enrollment token (deleted after enrollment) |
| `/var/lib/sftd/` | Agent runtime data directory |
| `/var/log/okta-paa-install.log` | Installation script log |
| `/etc/apt/sources.list.d/oktapam-stable.list` | APT repository entry (Debian/Ubuntu only) |
| `/usr/share/keyrings/oktapam-2023-archive-keyring.gpg` | Okta GPG signing key (Debian/Ubuntu only) |
| `/etc/yum.repos.d/oktapam-stable.repo` | YUM/DNF repository file (RHEL/Amazon Linux only) |

---

## Troubleshooting

### Service fails to start

```bash
# Check detailed status
systemctl status sftd --no-pager

# Check the systemd journal
journalctl -u sftd -n 100 --no-pager

# Check the install log
cat /var/log/okta-paa-install.log
```

### Server not appearing in Okta PAM console after enrollment

- Verify the server has outbound connectivity to Okta PAM services.
- Check whether the enrollment token was valid:
  ```bash
  # If the file still exists, enrollment did not complete
  ls -la /var/lib/sftd/enrollment.token
  ```
- Confirm `sftd` is running and check its logs:
  ```bash
  journalctl -u sftd -n 50 --no-pager
  ```
- Generate a new enrollment token from **Resources → Servers → Enroll Server**
  and re-run the script:
  ```bash
  sudo ./install-okta-paa.sh --token "NEW_ENROLLMENT_TOKEN"
  ```

### GPG key or repository import fails

Verify outbound connectivity to `dist.scaleft.com` on port 443:

```bash
curl -v https://dist.scaleft.com/GPG-KEY-OktaPAM-2023
```

### Package installation fails

Run with `--verbose` and examine both the console and the log file:

```bash
sudo ./install-okta-paa.sh --token "YOUR_TOKEN" --verbose 2>&1 | tee /tmp/paa-debug.log
```

### Config file already exists warning

If you re-run the script, the script will **not overwrite** an existing
`/etc/sft/sftd.yaml` to protect any customisations. Manually verify it
contains the correct token file path:

```bash
grep EnrollmentTokenFile /etc/sft/sftd.yaml
# Expected output:
# EnrollmentTokenFile: /var/lib/sftd/enrollment.token
```

---

## Uninstalling

To remove the Okta PAA from a server:

**Debian / Ubuntu:**

```bash
sudo systemctl stop sftd
sudo systemctl disable sftd
sudo apt-get remove --purge scaleft-server-tools
sudo rm -f /etc/apt/sources.list.d/oktapam-stable.list
sudo rm -f /usr/share/keyrings/oktapam-2023-archive-keyring.gpg
sudo apt-get update
```

**RHEL / Amazon Linux:**

```bash
sudo systemctl stop sftd
sudo systemctl disable sftd
sudo dnf remove scaleft-server-tools   # or: sudo yum remove scaleft-server-tools
sudo rm -f /etc/yum.repos.d/oktapam-stable.repo
```

> After uninstalling the agent, remember to also remove the server from the
> Okta PAM console under **Resources → Servers**.

---

## Image / AMI builds (preventing auto-enrollment)

When baking a server image (AWS AMI, Azure image, etc.) you typically want to
install the agent **without enrolling** it — each instance launched from the
image should enroll individually using its own token.

To prevent `sftd` from auto-enrolling on first boot during image creation:

```bash
# Create the disable-autostart flag file before starting the service
sudo mkdir -p /etc/sftd
sudo touch /etc/sftd/disable-autostart

# Install and configure normally, but the service will NOT enroll on this boot
sudo ./install-okta-paa.sh --token "placeholder-not-used"

# After the image is baked, provision each instance with its own token at
# cloud-init / user-data time, and remove the flag file so sftd enrolls:
sudo rm -f /etc/sftd/disable-autostart
sudo systemctl restart sftd
```

---

## Reference

- [Okta Privileged Access Agent Overview](https://help.okta.com/pam/en-us/content/topics/pam/paa/paa-overview.htm)
- [Okta PAM Documentation](https://help.okta.com/pam/en-us/content/topics/pam/)
- [Okta Privileged Access product page](https://www.okta.com/products/privileged-access/)
