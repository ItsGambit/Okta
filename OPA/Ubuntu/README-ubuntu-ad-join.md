# Ubuntu 24.04.x LTS to Windows Server 2025 Active Directory Domain Join

**Version:** 1.1.1  
**Release date:** 2026-06-02

This package contains `join-ubuntu-to-ad.sh`, a Bash script that joins an Ubuntu 24.04.x LTS server to a Windows Active Directory domain using `realmd` and SSSD.

## Download from GitHub

If the server has internet access, download the raw script directly from GitHub. This keeps the filename as `join-ubuntu-to-ad.sh`:

```bash
cd /tmp
curl -fsSLo join-ubuntu-to-ad.sh https://raw.githubusercontent.com/ItsGambit/Okta/main/OPA/Ubuntu/join-ubuntu-to-ad.sh
chmod +x join-ubuntu-to-ad.sh
./join-ubuntu-to-ad.sh --version
sudo ./join-ubuntu-to-ad.sh --help
```

Alternative with `wget`, also keeping the same filename:

```bash
cd /tmp
wget -O join-ubuntu-to-ad.sh https://raw.githubusercontent.com/ItsGambit/Okta/main/OPA/Ubuntu/join-ubuntu-to-ad.sh
chmod +x join-ubuntu-to-ad.sh
./join-ubuntu-to-ad.sh --version
sudo ./join-ubuntu-to-ad.sh --help
```

> Do not use the normal GitHub `blob` URL with `curl` for execution. Use the `raw.githubusercontent.com` URL above.

## Versioning

Current release: **1.1.1**  
Release date: **2026-06-02**

Check the downloaded script version without root privileges:

```bash
./join-ubuntu-to-ad.sh --version
```

The script also writes its version at startup and on the success log line in `/var/log/ubuntu-ad-join.log`.

## Changelog

### 1.1.1 - 2026-06-02

- Applied the formatting patch directly to the script.
- Normalized the AD password pipe to use `printf '%s\n' "$AD_PASSWORD"` instead of a literal newline inside the format string.
- Kept the file names unchanged: `join-ubuntu-to-ad.sh` and `README-ubuntu-ad-join.md`.

### 1.1.0 - 2026-06-02

- Added script and README versioning.
- Added `--version` / `-V` support.
- Retained password tracing protection, safer rollback, and DNS restart wait logic.

## What it does

- Verifies the host is Ubuntu 24.04.x and running as root, except `--help` and `--version`, which work as a non-root user.
- Prompts for required values, or accepts switches for non-interactive automation.
- Updates the package index, optionally performs `apt full-upgrade`, and installs required AD/SSSD packages.
- Installs `chrony` for Kerberos-friendly time synchronization. On Ubuntu this can disable `systemd-timesyncd`, which is expected behavior.
- Optionally sets the host FQDN.
- Optionally persists AD DNS servers through a `systemd-resolved` drop-in.
- Waits for `systemd-resolved` to initialize after DNS changes before preflight checks.
- Checks DNS SRV discovery, `realm discover`, and time sync status before joining.
- Joins the domain with `realm join`.
- Uses `--membership-software auto` by default: tries `adcli`, then falls back to Samba if needed.
- Enables automatic home directory creation for AD users.
- Performs post-join validation with `realm list`, `getent`, and optional `id <test-user>`.
- Logs verbosely to `/var/log/ubuntu-ad-join.log`.
- Creates backups under `/var/backups/ubuntu-ad-join/` and can rollback on error.
- Protects AD passwords from `set -x` tracing when `--verbose` is used.

## Why the Samba fallback exists

Most Ubuntu + AD joins work with `realmd`, `adcli`, and SSSD. Some Windows Server 2025 domain configurations have been reported to fail during the computer-account password set step when using `adcli`; using `realm join --membership-software=samba` is a practical fallback. The script defaults to `auto` so it tries the standard `adcli` path first, then Samba.

## Files

