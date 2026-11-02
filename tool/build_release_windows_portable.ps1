<#
.SYNOPSIS
Build a self-contained Windows x64 portable ZIP release.
.EXAMPLE
.\tool\build_release_windows_portable.ps1
.EXAMPLE
.\tool\build_release_windows_portable.ps1 -Version 1.2.3+4
#>
[CmdletBinding()]
param(
  [string]$Python = 'python',
  [string]$Flutter = 'flutter',
  [string]$VcRuntimeDirectory = '',
  [switch]$SkipBuild,
  [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(?:\+[0-9]+)?$')]
  [string]$Version = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectDirectory = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$workDirectory = Join-Path $projectDirectory 'build\windows_portable'
$sourceDirectory = Join-Path $workDirectory 'source'
$stageDirectory = Join-Path $workDirectory 'stage\Take-A-Look-V2'
$releaseDirectory = Join-Path $projectDirectory 'build\releases'
$logDirectory = Join-Path $projectDirectory 'build\logs'
$oldRollForward = $env:DOTNET_ROLL_FORWARD
$transcribing = $false

function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
  $null = Get-Command $Executable -CommandType Application -ErrorAction Stop
  $previousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & $Executable @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
    $exitCode = $LASTEXITCODE
  } finally { $ErrorActionPreference = $previousPreference }
  if ($exitCode -ne 0) { throw "$Executable failed (exit $exitCode)." }
}

function Reset-WorkDirectory([string]$Path) {
  $resolved = [IO.Path]::GetFullPath($Path)
  $allowed = [IO.Path]::GetFullPath($workDirectory) + [IO.Path]::DirectorySeparatorChar
  if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean outside the portable build directory: $resolved"
  }
  if (Test-Path -LiteralPath $resolved) {
    if ((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "Refusing to clean a linked build root: $resolved"
    }
    $entries = @((Get-Item -LiteralPath $resolved)) + @(Get-ChildItem -LiteralPath $resolved -Recurse -Force)
    if ($entries | Where-Object { $_.Name -eq 'recordings' -or $_.Extension -eq '.talraw' }) {
      throw "Recordings were found in the portable build directory. Move them to a safe location first: $resolved"
    }
    foreach ($link in $entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) {
      $linkPath = [IO.Path]::GetFullPath($link.FullName)
      if (-not $linkPath.StartsWith($resolved + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to unlink outside the generated directory: $linkPath"
      }
      if ($link.PSIsContainer) { [IO.Directory]::Delete($linkPath) }
      else { [IO.File]::Delete($linkPath) }
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
  New-Item -ItemType Directory -Path $resolved -Force | Out-Null
}

function Find-VcRuntime {
  if ($VcRuntimeDirectory) { return (Resolve-Path -LiteralPath $VcRuntimeDirectory).Path }
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path -LiteralPath $vswhere)) {
    throw 'Visual Studio C++ tools were not found. Install Desktop development with C++, or pass -VcRuntimeDirectory.'
  }
  $installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  if ($LASTEXITCODE -ne 0 -or -not $installation) { throw 'Visual Studio C++ tools were not found.' }
  $versionFile = Join-Path $installation 'VC\Auxiliary\Build\Microsoft.VCRedistVersion.default.txt'
  $redistVersion = (Get-Content -LiteralPath $versionFile -Raw).Trim()
  $redistRoot = Join-Path $installation "VC\Redist\MSVC\$redistVersion\x64"
  $crt = @(Get-ChildItem -LiteralPath $redistRoot -Directory -Filter 'Microsoft.VC*.CRT')
  if ($crt.Count -ne 1) { throw "Cannot find the x64 C++ redistributable. Pass -VcRuntimeDirectory. Searched: $redistRoot" }
  return $crt[0].FullName
}

function Copy-Payload([string]$Source, [string]$Destination) {
  New-Item -ItemType Directory -Path $Destination -Force | Out-Null
  foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
    if ($item.Name -in @('recordings', '__pycache__', '.venv') -or
        $item.Extension -in @('.talraw', '.pdb', '.ilk', '.exp', '.lib', '.pyc', '.log')) { continue }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "The portable payload must not contain links: $($item.FullName)"
    }
    $destinationPath = Join-Path $Destination $item.Name
    if ($item.PSIsContainer) { Copy-Payload $item.FullName $destinationPath }
    else { Copy-Item -LiteralPath $item.FullName -Destination $destinationPath }
  }
}

