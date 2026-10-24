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
Assert-True ($pairs['--ssd-cache'] -eq 'auto') 'the SSD cache should be saved'
Assert-True ($pairs['--prefill-chunk'] -eq '1024') 'the prefill chunk should be saved'
Assert-True ($pairs['--pack'] -eq 'F:\AI\Strata-data\packs\deepseek-v4.1-flash-ist-das-2.00bpw') 'the official pack must be preserved'
Assert-True ($pairs['--eos'] -eq '1') 'the official EOS setting must be preserved'
Assert-True (@($out | Where-Object { $_ -eq '--dspark' }).Count -eq 1) 'DSpark must be written once'

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
Assert-True (@($presets.Keys).Count -eq 3) 'three presets should be offered'
$fastName = @($presets.Keys | Where-Object { [string]$presets[$_].SsdPolicy -eq 'lfu' })[0]
$autoName = @($presets.Keys | Where-Object { [string]$presets[$_].SsdCache -eq '' })[0]
$leanName = @($presets.Keys | Where-Object { [string]$presets[$_].SsdCache -eq '0' })[0]
Assert-True ([string]$presets[$fastName].SsdCache -eq '145') 'the fast preset takes the suggested RAM figure'

$fastControls = New-FakeDeepSeekControls '' $policyDefault $policyDefault
Set-StrataDeepSeekPresetControls -Name $fastName -Controls $fastControls -SsdCacheGb 145
Assert-True ($fastControls.Ssd.Text -eq '145') 'the fast preset fills the suggested RAM figure'
Assert-True ($fastControls.Policy.SelectedItem -eq 'lfu') 'the fast preset keeps hot experts with lfu'
Assert-True ((Get-StrataDeepSeekPresetName -Controls $fastControls -SsdCacheGb 145) -eq $fastName) 'the preset label should follow the values'
# The figure is per machine and moves with free memory: a saved 153 GB on a box that now suggests 96 GB is
# still the same intent (a big RAM store + LFU), so reopening the launcher must not report 自定义.
$fastControls.Ssd.Text = '153'
Assert-True ((Get-StrataDeepSeekPresetName -Controls $fastControls -SsdCacheGb 96) -eq $fastName) 'a saved figure still reads as the fast preset after the suggestion moves'
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

# --- the suggested figure belongs to the machine, not to this one --------------------------------------
# min(free - 12, total * 0.6), and a machine that cannot lend 8 GB gets no figure at all (auto stays in charge).
Assert-True ((Get-StrataSsdCacheSuggestion -TotalGb 256 -FreeGb 184) -eq 153) 'a 256 GB box with 184 GB free suggests 153'
Assert-True ((Get-StrataSsdCacheSuggestion -TotalGb 256 -FreeGb 100) -eq 88) 'a busy 256 GB box suggests what is free, not 153'
Assert-True ((Get-StrataSsdCacheSuggestion -TotalGb 128 -FreeGb 120) -eq 76) 'a 128 GB box suggests 76'
Assert-True ((Get-StrataSsdCacheSuggestion -TotalGb 64 -FreeGb 60) -eq 38) 'a 64 GB box suggests 38'
Assert-True ((Get-StrataSsdCacheSuggestion -TotalGb 32 -FreeGb 28) -eq 16) 'a 32 GB box suggests 16'
Assert-True ((Get-StrataSsdCacheSuggestion -TotalGb 16 -FreeGb 13) -eq 0) 'a machine that cannot lend 8 GB gets no figure'
Assert-True ((Get-StrataSsdCacheSuggestion -TotalGb 0 -FreeGb 0) -eq 0) 'an unknown machine gets no figure'
Assert-True ((Get-StrataSsdCacheSuggestion -TotalGb 512 -FreeGb 400) -eq 256) 'the suggestion is capped at 256 GB'
Assert-True ((Get-StrataSsdCacheSuggestion -TotalGb 256 -FreeGb 0) -eq 153) 'an unreadable free figure falls back to the total'
$zeroControls = New-FakeDeepSeekControls '' $policyDefault $policyDefault
Set-StrataDeepSeekPresetControls -Name $fastName -Controls $zeroControls -SsdCacheGb 0
Assert-True ($zeroControls.Ssd.Text -eq '') 'with no suggestion the fast preset leaves auto in charge instead of inventing a number'

'PASS: DeepSeek settings map to the dsv41 flags and Qwen-only flags are dropped'
