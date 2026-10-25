$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}

function Get-Pairs([string[]]$List) {
    $pairs = @{}
    for ($i = 0; $i -lt $List.Count - 1; $i++) {
        if ([string]$List[$i] -like '--*') { $pairs[[string]$List[$i]] = [string]$List[$i + 1] }
    }
    return $pairs
}

$launcherRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $launcherRoot 'Strata-Launcher-Settings.ps1')

Assert-True (Test-StrataDeepSeekConfig -Config ([pscustomobject]@{ arch = 'deepseek41' })) 'arch deepseek41 should be detected'
Assert-True (Test-StrataDeepSeekConfig -Config ([pscustomobject]@{ exe = 'D:\AI\Strata\engine-dsv41\strata-dsv41.exe' })) 'the dsv41 executable should be detected'
Assert-True (-not (Test-StrataDeepSeekConfig -Config ([pscustomobject]@{ arch = 'qwen'; exe = 'D:\AI\Strata\engine\strata.exe' }))) 'the Qwen engine must not be detected as DeepSeek'
Assert-True ((Get-StrataInitialContext -Config ([pscustomobject]@{ arch = 'deepseek41'; args = [string[]]@('--pack','P') })) -eq 8192) 'DeepSeek without a context flag must show the official 8K default'
Assert-True ((Get-StrataInitialContext -Config ([pscustomobject]@{ arch = 'qwen4exp'; args = [string[]]@('--native','Q.gguf') })) -eq 131072) 'Qwen keeps its existing context fallback'

$official = [string[]]@('--pack','F:\AI\Strata-data\packs\deepseek-v4.1-flash-ist-das-2.00bpw','--max-context','8192','--eos','1','--dspark','auto','--dspark-conf','0.65')
$settings = Get-StrataDeepSeekSettings -ArgsList $official
Assert-True ($settings.Context -eq 8192) 'the official context should be read'
Assert-True ($settings.Dspark -eq 'auto') 'the official DSpark mode should be read'
Assert-True ($settings.DsparkConf -eq '0.65') 'the official DSpark confidence should be read'
Assert-True ($settings.ReserveMib -eq '') 'an unset reserve should stay empty'
Assert-True ($settings.CpuThreads -eq '') 'unset CPU threads should stay empty'

$list = [Collections.ArrayList]::new()
foreach ($item in $official) { [void]$list.Add($item) }
[void]$list.Add('--kv'); [void]$list.Add('int8')
[void]$list.Add('--vram-reserve-mib'); [void]$list.Add('990')
[void]$list.Add('--vision')

$saved = Set-StrataDeepSeekArgs -List $list -Settings ([pscustomobject]@{
    Context = 16384; ReserveMib = 2048; CpuThreads = 12; Dspark = 'on'; DsparkConf = '0.7'; SsdCache = 'auto'; PrefillChunk = '1024'; Tp = '1'
})
$out = [string[]]@($saved)
foreach ($flag in @('--kv','--vram-reserve-mib','--pool-workers','--kv-resident','--rope-scaling','--rope-scale','--vision')) {
    Assert-True (-not (@($out) -contains $flag)) "the Qwen-only $flag should be removed"
}
$pairs = Get-Pairs $out
Assert-True ($pairs['--max-context'] -eq '16384') 'the context should be saved'
Assert-True ($pairs['--reserve-mib'] -eq '2048') 'the reserve should be saved as --reserve-mib'
Assert-True ($pairs['--cpu-threads'] -eq '12') 'the threads should be saved as --cpu-threads'
Assert-True ($pairs['--dspark'] -eq 'on') 'the DSpark mode should be saved'
Assert-True ($pairs['--dspark-conf'] -eq '0.7') 'the DSpark confidence should be saved'
Assert-True (-not $pairs.ContainsKey('--ssd-cache')) 'auto SSD cache must omit the flag; the engine parses the literal auto as zero'
Assert-True ($pairs['--prefill-chunk'] -eq '1024') 'the prefill chunk should be saved'
Assert-True ($pairs['--pack'] -eq 'F:\AI\Strata-data\packs\deepseek-v4.1-flash-ist-das-2.00bpw') 'the official pack must be preserved'
Assert-True ($pairs['--eos'] -eq '1') 'the official EOS setting must be preserved'
Assert-True (@($out | Where-Object { $_ -eq '--dspark' }).Count -eq 1) 'DSpark must be written once'

