function Get-StrataSamplingValue {
    param($Sampling, [string]$Name, [string]$Alias, $Fallback)

    if ($null -ne $Sampling) {
        $canonical = $Sampling.PSObject.Properties[$Name]
        if ($null -ne $canonical -and $null -ne $canonical.Value) { return $canonical.Value }
        if ($Alias) {
            $alternative = $Sampling.PSObject.Properties[$Alias]
            if ($null -ne $alternative -and $null -ne $alternative.Value) { return $alternative.Value }
        }
    }
    return $Fallback
}

function Test-StrataOwnPathConfig {
    param($Config)
    return [string]$Config.arch -eq 'qwen35moe'
}

function Split-StrataEngineArgs {
    param([string[]]$ArgsList)
    $groups = [Collections.ArrayList]::new()
    $tokens = [Collections.ArrayList]::new()
    foreach ($item in @($ArgsList)) {
        $word = [string]$item
        if (-not $word) { continue }
        if ($word.StartsWith('--') -or $tokens.Count -eq 0) {
            if ($tokens.Count) {
                [void]$groups.Add([pscustomobject]@{ Flag = [string]$tokens[0]; Tokens = [string[]]@($tokens) })
            }
            $tokens = [Collections.ArrayList]::new()
        }
        [void]$tokens.Add($word)
    }
    if ($tokens.Count) {
        [void]$groups.Add([pscustomobject]@{ Flag = [string]$tokens[0]; Tokens = [string[]]@($tokens) })
    }
    return @($groups)
}

function Get-StrataEffectiveArgs {
    param($Config)
    $base = @(Split-StrataEngineArgs -ArgsList @($Config.args))
    $user = @(Split-StrataEngineArgs -ArgsList @($Config.user_args))
    if (-not $user.Count) { return @($Config.args) }
    $overrides = @{}
    foreach ($group in $user) { if ($group.Flag.StartsWith('--')) { $overrides[$group.Flag] = $true } }
    foreach ($group in $base) {
        if (-not $overrides.ContainsKey($group.Flag)) { foreach ($word in $group.Tokens) { Write-Output $word } }
    }
    foreach ($group in $user) { foreach ($word in $group.Tokens) { Write-Output $word } }
}

function Sync-StrataUserArgsForSave {
    param($Config, [string[]]$OriginalArgs)
    $managed = @('--max-context','--kv','--kv-resident','--vram-reserve-mib','--pool-workers',
                 '--rope-scaling','--rope-scale','--vision','--reserve-mib','--cpu-threads',
                 '--dspark','--dspark-conf','--ssd-cache','--ssd-policy','--mmap-experts','--vram-experts',
                 '--prefill-chunk','--dspark-block','--tp')
    $before = @(Split-StrataEngineArgs -ArgsList $OriginalArgs)
    $after = @(Split-StrataEngineArgs -ArgsList @($Config.args))
    $user = @(Split-StrataEngineArgs -ArgsList @($Config.user_args))
    $result = [Collections.ArrayList]::new()
    foreach ($group in $user) {
        if ($managed -notcontains $group.Flag) {
            foreach ($word in $group.Tokens) { [void]$result.Add($word) }
        }
    }
    foreach ($flag in $managed) {
        $was = @($before | Where-Object Flag -EQ $flag | Select-Object -First 1)
        $now = @($after | Where-Object Flag -EQ $flag | Select-Object -First 1)
        $hadOverride = @($user | Where-Object Flag -EQ $flag).Count -gt 0
        $changed = (($was.Count -ne $now.Count) -or
                    (($was | ForEach-Object { $_.Tokens -join [char]0 }) -join [char]1) -ne
                    (($now | ForEach-Object { $_.Tokens -join [char]0 }) -join [char]1))
        if (($changed -or $hadOverride) -and $now.Count) {
            foreach ($word in $now[0].Tokens) { [void]$result.Add($word) }
        }
    }
    if ($result.Count) {
        $Config | Add-Member -NotePropertyName user_args -NotePropertyValue ([string[]]@($result)) -Force
    } else {
        $Config.PSObject.Properties.Remove('user_args')
    }
    $Config | Add-Member -NotePropertyName args_written -NotePropertyValue ([string[]]@($Config.args)) -Force
}

