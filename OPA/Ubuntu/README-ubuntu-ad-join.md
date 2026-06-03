# Ubuntu 24.04.x LTS to Windows Server 2025 Active Directory Domain Join

**Version:** 1.1.3  
**Release date:** 2026-06-02

This package contains `join-ubuntu-to-ad.sh`, a Bash script that joins an Ubuntu 24.04.x LTS server to a Windows Active Directory domain using `realmd` and SSSD.

## Download from GitHub

```bash
cd /tmp
curl -fsSLo join-ubuntu-to-ad.sh https://raw.githubusercontent.com/ItsGambit/Okta/main/OPA/Ubuntu/join-ubuntu-to-ad.sh
chmod +x join-ubuntu-to-ad.sh
./join-ubuntu-to-ad.sh --version
sudo ./join-ubuntu-to-ad.sh --help
```

Alternative with `wget`:

```bash
cd /tmp
wget -O join-ubuntu-to-ad.sh https://raw.githubusercontent.com/ItsGambit/Okta/main/OPA/Ubuntu/join-ubuntu-to-ad.sh
chmod +x join-ubuntu-to-ad.sh
./join-ubuntu-to-ad.sh --version
sudo ./join-ubuntu-to-ad.sh --help
```

## Versioning

Current release: **1.1.3**  
Release date: **2026-06-02**

```bash
./join-ubuntu-to-ad.sh --version
```

## Changelog

### 1.1.3 - 2026-06-02

- Made AD user prompts clearer: username and username@domain are both accepted.
- Added smart user qualification to avoid creating `username@domain@domain` during validation.
- Join user lookup and optional test-user lookup now normalize only when needed.

### 1.1.2 - 2026-06-02

- Fixed optional `--test-user` validation so failure to resolve the test user no longer triggers rollback after a successful domain join.
- Improved `RUN:` logging so commands appear on one line.

### 1.1.1 - 2026-06-02

- Normalized the AD password pipe to use `printf '%s\n' "$AD_PASSWORD"`.

## Username format guidance

For both the AD join user and optional test user, the script accepts either format:

```text
username
username@domain.example.com
```

The script detects whether `@domain` is already present. It only appends the domain when needed, so it will not create invalid values like:

```text
username@domain.example.com@domain.example.com
```

If `realm list` shows `login-formats: %U@domain`, fully qualified names such as `username@domain.example.com` are usually the safest choice for validation.

## What it does

- Verifies the host is Ubuntu 24.04.x and running as root, except `--help` and `--version`, which work as a non-root user.
- Prompts for required values, or accepts switches for non-interactive automation.
- Updates the package index, optionally performs `apt full-upgrade`, and installs required AD/SSSD packages.
- Installs `chrony` for Kerberos-friendly time synchronization.
- Optionally sets the host FQDN and AD DNS servers.
- Waits for `systemd-resolved` to initialize after DNS changes.
- Joins the domain with `realm join` using adcli, with Samba fallback in auto mode.
- Enables automatic home directory creation for AD users.
- Performs post-join validation with `realm list`, `getent`, and optional non-fatal `id <test-user>`.
- Logs to `/var/log/ubuntu-ad-join.log`.
- Creates backups under `/var/backups/ubuntu-ad-join/` and can rollback on setup errors.
- Protects AD passwords from `set -x` tracing when `--verbose` is used.

## Non-interactive example

```bash
sudo ./join-ubuntu-to-ad.sh   --non-interactive   --domain corp.example.com   --user 'join_account@corp.example.com'   --password-file /root/ad_join_password.txt   --dns 10.0.0.10,10.0.0.11   --hostname ubuntu01.corp.example.com   --membership-software auto   --test-user 'someuser@corp.example.com'   --verbose
```

## Troubleshooting

```bash
sudo less /var/log/ubuntu-ad-join.log
sudo systemctl status sssd --no-pager
sudo journalctl -u sssd -n 200 --no-pager
realm list
```

## Security notes

- Prefer a delegated AD join account instead of Domain Administrator.
- If using `--password-file`, store it with mode `600`, owned by root, and delete it after joining if no longer needed.
- The script disables shell tracing around password reads and password piping, even when `--verbose` is enabled.