function Get-FileHashHex([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

try {
  if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
  if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -and $env:PROCESSOR_ARCHITEW6432 -ne 'AMD64') {
    throw 'This packaging script requires an x64 Windows build host.'
  }
  foreach ($directory in @($workDirectory, $releaseDirectory, $logDirectory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  $logPath = Join-Path $logDirectory ('windows-portable-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
  Start-Transcript -LiteralPath $logPath | Out-Null
  $transcribing = $true
  $pubspec = Get-Content -LiteralPath (Join-Path $projectDirectory 'pubspec.yaml') -Raw
  $versionText = if ($Version) { $Version } else {
    $sourceMatch = [regex]::Match($pubspec, '(?m)^version:\s*([^\r\n]+)\s*$')
    if (-not $sourceMatch.Success) { '' } else { $sourceMatch.Groups[1].Value.Trim() }
  }
  $match = [regex]::Match($versionText, '^(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$')
  if (-not $match.Success) { throw 'Version must use major.minor.patch[+build].' }
  $releaseVersion = '{0}.{1}.{2}' -f $match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value
  $buildNumber = if ($match.Groups[4].Success) { $match.Groups[4].Value } else { '0' }
  $fullVersion = "$releaseVersion+$buildNumber"
  $crtDirectory = Find-VcRuntime
  foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $crtDirectory $dll))) { throw "Missing C++ runtime: $dll" }
  }

  $builtBundle = Join-Path $sourceDirectory 'build\windows\x64\runner\Release'
  $buildStamp = Join-Path $workDirectory 'application-version.txt'
  if (-not $SkipBuild) {
    $flutterCommand = @(Get-Command $Flutter -CommandType Application -ErrorAction Stop)[0].Source
    $backendPython = Join-Path $projectDirectory 'backend\.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $backendPython)) {
      Invoke-Checked 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $PSScriptRoot 'setup_backend.ps1'), '-Python', $Python)
    }
    Write-Host 'Copying current workspace sources into the isolated portable build directory...'
    $inputs = & git -C $projectDirectory -c core.quotepath=false ls-files --cached --others --exclude-standard -- lib assets plugins windows backend pubspec.yaml pubspec.lock analysis_options.yaml .metadata
    if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate source files. Build from a Git checkout.' }
    foreach ($folder in @('lib', 'assets', 'plugins', 'windows', 'backend')) {
      Reset-WorkDirectory (Join-Path $sourceDirectory $folder)
    }
    foreach ($relative in $inputs) {
      $inputPath = Join-Path $projectDirectory $relative
      if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) { continue }
      $outputPath = Join-Path $sourceDirectory $relative
      New-Item -ItemType Directory -Path (Split-Path -Parent $outputPath) -Force | Out-Null
      Copy-Item -LiteralPath $inputPath -Destination $outputPath -Force
    }
    $isolatedPubspecPath = Join-Path $sourceDirectory 'pubspec.yaml'
    $isolatedPubspec = Get-Content -LiteralPath $isolatedPubspecPath -Raw
    $versionRegex = [regex]::new('(?m)^version:\s*[^\r\n]+')
    $updatedPubspec = $versionRegex.Replace($isolatedPubspec, "version: $fullVersion", 1)
    if ($updatedPubspec -eq $isolatedPubspec) { throw 'The isolated pubspec.yaml does not contain a version field.' }
    [IO.File]::WriteAllText($isolatedPubspecPath, $updatedPubspec, [Text.UTF8Encoding]::new($false))
    Write-Host "Building portable application version $fullVersion."

    if (Test-Path -LiteralPath $buildStamp) { Remove-Item -LiteralPath $buildStamp }
    Invoke-Checked 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
      (Join-Path $PSScriptRoot 'build_backend.ps1'), '-Python', $backendPython,
      '-OutputDirectory', (Join-Path $sourceDirectory 'backend\runtime'),
      '-WorkDirectory', (Join-Path $workDirectory 'backend_pyinstaller'))
    Reset-WorkDirectory $builtBundle
    Push-Location $sourceDirectory
    try {
      Invoke-Checked $flutterCommand @('pub', 'get')
      Invoke-Checked $flutterCommand @('build', 'windows', '--release', '--no-pub')
    } finally { Pop-Location }
    Set-Content -LiteralPath $buildStamp -Value $fullVersion -Encoding ascii
  } elseif (-not (Test-Path -LiteralPath $buildStamp) -or (Get-Content -LiteralPath $buildStamp -Raw).Trim() -ne $fullVersion) {
    throw '-SkipBuild requires a successful portable application build with the requested version.'
  }

  Reset-WorkDirectory (Join-Path $workDirectory 'stage')
  Copy-Payload $builtBundle $stageDirectory
  Get-ChildItem -LiteralPath $crtDirectory -File -Filter '*.dll' | Copy-Item -Destination $stageDirectory -Force
  foreach ($required in @('take_a_look_v2.exe', 'flutter_windows.dll', 'data\app.so', 'data\icudtl.dat',
                         'backend\pyproject.toml', 'backend\runtime\take_a_look_backend\take_a_look_backend.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $stageDirectory $required))) { throw "Missing portable payload: $required" }
  }
  $exeVersion = (Get-Item -LiteralPath (Join-Path $stageDirectory 'take_a_look_v2.exe')).VersionInfo
  $expectedFileVersion = "$releaseVersion.$buildNumber"
  $actualFileVersion = '{0}.{1}.{2}.{3}' -f $exeVersion.FileMajorPart, $exeVersion.FileMinorPart, $exeVersion.FileBuildPart, $exeVersion.FilePrivatePart
  if ($actualFileVersion -ne $expectedFileVersion) { throw "Application EXE version $actualFileVersion does not match $expectedFileVersion. Run a full build." }
  Write-Host 'Checking the packaged Python runtime (offline, without opening a probe)...'
  Invoke-Checked (Join-Path $stageDirectory 'backend\runtime\take_a_look_backend\take_a_look_backend.exe') @('--self-test')
  Set-Content -LiteralPath (Join-Path $stageDirectory 'PORTABLE-README.txt') -Encoding utf8 -Value @'
Take A Look V2 for Windows x64

Extract this ZIP to a writable folder and run take_a_look_v2.exe.
Keep the entire folder together. Sampling recordings are saved in the recordings
folder beside the executable and remain there when the application is moved.
The package includes the Visual C++ runtime and a self-contained Python backend.
'@
  Set-Content -LiteralPath (Join-Path $stageDirectory '.take-a-look-package') -Value 'Take A Look V2 portable package' -Encoding ascii

  $packageName = "Take-A-Look-V2-$fullVersion-windows-x64-portable.zip"
  $temporaryArchive = Join-Path $workDirectory $packageName
  $archivePath = Join-Path $releaseDirectory $packageName
  if (Test-Path -LiteralPath $temporaryArchive) { Remove-Item -LiteralPath $temporaryArchive -Force }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::CreateFromDirectory($stageDirectory, $temporaryArchive, [IO.Compression.CompressionLevel]::Optimal, $false)

  $expectedFiles = @(Get-ChildItem -LiteralPath $stageDirectory -Recurse -File -Force)
  $zip = [IO.Compression.ZipFile]::OpenRead($temporaryArchive)
  try {
    $entries = @($zip.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) })
    if ($entries.Count -ne $expectedFiles.Count) { throw "ZIP verification failed: expected $($expectedFiles.Count) files, found $($entries.Count)." }
    $entriesByPath = @{}
    foreach ($entry in $entries) { $entriesByPath[$entry.FullName.Replace('\', '/')] = $entry }
    foreach ($file in $expectedFiles) {
      $relative = $file.FullName.Substring($stageDirectory.Length + 1).Replace('\', '/')
      $entry = $entriesByPath[$relative]
      if ($null -eq $entry) { throw "ZIP is missing $relative" }
      $stream = $entry.Open()
      $sha = [Security.Cryptography.SHA256]::Create()
      try { $entryHash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
      finally { $stream.Dispose(); $sha.Dispose() }
      if ($entryHash -ne (Get-FileHashHex $file.FullName)) { throw "ZIP content verification failed: $relative" }
    }
    if (($entriesByPath.Keys -join "`n") -match '(^|/)recordings(/|$)|\.talraw$') { throw 'Portable ZIP unexpectedly contains acquisition recordings.' }
  } finally { $zip.Dispose() }

  Copy-Item -LiteralPath $temporaryArchive -Destination $archivePath -Force
  $archiveHash = Get-FileHashHex $archivePath
  Set-Content -LiteralPath "$archivePath.sha256" -Value "$archiveHash  $packageName" -Encoding ascii
  Write-Host "Portable ZIP: $archivePath"
  Write-Host "SHA-256: $archivePath.sha256"
  Write-Host "Build log: $logPath"
} catch {
  Write-Host "Windows portable build failed: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host $_.ScriptStackTrace
  exit 1
} finally {
  $env:DOTNET_ROLL_FORWARD = $oldRollForward
  if ($transcribing) { Stop-Transcript | Out-Null }
}
