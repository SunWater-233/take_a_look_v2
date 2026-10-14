<#
.SYNOPSIS
Build the Windows x64 application and a self-contained, per-user MSI.
.EXAMPLE
.\tool\build_release_windows.ps1
.EXAMPLE
.\tool\build_release_windows.ps1 -SkipBuild
#>
[CmdletBinding()]
param(
  [string]$Python = 'python',
  [string]$Flutter = 'flutter',
  [string]$VcRuntimeDirectory = '',
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectDirectory = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$workDirectory = Join-Path $projectDirectory 'build\windows_msi'
$sourceDirectory = Join-Path $workDirectory 'source'
$stageDirectory = Join-Path $workDirectory 'stage'
$releaseDirectory = Join-Path $projectDirectory 'build\releases'
$logDirectory = Join-Path $projectDirectory 'build\logs'
$wixVersion = '5.0.2'
$toolDirectory = Join-Path $projectDirectory "build\tools\wix-$wixVersion"
$wix = Join-Path $toolDirectory 'wix.exe'
$oldRollForward = $env:DOTNET_ROLL_FORWARD
$transcribing = $false

function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
  $null = Get-Command $Executable -CommandType Application -ErrorAction Stop
  $previousPreference = $ErrorActionPreference
  try {
    # Native stderr is diagnostic output, not a PowerShell exception. Render both
    # streams through the host so Windows PowerShell transcripts capture them.
    $ErrorActionPreference = 'Continue'
    & $Executable @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
    $exitCode = $LASTEXITCODE
  } finally { $ErrorActionPreference = $previousPreference }
  if ($exitCode -ne 0) {
    throw "$Executable failed (exit $exitCode)."
  }
}

function Reset-WorkDirectory([string]$Path) {
  $resolved = [IO.Path]::GetFullPath($Path)
  $allowed = [IO.Path]::GetFullPath($workDirectory) + [IO.Path]::DirectorySeparatorChar
  if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean outside the MSI build directory: $resolved"
  }
  if (Test-Path -LiteralPath $resolved) {
    if ((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "Refusing to clean a linked build root: $resolved"
    }
    $entries = @((Get-Item -LiteralPath $resolved)) + @(Get-ChildItem -LiteralPath $resolved -Recurse -Force)
    if ($entries | Where-Object { $_.Name -eq 'recordings' -or $_.Extension -eq '.talraw' }) {
      throw "Recordings were found in the MSI scratch directory. Move them to a safe location first: $resolved"
    }
    # Flutter creates plugin directory links. Unlink these entries without following
    # their targets before recursively deleting the remaining generated directory.
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
      throw "The installer payload must not contain links: $($item.FullName)"
    }
    $destinationPath = Join-Path $Destination $item.Name
    if ($item.PSIsContainer) { Copy-Payload $item.FullName $destinationPath }
    else { Copy-Item -LiteralPath $item.FullName -Destination $destinationPath }
  }
}

function Get-PayloadId([string]$Prefix, [string]$RelativePath) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($RelativePath.ToLowerInvariant())
    return $Prefix + ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').Substring(0, 32)
  } finally { $sha.Dispose() }
}

function Add-XmlElement($Parent, [string]$Name, [hashtable]$Attributes) {
  $element = $payloadXml.CreateElement($Name, 'http://wixtoolset.org/schemas/v4/wxs')
  foreach ($key in $Attributes.Keys) { $element.SetAttribute($key, [string]$Attributes[$key]) }
  $null = $Parent.AppendChild($element)
  return $element
}

