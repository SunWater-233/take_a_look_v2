<#
Exercise the production installer rules with tiny fixtures and a unique product
identity. Never installs or uninstalls the real application. Run after an MSI build.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$wix = Join-Path $project 'build\tools\wix-5.0.2\wix.exe'
$extension = Join-Path $project 'build\tools\wix-5.0.2\.wix\extensions\WixToolset.UI.wixext\5.0.2\wixext5\WixToolset.UI.wixext.dll'
$testName = 'TAL MSI Test ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$testRoot = Join-Path $project ('build\' + $testName)
$installed = Join-Path $testRoot ('installed app ' + [char]0x4e2d + [char]0x6587)
$relocated = Join-Path $testRoot ('relocated app ' + [char]0x65b0 + [char]0x76ee + [char]0x5f55)
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$upgradeCode = [guid]::NewGuid().ToString('D')
$mainGuid = [guid]::NewGuid().ToString('D')
$obsoleteGuid = [guid]::NewGuid().ToString('D')
$packagePath = Join-Path $testRoot 'Package.wxs'
$package = (Get-Content -LiteralPath (Join-Path $project 'windows\installer\Package.wxs') -Raw -Encoding utf8).
  Replace('Take A Look V2', $testName).Replace('0A9CF9B8-3C51-4D96-9CB7-A306F0FE9806', $upgradeCode)
[IO.File]::WriteAllText($packagePath, $package)
$productCodes = New-Object 'Collections.Generic.List[string]'

function Build-Fixture([string]$Version, [string]$Label, [bool]$IncludeObsolete) {
  $contentPath = Join-Path $testRoot ($Label + '.txt')
  Set-Content -LiteralPath $contentPath -Value $Label -Encoding ascii
  $escapedPath = [Security.SecurityElement]::Escape($contentPath)
  $obsoleteComponent = ''
  $obsoleteReference = ''
  if ($IncludeObsolete) {
    $obsoleteComponent = @"
      <Component Id="ObsoleteFile" Guid="$obsoleteGuid">
        <File Source="$escapedPath" Name="obsolete.txt" />
        <RegistryValue Root="HKCU" Key="Software\$testName" Name="Obsolete" Type="integer" Value="1" KeyPath="yes" />
      </Component>
"@
    $obsoleteReference = '<ComponentRef Id="ObsoleteFile" />'
  }
  $payload = @"
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Fragment>
    <DirectoryRef Id="INSTALLFOLDER">
      <Component Id="MainFile" Guid="$mainGuid">
        <File Source="$escapedPath" Name="take_a_look_v2.exe" />
        <RegistryValue Root="HKCU" Key="Software\$testName" Name="Main" Type="integer" Value="1" KeyPath="yes" />
        <RemoveFolder Id="RemoveApp" On="uninstall" />
        <RemoveFolder Id="RemovePrograms" Directory="UserProgramsFolder" On="uninstall" />
      </Component>
      $obsoleteComponent
    </DirectoryRef>
    <ComponentGroup Id="ApplicationFiles"><ComponentRef Id="MainFile" />$obsoleteReference</ComponentGroup>
  </Fragment>
</Wix>
"@
  $payloadPath = Join-Path $testRoot ($Label + '.wxs')
  [IO.File]::WriteAllText($payloadPath, $payload)
  $msi = Join-Path $testRoot ($Label + '.msi')
  & $wix build $packagePath (Join-Path $project 'windows\installer\UI.wxs') $payloadPath -arch x64 -culture zh-CN `
    -ext $extension -d "ProductVersion=$Version" -d "AppIcon=$(Join-Path $project 'windows\runner\resources\app_icon.ico')" -o $msi
  if ($LASTEXITCODE -ne 0) { throw 'Fixture compilation failed.' }
  $com = New-Object -ComObject WindowsInstaller.Installer
  $db = $com.OpenDatabase($msi, 0)
  $view = $db.OpenView('SELECT `Value` FROM `Property` WHERE `Property` = ''ProductCode''')
  $null = $view.Execute()
  $record = $view.Fetch()
  $productCodes.Add($record.StringData(1))
  $null = $view.Close()
  foreach ($object in @($record, $view, $db, $com)) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($object) }
  return $msi
}

function Run-Msi([string[]]$Arguments, [string]$Label, [int[]]$Expected = @(0)) {
  $log = Join-Path $testRoot ($Label + '.log')
  $process = Start-Process -FilePath msiexec.exe -WindowStyle Hidden -PassThru `
    -ArgumentList ($Arguments + @('/qn', '/norestart', '/L*v', ('"' + $log + '"')))
  $null = $process.Handle
  if (-not $process.WaitForExit(60000)) { throw "Installer test timed out: $log" }
  if ($Expected -notcontains $process.ExitCode) { throw "Installer test failed (exit $($process.ExitCode)): $log" }
}

