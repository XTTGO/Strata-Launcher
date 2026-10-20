$ErrorActionPreference = 'Stop'

$benchmarkPath = (Resolve-Path 'launcher\Benchmark-Launcher.ps1').Path
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($benchmarkPath,[ref]$tokens,[ref]$errors)

if ($errors.Count -gt 0) {
    $summary = @($errors | Select-Object -First 5 | ForEach-Object {
        "line $($_.Extent.StartLineNumber): $($_.Message)"
    }) -join "`r`n"
    throw "FAIL: Benchmark-Launcher.ps1 cannot be parsed by the Windows PowerShell 5 file loader.`r`n$summary"
}

'PASS: Benchmark-Launcher.ps1 parses through the Windows PowerShell 5 file loader'
