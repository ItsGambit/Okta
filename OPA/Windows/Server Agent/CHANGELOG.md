# Changelog

All notable changes to this deployment bundle will be documented in this file.

## [2026-04-25] Bundle v1.0
### Added
- Generic installer script: `Install-OktaOPA-ServerAgent-Generic.ps1`
- Intune-targeted installer script: `Install-OktaOPA-ServerAgent-Intune.ps1`
- SCCM-targeted installer script: `Install-OktaOPA-ServerAgent-SCCM.ps1`
- Readme files for each variant: `README-Generic.md`, `README-Intune.md`, `README-SCCM.md`
- Detection script: `Detect-OktaOPA.ps1` (supports Intune/SCCM detection exit codes)

### Changed
- MSI exit code `3010` (reboot required) is normalized to script exit code `0` (success) while logging a reboot-required warning.

### Notes
- Enrollment uses the documented Windows token file path and relies on agent auto-enroll behavior.
