param(
  [ValidateRange(1, 10)][int]$Runs = 2,
  [ValidateSet('all', 'heartbeat', 'worker', 'live')][string]$Suite = 'all',
  [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$ResultSet = 'results',
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$projectDirectory = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$benchmarkDirectory = Join-Path $projectDirectory 'build\data_benchmark'
$harnessDirectory = Join-Path $benchmarkDirectory 'harness'
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
$sourcePaths = @(
  'lib/src/backend/backend_transport.dart', 'lib/src/telemetry/telemetry_store.dart',
  'lib/src/telemetry/sample_buffer.dart', 'lib/src/models/models.dart',
  'lib/src/analysis/analysis_data.dart', 'lib/src/analysis/analysis_worker.dart',
  'lib/src/analysis/analysis.dart', 'lib/src/analysis/analysis_fft.dart',
  'lib/src/controller/controller.dart', 'lib/src/controller/controller_telemetry.dart',
  'lib/src/panels/analysis_chart_panel.dart', 'lib/src/panels/analysis_fft_panel.dart',
  'lib/src/chart/downsampling.dart', 'lib/src/chart/painter.dart',
  'tool/benchmarks/data_benchmark.dart'
)
$sourceHashes = @{}
foreach ($sourcePath in $sourcePaths) {
  $sourceHashes[$sourcePath] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $projectDirectory $sourcePath)).Hash
}
$buildManifest = Join-Path $benchmarkDirectory 'compiled-source-hashes.json'
if ($SkipBuild) {
  $compiledHashes = Get-Content -Raw -LiteralPath $buildManifest | ConvertFrom-Json
  foreach ($sourcePath in $sourcePaths) {
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
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $resultDirectory "environment-$Suite.json") -Encoding utf8
if ($Suite -eq 'all') {
  Copy-Item -LiteralPath (Join-Path $resultDirectory 'environment-all.json') -Destination (Join-Path $resultDirectory 'environment.json') -Force
}

$benchmarkExecutable = Join-Path $harnessDirectory 'build\windows\x64\runner\Release\tal_data_benchmark.exe'
$previousOutput = $env:TAL_BENCH_OUTPUT
$previousSuite = $env:TAL_BENCH_SUITE
try {
  $env:TAL_BENCH_SUITE = $Suite
  for ($run = 1; $run -le $Runs; $run++) {
    $resultName = if ($Suite -eq 'all') { "run-$run.json" } else { "$Suite-run-$run.json" }
    $env:TAL_BENCH_OUTPUT = Join-Path $resultDirectory $resultName
    Write-Output "Starting release benchmark run $run of $Runs. Progress: $env:TAL_BENCH_OUTPUT.progress.jsonl"
    $process = Start-Process -FilePath $benchmarkExecutable -WorkingDirectory (Split-Path $benchmarkExecutable) -WindowStyle Hidden -PassThru -Wait
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
