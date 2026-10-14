<#
.SYNOPSIS
Build the Linux Release package in WSL.
.DESCRIPTION
Uses the prepared Debian 11 build environment by default. Outputs are written
to build/releases and logs to build/logs. Native uses the WSL host toolchain.
.EXAMPLE
.\tool\build_release_wsl.ps1
.EXAMPLE
.\tool\build_release_wsl.ps1 -Distribution Ubuntu-24.04 -Check
.EXAMPLE
.\tool\build_release_wsl.ps1 -KeepBuild
#>
[CmdletBinding()]
param(
  [string]$Distribution = $env:TAL_WSL_DISTRO,
  [switch]$Check,
  [switch]$Native,
  [switch]$KeepBuild
)

$ErrorActionPreference = 'Stop'

try {
  $wsl = @(Get-Command wsl.exe -CommandType Application -ErrorAction Stop)[0]
  $projectDirectory = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
  $wslArguments = @()
  if ($Distribution) {
    $wslArguments += @('--distribution', $Distribution)
  }
  # Pass arguments directly; never interpolate paths into a shell command.
  $wslArguments += @('--cd', $projectDirectory, '--exec', 'bash', 'tool/build_release_wsl.sh')
  if ($Check) { $wslArguments += '--check' }
  if ($Native) { $wslArguments += '--native' }
  if ($KeepBuild) { $wslArguments += '--keep-build' }
  & $wsl.Source @wslArguments
  exit $LASTEXITCODE
} catch {
  [Console]::Error.WriteLine("Unable to start the WSL release build: $($_.Exception.Message)")
  exit 1
}
