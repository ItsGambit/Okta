<#
.SYNOPSIS
  Install latest Okta Privileged Access (OPA) / ScaleFT Server Tools (sftd) on Windows Server.

.DESCRIPTION
  - Discovers and downloads the latest MSI from Okta’s official Windows server-tools repo.
  - Installs with basic UI (/qb) when interactive; fully silent (/qn) when non-interactive.
  - Enrolls server by writing the enrollment token to the documented token file path.
  - Validates service presence and attempts start.
  - Logs everything (script log + MSI log).
  - Rollback: if install fails, uninstall via registry uninstall info and remove staged files.

.VERSION
  1.1.2
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  # Enrollment token (required in non-interactive mode)
  [Parameter(Mandatory = $false)]
  [string]$EnrollmentToken,

  # Choose stable vs preview repo channel
  [ValidateSet("Stable", "Preview")]
  [string]$Channel = "Stable",

  # Force non-interactive behavior (no prompts; uses /qn)
  [switch]$NonInteractive,

  # Optional: pin a specific version like "1.103.2" (otherwise latest)
  [string]$Version,

  # Optional: extra msiexec switches (e.g. "/norestart")
  [string[]]$MsiSwitches = @("/norestart"),

  # Optional: MSI properties (Hashtable expanded to KEY=VALUE)
  [hashtable]$MsiProperties = @{}
)

#region Constants & Paths -------------------------------------------------------

$ScriptVersion = "1.1.2"

# Official Okta/ScaleFT dist root (server-tools repo)
$RepoBase  = "https://dist.scaleft.com/repos/windows"
$Arch      = "amd64"
$RepoName  = if ($Channel -eq "Stable") { "stable" } else { "preview" }
$RepoUrl   = "$RepoBase/$RepoName/$Arch/server-tools"

# Enrollment token path on Windows (documented)
$ScaleftRoot         = "C:\Windows\System32\config\systemprofile\AppData\Local\scaleft"
$EnrollmentTokenFile = Join-Path $ScaleftRoot "enrollment.token"

# Logging locations
$WorkRoot  = "C:\ProgramData\Okta\OPA"
$LogRoot   = Join-Path $WorkRoot "logs"
$DlRoot    = Join-Path $WorkRoot "downloads"
$ScriptLog = Join-Path $LogRoot "install.log"
$MsiLog    = Join-Path $LogRoot "msi.log"

$ErrorActionPreference = "Stop"

#endregion Constants & Paths ----------------------------------------------------

#region Logging ----------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $LogRoot, $DlRoot | Out-Null

function Write-Log {
  param(
    [string]$Message,
    [ValidateSet("INFO","WARN","ERROR")]
    [string]$Level = "INFO"
  )
  $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
  Add-Content -Path $ScriptLog -Value $line
}

# Start transcript (best effort)
try {
  Start-Transcript -Path (Join-Path $LogRoot "transcript.log") -Append | Out-Null
} catch { }

#endregion Logging --------------------------------------------------------------

#region Preflight ---------------------------------------------------------------

Write-Log "Starting OPA Server Agent install script v$ScriptVersion"
Write-Log "Channel: $Channel | NonInteractive: $NonInteractive | Version Pin: $Version"

# Admin check
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Log "Must run as Administrator." "ERROR"
  throw "Administrator privileges required."
}

# Server OS and DC checks
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem

Write-Log "Detected OS: $($os.Caption) ($($os.Version))"

# ProductType: 1=Workstation, 2=Domain Controller, 3=Server
if ($os.ProductType -eq 1) {
  Write-Log "This script is intended for Windows Server. Detected workstation." "ERROR"
  throw "Unsupported OS (workstation)."
}

# DomainRole: 4=Backup DC, 5=Primary DC
if ($cs.DomainRole -in 4,5) {
  Write-Log "Domain Controller detected. Server agent is not supported on DCs." "ERROR"
  throw "Unsupported role (Domain Controller)."
}

# Enrollment token handling
$isInteractive = [Environment]::UserInteractive -and -not $NonInteractive

