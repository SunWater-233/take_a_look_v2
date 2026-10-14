<# Verify MSI metadata, extract without registering an installation, and test the delivered files. #>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$MsiPath,
  [Parameter(Mandatory = $true)][string]$PayloadDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$MsiPath = (Resolve-Path -LiteralPath $MsiPath).Path
$PayloadDirectory = (Resolve-Path -LiteralPath $PayloadDirectory).Path
$projectDirectory = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$verificationRoot = Join-Path $projectDirectory ('build\msi-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$extractDirectory = Join-Path $verificationRoot ('space ' + [char]0x4e2d + [char]0x6587)
New-Item -ItemType Directory -Path $extractDirectory -Force | Out-Null

function Get-PayloadHash([string]$Path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  $stream = [IO.File]::OpenRead($Path)
  try { return [BitConverter]::ToString($sha.ComputeHash($stream)) }
  finally { $stream.Dispose(); $sha.Dispose() }
}

function Read-MsiTable([string]$Query, [string[]]$Columns) {
  $view = $database.OpenView($Query)
  try {
    $null = $view.Execute()
    while ($record = $view.Fetch()) {
      try {
        $row = @{}
        for ($index = 0; $index -lt $Columns.Count; $index++) {
          $row[$Columns[$index]] = $record.StringData($index + 1)
        }
        [pscustomobject]$row
      } finally { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($record) }
    }
  } finally {
    $null = $view.Close()
    $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)
  }
}

$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $null
try {
  $database = $installer.OpenDatabase($MsiPath, 0)
  $properties = @{}
  Read-MsiTable 'SELECT `Property`, `Value` FROM `Property`' @('Name', 'Value') | ForEach-Object { $properties[$_.Name] = $_.Value }
  if ($properties['ProductName'] -ne 'Take A Look V2' -or $properties['ALLUSERS']) {
    throw 'The MSI is not the expected per-user application.'
  }
  if ($properties['WIXUI_INSTALLDIR'] -ne 'INSTALLFOLDER') { throw 'The install directory UI is not bound to INSTALLFOLDER.' }
  $pathControls = @(Read-MsiTable 'SELECT `Dialog_`, `Property` FROM `Control` WHERE `Type` = ''PathEdit''' @('Dialog', 'Property'))
  if (-not ($pathControls | Where-Object { $_.Dialog -eq 'InstallDirDlg' -and $_.Property -eq 'WIXUI_INSTALLDIR' })) {
    throw 'The MSI has no editable installation directory control.'
  }
  $navigation = @(Read-MsiTable 'SELECT `Dialog_`, `Control_`, `Event`, `Argument` FROM `ControlEvent`' @('Dialog', 'Control', 'Event', 'Argument'))
  if (-not ($navigation | Where-Object { $_.Dialog -eq 'WelcomeDlg' -and $_.Control -eq 'Next' -and $_.Argument -eq 'InstallDirDlg' }) -or
      -not ($navigation | Where-Object { $_.Dialog -eq 'InstallDirDlg' -and $_.Control -eq 'ChangeFolder' -and $_.Argument -eq 'BrowseDlg' })) {
    throw 'The install directory or folder browser is unreachable from the setup wizard.'
  }
  $summary = $database.SummaryInformation(0)
  try {
    if ($summary.Property(7) -notlike 'x64;*' -or -not ([int]$summary.Property(15) -band 8)) {
      throw 'The MSI must be x64 and must not require elevation.'
    }
  } finally { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($summary) }
  $files = @(Read-MsiTable 'SELECT `FileName` FROM `File`' @('Name'))
  $expectedFiles = @(Get-ChildItem -LiteralPath $PayloadDirectory -Recurse -File)
  $longestRelativePath = ($expectedFiles | ForEach-Object { $_.FullName.Length - $PayloadDirectory.Length - 1 } | Measure-Object -Maximum).Maximum
  if ($extractDirectory.Length + '\LocalApp\Programs\Take A Look V2\'.Length + $longestRelativePath -ge 260) {
    throw 'MSI extraction paths would exceed Windows Installer MAX_PATH. Move the project to a shorter path and rebuild.'
  }
  if ($files.Count -ne $expectedFiles.Count) { throw 'MSI file count differs from the staged application.' }
  $directories = @(Read-MsiTable 'SELECT `DefaultDir` FROM `Directory`' @('Name'))
  if ($directories.Name -match 'recordings' -or $files.Name -match '\.talraw$') { throw 'The MSI contains recordings.' }
  $registries = @(Read-MsiTable 'SELECT `Root` FROM `Registry`' @('Root'))
  if ($registries | Where-Object Root -ne '1') { throw 'The per-user MSI must only write HKCU registry values.' }
  $shortcuts = @(Read-MsiTable 'SELECT `Shortcut` FROM `Shortcut`' @('Name'))
  if ($shortcuts.Count -ne 2) { throw 'Start menu and desktop shortcuts are required.' }
  $removals = @(Read-MsiTable 'SELECT `FileName` FROM `RemoveFile`' @('Name'))
  if ($removals | Where-Object Name) { throw 'The installer must only remove empty directories, not unowned files.' }
  $upgrades = @(Read-MsiTable 'SELECT `UpgradeCode` FROM `Upgrade`' @('Code'))
  if (-not $upgrades -or ($upgrades | Where-Object Code -ne $properties['UpgradeCode'])) { throw 'Invalid upgrade identity.' }
} finally {
  if ($database) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($database) }
  $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)
}

