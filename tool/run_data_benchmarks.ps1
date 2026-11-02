param(
  [ValidateRange(1, 10)][int]$Runs = 2,
  [ValidateSet('all', 'heartbeat', 'worker', 'live', 'audit')][string]$Suite = 'all',
  [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$ResultSet = 'results',
  [switch]$SkipBuild,
  [switch]$BuildOnly,
  [string]$SourceRoot = '',
  [long]$ProcessorAffinity = 0,
  [ValidateRange(1, 10)][int]$FirstRun = 1
)

$ErrorActionPreference = 'Stop'
$projectDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sourceDirectory = if ($SourceRoot) { (Resolve-Path -LiteralPath $SourceRoot).Path } else { $projectDirectory }
$benchmarkDirectory = Join-Path $projectDirectory 'build\data_benchmark'
$harnessDirectory = Join-Path $benchmarkDirectory $(if ($SourceRoot) { "harness-$ResultSet" } else { 'harness' })
$resultDirectory = Join-Path $benchmarkDirectory $ResultSet
New-Item -ItemType Directory -Force -Path $resultDirectory | Out-Null

if (-not $SkipBuild) {
  if (-not (Test-Path -LiteralPath (Join-Path $harnessDirectory 'pubspec.yaml'))) {
    & flutter create --platforms=windows --project-name=tal_data_benchmark --no-pub $harnessDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create benchmark harness.' }
  }
  @'
name: tal_data_benchmark
publish_to: none
environment:
  sdk: ^3.11.5
dependencies:
  flutter:
    sdk: flutter
  take_a_look_v2:
    path: ../../..
flutter:
  uses-material-design: true
'@ | Set-Content -LiteralPath (Join-Path $harnessDirectory 'pubspec.yaml') -Encoding utf8
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'benchmarks\data_benchmark.dart') -Destination (Join-Path $harnessDirectory 'lib\main.dart') -Force
  $auditPackagePath = $sourceDirectory.Replace('\', '/').Replace("'", "''")
  $auditPubspec = Join-Path $harnessDirectory 'pubspec.yaml'
  (Get-Content -Raw -LiteralPath $auditPubspec).Replace('path: ../../..', "path: '$auditPackagePath'") | Set-Content -LiteralPath $auditPubspec -Encoding utf8
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'benchmarks\performance_audit.dart') -Destination (Join-Path $harnessDirectory 'lib\performance_audit.dart') -Force
  $auditAdapter = Join-Path $harnessDirectory 'lib\audit_protocol_adapter.dart'
  if (Test-Path -LiteralPath (Join-Path $sourceDirectory 'lib\src\controller\controller_sync.dart')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'benchmarks\audit_protocol_adapter.dart') -Destination $auditAdapter -Force
  } else {
    @'
import 'package:take_a_look_v2/src/controller/controller.dart';
Map<String,dynamic> auditFullSnapshot(TakeALookController c) => c.snapshot();
Map<String,dynamic> auditTelemetryDelta(TakeALookController c, Map<String,int> cursors) => c.telemetryDeltaSnapshot(cursors);
Map<String,int> auditStateVersions(TakeALookController c) => {};
Map<String,dynamic> auditStateDelta(TakeALookController c, Map<String,int> versions) => c.stateSnapshot();
'@ | Set-Content -LiteralPath $auditAdapter -Encoding utf8
  }
  # Keep the measurement window hidden, including when runApp renders frames.
  $windowSource = Join-Path $harnessDirectory 'windows\runner\flutter_window.cpp'
  $windowText = Get-Content -Raw -LiteralPath $windowSource
  $windowText.Replace('this->Show();', '// Benchmark window stays hidden.') | Set-Content -LiteralPath $windowSource -Encoding utf8
  Push-Location $harnessDirectory
  try {
    & flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'Benchmark release build failed.' }
  } finally {
    Pop-Location
  }
}

