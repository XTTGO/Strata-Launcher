$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Resolve-Path 'launcher') 'Strata-Launcher-Reload.ps1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "FAIL: in-process reload module is missing: $modulePath"
}
$moduleSource = Get-Content -LiteralPath $modulePath -Raw -Encoding UTF8
. ([scriptblock]::Create($moduleSource))

$probeRoot = Join-Path (Resolve-Path 'launcher\tests').Path ('reload probe ' + [Guid]::NewGuid().ToString('N'))
$probeScript = Join-Path $probeRoot 'probe.ps1'
$markerPath = Join-Path $probeRoot 'reloaded.json'
try {
    [void](New-Item -ItemType Directory -Path $probeRoot -Force)
    $escapedMarker = $markerPath.Replace("'", "''")
    $probeSource = @"
param([string]`$ConfigPath)
@{ pid=`$PID; config=`$ConfigPath } | ConvertTo-Json | Set-Content -LiteralPath '$escapedMarker' -Encoding UTF8
"@
    [IO.File]::WriteAllText($probeScript, $probeSource, [Text.UTF8Encoding]::new($true))

    $expectedConfig = 'D:\AI\Strata\model with spaces.json'
    $result = Invoke-StrataLauncherReload -LauncherPath $probeScript -ConfigPath $expectedConfig
    if (-not (Test-Path -LiteralPath $markerPath)) { throw 'FAIL: reload did not execute the launcher script' }
    $actual = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$actual.pid -ne $PID) { throw "FAIL: model switch created a new process ($($actual.pid) instead of $PID)" }
    if ([string]$actual.config -ne $expectedConfig) { throw 'FAIL: model switch did not pass the selected config path' }
    'PASS: model switch reloads in the existing PowerShell process'
} finally {
    if (Test-Path -LiteralPath $probeRoot) { Remove-Item -LiteralPath $probeRoot -Recurse -Force }
}
