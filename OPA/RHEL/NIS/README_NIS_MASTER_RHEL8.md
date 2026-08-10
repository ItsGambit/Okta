# RHEL 8.10 EC2 NIS Master Installer

**Version:** 1.1.4  
**Script:** `nis-master-rhel8-installer.sh`

This package installs and configures an Amazon EC2 instance running RHEL 8.x, including RHEL 8.10, as a **NIS Master server** using `ypserv`, `ypbind`, `yp-tools`, `rpcbind`, and `make`.

> Security note: NIS is a legacy service and does not provide modern transport encryption. Use it only on a trusted private VPC/subnet. Do not expose NIS/RPC ports to the Internet.

## Official Documentation References

- Red Hat Customer Portal: NIS Master/Slave and client configuration for RHEL 5, 6, 7, and 8: <https://access.redhat.com/solutions/47192>
- Red Hat Customer Portal: NIS support status for RHEL 8 and deprecation guidance: <https://access.redhat.com/solutions/5991271>
- AWS VPC Security Group rules: <https://docs.aws.amazon.com/vpc/latest/userguide/security-group-rules.html>
- AWS VPC Security Groups overview: <https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html>

## What the Script Does

The installer performs these production-oriented steps:

1. Validates that it is running as `root` on RHEL 8.x.
2. Prompts for required configuration, unless non-interactive options are provided.
3. Validates input values, including FQDN, IP address, CIDR, and ports.
4. Creates timestamped backups of files it may change.
5. Checks whether required packages are installed.
6. Installs missing packages unless `--skip-package-install` is used.
7. Configures the system hostname and `/etc/hosts` mapping.
8. Configures the NIS domain in `/etc/sysconfig/network`.
9. Pins NIS/RPC service ports to predictable values for EC2 Security Group and firewall use.
10. Writes `/var/yp/securenets` to restrict NIS access to localhost and a trusted CIDR.
11. Enables SELinux booleans required for NIS, unless skipped.
12. Opens local firewalld ports if firewalld is active, unless skipped.
13. Enables and restarts `rpcbind`, `nis-domainname`, `ypserv`, `ypxfrd`, and `yppasswdd`.
14. Initializes the NIS master maps with `ypinit -m`.
15. Runs `make -C /var/yp` to build maps.
16. Optionally configures the server as a local NIS client with `--configure-local-client`.
17. Runs post-install validation with `systemctl` and `rpcinfo`.
18. Logs all actions to `/var/log/nis-master-rhel8-installer.log`.
19. Rolls back modified configuration files if an error occurs, unless `--no-rollback` is used.

## Files Modified

The script may modify these files:

```text
/etc/hosts
/etc/sysconfig/network
/etc/sysconfig/yppasswdd
/var/yp/securenets
/etc/yp.conf                    # only with --configure-local-client
/etc/nsswitch.conf              # only with --configure-local-client
```

Backups are stored under:

```text
/var/backups/nis-master-rhel8-installer/<timestamp>/
```

## Ports Used

The script pins NIS/RPC services to these default ports:

```text
TCP/UDP 111       rpcbind
TCP/UDP 944       ypserv
TCP/UDP 945       ypxfrd
TCP/UDP 950       yppasswdd
TCP/UDP 944-951   firewalld and AWS Security Group range recommendation
```

You can override service ports with service-specific `/etc/sysconfig/ypserv`, `/etc/sysconfig/ypxfrd`, and `/etc/sysconfig/yppasswdd` files. Override service ports with:

```bash
--ypserv-port 944
--ypxfrd-port 945
--yppasswdd-port 950
```

## AWS Security Group Requirements

Because EC2 Security Groups deny inbound traffic unless explicit inbound rules exist, add inbound rules that allow only trusted NIS clients or their client Security Group.

Recommended inbound rules:

```text
TCP 111       from trusted client CIDR or client Security Group
UDP 111       from trusted client CIDR or client Security Group
TCP 944-951   from trusted client CIDR or client Security Group
UDP 944-951   from trusted client CIDR or client Security Group
```