function Get-StrataVisionConfigForSave {
    param($Config, [string]$SidecarPath, [string]$Root)

    if ($Config.vision) {
        $vision = $Config.vision
    } elseif (Test-Path -LiteralPath $SidecarPath -PathType Leaf) {
        $vision = Get-Content -LiteralPath $SidecarPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        $name = [string]$Config.model_name
        if ($name.StartsWith('swift-1.5-',[StringComparison]::OrdinalIgnoreCase)) {
            $encoderName = 'mmproj-Swift-Qwen3.8-Flash-Next-BF16.gguf'
        } elseif ($name.StartsWith('qwen3.8-flash-next-',[StringComparison]::OrdinalIgnoreCase)) {
            $encoderName = 'mmproj-Qwen3.8-Flash-Next-BF16.gguf'
        } else {
            throw "此模型无法自动创建视觉配置：$name。请先用官方 setup 安装视觉组件。"
        }

        $argsList = [string[]]@($Config.args)
        $nativeIndex = [Array]::IndexOf($argsList,'--native')
        if ($nativeIndex -lt 0 -or $nativeIndex + 1 -ge $argsList.Count -or -not $argsList[$nativeIndex + 1]) {
            throw '当前模型没有 --native GGUF 路径，无法自动创建视觉配置。请先用官方 setup 安装视觉组件。'
        }
        $model = [string]$argsList[$nativeIndex + 1]
        if (-not [IO.Path]::IsPathRooted($model)) { $model = Join-Path $Root $model }
        $model = [IO.Path]::GetFullPath($model)
        $modelDirectory = Split-Path -Parent $model
        $modelParent = Split-Path -Parent $modelDirectory
        $dataDirectory = Join-Path (Split-Path -Parent $Root) 'Strata-data\models'
        $candidates = @(
            (Join-Path $modelDirectory $encoderName),
            (Join-Path $modelParent $encoderName),
            (Join-Path $dataDirectory $encoderName)
        )
        $mmproj = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if (-not $mmproj) {
            throw "找不到视觉编码器 $encoderName。已检查：$($candidates -join '; ')。请先用官方 setup 安装视觉组件。"
        }
        $buildPath = Join-Path $Root 'engine\BUILD.json'
        if (-not (Test-Path -LiteralPath $buildPath -PathType Leaf)) {
            throw "找不到视觉程序的构建信息：$buildPath。请先用官方 setup 安装视觉组件。"
        }
        try { $build = Get-Content -LiteralPath $buildPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { throw "无法读取视觉程序的构建信息：$buildPath。请先用官方 setup 检查安装。" }
        $backend = [string]$build.vision
        if ($backend -notin @('gpu','cpu')) {
            throw "当前安装的视觉程序未标记为可用（BUILD.json vision=$backend）。请先用官方 setup 安装视觉组件。"
        }
        $vision = [pscustomobject]@{
            exe = Join-Path $Root 'engine\strata-vision.exe'
            mmproj = $mmproj
            model = $model
            gpu = ($backend -eq 'gpu')
            max_tokens = $(if ($backend -eq 'gpu') { 1024 } else { 300 })
        }
    }

    foreach ($key in @('exe','mmproj','model')) {
        $path = [string]$vision.$key
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "视觉配置中的 $key 文件不存在：$path。请检查路径或先用官方 setup 安装视觉组件。"
        }
    }
    return $vision
}

function Set-StrataNativeContextArgs {
    param([string[]]$ArgsList, [long]$MaxContext)
    if ($MaxContext -lt 1 -or $MaxContext -gt 262144) {
        throw 'Qwen3.6 native context limit is 262144; YaRN is unsupported.'
    }
    $updated = [Collections.ArrayList]::new()
    foreach ($item in $ArgsList) { [void]$updated.Add([string]$item) }
    $index = $updated.IndexOf('--max-context')
    if ($index -ge 0 -and $index + 1 -lt $updated.Count) {
        $updated[$index + 1] = [string]$MaxContext
    } else {
        [void]$updated.Add('--max-context')
        [void]$updated.Add([string]$MaxContext)
    }
    return ,@($updated)
}

function Merge-StrataSampling {
    param($Existing, $Edited, [string]$SeedText)

    $merged = [ordered]@{}
    if ($null -ne $Existing) {
        foreach ($property in $Existing.PSObject.Properties) {
            $merged[$property.Name] = $property.Value
        }
    }

    if (-not $merged.Contains('repetition_penalty') -and $merged.Contains('repeat_penalty')) {
        $merged['repetition_penalty'] = $merged['repeat_penalty']
    }
    if (-not $merged.Contains('penalty_last_n') -and $merged.Contains('repeat_last_n')) {
        $merged['penalty_last_n'] = $merged['repeat_last_n']
    }
    [void]$merged.Remove('repeat_penalty')
    [void]$merged.Remove('repeat_last_n')

    if ($null -ne $Edited) {
        foreach ($property in $Edited.PSObject.Properties) {
            $merged[$property.Name] = $property.Value
        }
    }

    [void]$merged.Remove('seed')
    if (-not [string]::IsNullOrWhiteSpace($SeedText)) {
        $seed = 0L
        if (-not [long]::TryParse($SeedText.Trim(), [ref]$seed)) {
            throw 'Seed must be an integer or left blank.'
        }
        $merged['seed'] = $seed
    }
    return [pscustomobject]$merged
}