if (-not $EnrollmentToken) {
  if (-not $isInteractive) {
    Write-Log "Non-interactive mode requires -EnrollmentToken." "ERROR"
    throw "EnrollmentToken required in non-interactive mode."
  }

  # Prompt securely; token must be written plaintext to the token file for enrollment
  $secure = Read-Host "Enter Okta OPA Server Enrollment Token" -AsSecureString
  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { $EnrollmentToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }

  if (-not $EnrollmentToken) {
    Write-Log "No enrollment token provided." "ERROR"
    throw "EnrollmentToken not provided."
  }
}

#endregion Preflight ------------------------------------------------------------

#region Helper: Detect Installed Agent (Registry) -------------------------------

function Get-InstalledScaleFTServerTools {
  # Searches both 64-bit and Wow6432Node uninstall keys
  $paths = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
  )

  foreach ($p in $paths) {
    Get-ItemProperty $p -ErrorAction SilentlyContinue |
      Where-Object {
        $_.DisplayName -match "ScaleFT-Server-Tools|ScaleFT Server Tools|Okta Privileged Access|Advanced Server Access"
      } |
      Select-Object DisplayName, DisplayVersion, PSChildName, UninstallString, QuietUninstallString
  }
}

#endregion Helper ---------------------------------------------------------------

#region Helper: Discover Latest Version ----------------------------------------

function Get-LatestServerToolsVersion {
  param([string]$IndexUrl)

  # Repo has directories like v1.103.2/
  $html = (Invoke-WebRequest -Uri "$IndexUrl/" -UseBasicParsing).Content

  $matches = [regex]::Matches($html, 'href="v(?<ver>\d+\.\d+\.\d+)/"')
  if ($matches.Count -lt 1) { throw "No versions found at $IndexUrl" }

  $versions = $matches | ForEach-Object { [version]$_.Groups["ver"].Value }
  return ($versions | Sort-Object -Descending | Select-Object -First 1).ToString()
}

#endregion Helper ---------------------------------------------------------------

#region Helper: Safe Uninstall --------------------------------------------------

