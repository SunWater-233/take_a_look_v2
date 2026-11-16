<#
.SYNOPSIS
Build desktop packages through the shared Python entry point (native OS required).
.EXAMPLE
.\tool\build.ps1 -Target all -Mode release -Version 1.2.3+4
.EXAMPLE
.\tool\build.ps1 -Target windows -WindowsPackage portable -Mode debug
.EXAMPLE
.\tool\build.ps1 -CleanOnly
#>
[CmdletBinding()]
param(
  [ValidateSet('windows', 'linux', 'macos', 'all')][string]$Target = 'windows',
  [ValidateSet('release', 'debug')][string]$Mode = 'release',
  [string]$Version = '',
  [ValidateSet('all', 'msi', 'portable')][string]$WindowsPackage = 'all',
  [string]$Python = 'python',
  [string]$Flutter = 'flutter',
  [string]$VcRuntimeDirectory = '',
  [string]$Distribution = $env:TAL_WSL_DISTRO,
  [switch]$Clean,
  [switch]$CleanOnly,
  [switch]$DryRun,
  [switch]$Check,
  [switch]$SkipBuild,
  [switch]$Native,
  [switch]$KeepBuild
)
$ErrorActionPreference = 'Stop'
$arguments = @((Join-Path $PSScriptRoot 'build.py'), '--target', $Target.ToLowerInvariant(),
  '--mode', $Mode.ToLowerInvariant(), '--windows-package', $WindowsPackage.ToLowerInvariant(),
  '--python', $Python, '--flutter', $Flutter)
foreach ($entry in @(@('--version', $Version), @('--distribution', $Distribution),
                     @('--vc-runtime-directory', $VcRuntimeDirectory))) {
  if ($entry[1]) { $arguments += $entry }
}
foreach ($entry in @(@('--clean', $Clean), @('--clean-only', $CleanOnly), @('--dry-run', $DryRun),
                     @('--check', $Check), @('--skip-build', $SkipBuild), @('--native', $Native),
                     @('--keep-build', $KeepBuild))) {
  if ($entry[1]) { $arguments += $entry[0] }
}
try {
  & $Python @arguments
  exit $LASTEXITCODE
} catch {
  [Console]::Error.WriteLine("Unable to run the build entry point: $($_.Exception.Message)")
  exit 1
}