function Add-PayloadDirectory([string]$Path, $DirectoryElement, [string]$DirectoryId) {
  $relative = $Path.Substring($stageDirectory.Length).TrimStart('\')
  $folderId = Get-PayloadId 'Cleanup_' $relative
  $cleanup = Add-XmlElement $DirectoryElement 'Component' @{ Id = $folderId; Guid = '*' }
  $null = Add-XmlElement $cleanup 'RegistryValue' @{
    Root = 'HKCU'; Key = 'Software\Take A Look V2\Installer\Folders'; Name = $folderId
    Type = 'integer'; Value = '1'; KeyPath = 'yes'
  }
  # RemoveFolder only removes empty directories. User recordings are never owned by MSI.
  $null = Add-XmlElement $cleanup 'RemoveFolder' @{ Id = $folderId; On = 'uninstall' }
  if ($DirectoryId -eq 'INSTALLFOLDER') {
    $null = Add-XmlElement $cleanup 'RemoveFolder' @{ Id = 'RemoveUserPrograms'; Directory = 'UserProgramsFolder'; On = 'uninstall' }
  }
  $null = Add-XmlElement $componentGroup 'ComponentRef' @{ Id = $folderId }
  foreach ($item in Get-ChildItem -LiteralPath $Path | Sort-Object Name) {
    $itemRelative = $item.FullName.Substring($stageDirectory.Length + 1)
    if ($item.PSIsContainer) {
      $id = Get-PayloadId 'Dir_' $itemRelative
      $directory = Add-XmlElement $DirectoryElement 'Directory' @{ Id = $id; Name = $item.Name }
      Add-PayloadDirectory $item.FullName $directory $id
    } else {
      $id = Get-PayloadId 'File_' $itemRelative
      # WiX cannot auto-generate GUIDs for a file with a registry key path.
      $guid = ([guid](Get-PayloadId '' ('Take A Look V2/x64/file/' + $itemRelative))).ToString('D')
      $component = Add-XmlElement $DirectoryElement 'Component' @{ Id = $id; Guid = $guid }
      $null = Add-XmlElement $component 'File' @{ Id = $id; Source = $item.FullName }
      # Per-user components need HKCU key paths (ICE38), stable across rebuilds.
      $null = Add-XmlElement $component 'RegistryValue' @{
        Root = 'HKCU'; Key = 'Software\Take A Look V2\Installer\Files'; Name = $id
        Type = 'integer'; Value = '1'; KeyPath = 'yes'
      }
      $null = Add-XmlElement $componentGroup 'ComponentRef' @{ Id = $id }
    }
  }
}

try {
  if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
  if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -and $env:PROCESSOR_ARCHITEW6432 -ne 'AMD64') {
    throw 'This packaging script requires an x64 Windows build host.'
  }
  foreach ($directory in @($workDirectory, $releaseDirectory, $logDirectory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  $logPath = Join-Path $logDirectory ('windows-msi-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
  Start-Transcript -LiteralPath $logPath | Out-Null
  $transcribing = $true
  $pubspec = Get-Content -LiteralPath (Join-Path $projectDirectory 'pubspec.yaml') -Raw
  $match = [regex]::Match($pubspec, '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)(?:\+\d+)?\s*$')
  if (-not $match.Success) { throw 'pubspec.yaml version must be major.minor.patch[+build].' }
  $version = '{0}.{1}.{2}' -f $match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value
  if ([int64]$match.Groups[1].Value -gt 255 -or [int64]$match.Groups[2].Value -gt 255 -or [int64]$match.Groups[3].Value -gt 65535) {
    throw 'MSI versions must fit 0..255.0..255.0..65535.'
  }
  $crtDirectory = Find-VcRuntime
  foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $crtDirectory $dll))) { throw "Missing C++ runtime: $dll" }
  }

  # Keep pinned WiX tools and extensions inside ignored build/, never install globally.
  # Allow the .NET 8 tool to run when only a newer supported .NET runtime is installed.
  $env:DOTNET_ROLL_FORWARD = 'Major'
  if (-not (Test-Path -LiteralPath $wix)) {
    Invoke-Checked 'dotnet' @('tool', 'install', 'wix', '--version', $wixVersion, '--tool-path', $toolDirectory,
                            '--add-source', 'https://api.nuget.org/v3/index.json')
  }
  $uiExtension = Join-Path $toolDirectory ".wix\extensions\WixToolset.UI.wixext\$wixVersion\wixext5\WixToolset.UI.wixext.dll"
  if (-not (Test-Path -LiteralPath $uiExtension)) {
    Push-Location $toolDirectory
    try { Invoke-Checked $wix @('extension', 'add', "WixToolset.UI.wixext/$wixVersion") }
    finally { Pop-Location }
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
    Write-Host 'Copying current workspace sources into the isolated MSI build directory...'
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
    if (Test-Path -LiteralPath $buildStamp) { Remove-Item -LiteralPath $buildStamp }
    Invoke-Checked 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
      (Join-Path $PSScriptRoot 'build_backend.ps1'), '-Python', $backendPython,
      '-OutputDirectory', (Join-Path $sourceDirectory 'backend\runtime'),
      '-WorkDirectory', (Join-Path $workDirectory 'backend_pyinstaller'))
    # Remove old bundle files so deleted plugins/libraries cannot leak into a new MSI.
    Reset-WorkDirectory $builtBundle
    Push-Location $sourceDirectory
    try {
      Invoke-Checked $flutterCommand @('pub', 'get')
      Invoke-Checked $flutterCommand @('build', 'windows', '--release', '--no-pub')
    } finally { Pop-Location }
    Set-Content -LiteralPath $buildStamp -Value $version -Encoding ascii
  } elseif (-not (Test-Path -LiteralPath $buildStamp) -or (Get-Content -LiteralPath $buildStamp -Raw).Trim() -ne $version) {
    throw '-SkipBuild requires a successful MSI application build with the current pubspec.yaml version.'
  }

  Reset-WorkDirectory $stageDirectory
  Copy-Payload $builtBundle $stageDirectory
  Get-ChildItem -LiteralPath $crtDirectory -File -Filter '*.dll' | Copy-Item -Destination $stageDirectory -Force
  foreach ($required in @('take_a_look_v2.exe', 'flutter_windows.dll', 'data\app.so', 'data\icudtl.dat',
                         'backend\pyproject.toml', 'backend\runtime\take_a_look_backend\take_a_look_backend.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $stageDirectory $required))) { throw "Missing release payload: $required" }
  }
  $exeVersion = (Get-Item -LiteralPath (Join-Path $stageDirectory 'take_a_look_v2.exe')).VersionInfo
  if (("{0}.{1}.{2}" -f $exeVersion.FileMajorPart, $exeVersion.FileMinorPart, $exeVersion.FileBuildPart) -ne $version) {
    throw 'The application EXE version does not match pubspec.yaml. Run a full build.'
  }
  Write-Host 'Checking the packaged Python runtime (offline, without opening a probe)...'
  Invoke-Checked (Join-Path $stageDirectory 'backend\runtime\take_a_look_backend\take_a_look_backend.exe') @('--self-test')

  $payloadXml = New-Object Xml.XmlDocument
  $null = $payloadXml.AppendChild($payloadXml.CreateXmlDeclaration('1.0', 'utf-8', $null))
  $wixElement = Add-XmlElement $payloadXml 'Wix' @{}
  $fragment = Add-XmlElement $wixElement 'Fragment' @{}
  $componentGroup = Add-XmlElement $fragment 'ComponentGroup' @{ Id = 'ApplicationFiles' }
  $directoryRef = Add-XmlElement $fragment 'DirectoryRef' @{ Id = 'INSTALLFOLDER' }
  Add-PayloadDirectory $stageDirectory $directoryRef 'INSTALLFOLDER'
  $payloadSource = Join-Path $workDirectory 'Payload.wxs'
  $payloadXml.Save($payloadSource)

  $installerDirectory = Join-Path $projectDirectory 'windows\installer'
  $packageName = "Take-A-Look-V2-$version-windows-x64.msi"
  $temporaryMsi = Join-Path $workDirectory $packageName
  Write-Host "Building $packageName..."
  Invoke-Checked $wix @('build', (Join-Path $installerDirectory 'Package.wxs'),
    (Join-Path $installerDirectory 'UI.wxs'), $payloadSource, '-arch', 'x64', '-culture', 'zh-CN',
    '-ext', $uiExtension, '-d', "ProductVersion=$version", '-d', "AppIcon=$(Join-Path $projectDirectory 'windows\runner\resources\app_icon.ico')",
    '-pdb', (Join-Path $workDirectory 'installer.wixpdb'), '-o', $temporaryMsi)
  & (Join-Path $PSScriptRoot 'verify_windows_msi.ps1') -MsiPath $temporaryMsi -PayloadDirectory $stageDirectory

  # Publish only after verification, preserving any previous successful release on failure.
  $msiPath = Join-Path $releaseDirectory $packageName
  Copy-Item -LiteralPath $temporaryMsi -Destination $msiPath -Force
  $sha = [Security.Cryptography.SHA256]::Create()
  $stream = [IO.File]::OpenRead($msiPath)
  try { $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
  finally { $stream.Dispose(); $sha.Dispose() }
  Set-Content -LiteralPath "$msiPath.sha256" -Value "$hash  $packageName" -Encoding ascii
  Write-Host "MSI: $msiPath"
  Write-Host "SHA-256: $msiPath.sha256"
  Write-Host "Build log: $logPath"
} catch {
  Write-Host "Windows MSI build failed: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host $_.ScriptStackTrace
  exit 1
} finally {
  $env:DOTNET_ROLL_FORWARD = $oldRollForward
  if ($transcribing) { Stop-Transcript | Out-Null }
}
