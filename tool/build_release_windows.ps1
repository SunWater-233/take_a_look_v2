<# Compatibility entry point; new builds should use tool/build.ps1. #>
[CmdletBinding()]
param(
  [string]$Python = 'python',
  [string]$Flutter = 'flutter',
  [string]$VcRuntimeDirectory = '',
  [switch]$SkipBuild,
  [string]$Version = '',
  [ValidateSet('release', 'debug')][string]$Mode = 'release'
)
& (Join-Path $PSScriptRoot 'build.ps1') -Target windows -WindowsPackage msi @PSBoundParameters
