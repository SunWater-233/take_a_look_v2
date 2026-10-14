param(
    [string]$Python = "",
    [string]$OutputDirectory = "",
    [string]$WorkDirectory = ""
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BackendRoot = Join-Path $ProjectRoot "backend"
$PythonExecutable = if ($Python) {
    $Python
} else {
    Join-Path $BackendRoot ".venv\Scripts\python.exe"
}
$DistRoot = if ($OutputDirectory) { $OutputDirectory } else { Join-Path $BackendRoot "runtime" }
$WorkRoot = if ($WorkDirectory) { $WorkDirectory } else { Join-Path $ProjectRoot "build\backend_pyinstaller" }

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
    --collect-all cmsis_pack_manager `
    --collect-all elftools `
    --collect-submodules pylink `
    (Join-Path $BackendRoot "take_a_look_backend\stdio.py")
if ($LASTEXITCODE -ne 0) {
    throw "Backend packaging failed (exit $LASTEXITCODE)."
}

Write-Host "Packaged backend: $(Join-Path $DistRoot 'take_a_look_backend')"