Write-Host 'Extracting the MSI for payload verification (no application installation)...'
$extractLog = Join-Path $verificationRoot 'extract.log'
$arguments = @('/a', ('"' + $MsiPath + '"'), '/qn', '/norestart', ('TARGETDIR="' + $extractDirectory + '"'),
               '/L*v', ('"' + $extractLog + '"'))
$process = Start-Process -FilePath msiexec.exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
$null = $process.Handle
if (-not $process.WaitForExit(60000)) { throw "MSI extraction timed out. See $extractLog" }
if ($process.ExitCode -ne 0) { throw "MSI extraction failed (exit $($process.ExitCode)). See $extractLog" }
$executables = @(Get-ChildItem -LiteralPath $extractDirectory -Recurse -File -Filter 'take_a_look_v2.exe')
if ($executables.Count -ne 1) { throw 'The extracted MSI must contain exactly one application EXE.' }
$extractedApp = $executables[0].DirectoryName
foreach ($file in $expectedFiles) {
  $relative = $file.FullName.Substring($PayloadDirectory.Length + 1)
  $deliveredFile = Join-Path $extractedApp $relative
  if (-not (Test-Path -LiteralPath $deliveredFile) -or
      (Get-PayloadHash $file.FullName) -ne (Get-PayloadHash $deliveredFile)) {
    throw "MSI payload verification failed: $relative"
  }
}
foreach ($relative in @('take_a_look_v2.exe', 'backend\runtime\take_a_look_backend\take_a_look_backend.exe')) {
  $bytes = [IO.File]::ReadAllBytes((Join-Path $extractedApp $relative))
  $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
  if ([BitConverter]::ToUInt16($bytes, $peOffset + 4) -ne 0x8664) { throw "Expected an x64 executable: $relative" }
}
$environmentNames = @('PYTHONPATH', 'PYTHONHOME', 'TAKE_A_LOOK_PYTHON', 'TAKE_A_LOOK_BACKEND_DIR', 'TAL_RECORDINGS_DIR')
$savedEnvironment = @{}
foreach ($name in $environmentNames) {
  $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
  [Environment]::SetEnvironmentVariable($name, $null, 'Process')
}
Push-Location $verificationRoot
try {
  $backend = Join-Path $extractedApp 'backend\runtime\take_a_look_backend\take_a_look_backend.exe'
  $reportJson = & $backend --self-test
  if ($LASTEXITCODE -ne 0) { throw "Extracted backend self-test failed: $reportJson" }
  $report = $reportJson | ConvertFrom-Json
  if ($report.ok -ne $true -or $report.checks.rpc -ne 'ok') { throw "Extracted backend self-test failed: $reportJson" }
} finally {
  Pop-Location
  foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
}
Write-Host "MSI verified: $($expectedFiles.Count) files, SHA-256 matches, x64 EXEs, per-user metadata, shortcuts and offline backend RPC."
Write-Host "Verification files: $verificationRoot"