function Get-StrataUsagePresets {
    $baseline = [ordered]@{
        temperature = [decimal]1
        top_p = [decimal]0.95
        top_k = [decimal]20
        min_p = [decimal]0
        presence_penalty = [decimal]0
        repetition_penalty = [decimal]1
        frequency_penalty = [decimal]0
        penalty_last_n = [decimal]64
        seed = ''
        max_tokens = [decimal]0
        reasoning_budget_tokens = [decimal]0
    }
    $presets = [ordered]@{}
    foreach ($entry in @(@('快速直答','none'), @('日常通用','medium'), @('Agent / 深度思考','high'))) {
        $values = [ordered]@{ effort = $entry[1] }
        foreach ($key in $baseline.Keys) { $values[$key] = $baseline[$key] }
        if ($entry[0] -eq '快速直答') {
            $values.temperature = [decimal]0.7
            $values.top_p = [decimal]0.8
            $values.presence_penalty = [decimal]1.5
        }
        $presets[$entry[0]] = $values
    }
    return $presets
}

function Set-StrataUsagePresetControls {
    param([string]$Name, [System.Collections.IDictionary]$Controls)
    $presets = Get-StrataUsagePresets
    if (-not $presets.Contains($Name)) { throw "未知使用预设：$Name" }
    $values = $presets[$Name]
    $Controls.effort.SelectedItem = $values.effort
    foreach ($key in $values.Keys) {
        if ($key -eq 'effort') { continue }
        if ($key -eq 'seed') { $Controls.seed.Text = $values.seed }
        else { $Controls[$key].Value = $values[$key] }
    }
}

function Get-StrataUsagePresetName {
    param([System.Collections.IDictionary]$Controls)
    foreach ($entry in (Get-StrataUsagePresets).GetEnumerator()) {
        $values = $entry.Value
        if ([string]$Controls.effort.SelectedItem -ne [string]$values.effort) { continue }
        if ([string]$Controls.seed.Text -ne [string]$values.seed) { continue }
        $matches = $true
        foreach ($key in $values.Keys) {
            if ($key -in @('effort','seed')) { continue }
            if ([decimal]$Controls[$key].Value -ne [decimal]$values[$key]) { $matches = $false; break }
        }
        if ($matches) { return [string]$entry.Key }
    }
    return '自定义'
}

function Connect-StrataUsagePresetControls {
    param($Selector, [System.Collections.IDictionary]$Controls)
    $state = [pscustomobject]@{ Applying = $false; LabelOnly = $false }
    $sync = {
        if ($state.Applying) { return }
        $label = Get-StrataUsagePresetName -Controls $Controls
        if ([string]$Selector.SelectedItem -ne $label) {
            $state.LabelOnly = $true
            try { $Selector.SelectedItem = $label }
            finally { $state.LabelOnly = $false }
        }
    }.GetNewClosure()
    $Selector.Add_SelectedIndexChanged({
        if ($state.LabelOnly) { return }
        $name = [string]$Selector.SelectedItem
        if ($name -eq '自定义') { return }
        $state.Applying = $true
        try { Set-StrataUsagePresetControls -Name $name -Controls $Controls }
        finally { $state.Applying = $false }
    }.GetNewClosure())
    $Controls.effort.Add_SelectedIndexChanged($sync)
    foreach ($key in @('temperature','top_p','top_k','min_p','presence_penalty','repetition_penalty','frequency_penalty','penalty_last_n','max_tokens','reasoning_budget_tokens')) {
        $Controls[$key].Add_ValueChanged($sync)
    }
    $Controls.seed.Add_TextChanged($sync)
    & $sync
}