Do not allow these ports from `0.0.0.0/0`.

## Interactive Usage

Copy the script to the RHEL 8.10 EC2 instance, then run:

```bash
chmod +x nis-master-rhel8-installer.sh
sudo ./nis-master-rhel8-installer.sh
```

The script will ask for:

```text
NIS domain
NIS master private FQDN
NIS master private IP address
Trusted client CIDR
```

Example values:

```text
NIS domain: corpnis
Master FQDN: nis-master.example.internal
Master IP: 10.0.1.10
Allowed CIDR: 10.0.0.0/16
```

## Non-Interactive Usage

For automation, pass all required values and use `--non-interactive --yes`:

```bash
sudo ./nis-master-rhel8-installer.sh \
  --non-interactive \
  --yes \
  --nis-domain corpnis \
  --master-fqdn nis-master.example.internal \
  --master-ip 10.0.1.10 \
  --allowed-cidr 10.0.0.0/16
```

You can also use environment variables:

```bash
sudo NIS_DOMAIN=corpnis \
  MASTER_FQDN=nis-master.example.internal \
  MASTER_IP=10.0.1.10 \
  ALLOWED_CIDR=10.0.0.0/16 \
  ./nis-master-rhel8-installer.sh --non-interactive --yes
```

## Dry Run

Use dry-run mode to see planned actions without changing the system:

```bash
sudo ./nis-master-rhel8-installer.sh \
  --dry-run \
  --non-interactive \
  --yes \
  --nis-domain corpnis \
  --master-fqdn nis-master.example.internal \
  --master-ip 10.0.1.10 \
  --allowed-cidr 10.0.0.0/16
```

## Optional Local Client Configuration

To make the NIS master also bind to itself as a NIS client:

```bash
sudo ./nis-master-rhel8-installer.sh \
  --non-interactive \
  --yes \
  --nis-domain corpnis \
  --master-fqdn nis-master.example.internal \
  --master-ip 10.0.1.10 \
  --allowed-cidr 10.0.0.0/16 \
  --configure-local-client
```

This updates `/etc/yp.conf` and uses `authselect select nis --force` instead of directly editing `/etc/nsswitch.conf`. RHEL 8 manages NSS/PAM configuration through authselect, so manual `sed` edits to `/etc/nsswitch.conf` are intentionally avoided.

## Rebuilding NIS Maps

After adding or changing local users, groups, or hosts that should be served through NIS, rebuild maps:

```bash
sudo make -C /var/yp
```

Example:

```bash
sudo useradd nisuser1
sudo passwd nisuser1
sudo make -C /var/yp
```

## Validation Commands

After installation, validate the server:

```bash
sudo systemctl status rpcbind nis-domainname ypserv ypxfrd yppasswdd --no-pager
rpcinfo -p localhost
ls -l /var/yp/<your-nis-domain>/
```

If configured as a local client:

```bash
ypwhich
ypcat passwd.byname
getent passwd <nis-user>
```

## Rollback Behavior

If the script encounters an error, it automatically attempts to restore modified configuration files from the timestamped backup directory.

Rollback includes configuration files and service enablement/activity state captured before installation. It does not uninstall packages, because package removal may be unsafe on production systems.

Disable rollback only when you are intentionally debugging:

```bash
--no-rollback
```

## Logging

The log file is:

```text
/var/log/nis-master-rhel8-installer.log
```

The log includes commands run, validation status, backup location, and any errors encountered.

## Script Options

