$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Strata-Launcher-Settings.ps1')

# An official config may carry its own --pool-workers, and user_args may override it again.
$config = [pscustomobject]@{
    args = @('--max-context','32768','--pool-workers','6')
    user_args = @('--pool-workers','8','--spec','4')
}
$initial = @(Get-StrataEffectiveArgs -Config $config)
if (($initial -join ' ') -ne '--max-context 32768 --pool-workers 8 --spec 4') {
    throw "User --pool-workers was not shown as the effective count: $($initial -join ' ')"
}

# The launcher sets 12 workers: that value must win over the stale user override.
$config.args = @('--max-context','32768','--pool-workers','12')
Sync-StrataUserArgsForSave -Config $config -OriginalArgs $initial
$effective = @(Get-StrataEffectiveArgs -Config $config)
if (($effective -join ' ') -ne '--max-context 32768 --spec 4 --pool-workers 12') {
    throw "Saved --pool-workers was overridden by stale user_args: $($effective -join ' ')"
}

# 0 means automatic: the flag is removed, and the stale user override goes with it.
$config.args = @('--max-context','32768')
Sync-StrataUserArgsForSave -Config $config -OriginalArgs $effective
$effective = @(Get-StrataEffectiveArgs -Config $config)
if ($effective -contains '--pool-workers' -or ($config.user_args -contains '--pool-workers')) {
    throw "Automatic mode still pins a worker count: $($effective -join ' ')"
}

# A config that never mentions the flag stays untouched and automatic.
$clean = [pscustomobject]@{ args = @('--max-context','32768') }
$before = @(Get-StrataEffectiveArgs -Config $clean)
Sync-StrataUserArgsForSave -Config $clean -OriginalArgs $before
$after = @(Get-StrataEffectiveArgs -Config $clean)
if (($after -join ' ') -ne '--max-context 32768') {
    throw "A plain config gained a worker setting: $($after -join ' ')"
}
'PASS: CPU worker count saves, overrides stale user_args, and restores automatic mode'