function Get-StrataDeepSeekModelKey {
    param([string]$ConfigPath)
    $stem = [IO.Path]::GetFileNameWithoutExtension([string]$ConfigPath)
    if ($stem -match '^strata-deepseek-v4\.1-flash-(.+)$') { return $Matches[1] }
    return ''
}
function Test-StrataDeepSeekConfig {
    param($Config)
    if (-not $Config) { return $false }
    if ([string]$Config.arch -eq 'deepseek41') { return $true }
    return ([string]$Config.exe) -match 'strata-dsv41|engine-dsv41'
}

function Remove-StrataArgPair {
    param([Collections.ArrayList]$List, [string]$Flag)
    for ($i = $List.Count - 1; $i -ge 0; $i--) {
        if ([string]$List[$i] -ne $Flag) { continue }
        $List.RemoveAt($i)
        if ($i -lt $List.Count -and -not ([string]$List[$i]).StartsWith('--')) { $List.RemoveAt($i) }
    }
}

function Set-StrataArgPair {
    param([Collections.ArrayList]$List, [string]$Flag, $Value)
    Remove-StrataArgPair -List $List -Flag $Flag
    $text = ([string]$Value).Trim()
    if ($text) { [void]$List.Add($Flag); [void]$List.Add($text) }
}

function Get-StrataDeepSeekSetting {
    param($Settings, [string]$Name)
    if ($null -eq $Settings) { return '' }
    $property = $Settings.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    return [string]$property.Value
}

# The engine's own values: --ssd-policy lru|lfu|lfulru, --mmap-experts auto|on|off.
function Get-StrataSsdPolicyValue {
    param([string]$Item)
    switch -Regex ($Item.Trim().ToLowerInvariant()) {
        '^lfu.*lru$' { return 'lfulru' }
        '^lfu$' { return 'lfu' }
        '^lru$' { return 'lru' }
        default { return '' }
    }
}

function Get-StrataSsdPolicyItem {
    param([string]$Value)
    switch -Regex ($Value.Trim().ToLowerInvariant()) {
        '^lfu.*lru$' { return 'lfu→lru' }
        '^lfu$' { return 'lfu' }
        '^lru$' { return 'lru' }
        default { return '默认' }
    }
}

function Get-StrataMmapValue {
    param([string]$Item)
    switch ($Item.Trim().ToLowerInvariant()) {
        'on' { return 'on' }
        'off' { return 'off' }
        'auto' { return 'auto' }
        default { return '' }
    }
}

function Get-StrataMmapItem {
    param([string]$Value)
    switch ($Value.Trim().ToLowerInvariant()) {
        'on' { return 'on' }
        'off' { return 'off' }
        'auto' { return 'auto' }
        default { return '默认' }
    }
}

# The expert RAM store's own auto rule stops at 48 GB, so a big PC is told to use 48 and no more.  The figure
# below is what the machine can actually lend: the RAM free now less the engine's own 12 GB margin, and never
# more than six tenths of the installed memory, so a box busy with other programs is not given a wishful number.
# 0 means "no useful figure": the caller leaves the flag unset and the engine's own rule stays in charge.
function Get-StrataSsdCacheSuggestion {
    param([double]$TotalGb = 0, [double]$FreeGb = 0)
    if ($TotalGb -le 0) { return 0 }
    if ($FreeGb -le 0) { $FreeGb = $TotalGb }
    $fromFree = [Math]::Floor($FreeGb - 12)
    $fromTotal = [Math]::Floor($TotalGb * 0.6)
    $gb = [Math]::Min($fromFree, $fromTotal)
    if ($gb -lt 8) { return 0 }
    if ($gb -gt 256) { $gb = 256 }
    return [int]$gb
}