$none = Set-StrataDeepSeekArgs -List ([Collections.ArrayList]::new([string[]]@('--pack','P','--dspark','off'))) -Settings ([pscustomobject]@{
    Context = 8192; ReserveMib = ''; CpuThreads = ''; Dspark = 'none'; DsparkConf = ''; SsdCache = ''; PrefillChunk = ''; Tp = ''
})
Assert-True ((Get-Pairs ([string[]]@($none)))['--dspark'] -eq 'none') 'none must skip loading DSpark rather than silently becoming auto'

Assert-True (-not (Test-StrataDeepSeekExpertsSupported -Version '0.1.49.2')) '0.1.49.2 must not receive --experts'
Assert-True (Test-StrataDeepSeekExpertsSupported -Version '0.1.50') '0.1.50 may receive --experts'
Assert-True (Test-StrataDeepSeekExpertsSupported -Version '0.1.51') 'newer engines may receive --experts'
Assert-True (-not (Test-StrataDeepSeekExpertsSupported -Version 'unknown')) 'an unknown engine version must be treated conservatively'

$oldEngine = Set-StrataDeepSeekArgs -List ([Collections.ArrayList]::new([string[]]@('--pack','P','--experts','6'))) -Settings ([pscustomobject]@{
    Context = 8192; ReserveMib = ''; CpuThreads = ''; Dspark = 'auto'; DsparkConf = ''; SsdCache = ''; PrefillChunk = ''; Tp = ''
    Experts = '5'; ExpertsSupported = $false
})
Assert-True (-not (@($oldEngine) -contains '--experts')) 'old engine must not receive a stale or newly chosen --experts flag'
$newEngine = Set-StrataDeepSeekArgs -List ([Collections.ArrayList]::new([string[]]@('--pack','P'))) -Settings ([pscustomobject]@{
    Context = 8192; ReserveMib = ''; CpuThreads = ''; Dspark = 'auto'; DsparkConf = ''; SsdCache = ''; PrefillChunk = ''; Tp = ''
    Experts = '6'; ExpertsSupported = $true
})
Assert-True ((Get-Pairs ([string[]]@($newEngine)))['--experts'] -eq '6') 'new engine should receive explicit full-quality choice'

$mixed = Set-StrataDeepSeekArgs -List ([Collections.ArrayList]::new([string[]]@(
    '--pack','P','--prefill','auto','--spec','4','--mtp','on','--native','Q.gguf',
    '--resident-budget-gib','32','--expert-cache','auto','--layer-split','auto','--eos','1','--window','2048'
))) -Settings ([pscustomobject]@{
    Context = 8192; ReserveMib = ''; CpuThreads = ''; Dspark = 'auto'; DsparkConf = ''; SsdCache = ''; PrefillChunk = ''; Tp = ''
})
foreach ($flag in @('--prefill','--spec','--mtp','--native','--resident-budget-gib','--expert-cache','--layer-split')) {
    Assert-True (-not (@($mixed) -contains $flag)) "Qwen-only $flag must not reach the DeepSeek engine"
}
Assert-True ((Get-Pairs ([string[]]@($mixed)))['--eos'] -eq '1') 'official DeepSeek EOS must stay'
Assert-True ((Get-Pairs ([string[]]@($mixed)))['--window'] -eq '2048') 'supported DeepSeek flags outside the UI must stay'

$tpItems = @(Get-StrataDeepSeekTpItems -CurrentValue '4')
Assert-True ($tpItems -contains '4') 'an existing supported tensor-parallel value must remain selectable'
Assert-True ($tpItems -contains '1' -and $tpItems -contains '2') 'common tensor-parallel values must remain selectable'