$processor = Get-CimInstance Win32_Processor
$computer = Get-CimInstance Win32_ComputerSystem
$sourcePaths = @('pubspec.yaml', 'pubspec.lock') + @(
  Get-ChildItem -LiteralPath (Join-Path $sourceDirectory 'lib') -Recurse -File -Filter '*.dart' |
    ForEach-Object { [IO.Path]::GetRelativePath($sourceDirectory, $_.FullName).Replace('\', '/') } |
    Sort-Object
)
$sourceHashes = @{}
foreach ($sourcePath in $sourcePaths) {
  $sourceHashes[$sourcePath] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $sourceDirectory $sourcePath)).Hash
}
$sourceHashes['tool/benchmarks/performance_audit.dart'] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $projectDirectory 'tool\benchmarks\performance_audit.dart')).Hash
$sourceHashes['tool/benchmarks/data_benchmark.dart'] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $projectDirectory 'tool\benchmarks\data_benchmark.dart')).Hash
$buildManifest = Join-Path $harnessDirectory 'compiled-source-hashes.json'
if ($SkipBuild) {
  $compiledHashes = Get-Content -Raw -LiteralPath $buildManifest | ConvertFrom-Json
  if (@($compiledHashes.PSObject.Properties).Count -ne $sourceHashes.Count) {
    throw 'Source inventory changed since compilation; rerun without -SkipBuild.'
  }
  foreach ($sourcePath in $sourceHashes.Keys) {
    if ($compiledHashes.$sourcePath -ne $sourceHashes[$sourcePath]) {
      throw "Source changed since compilation; rerun without -SkipBuild: $sourcePath"
    }
  }
} else {
  $sourceHashes | ConvertTo-Json | Set-Content -LiteralPath $buildManifest -Encoding utf8
}
$flutterVersion = (& flutter --version --machine | Out-String | ConvertFrom-Json)
@{
  cpu = $processor.Name
  cores = $processor.NumberOfCores
  logicalProcessors = $processor.NumberOfLogicalProcessors
  ramGiB = [math]::Round($computer.TotalPhysicalMemory / 1GB, 2)
  flutter = $flutterVersion
  sourceSha256 = $sourceHashes
  sourceDirectory = $sourceDirectory
  processorAffinity = $ProcessorAffinity
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $resultDirectory "environment-$Suite.json") -Encoding utf8
if ($Suite -eq 'all') {
  Copy-Item -LiteralPath (Join-Path $resultDirectory 'environment-all.json') -Destination (Join-Path $resultDirectory 'environment.json') -Force
}

$benchmarkExecutable = Join-Path $harnessDirectory 'build\windows\x64\runner\Release\tal_data_benchmark.exe'
if ($BuildOnly) { Write-Output "Benchmark build ready: $benchmarkExecutable"; return }
$previousOutput = $env:TAL_BENCH_OUTPUT
$previousSuite = $env:TAL_BENCH_SUITE
try {
  $env:TAL_BENCH_SUITE = $Suite
  for ($run = $FirstRun; $run -lt ($FirstRun + $Runs); $run++) {
    $resultName = if ($Suite -eq 'all') { "run-$run.json" } else { "$Suite-run-$run.json" }
    $env:TAL_BENCH_OUTPUT = Join-Path $resultDirectory $resultName
    Write-Output "Starting release benchmark run $run of $Runs. Progress: $env:TAL_BENCH_OUTPUT.progress.jsonl"
    $process = Start-Process -FilePath $benchmarkExecutable -WorkingDirectory (Split-Path $benchmarkExecutable) -WindowStyle Hidden -PassThru `
      -RedirectStandardOutput "$env:TAL_BENCH_OUTPUT.stdout.log" -RedirectStandardError "$env:TAL_BENCH_OUTPUT.stderr.log"
    $null = $process.Handle
    try {
      if ($ProcessorAffinity -gt 0) { $process.ProcessorAffinity = [IntPtr]$ProcessorAffinity }
      $process.WaitForExit()
    } catch {
      if (-not $process.HasExited) { $process.Kill() }
      throw
    }
    if ($process.ExitCode -ne 0) { throw "Benchmark failed: $env:TAL_BENCH_OUTPUT" }
    $result = Get-Content -Raw -LiteralPath $env:TAL_BENCH_OUTPUT | ConvertFrom-Json
    if ($result.status -ne 'passed') { throw "Benchmark validation failed: $env:TAL_BENCH_OUTPUT" }
    Write-Output "Completed run $run with $($result.results.Count) measurements."
  }
} finally {
  $env:TAL_BENCH_OUTPUT = $previousOutput
  $env:TAL_BENCH_SUITE = $previousSuite
}
Write-Output "Benchmark results: $resultDirectory"
