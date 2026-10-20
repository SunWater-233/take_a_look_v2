param(
    [Parameter(Mandatory = $true)]
    [string]$Executable
)

$ErrorActionPreference = 'Stop'
$runtimeFile = Get-Item -LiteralPath $Executable -ErrorAction Stop
if ($runtimeFile.PSIsContainer -or $runtimeFile.Extension -ne '.exe') {
    throw "Expected a generated Windows executable: $Executable"
}

# Executables built in a Low-integrity checkout inherit that label. Windows
# then starts them at Low integrity, preventing ordinary AppData writes even
# when the user's DACL grants full control. Label only the generated runtime
# file for normal desktop execution; never change the checkout or data ACLs.
& "$env:SystemRoot\System32\icacls.exe" $runtimeFile.FullName /setintegritylevel M | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Unable to set the generated runtime's integrity label to Medium. Rebuild from a normal Windows shell: $($runtimeFile.FullName)"
}