- `join-ubuntu-to-ad.sh` — the script.
- `README-ubuntu-ad-join.md` — this documentation.

## Requirements

- Ubuntu Server 24.04.x LTS.
- Root/sudo access on the Ubuntu server.
- Network connectivity to domain controllers.
- Ubuntu DNS must be able to resolve the AD domain and `_ldap._tcp.<domain>` SRV records.
- Time synchronization within Kerberos tolerance.
- An AD account delegated to join computers to the domain.

## Install and run

```bash
chmod +x join-ubuntu-to-ad.sh
sudo ./join-ubuntu-to-ad.sh
```

## Non-interactive example

Create a root-readable password file:

```bash
sudo install -m 600 /dev/null /root/ad_join_password.txt
sudo nano /root/ad_join_password.txt
```

Run:

```bash
sudo ./join-ubuntu-to-ad.sh   --non-interactive   --domain corp.example.com   --user join_account   --password-file /root/ad_join_password.txt   --dns 10.0.0.10,10.0.0.11   --hostname ubuntu01.corp.example.com   --computer-ou 'OU=Linux,OU=Servers,DC=corp,DC=example,DC=com'   --membership-software auto   --test-user 'someuser@corp.example.com'   --verbose
```

## Important switches

```text
--domain DOMAIN                 AD DNS domain, e.g. corp.example.com.
--realm REALM                   Kerberos realm; defaults to uppercase domain.
--user USER                     AD account allowed to join computers.
--password-file FILE            File containing the AD password.
--computer-ou OU                Optional destination OU distinguished name.
--hostname FQDN                 Optional hostname/FQDN to set before join.
--dns IP[,IP]                   Optional AD DNS servers to persist.
--test-user USER                Optional AD user for validation.
--membership-software auto|adcli|samba
--short-names                   Allows `user` instead of `user@domain` where appropriate.
--no-update                     Skip `apt full-upgrade`.
--rollback                      Leave the domain and restore latest backup.
--non-interactive               Do not prompt.
--verbose                       Echo non-sensitive command output and log more detail.
--version                       Show script version. Does not require root.
```

## Rollback

Automatic rollback is enabled by default if the script fails after backup creation. Manual rollback:

```bash
sudo ./join-ubuntu-to-ad.sh --domain corp.example.com --rollback
```

Rollback attempts to:

1. Run `realm leave`.
2. Restore backed up configuration files from `/var/backups/ubuntu-ad-join/latest`.
3. Remove only the DNS drop-in file created by the script: `/etc/systemd/resolved.conf.d/90-ad-domain-join.conf`.
4. Overlay the backed-up `resolved.conf.d` contents instead of deleting the entire directory.
5. Restart affected services.

## Validation performed

The script checks:

- Ubuntu release is 24.04.x.
- Required packages install successfully.
- DNS resolves the domain.
- `_ldap._tcp.<domain>` SRV records exist.
- `realm discover <domain>` succeeds.
- `realm list` reports `configured: kerberos-member`.
- Optional `id <test-user>` succeeds.

## Troubleshooting

View the log:

```bash
sudo less /var/log/ubuntu-ad-join.log
```

Common issues:

- **DNS failure:** ensure the Ubuntu server uses AD-integrated DNS.
- **Kerberos errors:** verify time sync with `chronyc tracking` and DC reachability.
- **Join fails with Windows Server 2025:** rerun with `--membership-software samba`.
- **Users do not resolve:** check `sssd` status and logs:

```bash
sudo systemctl status sssd
sudo journalctl -u sssd -n 200 --no-pager
realm list
```

## Security notes

- Prefer a delegated AD join account instead of Domain Administrator.
- If using `--password-file`, store it with mode `600`, owned by root, and delete it after joining if no longer needed.
- The script disables shell tracing around password reads and password piping, even when `--verbose` is enabled.
- The script log is created mode `600`; do not paste logs publicly without redacting domain/user details.