function Invoke-SafeUninstall {
  param(
    [Parameter(Mandatory=$true)]
    [psobject]$InstalledProduct
  )

  # Prefer QuietUninstallString when provided by the installer
  $quiet = $InstalledProduct.QuietUninstallString
  $unins = $InstalledProduct.UninstallString

  if ($quiet) {
    Write-Log "Rollback: running QuietUninstallString" "WARN"
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c $quiet" -Wait -NoNewWindow
    return
  }

  # If UninstallString contains an MSI product code GUID, use msiexec /x safely
  if ($unins) {
    $m = [regex]::Match($unins, '{[0-9A-Fa-f-]{36}}')
    if ($m.Success) {
      $guid = $m.Value
      Write-Log "Rollback: running msiexec /x $guid" "WARN"
      $args = "/x $guid /qn /norestart /l*v `"$MsiLog`""
      Start-Process -FilePath "msiexec.exe" -ArgumentList $args -Wait -NoNewWindow
      return
    }

    # Fallback: execute uninstall string as-is
    Write-Log "Rollback: executing UninstallString as-is (fallback)" "WARN"
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c $unins" -Wait -NoNewWindow
    return
  }

  Write-Log "Rollback: no uninstall command found in registry." "WARN"
}

#endregion Helper ---------------------------------------------------------------

#region Download MSI ------------------------------------------------------------

$targetVersion = if ($Version) { $Version } else { Get-LatestServerToolsVersion -IndexUrl $RepoUrl }
Write-Log "Selected server-tools version: $targetVersion"

$versionDir = "v$targetVersion"
$msiName    = "ScaleFT-Server-Tools-$targetVersion.msi"
$msiUrl     = "$RepoUrl/$versionDir/$msiName"
$msiPath    = Join-Path $DlRoot $msiName

Write-Log "MSI URL: $msiUrl"
Write-Log "Download path: $msiPath"

if (-not (Test-Path $msiPath)) {
  Write-Log "Downloading MSI..."
  Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
} else {
  Write-Log "MSI already present; skipping download."
}

# Authenticode check (best effort)
try {
  $sig = Get-AuthenticodeSignature -FilePath $msiPath
  Write-Log "MSI signature status: $($sig.Status)"
  if ($sig.Status -ne "Valid") {
    Write-Log "WARNING: MSI signature not valid: $($sig.Status)" "WARN"
  }
} catch {
  Write-Log "Unable to validate MSI signature: $_" "WARN"
}

#endregion Download MSI ---------------------------------------------------------

#region Idempotency: Already Installed? -----------------------------------------

$installed = Get-InstalledScaleFTServerTools | Select-Object -First 1
if ($installed) {
  Write-Log "Server tools already installed: $($installed.DisplayName) v$($installed.DisplayVersion). Exiting."
  exit 0
}

#endregion Idempotency ----------------------------------------------------------

#region Enrollment Token File ---------------------------------------------------

New-Item -ItemType Directory -Force -Path $ScaleftRoot | Out-Null

Write-Log "Writing enrollment token file to $EnrollmentTokenFile"
Set-Content -Path $EnrollmentTokenFile -Value $EnrollmentToken -Encoding ASCII -Force

#endregion Enrollment Token File ------------------------------------------------

#region Install + Rollback ------------------------------------------------------

$rollbackNeeded = $false
$installedAfter = $null
$rebootRequired = $false

try {
  # UI behavior: /qb when interactive, /qn when non-interactive
  $uiSwitch = if ($isInteractive) { "/qb" } else { "/qn" }

  # Build msiexec properties
  $props = @()
  foreach ($k in $MsiProperties.Keys) {
    $props += ("{0}={1}" -f $k, $MsiProperties[$k])
  }

  # Build msiexec argument list
  $msiArgs = @(
    "/i `"$msiPath`"",
    $uiSwitch,
    "/l*v `"$MsiLog`""
  ) + $MsiSwitches + $props

  $msiArgsLine = $msiArgs -join " "
  Write-Log "Executing: msiexec.exe $msiArgsLine"

  if ($PSCmdlet.ShouldProcess("msiexec.exe", "Install ScaleFT Server Tools $targetVersion")) {
    $p = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgsLine -Wait -PassThru -NoNewWindow
    Write-Log "MSI exit code: $($p.ExitCode)"

    switch ($p.ExitCode) {
      0 { }
      3010 {
        $rebootRequired = $true
        Write-Log "MSI returned 3010 (reboot required). Normalizing to success; reboot will be required." "WARN"
      }
      default {
        throw "MSI installation failed with exit code $($p.ExitCode). See $MsiLog"
      }
    }

    $rollbackNeeded = $true

    # Validate install via registry
    $installedAfter = Get-InstalledScaleFTServerTools | Select-Object -First 1
    if (-not $installedAfter) {
      throw "Install completed but product not found in uninstall registry keys."
    }

    Write-Log "Installed: $($installedAfter.DisplayName) v$($installedAfter.DisplayVersion)"
  }

  # Start the agent service (sftd)
  $svc = Get-Service -Name "sftd" -ErrorAction SilentlyContinue
  if (-not $svc) {
    Write-Log "Service 'sftd' not found after install." "ERROR"
    throw "Service validation failed."
  }

  if ($svc.Status -ne "Running") {
    Write-Log "Starting service sftd"
    Start-Service -Name "sftd"
  }

  if ($rebootRequired) {
    Write-Log "Installation succeeded but a reboot is required (per MSI 3010)." "WARN"
  }

  Write-Log "Install successful. Agent will auto-enroll using token file; token file is removed after enrollment by the agent."
  exit 0
}
catch {
  Write-Log "ERROR: $_" "ERROR"

  try {
    $candidate = $installedAfter
    if (-not $candidate) { $candidate = Get-InstalledScaleFTServerTools | Select-Object -First 1 }

    if ($rollbackNeeded -and $candidate) {
      Write-Log "Attempting rollback uninstall of: $($candidate.DisplayName) v$($candidate.DisplayVersion)" "WARN"
      Invoke-SafeUninstall -InstalledProduct $candidate
      Write-Log "Rollback uninstall attempted."
    }
  } catch {
    Write-Log "Rollback encountered an error: $_" "ERROR"
  }

  # Cleanup token file (security hygiene)
  try {
    if (Test-Path $EnrollmentTokenFile) {
      Remove-Item -Path $EnrollmentTokenFile -Force
      Write-Log "Removed enrollment token file after failure."
    }
  } catch {
    Write-Log "Could not remove token file: $_" "WARN"
  }

  exit 1
}
finally {
  try { Stop-Transcript | Out-Null } catch { }
}

#endregion Install + Rollback ---------------------------------------------------
