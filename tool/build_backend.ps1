param(
    [string]$Python = ""
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BackendRoot = Join-Path $ProjectRoot "backend"
$PythonExecutable = if ($Python) {
    $Python
} else {
    Join-Path $BackendRoot ".venv\Scripts\python.exe"
}
$DistRoot = Join-Path $BackendRoot "runtime"
$WorkRoot = Join-Path $ProjectRoot "build\backend_pyinstaller"

if (-not (Test-Path -LiteralPath $PythonExecutable)) {
    throw "Backend Python was not found at $PythonExecutable. Run tool/setup_backend.ps1 first."
}

& $PythonExecutable -m PyInstaller `
    --clean `
    --noconfirm `
    --onedir `
    --name take_a_look_backend `
    --distpath $DistRoot `
    --workpath $WorkRoot `
    --specpath $WorkRoot `
    --paths $BackendRoot `
    --additional-hooks-dir (Join-Path $BackendRoot "pyinstaller_hooks") `
    --collect-all pyocd `
    --collect-all elftools `
    --collect-submodules pylink `
    (Join-Path $BackendRoot "take_a_look_backend\stdio.py")

Write-Host "Packaged backend: $(Join-Path $DistRoot 'take_a_look_backend')"