try {
  $first = Build-Fixture '0.1.0' 'first' $true
  $same = Build-Fixture '0.1.0' 'same-version' $false
  $next = Build-Fixture '0.1.1' 'next-version' $false
  $moved = Build-Fixture '0.1.2' 'relocated-version' $false
  Run-Msi @('/i', ('"' + $first + '"'), ('INSTALLFOLDER="' + $installed + '"')) 'install'
  if (-not (Test-Path -LiteralPath (Join-Path $installed 'obsolete.txt'))) { throw 'Initial file was not installed.' }
  $recordingDirectory = Join-Path $installed 'recordings\session'
  New-Item -ItemType Directory -Path $recordingDirectory -Force | Out-Null
  $recording = Join-Path $recordingDirectory 'samples.talraw'
  Set-Content -LiteralPath $recording -Value 'keep acquisition data' -Encoding ascii
  # Upgrades discover the registered custom directory without an INSTALLFOLDER override.
  Run-Msi @('/i', ('"' + $same + '"')) 'same-version-upgrade'
  if (Test-Path -LiteralPath (Join-Path $installed 'obsolete.txt')) { throw 'Upgrade left an obsolete file.' }
  if ((Get-Content -LiteralPath (Join-Path $installed 'take_a_look_v2.exe') -Raw).Trim() -ne 'same-version') { throw 'Same-version upgrade failed.' }
  Run-Msi @('/i', ('"' + $next + '"')) 'upgrade'
  if ((Get-Content -LiteralPath (Join-Path $installed 'take_a_look_v2.exe') -Raw).Trim() -ne 'next-version') { throw 'Version upgrade failed.' }
  # An explicit new path must take precedence over the location saved in HKCU.
  Run-Msi @('/i', ('"' + $moved + '"'), ('INSTALLFOLDER="' + $relocated + '"')) 'relocate'
  if (Test-Path -LiteralPath (Join-Path $installed 'take_a_look_v2.exe')) { throw 'Relocation left the old installed application.' }
  if ((Get-Content -LiteralPath (Join-Path $relocated 'take_a_look_v2.exe') -Raw).Trim() -ne 'relocated-version') { throw 'The saved directory overrode the requested new path.' }
  $newRecordings = Join-Path $relocated 'recordings\session'
  New-Item -ItemType Directory -Path $newRecordings -Force | Out-Null
  $newRecording = Join-Path $newRecordings 'samples.talraw'
  Set-Content -LiteralPath $newRecording -Value 'keep new acquisition data' -Encoding ascii
  Run-Msi @('/i', ('"' + $first + '"')) 'downgrade' @(1603, 1638)
  Run-Msi @('/x', $productCodes[3]) 'uninstall'
  if (Test-Path -LiteralPath (Join-Path $installed 'take_a_look_v2.exe')) { throw 'Uninstall left an installed file.' }
  if (Test-Path -LiteralPath (Join-Path $relocated 'take_a_look_v2.exe')) { throw 'Uninstall left the relocated application.' }
  if ((Get-Content -LiteralPath $recording -Raw).Trim() -ne 'keep acquisition data') { throw 'Recordings were changed.' }
  if ((Get-Content -LiteralPath $newRecording -Raw).Trim() -ne 'keep new acquisition data') { throw 'Relocated recordings were changed.' }
  foreach ($folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
    if (Test-Path -LiteralPath (Join-Path $folder ($testName + '.lnk'))) { throw 'Uninstall left a shortcut.' }
    if (Test-Path -LiteralPath (Join-Path $folder $testName)) { throw 'Uninstall left the start menu directory.' }
  }
  Write-Host "MSI lifecycle passed: custom Unicode path, remembered location, same-version replacement, upgrade, relocation, downgrade rejection, obsolete-file removal and recording preservation. Logs: $testRoot"
} finally {
  # Only these randomly identified fixture products can be touched by cleanup.
  foreach ($code in $productCodes) { Run-Msi @('/x', $code) ('cleanup-' + $code.Trim('{}')) @(0, 1605) }
}
