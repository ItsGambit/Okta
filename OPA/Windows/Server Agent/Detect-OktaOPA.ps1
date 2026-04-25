<#
.SYNOPSIS
  Detection script for Okta Privileged Access (OPA) / ScaleFT Server Tools on Windows Server.

.DESCRIPTION
  Checks whether ScaleFT/OPA Server Tools are installed by:
   1) Looking for an installed product in HKLM uninstall registry keys
   2) Checking that the 'sftd' service exists (optional)

  Supports both Intune and SCCM detection behaviors.

.PARAMETER Mode
  Intune  - Exit 0 if detected, exit 1 if not detected (Intune requirement)
  SCCM    - Exit 0 if detected, exit 1 if not detected (common SCCM script detection)

.PARAMETER Strong
  If set, requires BOTH registry match AND 'sftd' service existence.
  If not set, registry match alone is sufficient.

.PARAMETER MinVersion
  Optional minimum version required (e.g. 1.103.2). If installed version is lower, treat as not detected.

.EXAMPLE
  .\Detect-OktaOPA.ps1 -Mode Intune -Strong

.EXAMPLE
  .\Detect-OktaOPA.ps1 -Mode SCCM -MinVersion 1.103.2

.NOTES
  - Avoids Win32_Product.
#>

[CmdletBinding()]
param(
  [ValidateSet('Intune','SCCM')]
  [string]$Mode = 'Intune',

  [switch]$Strong,

  [string]$MinVersion
)

$ErrorActionPreference = 'SilentlyContinue'

function Get-InstalledScaleFTServerTools {
  $paths = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )

  foreach ($p in $paths) {
    Get-ItemProperty $p |
      Where-Object {
        $_.DisplayName -match 'ScaleFT-Server-Tools|ScaleFT Server Tools|Okta Privileged Access|Advanced Server Access'
      } |
      Select-Object -First 1 -Property DisplayName, DisplayVersion
  }
}

$installed = Get-InstalledScaleFTServerTools
$svc = Get-Service -Name 'sftd'

$detected = $false

if ($installed) {
  if ($MinVersion) {
    try {
      $installedVer = [version]$installed.DisplayVersion
      $minVer = [version]$MinVersion
      if ($installedVer -lt $minVer) {
        $detected = $false
      } else {
        $detected = $true
      }
    } catch {
      # If version parsing fails, fall back to presence-based detection
      $detected = $true
    }
  } else {
    $detected = $true
  }
}

if ($Strong) {
  $detected = $detected -and [bool]$svc
}

if ($detected) {
  Write-Output "DETECTED: $($installed.DisplayName) v$($installed.DisplayVersion)" 
  exit 0
}

Write-Output 'NOT DETECTED'
exit 1