```text
--nis-domain VALUE             NIS domain name, for example corpnis.
--master-fqdn VALUE            Master FQDN, for example nis-master.example.internal.
--master-ip VALUE              Private IP address of this EC2 instance.
--allowed-cidr VALUE           Trusted client CIDR, for example 10.0.0.0/16.
--ypserv-port VALUE            Fixed ypserv RPC port. Default: 944.
--ypxfrd-port VALUE            Fixed ypxfrd RPC port. Default: 945.
--yppasswdd-port VALUE         Fixed yppasswdd RPC port. Default: 950.
--configure-local-client       Configure this server to bind to itself as a NIS client.
--no-set-hostname              Do not change system hostname.
--force-init                   Re-run ypinit even when maps already exist.
--skip-firewall                Do not modify firewalld.
--skip-selinux                 Do not modify SELinux booleans.
--skip-package-install         Only validate packages. Do not install missing packages.
--skip-preflight-cleanup       Do not run systemd reset/reload cleanup before configuration.
--dry-run                      Print actions without changing the system.
--non-interactive              Do not prompt. Required values must be passed as flags or environment variables.
--yes                          Assume yes for confirmation prompts.
--no-rollback                  Do not automatically restore config backups on error.
--version                      Print version.
-h, --help                     Show help.
```

## Validation Performed Before Delivery

The script was checked with:

```bash
bash -n nis-master-rhel8-installer.sh
```

It was also reviewed for common safety issues:

- strict Bash mode via `set -Eeuo pipefail`
- traps for error handling
- rollback path for modified files
- input validation
- no infinite loops
- idempotent configuration updates where practical
- RHEL 8 authselect usage for local NIS client mode
- service-specific sysconfig files for ypserv, ypxfrd, and yppasswdd
- dry-run support
- non-interactive support
- production-style logging and comments

## Known Limitations

- The script does not automatically modify AWS Security Groups. Security Group changes should be handled through your normal AWS change process, Terraform, CloudFormation, AWS CLI, or console.
- The script does not remove packages on rollback.
- NIS is legacy and should not be exposed outside trusted networks.
- If your NIS master has existing custom `/var/yp/Makefile` changes, review them before using `--force-init`.


## Version History

### 1.1.0

- Replaced direct `/etc/nsswitch.conf` modification with `authselect select nis --force` for RHEL 8 local-client configuration.
- Moved `YPSERV_ARGS` and `YPXFRD_ARGS` from `/etc/sysconfig/network` into service-specific files:
  - `/etc/sysconfig/ypserv`
  - `/etc/sysconfig/ypxfrd`
- Kept `NISDOMAIN` in `/etc/sysconfig/network`.
- Added runtime validation that pinned `ypserv` and `ypxfrd` ports are visible through `rpcinfo`.
- Added authselect rollback capture and restore logic.


### 1.1.1

- Fixed IP-octet validation when global `IFS` is set to newline and tab by parsing the IP address with `IFS=. read -r -a octets <<< "$MASTER_IP"`.
- This corrects false failures for valid IPv4 addresses such as `10.20.138.15`.


### 1.1.2

- Added a reusable IPv4 validator and now validates both the master IP address and the CIDR IP component.
- Fixed leading-zero IPv4 arithmetic by forcing base-10 octet parsing with `10#`.
- Replaced regex-based `/etc/hosts` edits with an `awk` update that matches exact fields instead of unescaped dotted hostnames/IPs.
- Added explicit option-value validation for flags such as `--master-ip` and `--allowed-cidr`.
- Tightened `rpcinfo` pinned-port validation to match the expected RPC service name as well as the port.


### 1.1.3

- Writes `YPSERV_ARGS` and `YPXFRD_ARGS` to `/etc/sysconfig/network` as a compatibility path while still writing service-specific sysconfig files.
- Adds systemd drop-ins for `ypserv` and `ypxfrd` if the packaged unit files do not visibly consume the expected sysconfig variables.
- Accepts both `ypxfrd` and `fypxfrd` as valid RPC service names during pinned-port validation.
- Includes rollback cleanup for generated systemd drop-in files and reloads systemd after rollback.


### 1.1.4

- Added a preflight cleanup step that runs after package validation/install and before configuration changes.
- The cleanup runs `systemctl daemon-reload`, resets failed states for NIS-related services, and restarts `rpcbind` if present to clear stale RPC state from a previous failed run.
- Added `--skip-preflight-cleanup` for environments where restarting `rpcbind` must be controlled separately.
