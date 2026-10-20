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
if ($LASTEXITCODE -ne 0) { throw 'Unable to create the backend Python environment.' }
if ($IsWindows -or $env:OS -eq "Windows_NT") {
    foreach ($name in @('python.exe', 'pythonw.exe')) {
        & (Join-Path $ProjectRoot 'windows\normalise_runtime_integrity.ps1') `
            -Executable (Join-Path $VirtualEnv "Scripts\$name")
    }
}
& $BackendPython -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { throw 'Unable to update pip.' }
& $BackendPython -m pip install -e "$BackendRoot[dev]"
if ($LASTEXITCODE -ne 0) { throw 'Unable to install backend dependencies.' }
& $BackendPython -m pytest -q $BackendRoot
if ($LASTEXITCODE -ne 0) { throw 'Backend tests failed.' }

Write-Host "Backend environment ready: $BackendPython"