$mixedConfig = [pscustomobject]@{
    arch = 'deepseek41'; args = [string[]]@('--pack','P','--eos','1')
    drafting = 'mtp'; mtp = $true; vram_elastic = $true; vram_segment_mib = 512
    pool_cores = '2-14:2'; expert_profile_save = 'Q.profile'; expert_profile_save_every = 10
    gpu_roles = [pscustomobject]@{ '0' = 'main' }; layer_split = 'auto'; parallel = 4
    model_name = 'deepseek-v4.1-flash'
}
$safeConfig = Remove-StrataDeepSeekUnsupportedConfig -Config $mixedConfig
foreach ($key in @('drafting','mtp','vram_elastic','vram_segment_mib','pool_cores','expert_profile_save',
                   'expert_profile_save_every','layer_split','parallel')) {
    Assert-True ($null -eq $safeConfig.PSObject.Properties[$key]) "Qwen-only config field $key must not reach the DeepSeek start"
}
Assert-True ($null -ne $safeConfig.PSObject.Properties['gpu_roles']) 'unchanged server GPU selection roles must be preserved until the user edits GPU selection'
Assert-True ($safeConfig.model_name -eq 'deepseek-v4.1-flash') 'the model identity must stay'
Assert-True ((Get-Pairs ([string[]]@($safeConfig.args)))['--pack'] -eq 'P') 'the DeepSeek pack must stay'

$staleUserConfig = [pscustomobject]@{
    arch = 'deepseek41'; args = [string[]]@('--pack','P','--max-context','8192')
    user_args = [string[]]@('--prefill','auto','--window','2048')
}
Sync-StrataUserArgsForSave -Config $staleUserConfig -OriginalArgs ([string[]]@('--pack','P','--max-context','8192','--prefill','auto','--window','2048'))
Assert-True (-not (@($staleUserConfig.user_args) -contains '--prefill')) 'Qwen-only user_args must be removed too'
Assert-True (@($staleUserConfig.user_args) -contains '--window') 'a DeepSeek user_args option outside the editor must stay'

$empty = Set-StrataDeepSeekArgs -List ([Collections.ArrayList]::new([string[]]@('--pack','P'))) -Settings ([pscustomobject]@{
    Context = 8192; ReserveMib = ''; CpuThreads = ''; Dspark = 'auto'; DsparkConf = '0.65'; SsdCache = ''; PrefillChunk = ''; Tp = ''
})
$emptyOut = [string[]]@($empty)
Assert-True (-not (@($emptyOut) -contains '--reserve-mib')) 'an empty reserve should not be written'
Assert-True (-not (@($emptyOut) -contains '--cpu-threads')) 'empty CPU threads should not be written'
Assert-True (-not (@($emptyOut) -contains '--ssd-cache')) 'an empty SSD cache should not be written'

$officialUnofficial = Set-StrataDeepSeekArgs -List ([Collections.ArrayList]::new([string[]]@('--pack','P','--tp','2','--window','2048','--dspark','auto'))) -Settings ([pscustomobject]@{
    Context = 8192; ReserveMib = ''; CpuThreads = ''; Dspark = 'auto'; DsparkConf = ''; SsdCache = ''; PrefillChunk = ''; Tp = '2'
})
$unofficialOut = [string[]]@($officialUnofficial)
Assert-True (@($unofficialOut) -contains '--tp') 'the official --tp must be preserved'
Assert-True (@($unofficialOut) -contains '--window') 'engine flags the launcher does not edit must be preserved'
Assert-True (-not (@($unofficialOut) -contains '--dspark-conf')) 'an absent --dspark-conf must stay absent'

$config = [pscustomobject]@{ args = [string[]]@('--pack','P','--max-context','16384','--eos','1','--dspark','on'); user_args = [string[]]@('--dspark','auto') }
Sync-StrataUserArgsForSave -Config $config -OriginalArgs ([string[]]@('--pack','P','--max-context','8192','--eos','1','--dspark','auto'))
$userArgs = [string[]]@($config.user_args)
$userPairs = Get-Pairs $userArgs
Assert-True ($userPairs['--dspark'] -eq 'on') 'a changed DeepSeek flag must override the stale user_args value'
Assert-True ($userPairs['--max-context'] -eq '16384') 'a changed context must be mirrored into user_args'

$tpList = Set-StrataDeepSeekArgs -List ([Collections.ArrayList]::new([string[]]@('--pack','P','--tp','2'))) -Settings ([pscustomobject]@{
    Context = 8192; ReserveMib = ''; CpuThreads = ''; Dspark = 'auto'; DsparkConf = ''; SsdCache = ''; PrefillChunk = ''; Tp = ''
})
Assert-True (-not (@([string[]]@($tpList)) -contains '--tp')) 'an automatic --tp should be removed (engine default)'
$tpList2 = Set-StrataDeepSeekArgs -List ([Collections.ArrayList]::new([string[]]@('--pack','P'))) -Settings ([pscustomobject]@{
    Context = 8192; ReserveMib = ''; CpuThreads = ''; Dspark = 'auto'; DsparkConf = ''; SsdCache = ''; PrefillChunk = ''; Tp = '1'
})
Assert-True ((Get-Pairs ([string[]]@($tpList2)))['--tp'] -eq '1') 'a chosen --tp should be written'

