<# Regression checks for repeated isolated builds, plugin junctions and recordings. #>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$testRoot = Join-Path $project ('build\tests\windows-build-' + [guid]::NewGuid().ToString('N'))
$projectDirectory = $testRoot
$workDirectory = Join-Path $testRoot 'build\work\windows\release'
$Mode = 'release'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'tool\package_windows.ps1'), [ref]$tokens, [ref]$errors)
if ($errors) { throw ($errors | Out-String) }
foreach ($name in @('Reset-WorkDirectory', 'Save-WorkRecordings')) {
  $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
  Invoke-Expression $definition.Extent.Text
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$junctions = @()
try {
  $source = Join-Path $workDirectory 'source'
  $external = Join-Path $testRoot 'plugin-target'
  New-Item -ItemType Directory -Path $source, $external -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $external 'plugin.txt') -Value 'do not delete'
  $junction = Join-Path $source 'plugin-link'
  New-Item -ItemType Junction -Path $junction -Value $external | Out-Null
  $junctions += $junction
  Reset-WorkDirectory $source
  Assert (Test-Path -LiteralPath (Join-Path $external 'plugin.txt')) 'Reset followed a plugin junction.'
  Assert (@(Get-ChildItem -LiteralPath $source).Count -eq 0) 'The source was not fully reset.'

  $recordings = Join-Path $source 'build\runner\recordings\session'
  $fixture = Join-Path $source 'backend\pytest-of-user\session'
  New-Item -ItemType Directory -Path $recordings, $fixture -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $recordings 'samples.talraw') -Value 'recorded data'
  Set-Content -LiteralPath (Join-Path $recordings 'index.json') -Value '{"frames":1}'
  Set-Content -LiteralPath (Join-Path $fixture 'samples.talraw') -Value 'test data'
  Set-Content -LiteralPath (Join-Path $fixture 'manifest.json') -Value '{"frames":2}'
  Save-WorkRecordings $source
  Reset-WorkDirectory $source
  $backups = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'build\recordings') -Directory)
  Assert ($backups.Count -eq 1) 'Expected one backup for existing build recordings.'
  Assert ((Get-Content -LiteralPath (Join-Path $backups[0].FullName 'build\runner\recordings\session\samples.talraw')) -eq 'recorded data') 'Recording contents changed.'
  Assert (Test-Path -LiteralPath (Join-Path $backups[0].FullName 'backend\pytest-of-user\session\manifest.json')) 'Loose recording metadata was lost.'
  # A second reset needs no manual deletion or special preparation.
  Set-Content -LiteralPath (Join-Path $source 'stale-cmake-cache.txt') -Value 'old'
  Reset-WorkDirectory $source
  Assert (@(Get-ChildItem -LiteralPath $source).Count -eq 0) 'Repeated reset left stale files.'

  $stageLink = Join-Path $workDirectory 'stage'
  New-Item -ItemType Junction -Path $stageLink -Value $external | Out-Null
  $junctions += $stageLink
  $refused = $false
  try { Reset-WorkDirectory (Join-Path $stageLink 'payload') } catch { $refused = $true }
  Assert $refused 'Reset must reject linked ancestors.'
  Assert (Test-Path -LiteralPath (Join-Path $external 'plugin.txt')) 'External plugin data changed.'
  Write-Host 'Windows build regressions passed: repeated reset, plugin junctions, recording backup and linked ancestor guard.'
} finally {
  foreach ($junction in $junctions) {
    if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
  }
  $allowed = [IO.Path]::GetFullPath((Join-Path $project 'build\tests')) + [IO.Path]::DirectorySeparatorChar
  $resolved = [IO.Path]::GetFullPath($testRoot)
  if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test cleanup: $resolved" }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
