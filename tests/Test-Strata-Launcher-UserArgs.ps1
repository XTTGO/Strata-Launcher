$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Strata-Launcher-Settings.ps1')

$config = [pscustomobject]@{
    args = @('--max-context','32768','--vram-reserve-mib','2048','--vision')
    user_args = @('--max-context','131072','--vram-reserve-mib','0','--spec','4')
}
$initial = @(Get-StrataEffectiveArgs -Config $config)
if (($initial -join ' ') -ne '--vision --max-context 131072 --vram-reserve-mib 0 --spec 4') {
    throw "User options were not shown as effective settings: $($initial -join ' ')"
}
$config.args = @('--max-context','262144','--vram-reserve-mib','3072','--spec','4')
Sync-StrataUserArgsForSave -Config $config -OriginalArgs $initial
$effective = @(Get-StrataEffectiveArgs -Config $config)
if (($effective -join ' ') -ne '--spec 4 --max-context 262144 --vram-reserve-mib 3072') {
    throw "Saved options were overridden by stale user_args: $($effective -join ' ')"
}
if ($config.user_args -contains '--vision' -or ($config.args_written -join ' ') -ne ($config.args -join ' ')) {
    throw 'Vision removal or args_written stamping was lost.'
}

$legacy = [pscustomobject]@{ args = @('--max-context','32768','--spec','4') }
$unchanged = @(Get-StrataEffectiveArgs -Config $legacy)
Sync-StrataUserArgsForSave -Config $legacy -OriginalArgs $unchanged
if ($legacy.PSObject.Properties['user_args'] -or ($legacy.args_written -join ' ') -ne ($legacy.args -join ' ')) {
    throw 'Unchanged legacy options should not become user overrides.'
}
'PASS: effective user args and saved launcher settings agree'
