param(
  [ValidateSet('Debug', 'Release')][string]$Configuration = 'Debug',
  [switch]$Run,
  [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
$projectDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$outputDirectory = Join-Path $projectDirectory 'build\ui_test'
$sourceDirectory = Join-Path $outputDirectory 'source'
$bundleDirectory = Join-Path $outputDirectory $Configuration
New-Item -ItemType Directory -Force -Path $sourceDirectory | Out-Null

# Copy tracked inputs into an isolated checkout. Keep its build caches, while
# removing old source inputs so deleted/renamed Dart files cannot survive.
function Reset-TestDirectory([string]$Path, [string[]]$Preserve = @()) {
  $resolved = [IO.Path]::GetFullPath($Path)
  $allowed = [IO.Path]::GetFullPath($outputDirectory) + [IO.Path]::DirectorySeparatorChar
  if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean outside the UI test output: $resolved"
  }
  if (Test-Path -LiteralPath $resolved) {
    if ($Preserve.Count -eq 0) {
      Remove-Item -LiteralPath $resolved -Recurse -Force
    } else {
      foreach ($entry in Get-ChildItem -LiteralPath $resolved -Force) {
        if ($Preserve -contains $entry.Name) { continue }
        $entryPath = [IO.Path]::GetFullPath($entry.FullName)
        if (-not $entryPath.StartsWith($resolved + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
          throw "Refusing to clean outside the bundle: $entryPath"
        }
        Remove-Item -LiteralPath $entryPath -Recurse -Force
      }
    }
  }
  New-Item -ItemType Directory -Path $resolved -Force | Out-Null
}

foreach ($folder in @('lib', 'assets', 'plugins', 'windows', 'backend')) {
  Reset-TestDirectory (Join-Path $sourceDirectory $folder)
}
$inputs = & git -C $projectDirectory ls-files --cached --others --exclude-standard -- lib assets plugins windows backend pubspec.yaml pubspec.lock analysis_options.yaml .metadata
if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate project inputs.' }
foreach ($relative in $inputs) {
  $source = Join-Path $projectDirectory $relative
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
  $destination = Join-Path $sourceDirectory $relative
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
  Copy-Item -LiteralPath $source -Destination $destination -Force
}

# Retain the production runner (multi-window plugins and GPU setup), but give
# this executable a distinct identity. Never package the Python runtime.
$cmakePath = Join-Path $sourceDirectory 'windows\CMakeLists.txt'
$cmake = Get-Content -LiteralPath $cmakePath -Raw
$cmake.Replace('set(BINARY_NAME "take_a_look_v2")', 'set(BINARY_NAME "take_a_look_ui_test")') | Set-Content -LiteralPath $cmakePath -Encoding utf8
$resourcePath = Join-Path $sourceDirectory 'windows\runner\Runner.rc'
(Get-Content -LiteralPath $resourcePath -Raw).Replace('take_a_look_v2', 'take_a_look_ui_test') | Set-Content -LiteralPath $resourcePath -Encoding utf8

Push-Location $sourceDirectory
try {
  & flutter pub get
  if ($LASTEXITCODE -ne 0) { throw 'UI test dependency resolution failed.' }
  & flutter build windows "--$($Configuration.ToLowerInvariant())" --no-pub --target lib/main_ui_test.dart
  if ($LASTEXITCODE -ne 0) { throw 'UI test build failed.' }
} finally {
  Pop-Location
}

Reset-TestDirectory $bundleDirectory -Preserve @('recordings')
$builtBundle = Join-Path $sourceDirectory "build\windows\x64\runner\$Configuration"
Get-ChildItem -LiteralPath $builtBundle | Where-Object Name -ne 'recordings' | Copy-Item -Destination $bundleDirectory -Recurse -Force
$recordingsDirectory = Join-Path $bundleDirectory 'recordings'
New-Item -ItemType Directory -Force -Path $recordingsDirectory | Out-Null
$executable = Join-Path $bundleDirectory 'take_a_look_ui_test.exe'
if (-not (Test-Path -LiteralPath $executable)) { throw 'UI test executable is missing.' }
Write-Output "UI test executable: $executable"

if ($SmokeTest) {
  $previousDataDirectory = $env:TAL_UI_TEST_DATA_DIR
  try {
    $env:TAL_UI_TEST_DATA_DIR = Join-Path $outputDirectory 'smoke'
    New-Item -ItemType Directory -Force -Path $env:TAL_UI_TEST_DATA_DIR | Out-Null
    $reportPath = Join-Path $env:TAL_UI_TEST_DATA_DIR 'smoke-result.json'
    if (Test-Path -LiteralPath $reportPath) { Remove-Item -LiteralPath $reportPath -Force }
    $stdoutPath = Join-Path $env:TAL_UI_TEST_DATA_DIR 'stdout.log'
    $stderrPath = Join-Path $env:TAL_UI_TEST_DATA_DIR 'stderr.log'
    # Launch from a different working directory to verify portable data paths.
    $process = Start-Process -FilePath $executable -ArgumentList '--smoke-test' -WorkingDirectory $outputDirectory -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    # Retain the process handle before waiting; Refresh can discard a completed
    # process's cached exit status in PowerShell.
    $null = $process.Handle
    if (-not $process.WaitForExit(60000)) {
      Stop-Process -Id $process.Id -Force
      throw 'UI test smoke run exceeded 60 seconds.'
    }
    if ($process.ExitCode -ne 0) { throw "UI test smoke run failed (exit $($process.ExitCode)); inspect $env:TAL_UI_TEST_DATA_DIR" }
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    if ($report.smokePassed -ne $true) { throw 'Native smoke report did not confirm success.' }
    $recordingPath = [IO.Path]::GetFullPath($report.rawRecording.path)
    if (-not $recordingPath.StartsWith($recordingsDirectory + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
      throw "Native recording did not stay beside the executable: $recordingPath"
    }
    Write-Output "Native smoke checks passed: $env:TAL_UI_TEST_DATA_DIR"
  } finally {
    $env:TAL_UI_TEST_DATA_DIR = $previousDataDirectory
  }
}
if ($Run) {
  # This is the interactive test application explicitly requested by -Run.
  Start-Process -FilePath $executable -WorkingDirectory $bundleDirectory
}