. (Join-Path $launcherRoot 'Strata-Launcher-GpuPlacement.ps1')
$cards = @(
    [pscustomobject]@{ Index = 0; Uuid = 'u0'; BusId = '00000000:21:00.0'; MemoryMiB = 24576; Name = 'RTX 3090' },
    [pscustomobject]@{ Index = 1; Uuid = 'u1'; BusId = '00000000:4B:00.0'; MemoryMiB = 24576; Name = 'RTX 3090' }
)
$gpuConfig = [pscustomobject]@{ gpu = 0; gpu_roles = [pscustomobject]@{ '0' = 'main' }; layer_split = 'auto'; args = [string[]]@('--pack','P') }
$two = Set-StrataDeepSeekGpuConfig -Config $gpuConfig -Cards $cards -CurrentCards $cards -Selected @(0, 1)
Assert-True ([string]::Join(',', @($two.gpu | ForEach-Object { [string]$_ })) -eq '0,1') 'both chosen cards should be written to gpu'
Assert-True (-not $two.PSObject.Properties['gpu_roles']) 'DeepSeek must not keep Qwen gpu_roles'
Assert-True (-not $two.PSObject.Properties['layer_split']) 'DeepSeek must not keep the Qwen layer split'
$one = Set-StrataDeepSeekGpuConfig -Config $gpuConfig -Cards $cards -CurrentCards $cards -Selected @(1)
Assert-True ([int]$one.gpu -eq 1) 'a single chosen card should be a number'
$threw = $false
try { [void](Set-StrataDeepSeekGpuConfig -Config $gpuConfig -Cards $cards -CurrentCards $cards -Selected @()) } catch { $threw = $true }
Assert-True $threw 'an empty card selection must be rejected'

Assert-True ((Get-StrataDeepSeekModelKey 'D:\AI\Strata\strata-deepseek-v4.1-flash-ist-das-2.00bpw.json') -eq 'ist-das-2.00bpw') 'the model key should come from the DeepSeek config name'
Assert-True ((Get-StrataDeepSeekModelKey 'D:\AI\Strata\strata-iq3_s.json') -eq '') 'a Qwen config has no DeepSeek model key'

# --- expert-placement knobs: read, write, domain checks, mutual exclusion -------------------------------
# Keep this file ASCII: Windows PowerShell 5.1 reads a BOM-less script as the ANSI codepage, and the Chinese
# labels below are reached through the mapping helpers instead of being spelled out here.
$policyLabel = Get-StrataSsdPolicyItem 'lfulru'
$policyDefault = Get-StrataSsdPolicyItem ''
$placementSource = [string[]]@('--pack','P','--ssd-cache','96','--ssd-policy','lfu','--mmap-experts','on','--vram-experts','0.90','--dspark-block','3')
$placement = Get-StrataDeepSeekSettings -ArgsList $placementSource
Assert-True ($placement.SsdCache -eq '96') '--ssd-cache should be read'
Assert-True ($placement.SsdPolicy -eq 'lfu') '--ssd-policy should be read'
Assert-True ($placement.MmapExperts -eq 'on') '--mmap-experts should be read'
Assert-True ($placement.VramExperts -eq '0.90') '--vram-experts should be read'
Assert-True ($placement.DsparkBlock -eq '3') '--dspark-block should be read'
$blank = Get-StrataDeepSeekSettings -ArgsList ([string[]]@('--pack','P'))
foreach ($name in @('SsdPolicy','MmapExperts','VramExperts','DsparkBlock')) {
    Assert-True ((Get-StrataDeepSeekSetting $blank $name) -eq '') "an absent $name should stay empty"
}
Assert-True ((Get-StrataSsdPolicyValue $policyLabel) -eq 'lfulru') 'the lfu-to-lru label maps to the engine value'
Assert-True ((Get-StrataSsdPolicyValue $policyDefault) -eq '') 'the default label maps to no flag'
Assert-True ((Get-StrataSsdPolicyItem 'lfulru') -eq $policyLabel) 'the engine value maps back to the label'
Assert-True ((Get-StrataMmapItem 'off') -eq 'off') 'mmap on/off/auto keep their own labels'
Assert-True ((Get-StrataMmapValue 'off') -eq 'off') 'the mmap label maps to the engine value'