function Get-StrataSuggestedSsdCache {
    $totalGb = 0.0
    $freeGb = 0.0
    try { $totalGb = [double](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB } catch { $totalGb = 0 }
    try { $freeGb = [double](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory / 1MB } catch { $freeGb = 0 }
    if ($totalGb -le 0) { return 0 }
    return Get-StrataSsdCacheSuggestion -TotalGb $totalGb -FreeGb $freeGb
}

# The presets only touch the expert-placement knobs; sampling, context and the draft model stay as the user set them.
function Get-StrataDeepSeekPresets {
    param([int]$SsdCacheGb = 0)
    $fastCache = if ($SsdCacheGb -gt 0) { [string]$SsdCacheGb } else { '' }
    return [ordered]@{
        '尽可能快（多吃内存）' = [pscustomobject]@{ SsdCache = $fastCache; SsdPolicy = 'lfu'; Mmap = ''; Vram = 0; DsparkBlock = 0 }
        '自动（均衡）'         = [pscustomobject]@{ SsdCache = ''; SsdPolicy = ''; Mmap = ''; Vram = 0; DsparkBlock = 0 }
        '省内存（少占内存）'   = [pscustomobject]@{ SsdCache = '0'; SsdPolicy = ''; Mmap = ''; Vram = 0; DsparkBlock = 0 }
    }
}

function Test-StrataDeepSeekPresetMatch {
    param($Values, [System.Collections.IDictionary]$Controls)
    $cacheText = $Controls.Ssd.Text.Trim()
    if ($cacheText -ne [string]$Values.SsdCache) {
        # The fast preset's figure is computed per machine and moves with the memory free at the time, so a
        # different positive figure with the same policy is still the same intent.  Only an empty field (auto)
        # or an explicit 0 (store off) belongs to another preset.
        $fastWantsFigure = ([string]$Values.SsdCache) -notin @('', '0')
        $cacheGb = [double]0
        $cacheIsFigure = [double]::TryParse($cacheText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$cacheGb) -and $cacheGb -gt 0
        if (-not ($fastWantsFigure -and $cacheIsFigure)) { return $false }
    }
    if ((Get-StrataSsdPolicyValue ([string]$Controls.Policy.SelectedItem)) -ne (Get-StrataSsdPolicyValue ([string]$Values.SsdPolicy))) { return $false }
    if ((Get-StrataMmapValue ([string]$Controls.Mmap.SelectedItem)) -ne (Get-StrataMmapValue ([string]$Values.Mmap))) { return $false }
    if ([decimal]$Controls.Vram.Value -ne [decimal]$Values.Vram) { return $false }
    if ([decimal]$Controls.DsparkBlock.Value -ne [decimal]$Values.DsparkBlock) { return $false }
    return $true
}

function Get-StrataDeepSeekPresetName {
    param([System.Collections.IDictionary]$Controls, [int]$SsdCacheGb = 0)
    foreach ($entry in (Get-StrataDeepSeekPresets -SsdCacheGb $SsdCacheGb).GetEnumerator()) {
        if (Test-StrataDeepSeekPresetMatch -Values $entry.Value -Controls $Controls) { return [string]$entry.Key }
    }
    return '自定义'
}

function Set-StrataDeepSeekPresetControls {
    param([string]$Name, [System.Collections.IDictionary]$Controls, [int]$SsdCacheGb = 0)
    $presets = Get-StrataDeepSeekPresets -SsdCacheGb $SsdCacheGb
    if (-not $presets.Contains($Name)) { return }
    $values = $presets[$Name]
    $Controls.Ssd.Text = [string]$values.SsdCache
    $Controls.Policy.SelectedItem = (Get-StrataSsdPolicyItem ([string]$values.SsdPolicy))
    $Controls.Mmap.SelectedItem = (Get-StrataMmapItem ([string]$values.Mmap))
    $Controls.Vram.Value = [decimal]$values.Vram
    $Controls.DsparkBlock.Value = [decimal]$values.DsparkBlock
}

function Connect-StrataDeepSeekPresetControls {
    param($Selector, [System.Collections.IDictionary]$Controls, [int]$SsdCacheGb = 0)
    $state = [pscustomobject]@{ Applying = $false; LabelOnly = $false }
    $sync = {
        if ($state.Applying) { return }
        $label = Get-StrataDeepSeekPresetName -Controls $Controls -SsdCacheGb $SsdCacheGb
        if ([string]$Selector.SelectedItem -ne $label -and $Selector.Items -contains $label) {
            $state.LabelOnly = $true
            try { $Selector.SelectedItem = $label }
            finally { $state.LabelOnly = $false }
        }
    }.GetNewClosure()
    $Selector.Add_SelectedIndexChanged({
        if ($state.LabelOnly) { return }
        $name = [string]$Selector.SelectedItem
        if ($name -eq '自定义') { return }
        $state.Applying = $true
        try { Set-StrataDeepSeekPresetControls -Name $name -Controls $Controls -SsdCacheGb $SsdCacheGb }
        finally { $state.Applying = $false }
    }.GetNewClosure())
    $Controls.Ssd.Add_TextChanged($sync)
    $Controls.Policy.Add_SelectedIndexChanged($sync)
    $Controls.Mmap.Add_SelectedIndexChanged($sync)
    $Controls.Vram.Add_ValueChanged($sync)
    $Controls.DsparkBlock.Add_ValueChanged($sync)
    & $sync
}

function Get-StrataDeepSeekSettings {
    param([string[]]$ArgsList)
    $read = {
        param([string]$Flag, [string]$Fallback)
        $value = ''
        $items = @($ArgsList)
        for ($i = 0; $i -lt $items.Count - 1; $i++) {
            if ([string]$items[$i] -eq $Flag) { $value = [string]$items[$i + 1] }
        }
        if ($value) { $value } else { $Fallback }
    }
    [pscustomobject]@{
        Context      = [long](& $read '--max-context' '8192')
        ReserveMib   = [string](& $read '--reserve-mib' '')
        CpuThreads   = [string](& $read '--cpu-threads' '')
        Dspark       = [string](& $read '--dspark' 'auto')
        DsparkConf   = [string](& $read '--dspark-conf' '')
        SsdCache     = [string](& $read '--ssd-cache' '')
        SsdPolicy    = [string](& $read '--ssd-policy' '')
        MmapExperts  = [string](& $read '--mmap-experts' '')
        VramExperts  = [string](& $read '--vram-experts' '')
        PrefillChunk = [string](& $read '--prefill-chunk' '')
        DsparkBlock  = [string](& $read '--dspark-block' '')
        Tp           = [string](& $read '--tp' '')
    }
}

function Set-StrataDeepSeekArgs {
    param([Collections.ArrayList]$List, $Settings)
    # The dsv41 engine has its own flags and treats an unknown one as a fatal error: drop the Qwen-only
    # flags the launcher writes for its engine before any DeepSeek value is saved.
    foreach ($flag in @('--kv','--kv-resident','--vram-reserve-mib','--pool-workers','--rope-scaling','--rope-scale')) {
        Remove-StrataArgPair -List $List -Flag $flag
    }
    Remove-StrataArgPair -List $List -Flag '--vision'
    Set-StrataArgPair -List $List -Flag '--max-context' -Value ([string]$Settings.Context)
    Set-StrataArgPair -List $List -Flag '--reserve-mib' -Value $Settings.ReserveMib
    Set-StrataArgPair -List $List -Flag '--cpu-threads' -Value $Settings.CpuThreads
    $dspark = ([string]$Settings.Dspark).ToLowerInvariant()
    if ($dspark -notin @('auto','on','off')) { $dspark = 'auto' }
    Set-StrataArgPair -List $List -Flag '--dspark' -Value $dspark
    Set-StrataArgPair -List $List -Flag '--dspark-conf' -Value $Settings.DsparkConf
    # The expert-placement knobs.  An empty value leaves the flag out, so the engine's own rule stays in force;
    # a value out of the engine's domain is dropped rather than written (dsv41 stops on a bad flag value).
    $ssdCache = (Get-StrataDeepSeekSetting $Settings 'SsdCache').Trim()
    $ssdPolicy = Get-StrataSsdPolicyValue (Get-StrataDeepSeekSetting $Settings 'SsdPolicy')
    $mmap = Get-StrataMmapValue (Get-StrataDeepSeekSetting $Settings 'MmapExperts')
    $vramText = (Get-StrataDeepSeekSetting $Settings 'VramExperts').Trim()
    $vram = 0.0
    if ($vramText -and [double]::TryParse($vramText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$vram)) {
        if ($vram -lt 0.05 -or $vram -gt 1.0) { $vramText = '' } else { $vramText = $vram.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) }
    } else { $vramText = '' }
    $blockText = (Get-StrataDeepSeekSetting $Settings 'DsparkBlock').Trim()
    if ($blockText -notmatch '^\d+$' -or [int]$blockText -lt 1 -or [int]$blockText -gt 16) { $blockText = '' }
    Set-StrataArgPair -List $List -Flag '--ssd-cache' -Value $ssdCache
    Set-StrataArgPair -List $List -Flag '--ssd-policy' -Value $ssdPolicy
    Set-StrataArgPair -List $List -Flag '--mmap-experts' -Value $mmap
    Set-StrataArgPair -List $List -Flag '--vram-experts' -Value $vramText
    Set-StrataArgPair -List $List -Flag '--prefill-chunk' -Value $Settings.PrefillChunk
    Set-StrataArgPair -List $List -Flag '--dspark-block' -Value $blockText
    Set-StrataArgPair -List $List -Flag '--tp' -Value $Settings.Tp
    # "copy into RAM" and "RAM store" are two roads to the same place: copying every expert the GPU leaves
    # over already fills the memory, so a store budget on top of it would double-count.  One road at a time.
    if ($mmap -eq 'off') { Set-StrataArgPair -List $List -Flag '--ssd-cache' -Value '0' }
    return $List
}
