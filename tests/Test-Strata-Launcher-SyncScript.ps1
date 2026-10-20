$ErrorActionPreference = 'Stop'

$scriptPath = (Resolve-Path 'launcher\Sync-Strata-Launcher.ps1').Path
$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    $summary = @($parseErrors | Select-Object -First 5 | ForEach-Object {
        "line $($_.Extent.StartLineNumber): $($_.Message)"
    }) -join "`r`n"
    throw "FAIL: Sync-Strata-Launcher.ps1 cannot be loaded by Windows PowerShell 5.`r`n$summary"
}

'PASS: Sync-Strata-Launcher.ps1 parses through the Windows PowerShell 5 file loader'
