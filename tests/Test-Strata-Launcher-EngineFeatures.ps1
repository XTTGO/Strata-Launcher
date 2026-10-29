$ErrorActionPreference = 'Stop'
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" } }
$launcherRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $launcherRoot 'Strata-Launcher-Settings.ps1')

$tempParent = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.tmp'))
$temp = [IO.Path]::GetFullPath((Join-Path $tempParent ('engine-features-' + [Guid]::NewGuid().ToString('N'))))
if (-not $temp.StartsWith($tempParent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Temporary path escaped tests/.tmp' }
try {
    [void](New-Item -ItemType Directory -Path $temp -Force)
    $pack = Join-Path $temp 'pack'
    [void](New-Item -ItemType Directory -Path $pack -Force)
    [IO.File]::WriteAllText((Join-Path $pack 'ds4.txt'), "image_token_id 1`nvision.num_hidden_layers 24`n")
    $ds = [pscustomobject]@{ arch = 'deepseek41'; args = [string[]]@('--pack',$pack,'--vision','off') }
    $ready = Get-StrataDeepSeekVisionStatus -Config $ds -EngineVersion '0.1.52'
    Assert-True ($ready.Available -and -not $ready.Enabled) '0.1.52 with a vision pack must honour --vision off'
    $ds | Add-Member -NotePropertyName user_args -NotePropertyValue ([string[]]@('--vision','on'))
    $overridden = Get-StrataDeepSeekVisionStatus -Config $ds -EngineVersion '0.1.52'
    Assert-True ($overridden.Available -and $overridden.Enabled) 'effective user_args must determine the shown vision state'
    $old = Get-StrataDeepSeekVisionStatus -Config $ds -EngineVersion '0.1.51'
    Assert-True (-not $old.Available) 'the old DeepSeek engine must not offer image input'
    [IO.File]::WriteAllText((Join-Path $pack 'ds4.txt'), "image_token_id 1`n")
    $textOnly = Get-StrataDeepSeekVisionStatus -Config $ds -EngineVersion '0.1.52'
    Assert-True (-not $textOnly.Available -and $textOnly.Reason -match 'pack') 'a text-only pack must explain why images are unavailable'

    $qwen = [pscustomobject]@{ arch = ''; env = [pscustomobject]@{ KEEP_ME = 'yes' } }
    Assert-True (-not (Get-StrataSpeedSwitchIsOn -Config $qwen -Id 'faster_long_prompts')) 'KVA defaults off'
    Set-StrataSpeedSwitch -Config $qwen -Id 'faster_long_prompts' -Enabled $true
    Assert-True ($qwen.env.STRATA_KVA -eq '1' -and $qwen.env.KEEP_ME -eq 'yes') 'KVA on must preserve unrelated environment'
    Set-StrataSpeedSwitch -Config $qwen -Id 'faster_long_prompts' -Enabled $false
    Assert-True ($null -eq $qwen.env.PSObject.Properties['STRATA_KVA'] -and $qwen.env.KEEP_ME -eq 'yes') 'KVA off must remove only its own flag'
    Assert-True (Get-StrataSpeedSwitchIsOn -Config $qwen -Id 'faster_12gb_nvidia') '12 GB routing defaults on'
    Set-StrataSpeedSwitch -Config $qwen -Id 'faster_12gb_nvidia' -Enabled $false
    Assert-True ($qwen.env.STRATA_ROUTE_PRIOR -eq '0') '12 GB routing off must use the official value'
    Set-StrataSpeedSwitch -Config $qwen -Id 'faster_12gb_nvidia' -Enabled $true
    Assert-True ($null -eq $qwen.env.PSObject.Properties['STRATA_ROUTE_PRIOR']) 'routing on must restore the engine default'

    $deepseek = [pscustomobject]@{ arch = 'deepseek41'; env = [pscustomobject]@{ CUSTOM = 'keep' } }
    Set-StrataSpeedSwitch -Config $deepseek -Id 'deepseek_speedups' -Enabled $false
    Assert-True (-not (Get-StrataSpeedSwitchIsOn -Config $deepseek -Id 'deepseek_speedups')) 'the official seven DeepSeek flags must turn the speedups off'
    Assert-True ($deepseek.env.DS4_DEFAULTS -eq '026' -and $deepseek.env.DS4_STORE_PUT -eq '0') 'DeepSeek rollback must write the official values'
    Set-StrataSpeedSwitch -Config $deepseek -Id 'deepseek_speedups' -Enabled $true
    Assert-True ((Get-StrataSpeedSwitchIsOn -Config $deepseek -Id 'deepseek_speedups') -and $deepseek.env.CUSTOM -eq 'keep') 're-enabling speedups must keep other environment values'

    $small = [pscustomobject]@{ Name='RTX 3060'; MemoryMiB=12288; Vendor='nvidia'; Integrated=$false }
    $large = [pscustomobject]@{ Name='RTX 3090'; MemoryMiB=24576; Vendor='nvidia'; Integrated=$false }
    $radeon = [pscustomobject]@{ Name='Radeon RX 9070'; MemoryMiB=16384; Vendor='amd'; Arch='gfx1201' }
    $flash = [pscustomobject]@{ arch = '' }
    $ownPath = [pscustomobject]@{ arch = 'qwen35moe' }
    Assert-True (@(Get-StrataApplicableSpeedSwitches -Config $flash -Backend 'cuda' -Gpus @($small)) -contains 'faster_12gb_nvidia') '12 GB NVIDIA cards should see the routing switch'
    Assert-True (-not (@(Get-StrataApplicableSpeedSwitches -Config $flash -Backend 'cuda' -Gpus @($large)) -contains 'faster_12gb_nvidia')) '24 GB NVIDIA cards should not see the small-card switch'
    Assert-True (-not (@(Get-StrataApplicableSpeedSwitches -Config $ownPath -Backend 'cuda' -Gpus @($small)) -contains 'faster_long_prompts')) 'Qwen3.6 must not offer the Qwen3.8 KVA switch'
    Assert-True (@(Get-StrataApplicableSpeedSwitches -Config $flash -Backend 'hip' -Gpus @($radeon)) -contains 'faster_radeon_9000') 'Radeon RX 9000 should see its speed switch'
    Assert-True (@(Get-StrataApplicableSpeedSwitches -Config $deepseek -Backend 'cuda' -Gpus @($small)) -contains 'deepseek_speedups') 'DeepSeek should see its speedups switch'
    'PASS: latest engine vision and speed switches preserve the official argument and environment contracts'
} finally {
    if (Test-Path -LiteralPath $temp -PathType Container) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
