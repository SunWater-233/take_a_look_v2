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

# The development interpreter can also inherit Low integrity from the checkout.
$ManagedVirtualEnv = [IO.Path]::GetFullPath((Join-Path $BackendRoot '.venv')) + [IO.Path]::DirectorySeparatorChar
if ([IO.Path]::GetFullPath($PythonExecutable).StartsWith($ManagedVirtualEnv, [StringComparison]::OrdinalIgnoreCase)) {
    & (Join-Path $ProjectRoot 'windows\normalise_runtime_integrity.ps1') -Executable $PythonExecutable
}

& $PythonExecutable -c "import sys; print('Backend Python:', sys.version.split()[0]); sys.exit(0 if sys.version_info >= (3, 11) else 1)"
if ($LASTEXITCODE -ne 0) {
    throw "Backend Python could not run or is older than 3.11: $PythonExecutable. Recreate backend/.venv with a working Python 3.11+ interpreter, then install backend[dev]."
}

# Creating a venv does not install the project's build dependencies. Check the
# build tool before downloading/preparing packs or starting the packaging work.
& $PythonExecutable -m PyInstaller --version
if ($LASTEXITCODE -ne 0) {
    throw "PyInstaller is unavailable in $PythonExecutable. Install the backend development dependencies: uv pip install --python `"$PythonExecutable`" -e `"$BackendRoot[dev]`" (or use this interpreter's -m pip install -e `"$BackendRoot[dev]`" if pip is installed)."
}

& $PythonExecutable (Join-Path $ProjectRoot 'tool\prepare_bundled_packs.py')
if ($LASTEXITCODE -ne 0) { throw 'Preparing bundled chip packs failed.' }

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
    --collect-all zeroconf `
    (Join-Path $BackendRoot "take_a_look_backend\stdio.py")
if ($LASTEXITCODE -ne 0) {
    throw "Backend packaging failed (exit $LASTEXITCODE)."
}

Copy-Item -LiteralPath (Join-Path $BackendRoot 'bundled_packs') `
    -Destination (Join-Path $DistRoot 'take_a_look_backend') -Recurse -Force
# Repeated direct builds must not retain full packs from an earlier runtime.
Get-ChildItem -LiteralPath (Join-Path $DistRoot 'take_a_look_backend\bundled_packs') -File -Filter '*.pack' |
    Where-Object { -not (Test-Path -LiteralPath (Join-Path $BackendRoot "bundled_packs\$($_.Name)")) } |
    Remove-Item -Force

& (Join-Path $ProjectRoot 'windows\normalise_runtime_integrity.ps1') `
    -Executable (Join-Path $DistRoot 'take_a_look_backend\take_a_look_backend.exe')

Write-Host "Packaged backend: $(Join-Path $DistRoot 'take_a_look_backend')"
