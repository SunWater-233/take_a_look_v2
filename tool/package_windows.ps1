<# Windows worker for tool/build.py; MSI and portable share one application build. #>
[CmdletBinding()]
param(
  [ValidateSet('all', 'msi', 'portable')][string]$Package = 'all',
  [ValidateSet('release', 'debug')][string]$Mode = 'release',
  [string]$Python = 'python',
  [string]$Flutter = 'flutter',
  [string]$VcRuntimeDirectory = '',
  [switch]$SkipBuild,
  [switch]$Check,
  [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(?:\+[0-9]+)?$')][string]$Version = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Mode = $Mode.ToLowerInvariant()
$Package = $Package.ToLowerInvariant()
$projectDirectory = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$workDirectory = Join-Path $projectDirectory "build\work\windows\$Mode"
$sourceDirectory = Join-Path $workDirectory 'source'
$releaseDirectory = Join-Path $projectDirectory 'build\releases'
$logDirectory = Join-Path $projectDirectory 'build\logs'
$configuration = if ($Mode -eq 'debug') { 'Debug' } else { 'Release' }
$modeSuffix = if ($Mode -eq 'debug') { '-debug' } else { '' }
$wixVersion = '5.0.2'
$toolDirectory = Join-Path $projectDirectory "build\tools\wix-$wixVersion"
$wix = Join-Path $toolDirectory 'wix.exe'
$oldRollForward = $env:DOTNET_ROLL_FORWARD
$transcribing = $false

# Shared helpers and package verification are defined below.
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
    throw "Refusing to clean outside the Windows build directory: $resolved"
  }
  $ancestor = Split-Path -Parent $resolved
  while ($ancestor.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) {
    if ((Test-Path -LiteralPath $ancestor) -and
        ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "Refusing to clean through a linked directory: $ancestor"
    }
    $ancestor = Split-Path -Parent $ancestor
  }
  if (Test-Path -LiteralPath $resolved) {
    if ((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "Refusing to clean a linked build root: $resolved"
    }
    $entries = @()
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($resolved)
    while ($pending.Count) {
      foreach ($entry in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
        if ($entry.Name -eq 'recordings' -or $entry.Extension -eq '.talraw') {
          throw "Recordings were found in the build directory: $($entry.FullName)"
        }
        $entries += $entry
        if ($entry.PSIsContainer -and -not ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
          $pending.Push($entry.FullName)
        }
      }
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
    # Keep the root itself: editors/processes can hold it as a working directory.
    # Removing all its contents also removes every Flutter/CMake cache.
    foreach ($entry in Get-ChildItem -LiteralPath $resolved -Force) {
      Remove-Item -LiteralPath $entry.FullName -Recurse -Force
    }
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

function Save-WorkRecordings([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $sourceRoot = [IO.Path]::GetFullPath($Path)
  $allowedSource = [IO.Path]::GetFullPath($workDirectory) + [IO.Path]::DirectorySeparatorChar
  if (-not $sourceRoot.StartsWith($allowedSource, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to move data outside the Windows build directory: $sourceRoot"
  }
  $pending = [Collections.Generic.Stack[string]]::new()
  $pending.Push($sourceRoot)
  $protected = @()
  while ($pending.Count) {
    $directory = $pending.Pop()
    if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
    $children = @(Get-ChildItem -LiteralPath $directory -Force)
    $rawFiles = @($children | Where-Object { -not $_.PSIsContainer -and $_.Extension -eq '.talraw' })
    if ($directory -ne $sourceRoot -and ((Split-Path -Leaf $directory) -eq 'recordings' -or $rawFiles.Count)) {
      $protected += $directory
      continue
    }
    if ($directory -eq $sourceRoot) { $protected += @($rawFiles | ForEach-Object { $_.FullName }) }
    foreach ($child in $children | Where-Object { $_.PSIsContainer -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }) {
      $pending.Push($child.FullName)
    }
  }
  if (-not $protected.Count) { return }
  $recordingsRoot = Join-Path $projectDirectory 'build\recordings'
  if ((Test-Path -LiteralPath $recordingsRoot) -and
      ((Get-Item -LiteralPath $recordingsRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Refusing a linked recordings backup directory: $recordingsRoot"
  }
  $backupRoot = Join-Path $recordingsRoot ("windows-$Mode-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  foreach ($protectedPath in $protected) {
    $resolvedSource = [IO.Path]::GetFullPath($protectedPath)
    $destination = [IO.Path]::GetFullPath((Join-Path $backupRoot $resolvedSource.Substring($sourceRoot.Length + 1)))
    if (-not $resolvedSource.StartsWith($sourceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        -not $destination.StartsWith($backupRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'Refusing to move recordings outside the managed source and backup directories.'
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Move-Item -LiteralPath $resolvedSource -Destination $destination
  }
  Write-Host "Preserved build-directory recordings: $backupRoot"
}

function Copy-Payload([string]$Source, [string]$Destination) {
  New-Item -ItemType Directory -Path $Destination -Force | Out-Null
  foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
    if ($item.Name -in @('recordings', '__pycache__', '.venv') -or
        $item.Extension -in @('.talraw', '.ilk', '.exp', '.lib', '.pyc', '.log') -or
        ($Mode -eq 'release' -and $item.Extension -eq '.pdb')) { continue }
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
function Get-FileHashHex([string]$Path) {
  # Windows PowerShell launched from pwsh can inherit an incompatible module
  # search path on hosted runners. Hash without relying on cmdlet auto-loading.
  $sha = [Security.Cryptography.SHA256]::Create()
  $stream = [IO.File]::OpenRead($Path)
  try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
  finally { $stream.Dispose(); $sha.Dispose() }
}


try {
  if ($env:OS -ne 'Windows_NT') { throw 'Run this script on Windows.' }
  if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -and $env:PROCESSOR_ARCHITEW6432 -ne 'AMD64') {
    throw 'This packaging script requires an x64 Windows build host.'
  }
  foreach ($relative in @('build', 'build\work', 'build\work\windows', "build\work\windows\$Mode", 'build\releases', 'build\logs', 'build\tools')) {
    $directory = Join-Path $projectDirectory $relative
    if ((Test-Path -LiteralPath $directory) -and
        ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "Refusing a linked build directory: $directory"
    }
  }
  $versionText = if ($Version) { $Version } else {
    $pubspec = Get-Content -LiteralPath (Join-Path $projectDirectory 'pubspec.yaml') -Raw
    [regex]::Match($pubspec, '(?m)^version:\s*([^\r\n]+)').Groups[1].Value.Trim()
  }
  $match = [regex]::Match($versionText, '^(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$')
  if (-not $match.Success) { throw 'Version must use major.minor.patch[+build].' }
  $msiVersion = '{0}.{1}.{2}' -f $match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value
  $buildNumber = if ($match.Groups[4].Success) { $match.Groups[4].Value } else { '0' }
  $fullVersion = "$msiVersion+$buildNumber"
  # Use the requested version text for the directory on both platforms, even
  # when Windows normalises an omitted build number to +0 inside the EXE.
  $releaseDirectory = Join-Path $releaseDirectory "$versionText\windows"
  foreach ($directory in @((Split-Path -Parent $releaseDirectory), $releaseDirectory)) {
    if ((Test-Path -LiteralPath $directory) -and
        ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "Refusing a linked release directory: $directory"
    }
  }
  if ($Package -ne 'portable' -and ([int64]$match.Groups[1].Value -gt 255 -or [int64]$match.Groups[2].Value -gt 255 -or [int64]$match.Groups[3].Value -gt 65535)) {
    throw 'MSI versions must fit 0..255.0..255.0..65535.'
  }
  foreach ($part in @($match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value, $buildNumber)) {
    if ([int64]$part -gt 65535) { throw 'Windows EXE version fields must fit 0..65535.' }
  }
  $flutterCommand = @(Get-Command $Flutter -CommandType Application -ErrorAction Stop)[0].Source
  $dartCommand = Join-Path (Split-Path -Parent $flutterCommand) 'dart.bat'
  $null = Get-Command git -CommandType Application -ErrorAction Stop
  if ($Package -ne 'portable') { $null = Get-Command dotnet -CommandType Application -ErrorAction Stop }
  $crtDirectory = Find-VcRuntime
  foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $crtDirectory $dll))) { throw "Missing C++ runtime: $dll" }
  }
  if ($Check) {
    Invoke-Checked $flutterCommand @('--version')
    Write-Host "Windows $configuration environment check passed. CRT: $crtDirectory"
    return
  }
  foreach ($directory in @($workDirectory, $releaseDirectory, $logDirectory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  $logPath = Join-Path $logDirectory ("windows-$Mode-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + "-$PID.log")
  Start-Transcript -LiteralPath $logPath | Out-Null
  $transcribing = $true
  $builtBundle = Join-Path $sourceDirectory "build\windows\x64\runner\$configuration"
  $buildStamp = Join-Path $workDirectory 'application-version.txt'
  if (-not $SkipBuild) {
    $backendPython = Join-Path $projectDirectory 'backend\.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $backendPython)) {
      Invoke-Checked 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $PSScriptRoot 'setup_backend.ps1'), '-Python', $Python)
    }
    # CMake/.dart_tool caches must be reset together with generated Flutter files.
    if (Test-Path -LiteralPath $buildStamp) { Remove-Item -LiteralPath $buildStamp }
    Save-WorkRecordings $sourceDirectory
    Reset-WorkDirectory $sourceDirectory
    Reset-WorkDirectory (Join-Path $workDirectory 'backend_pyinstaller')
    $inputs = & git -C $projectDirectory -c core.quotepath=false ls-files --cached --others --exclude-standard -- lib assets plugins windows backend/take_a_look_backend backend/pyinstaller_hooks backend/pyproject.toml tool/update_helper.dart tool/write_update_manifest.dart pubspec.yaml pubspec.lock analysis_options.yaml .metadata
    if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate source files. Build from a Git checkout.' }
    foreach ($relative in $inputs) {
      if ($relative -match '(^|/)recordings(/|$)|\.talraw$') { continue }
      $inputPath = Join-Path $projectDirectory $relative
      if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) { continue }
      $outputPath = Join-Path $sourceDirectory $relative
      New-Item -ItemType Directory -Path (Split-Path -Parent $outputPath) -Force | Out-Null
      Copy-Item -LiteralPath $inputPath -Destination $outputPath -Force
    }
    $isolatedPubspecPath = Join-Path $sourceDirectory 'pubspec.yaml'
    $isolatedPubspec = Get-Content -LiteralPath $isolatedPubspecPath -Raw
    $versionRegex = [regex]::new('(?m)^version:\s*[^\r\n]+')
    if (-not $versionRegex.IsMatch($isolatedPubspec)) { throw 'The isolated pubspec.yaml does not contain a version field.' }
    # Replacing a version with itself is valid; check the field rather than text changes.
    [IO.File]::WriteAllText($isolatedPubspecPath, $versionRegex.Replace($isolatedPubspec, "version: $fullVersion", 1), [Text.UTF8Encoding]::new($false))
    Write-Host "Building Windows $configuration $fullVersion once for $Package."
    Invoke-Checked 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
      (Join-Path $PSScriptRoot 'build_backend.ps1'), '-Python', $backendPython,
      '-OutputDirectory', (Join-Path $sourceDirectory 'backend\runtime'),
      '-WorkDirectory', (Join-Path $workDirectory 'backend_pyinstaller'))
    Push-Location $sourceDirectory
    try {
      Invoke-Checked $flutterCommand @('pub', 'get')
      Invoke-Checked $flutterCommand @('build', 'windows', "--$Mode", '--no-pub')
      Invoke-Checked $dartCommand @('compile', 'exe', 'tool/update_helper.dart', '-o', (Join-Path $builtBundle 'take_a_look_updater.exe'))
      Invoke-Checked (Join-Path $builtBundle 'take_a_look_updater.exe') @('--self-test')
    } finally { Pop-Location }
    Set-Content -LiteralPath $buildStamp -Value $fullVersion -Encoding ascii
  } elseif (-not (Test-Path -LiteralPath $buildStamp) -or (Get-Content -LiteralPath $buildStamp -Raw).Trim() -ne $fullVersion) {
    throw '-SkipBuild requires a successful Windows application build with the requested mode and full version (including build number).'
  }
  $packages = if ($Package -eq 'all') { @('msi', 'portable') } else { @($Package) }
  foreach ($kind in $packages) {
    $stageDirectory = Join-Path $workDirectory "stage\$kind"
    Reset-WorkDirectory $stageDirectory
    Copy-Payload $builtBundle $stageDirectory
    Get-ChildItem -LiteralPath $crtDirectory -File -Filter '*.dll' | Copy-Item -Destination $stageDirectory -Force
    $requiredFiles = @('take_a_look_v2.exe', 'take_a_look_updater.exe', 'flutter_windows.dll', 'data\icudtl.dat',
      'backend\pyproject.toml', 'backend\runtime\take_a_look_backend\take_a_look_backend.exe')
    $requiredFiles += if ($Mode -eq 'release') { 'data\app.so' } else { 'data\flutter_assets\kernel_blob.bin' }
    foreach ($required in $requiredFiles) {
      if (-not (Test-Path -LiteralPath (Join-Path $stageDirectory $required))) { throw "Missing $configuration payload: $required" }
    }
    $exeVersion = (Get-Item -LiteralPath (Join-Path $stageDirectory 'take_a_look_v2.exe')).VersionInfo
    $actual = '{0}.{1}.{2}.{3}' -f $exeVersion.FileMajorPart, $exeVersion.FileMinorPart, $exeVersion.FileBuildPart, $exeVersion.FilePrivatePart
    if ($actual -ne "$msiVersion.$buildNumber") { throw "Application version $actual does not match $fullVersion. Run a full build." }
    Invoke-Checked (Join-Path $stageDirectory 'backend\runtime\take_a_look_backend\take_a_look_backend.exe') @('--self-test')
    if ($kind -eq 'portable') {
      Set-Content -LiteralPath (Join-Path $stageDirectory '.take-a-look-package') -Value 'Take A Look V2 portable package' -Encoding ascii
      Set-Content -LiteralPath (Join-Path $stageDirectory 'PORTABLE-README.txt') -Encoding utf8 -Value @"
Take A Look V2 for Windows x64 ($configuration)
Extract to a writable folder and run take_a_look_v2.exe. Keep the entire folder.
Recordings are saved beside the executable and are never included in packages.
Release packages include the Visual C++ runtime and a self-contained backend.
Debug builds are for development and require the Visual Studio debug runtime.
"@
    }
    Push-Location $sourceDirectory
    try {
      Invoke-Checked $dartCommand @('run', 'tool/write_update_manifest.dart', $stageDirectory, "windows-$kind", $fullVersion, 'x64')
    } finally { Pop-Location }
    if ($kind -eq 'msi') {
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
      $packageName = "Take-A-Look-V2-$msiVersion-windows-x64$modeSuffix.msi"
      $temporaryMsi = Join-Path $workDirectory $packageName
      Write-Host "Building $packageName..."
      Invoke-Checked $wix @('build', (Join-Path $installerDirectory 'Package.wxs'),
        (Join-Path $installerDirectory 'UI.wxs'), $payloadSource, '-arch', 'x64', '-culture', 'zh-CN',
        '-ext', $uiExtension, '-d', "ProductVersion=$msiVersion", '-d', "AppIcon=$(Join-Path $projectDirectory 'windows\runner\resources\app_icon.ico')",
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

      Remove-Item -LiteralPath $temporaryMsi -Force

    } else {
      $packageName = "Take-A-Look-V2-$fullVersion-windows-x64-portable$modeSuffix.zip"
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

      Remove-Item -LiteralPath $temporaryArchive -Force

    }
    # Keep the source bundle for -SkipBuild; staging is disposable after verification.
    Reset-WorkDirectory $stageDirectory
  }
  Write-Host "Build log: $logPath"
} catch {
  Write-Host "Windows build failed: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host $_.ScriptStackTrace
  exit 1
} finally {
  $env:DOTNET_ROLL_FORWARD = $oldRollForward
  if ($transcribing) { Stop-Transcript | Out-Null }
}
