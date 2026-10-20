$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Strata-Launcher-GpuPower.ps1')

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw "FAIL: $Message (expected $Expected, got $Actual)" }
}

$sample = '0, GPU-af64da72-8fa1-a3c0-69e5-b2fd0861cc77, NVIDIA GeForce RTX 3090, 259.00, 370.00, 100.00, 420.00'
$gpu = @(Convert-StrataGpuPowerCsv $sample)[0]
Assert-Equal $gpu.Uuid 'GPU-af64da72-8fa1-a3c0-69e5-b2fd0861cc77' 'GPU must be addressed by UUID'
Assert-Equal $gpu.Current 259 'current cap must parse'
Assert-Equal $gpu.Default 370 'factory cap must parse'
Assert-Equal $gpu.Minimum 100 'minimum must parse'
Assert-Equal $gpu.Maximum 420 'maximum must parse'
if (@(Convert-StrataGpuPowerCsv '0, GPU-abc, Unsupported, N/A, N/A, N/A, N/A').Count -ne 0) { throw 'FAIL: unsupported GPU must not be writable' }

$work = Join-Path (Join-Path $PSScriptRoot '.tmp') ('strata-gpu-power-test-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
try {
    $statePath = Join-Path $work 'gpu-power-restore.json'
    $script:live = 259
    $script:sets = [Collections.ArrayList]::new()
    $query = { param($uuid) [pscustomobject]@{ Uuid=$uuid; Name='NVIDIA GeForce RTX 3090'; Current=$script:live; Default=370; Minimum=100; Maximum=420 } }
    $set = { param($uuid,$watts) [void]$script:sets.Add("$uuid/$watts"); $script:live=$watts }
    try { Set-StrataGpuPowerLimit -Uuid $gpu.Uuid -Watts 99 -StatePath $statePath -Query $query -Set $set | Out-Null; throw 'FAIL: below-min cap accepted' } catch { if ($_.Exception.Message -like 'FAIL:*') { throw } }
    Assert-Equal $script:sets.Count 0 'invalid cap must never reach driver'
    Set-StrataGpuPowerLimit -Uuid $gpu.Uuid -Watts 220 -StatePath $statePath -Query $query -Set $set | Out-Null
    Assert-Equal $script:live 220 'apply should change the selected GPU'
    Assert-Equal (Get-StrataGpuPowerRestore -Uuid $gpu.Uuid -StatePath $statePath).Original 259 'restore baseline must survive launcher restart'
    Set-StrataGpuPowerLimit -Uuid $gpu.Uuid -Watts 210 -StatePath $statePath -Query $query -Set $set | Out-Null
    Assert-Equal (Get-StrataGpuPowerRestore -Uuid $gpu.Uuid -StatePath $statePath).Original 259 'second apply must preserve first baseline'
    $script:live=205
    try { Restore-StrataGpuPowerLimit -Uuid $gpu.Uuid -StatePath $statePath -Query $query -Set $set | Out-Null; throw 'FAIL: external change was overwritten' } catch { if ($_.Exception.Message -like 'FAIL:*') { throw } }
    Assert-Equal $script:live 205 'restore must not overwrite an external change'
    $script:live=210
    Restore-StrataGpuPowerLimit -Uuid $gpu.Uuid -StatePath $statePath -Query $query -Set $set | Out-Null
    Assert-Equal $script:live 259 'restore should use original cap, not factory default'
    if (Get-StrataGpuPowerRestore -Uuid $gpu.Uuid -StatePath $statePath) { throw 'FAIL: restore record should be cleared after readback' }
    Assert-Equal $script:sets.Count 3 'only two applies and one restore should touch driver'
    Set-StrataGpuPowerLimit -Uuid $gpu.Uuid -Watts 220 -StatePath $statePath -Query $query -Set $set | Out-Null
    $script:live=205
    try { Set-StrataGpuPowerLimit -Uuid $gpu.Uuid -Watts 200 -StatePath $statePath -Query $query -Set $set | Out-Null; throw 'FAIL: external change was silently overwritten' } catch { if ($_.Exception.Message -like 'FAIL:*') { throw } }
    Set-StrataGpuPowerLimit -Uuid $gpu.Uuid -Watts 200 -StatePath $statePath -Query $query -Set $set -AdoptCurrent | Out-Null
    Assert-Equal (Get-StrataGpuPowerRestore -Uuid $gpu.Uuid -StatePath $statePath).Original 205 'explicit takeover must use current external cap as baseline'
    Restore-StrataGpuPowerLimit -Uuid $gpu.Uuid -StatePath $statePath -Query $query -Set $set | Out-Null
    Assert-Equal $script:live 205 'takeover should restore the explicit new baseline'
    $failSet = { param($uuid,$watts) throw 'simulated UAC cancellation' }
    try { Set-StrataGpuPowerLimit -Uuid $gpu.Uuid -Watts 180 -StatePath $statePath -Query $query -Set $failSet | Out-Null; throw 'FAIL: cancelled elevation was reported as success' } catch { if ($_.Exception.Message -like 'FAIL:*') { throw } }
    if (Get-StrataGpuPowerRestore -Uuid $gpu.Uuid -StatePath $statePath) { throw 'FAIL: failed driver command left an active restore record' }
    $beforeRace=$script:sets.Count
    try { Set-StrataGpuPowerLimit -Uuid $gpu.Uuid -Watts 180 -StatePath $statePath -Query $query -Set $set -ExpectedCurrent 259 | Out-Null; throw 'FAIL: stale UI value was accepted' } catch { if ($_.Exception.Message -like 'FAIL:*') { throw } }
    Assert-Equal $script:sets.Count $beforeRace 'changed GPU state must block a stale confirmation'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}

'PASS: NVIDIA GPU power validation, readback, baseline, and guarded restore'
