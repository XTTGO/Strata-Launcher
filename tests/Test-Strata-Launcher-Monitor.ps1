$ErrorActionPreference = 'Stop'

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) {
        throw "FAIL: $Message`r`nExpected: $Expected`r`nActual:   $Actual"
    }
}

. (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'Strata-Launcher-Environment.ps1')

$strataHealth = [pscustomobject]@{ service = 'strata'; status = 'ok' }
Assert-Equal (Get-StrataMonitorUrl -Port 8080 -Health $strataHealth) 'http://127.0.0.1:8080/#monitor' 'the default port opens the official Monitor tab'
Assert-Equal (Get-StrataMonitorUrl -Port 9001 -Health $strataHealth) 'http://127.0.0.1:9001/#monitor' 'the selected non-default port is used'
Assert-Equal (Get-StrataMonitorUrl -Port 8080 -Health $null) $null 'an unavailable service does not produce a browser target'
Assert-Equal (Get-StrataMonitorUrl -Port 8080 -Health ([pscustomobject]@{ service = 'other'; status = 'ok' })) $null 'another service on the port is not treated as Strata'

'PASS: official Monitor target follows the selected Strata port and rejects other services'
