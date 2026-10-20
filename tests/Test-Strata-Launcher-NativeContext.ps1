$ErrorActionPreference='Stop'
. ([scriptblock]::Create((Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Strata-Launcher-Settings.ps1') -Raw -Encoding UTF8)))
$flashConfig=[pscustomobject]@{ model_name='qwen3.8-flash-next-iq3_s'; args=@('--pack','pack','--native','flash.gguf'); arch=$null }
if (Test-StrataOwnPathConfig -Config $flashConfig) { throw 'Flash-Next with --native was classified as Qwen3.6.' }
$qwen36Config=[pscustomobject]@{ model_name='Qwen3.6'; arch='qwen35moe'; args=@('--native','qwen36.gguf') }
if (-not (Test-StrataOwnPathConfig -Config $qwen36Config)) { throw 'Qwen3.6 was not recognized.' }
$original=@('--native','D:\models\qwen36.gguf','--max-context','131072','--prefill','auto','--mtp','2','--expert-vram','9000')
$updated=Set-StrataNativeContextArgs -ArgsList $original -MaxContext 262144
if ($updated.Count -ne $original.Count) { throw 'Native argument count changed.' }
if ($updated[3] -ne '262144') { throw 'Context was not updated.' }
if ($updated[5] -ne 'auto' -or $updated[7] -ne '2' -or $updated[9] -ne '9000') { throw 'Native model flags changed.' }
try { [void](Set-StrataNativeContextArgs -ArgsList $original -MaxContext 524288); throw 'Expected context guard.' }
catch { if ($_.Exception.Message -eq 'Expected context guard.') { throw } }
'Native context arguments passed.'