$placementSaved = Set-StrataDeepSeekArgs -List ([Collections.ArrayList]::new([string[]]@('--pack','P'))) -Settings ([pscustomobject]@{
    Context = 8192; ReserveMib = ''; CpuThreads = ''; Dspark = 'auto'; DsparkConf = ''
    SsdCache = '96'; SsdPolicy = $policyLabel; MmapExperts = 'auto'; VramExperts = '0.9'; PrefillChunk = ''; DsparkBlock = '3'; Tp = ''
})
$savedPairs = Get-Pairs ([string[]]@($placementSaved))
Assert-True ($savedPairs['--ssd-cache'] -eq '96') 'the SSD cache should be written'
Assert-True ($savedPairs['--ssd-policy'] -eq 'lfulru') 'the elimination policy should be written in the engine spelling'
Assert-True ($savedPairs['--mmap-experts'] -eq 'auto') 'the mmap mode should be written'
Assert-True ($savedPairs['--vram-experts'] -eq '0.9') 'the VRAM expert share should be written'
Assert-True ($savedPairs['--dspark-block'] -eq '3') 'the draft block should be written'

$badValues = Set-StrataDeepSeekArgs -List ([Collections.ArrayList]::new([string[]]@('--pack','P'))) -Settings ([pscustomobject]@{
    Context = 8192; ReserveMib = ''; CpuThreads = ''; Dspark = 'auto'; DsparkConf = ''
    SsdCache = ''; SsdPolicy = 'random'; MmapExperts = 'sideways'; VramExperts = '3.5'; PrefillChunk = ''; DsparkBlock = '99'; Tp = ''
})
$badPairs = Get-Pairs ([string[]]@($badValues))
foreach ($flag in @('--ssd-policy','--mmap-experts','--vram-experts','--dspark-block')) {
    Assert-True (-not $badPairs.ContainsKey($flag)) "an out-of-domain $flag must be dropped, not written"
}

$copyMode = Set-StrataDeepSeekArgs -List ([Collections.ArrayList]::new([string[]]@('--pack','P'))) -Settings ([pscustomobject]@{
    Context = 8192; ReserveMib = ''; CpuThreads = ''; Dspark = 'auto'; DsparkConf = ''
    SsdCache = '145'; SsdPolicy = ''; MmapExperts = 'off'; VramExperts = ''; PrefillChunk = ''; DsparkBlock = ''; Tp = ''
})
$copyPairs = Get-Pairs ([string[]]@($copyMode))
Assert-True ($copyPairs['--mmap-experts'] -eq 'off') 'copy mode should be written'
Assert-True ($copyPairs['--ssd-cache'] -eq '0') 'copying every expert into RAM must switch the store off instead of doubling the memory'

# --- presets: they only move the placement knobs, and the label follows the values -----------------------
function New-FakeDeepSeekControls([string]$Ssd, [string]$Policy, [string]$Mmap) {
    [ordered]@{
        Ssd = [pscustomobject]@{ Text = $Ssd }
        Policy = [pscustomobject]@{ SelectedItem = $Policy }
        Mmap = [pscustomobject]@{ SelectedItem = $Mmap }
        Vram = [pscustomobject]@{ Value = [double]0 }
        DsparkBlock = [pscustomobject]@{ Value = [double]0 }
    }
}
$presets = Get-StrataDeepSeekPresets -SsdCacheGb 145
Assert-True (-not (Test-StrataDeepSeekGpuSelectionChanged -Initial @(0,1) -Selected @() -AvailableCount 0)) 'without an NVIDIA inventory, save must preserve an existing AMD or unknown GPU selection'
Assert-True (Test-StrataDeepSeekGpuSelectionChanged -Initial @(0,1) -Selected @(0) -AvailableCount 2) 'an actual changed two-card selection is applied'
Assert-True (-not (Test-StrataDeepSeekGpuSelectionChanged -Initial @(0) -Selected @(0) -AvailableCount 2)) 'unchanged effective selection is preserved even if one detected card is ineligible'
Assert-True (-not (Test-StrataDeepSeekGpuSelectionChanged -Initial @() -Selected @() -AvailableCount 2)) 'a save without GPU edits does not invent a selection when every visible card is ineligible'
Assert-True (@($presets.Keys).Count -eq 3) 'three presets should be offered'
$fastName = @($presets.Keys | Where-Object { [string]$presets[$_].SsdPolicy -eq 'lfu' })[0]
$autoName = '自动（官方默认）'
$leanName = @($presets.Keys | Where-Object { [string]$presets[$_].SsdCache -eq '0' })[0]
Assert-True ([string]$presets[$fastName].SsdCache -eq '') 'LFU preset leaves RAM cache sizing to the current DeepSeek engine'

