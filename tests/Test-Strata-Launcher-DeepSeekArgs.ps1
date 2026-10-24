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

$officialUnofficial = Set-StrataDeepSeekArgs -List ([Collections.ArrayList]::new([string[]]@('--pack','P','--tp','2','--vram-experts','0.60','--dspark','auto'))) -Settings ([pscustomobject]@{
    Context = 8192; ReserveMib = ''; CpuThreads = ''; Dspark = 'auto'; DsparkConf = ''; SsdCache = ''; PrefillChunk = ''; Tp = '2'
})
$unofficialOut = [string[]]@($officialUnofficial)
Assert-True (@($unofficialOut) -contains '--tp') 'the official --tp must be preserved'
Assert-True (@($unofficialOut) -contains '--vram-experts') 'engine flags the launcher does not edit must be preserved'
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
'PASS: DeepSeek settings map to the dsv41 flags and Qwen-only flags are dropped'
