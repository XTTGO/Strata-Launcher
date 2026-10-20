$ErrorActionPreference = 'Stop'

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw "FAIL: $Message (expected $Expected, got $Actual)" }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}

. (Join-Path $PSScriptRoot '..\Strata-Launcher-Settings.ps1')

$existing = [pscustomobject]@{
    top_p = 0.8
    repeat_penalty = 1.2
    repeat_last_n = 0
    experimental_speed_projection = $false
    future_setting = 'preserve me'
    seed = 42
}
Assert-Equal (Get-StrataSamplingValue -Sampling $existing -Name 'repetition_penalty' -Alias 'repeat_penalty' -Fallback 1.0) 1.2 'the UI should read the official repetition alias'
Assert-Equal (Get-StrataSamplingValue -Sampling $existing -Name 'penalty_last_n' -Alias 'repeat_last_n' -Fallback 64) 0 'a zero-length penalty window must not be replaced by a fallback'

$edited = [pscustomobject]@{ top_p = 0.9; repetition_penalty = 1.3; penalty_last_n = 0 }
$merged = Merge-StrataSampling -Existing $existing -Edited $edited -SeedText ''
Assert-Equal $merged.top_p 0.9 'an edited sampling value should be saved'
Assert-Equal $merged.repetition_penalty 1.3 'the canonical repetition key should be saved'
Assert-Equal $merged.penalty_last_n 0 'the canonical window key should preserve zero'
Assert-Equal $merged.experimental_speed_projection $false 'an unshown supported option must survive saving'
Assert-Equal $merged.future_setting 'preserve me' 'an unshown future option must survive saving'
Assert-True ($null -eq $merged.PSObject.Properties['repeat_penalty']) 'the alias must be removed to avoid a duplicate-key refusal by Strata'
Assert-True ($null -eq $merged.PSObject.Properties['repeat_last_n']) 'the window alias must be removed to avoid a duplicate-key refusal by Strata'
Assert-True ($null -eq $merged.PSObject.Properties['seed']) 'clearing the seed input must remove the old seed'
Assert-Equal $existing.repeat_penalty 1.2 'merging must not mutate the source config in memory'

$withSeed = Merge-StrataSampling -Existing $existing -Edited $edited -SeedText '123'
Assert-Equal $withSeed.seed 123 'an explicit seed input should be saved'

'PASS: sampling aliases display correctly and saving retains unshown options'
