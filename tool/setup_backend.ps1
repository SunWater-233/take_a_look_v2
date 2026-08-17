param(
    [string]$Python = "python"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BackendRoot = Join-Path $ProjectRoot "backend"
$VirtualEnv = Join-Path $BackendRoot ".venv"
$BackendPython = if ($IsWindows -or $env:OS -eq "Windows_NT") {
    Join-Path $VirtualEnv "Scripts\python.exe"
} else {
    Join-Path $VirtualEnv "bin/python"
}

& $Python -m venv $VirtualEnv
& $BackendPython -m pip install --upgrade pip
& $BackendPython -m pip install -e "$BackendRoot[dev]"
& $BackendPython -m pytest -q $BackendRoot

Write-Host "Backend environment ready: $BackendPython"
