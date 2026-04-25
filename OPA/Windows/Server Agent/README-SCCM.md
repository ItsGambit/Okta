# Install-OktaOPA-ServerAgent-SCCM.ps1

## Overview
This **SCCM-targeted** PowerShell script installs the **Okta Privileged Access (OPA) / ScaleFT Server Tools** (server agent service `sftd`) on **Windows Server** by downloading the **latest version** from Okta’s official Windows `server-tools` repository.

**Key capabilities**
- Downloads latest **Stable** or **Preview** server-tools MSI from Okta’s official distribution host (`dist.scaleft.com`).
- Uses **/qb** (basic progress UI) when interactive; uses **/qn** (silent) when non-interactive.
- Enrolls the server by writing the enrollment token to the **documented token file path**.
- Creates verbose logs (script log + MSI log) for production troubleshooting.
- Idempotent: exits success if already installed.
- Rollback: attempts uninstall if install/validation fails.

## Requirements
- PowerShell 5.1+
- Local Administrator permissions
- Network access to `dist.scaleft.com`
- Windows Server (the server agent is **not supported on Microsoft Active Directory domain controllers** per Okta docs)

## Enrollment Token Handling
Okta’s documented token enrollment flow for servers requires saving the enrollment token to a file at the Windows token path:

`C:\Windows\System32\config\systemprofile\AppData\Local\scaleft\enrollment.token`

The server agent reads this file on startup to enroll, and the token file is deleted after successful enrollment.

### Interactive mode
If you do not pass `-EnrollmentToken`, the script prompts for it.

### Non-interactive mode
You **must** pass the token via `-EnrollmentToken` and include `-NonInteractive`.

## Usage

### Interactive install (basic UI)
```powershell
.\Install-OktaOPA-ServerAgent.ps1
```

### Non-interactive install (silent)
```powershell
.\Install-OktaOPA-ServerAgent.ps1 -NonInteractive -EnrollmentToken "<TOKEN>"
```

### Preview channel
```powershell
.\Install-OktaOPA-ServerAgent.ps1 -Channel Preview
```

### Pin a specific version
```powershell
.\Install-OktaOPA-ServerAgent.ps1 -Version "1.103.2" -NonInteractive -EnrollmentToken "<TOKEN>"
```

### Pass additional native msiexec switches
Example (recommended):
```powershell
.\Install-OktaOPA-ServerAgent.ps1 -MsiSwitches "/norestart"
```

> Note: The script automatically chooses `/qb` (interactive) or `/qn` (non-interactive). Avoid passing UI switches manually.

## Logs
Logs are written to:

`C:\ProgramData\Okta\OPA\logs`

- `install.log` — script execution log
- `msi.log` — verbose MSI log (`/l*v`)
- `transcript.log` — PowerShell transcript (best effort)

## Return Codes
### Script exit codes
- `0` = Success (installed OR already installed)
- `1` = Failure (rollback attempted)

### MSI exit codes
- `0` = Success
- `3010` = Success, reboot required

**Normalization behavior:** If the MSI returns **3010**, the script logs **"reboot required"** and still returns **exit 0** (success).

## SCCM / Intune Detection Rules
Use detection rules to confirm installation.

### Recommended strong detection
**(1) Registry** shows installed product AND **(2) service** exists.

#### Registry detection
Check these uninstall registry locations:
- `HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\*`
- `HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*`

Match `DisplayName` containing one of:
- `ScaleFT-Server-Tools` (primary)
- `ScaleFT Server Tools`, `Okta Privileged Access`, `Advanced Server Access` (fallback)

#### Service detection
Service name: `sftd`

### Intune detection script (registry + service)
Intune expects: **exit 0 = detected**, **exit 1 = not detected**.

```powershell
$paths = @(
  "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
  "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

$installed = foreach ($p in $paths) {
  Get-ItemProperty $p -ErrorAction SilentlyContinue |
    Where-Object {
      $_.DisplayName -match "ScaleFT-Server-Tools|ScaleFT Server Tools|Advanced Server Access|Okta Privileged Access"
    } | Select-Object -First 1
}

$svc = Get-Service -Name "sftd" -ErrorAction SilentlyContinue

if ($installed -and $svc) { exit 0 } else { exit 1 }
```

## What is a Pester test suite (and why you might want one)?
**Pester** is PowerShell’s testing framework.

A **Pester test suite** for this script would validate the logic **without actually installing anything**, by mocking:
- `Invoke-WebRequest` (no network required)
- registry reads (`Get-ItemProperty`) (no real product required)
- `Start-Process` (msiexec is not run)

It can automatically verify:
- version parsing (select highest version from `vX.Y.Z/` repo index)
- download URL construction (stable/preview + version)
- uninstall detection logic (registry pattern matching)

This is useful before mass rollouts to reduce surprises.

## Official documentation references
- Windows server agent install example (`msiexec /qb /i ...`)
  - https://help.okta.com/asa/en-us/content/topics/adv_server_access/docs/sftd-windows.htm
  - https://help.okta.com/en-us/content/topics/privileged-access/tool-setup/pam-sftd-windows.htm
- Server enrollment token file path (Windows) and enrollment workflow
  - https://help.okta.com/oie/en-us/content/topics/privileged-access/server-agent/pam-create-server-enrollment-token.htm
- Server agent configuration, AutoEnroll defaults, token file behavior, and Windows file paths
  - https://help.okta.com/asa/en-us/Content/Topics/Adv_Server_Access/docs/sftd-configure.htm


## SCCM packaging notes
- Run as SYSTEM (recommended).
- Provide the enrollment token via task sequence (machine env var `OKTA_OPA_ENROLLMENT_TOKEN`) or pass `-EnrollmentToken`.
- Script also writes to STDOUT so you can collect logs via SCCM execution history.