$fastControls = New-FakeDeepSeekControls '' $policyDefault $policyDefault
$fastControls.DsparkBlock.Value = 3
$fastControls.Vram.Value = 0.9
$fastControls.Mmap.SelectedItem = 'on'
Set-StrataDeepSeekPresetControls -Name $fastName -Controls $fastControls -SsdCacheGb 145
Assert-True ($fastControls.Ssd.Text -eq '') 'LFU preset must not impose a launcher-made cache size'
Assert-True ($fastControls.Policy.SelectedItem -eq 'lfu') 'the fast preset keeps hot experts with lfu'
Assert-True ($fastControls.DsparkBlock.Value -eq 3) 'expert cache preset must preserve a tuned DSpark draft block'
Assert-True ($fastControls.Vram.Value -eq 0.9 -and $fastControls.Mmap.SelectedItem -eq 'on') 'cache policy preset must preserve independent expert placement settings'
Assert-True ((Get-StrataDeepSeekPresetName -Controls $fastControls -SsdCacheGb 145) -eq $fastName) 'the preset label should follow the values'
$fastControls.Ssd.Text = '153'
Assert-True ((Get-StrataDeepSeekPresetName -Controls $fastControls -SsdCacheGb 96) -eq '自定义') 'explicit cache sizing is custom'
$fastControls.Ssd.Text = ''
$fastControls.Policy.SelectedItem = 'lru'
$custom = Get-StrataDeepSeekPresetName -Controls $fastControls -SsdCacheGb 96
Assert-True ($custom -notin @($fastName, $autoName, $leanName)) 'a different policy must leave every preset behind'
$fastControls.Policy.SelectedItem = 'lfu'

$autoControls = New-FakeDeepSeekControls '' $policyDefault $policyDefault
Set-StrataDeepSeekPresetControls -Name $autoName -Controls $autoControls -SsdCacheGb 145
Assert-True ($autoControls.Ssd.Text -eq '') 'auto leaves the SSD cache unset'
Assert-True ((Get-StrataDeepSeekPresetName -Controls $autoControls -SsdCacheGb 145) -eq $autoName) 'auto is recognised'
Set-StrataDeepSeekPresetControls -Name $leanName -Controls $autoControls -SsdCacheGb 145
Assert-True ($autoControls.Ssd.Text -eq '0') 'the lean preset switches the store off'
Assert-True ((Get-StrataDeepSeekPresetName -Controls $autoControls -SsdCacheGb 145) -eq $leanName) 'the lean preset is recognised'
Assert-True ((Get-StrataDeepSeekConfiguredEngineVersion -Config ([pscustomobject]@{exe='D:\AI\Strata\engine-dsv41\0.1.49.2-windows-x86_64-cuda-cuda13\strata-dsv41.exe'}) -FallbackVersion '0.1.50') -eq '0.1.49.2') 'the configured executable, not the newest installed engine, gates --experts'
Assert-True ((Get-StrataDeepSeekConfiguredEngineVersion -Config ([pscustomobject]@{}) -FallbackVersion '0.1.50') -eq '0.1.50') 'without an explicit executable, the installed-engine fallback is used'

$zeroControls = New-FakeDeepSeekControls '' $policyDefault $policyDefault
Set-StrataDeepSeekPresetControls -Name $fastName -Controls $zeroControls -SsdCacheGb 0
Assert-True ($zeroControls.Ssd.Text -eq '') 'LFU preset always lets the engine choose the RAM cache size'

'PASS: DeepSeek settings map to the dsv41 flags and Qwen-only flags are dropped'
