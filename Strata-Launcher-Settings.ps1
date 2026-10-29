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

function Get-StrataQwenOnlyFlags {
    return @('--native','--kv','--kv-resident','--vram-reserve-mib','--pool-workers',
             '--rope-scaling','--rope-scale','--prefill','--spec','--spec-min-p',
             '--batch-mtp','--mtp','--expert-cache','--resident-budget-gib','--layer-split',
             '--pcie-frac','--expert-vram','--split-skip-if-fits','--pool-cores',
             '--vram-elastic','--vram-segment-mib','--expert-profile-save','--expert-profile-save-every')
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
                 '--prefill-chunk','--dspark-block','--tp','--experts')
    $deepSeek = Test-StrataDeepSeekConfig -Config $Config
    if ($deepSeek) { $managed += @(Get-StrataQwenOnlyFlags) }
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

function Get-StrataModelCardSampling {
    param([string]$Family = 'qwen4exp', [bool]$Thinking = $true)
    switch ($Family) {
        'deepseek41' { return [ordered]@{ temperature = [decimal]1; top_p = [decimal]1 } }
        'qwen35moe' {
            if ($Thinking) { return [ordered]@{ temperature = [decimal]1; top_p = [decimal]0.95; top_k = [decimal]20; presence_penalty = [decimal]1.5 } }
            return [ordered]@{ temperature = [decimal]0.7; top_p = [decimal]0.8; top_k = [decimal]20; presence_penalty = [decimal]1.5 }
        }
        default {
            if ($Thinking) { return [ordered]@{ temperature = [decimal]1; top_p = [decimal]0.95; top_k = [decimal]20 } }
            return [ordered]@{ temperature = [decimal]0.7; top_p = [decimal]0.8; top_k = [decimal]20; presence_penalty = [decimal]1.5 }
        }
    }
}

function Get-StrataUsagePresets {
    param([string]$Family = 'qwen4exp')
    $thinkingCard = Get-StrataModelCardSampling -Family $Family -Thinking $true
    $instructCard = Get-StrataModelCardSampling -Family $Family -Thinking $false
    $baseline = [ordered]@{
        temperature = [decimal]1
        top_p = $(if ($Family -eq 'deepseek41') { [decimal]1 } else { [decimal]0.95 })
        top_k = $(if ($Family -eq 'deepseek41') { [decimal]64 } else { [decimal]20 })
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
        $card = if ($entry[0] -eq '快速直答') { $instructCard } else { $thinkingCard }
        foreach ($key in $card.Keys) { $values[$key] = $card[$key] }
        $presets[$entry[0]] = $values
    }
    return $presets
}

function Set-StrataUsagePresetControls {
    param([string]$Name, [System.Collections.IDictionary]$Controls, [string]$Family = 'qwen4exp')
    $presets = Get-StrataUsagePresets -Family $Family
    if ($Name -eq '官方默认') { $Name = 'Agent / 深度思考' }
    if (-not $presets.Contains($Name)) { throw "未知使用预设：$Name" }
    $values = $presets[$Name]
    $Controls.effort.SelectedItem = $values.effort
    foreach ($key in $values.Keys) {
        if ($key -eq 'effort') { continue }
        if ($key -eq 'seed') { $Controls.seed.Text = $values.seed }
        else { $Controls[$key].Value = $values[$key] }
    }
    if ($Controls.Contains('budget_mode')) { $Controls.budget_mode.SelectedItem = '官方默认' }
}

function Get-StrataUsagePresetName {
    param([System.Collections.IDictionary]$Controls, [string]$Family = 'qwen4exp')
    if ($Controls.Contains('budget_mode') -and [string]$Controls.budget_mode.SelectedItem -ne '官方默认') { return '自定义' }
    foreach ($entry in (Get-StrataUsagePresets -Family $Family).GetEnumerator()) {
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
    param($Selector, [System.Collections.IDictionary]$Controls, [string]$Family = 'qwen4exp')
    $state = [pscustomobject]@{ Applying = $false; LabelOnly = $false; Official = ([string]$Selector.SelectedItem -eq '官方默认') }
    $sync = {
        if ($state.Applying) { return }
        if ($state.Official) { return }
        $label = Get-StrataUsagePresetName -Controls $Controls -Family $Family
        if ([string]$Selector.SelectedItem -ne $label) {
            $state.LabelOnly = $true
            try { $Selector.SelectedItem = $label }
            finally { $state.LabelOnly = $false }
        }
    }.GetNewClosure()
    $changed = { if ($state.Applying) { return }; $state.Official = $false; & $sync }.GetNewClosure()
    $Selector.Add_SelectedIndexChanged({
        if ($state.LabelOnly) { return }
        $name = [string]$Selector.SelectedItem
        if ($name -eq '自定义') { return }
        $state.Official = ($name -eq '官方默认')
        $state.Applying = $true
        try { Set-StrataUsagePresetControls -Name $name -Controls $Controls -Family $Family }
        finally { $state.Applying = $false }
    }.GetNewClosure())
    $Controls.effort.Add_SelectedIndexChanged($changed)
    foreach ($key in @('temperature','top_p','top_k','min_p','presence_penalty','repetition_penalty','frequency_penalty','penalty_last_n','max_tokens','reasoning_budget_tokens')) {
        $Controls[$key].Add_ValueChanged($changed)
    }
    $Controls.seed.Add_TextChanged($changed)
    if ($Controls.Contains('budget_mode')) { $Controls.budget_mode.Add_SelectedIndexChanged($changed) }
    & $sync
}

function Get-StrataSamplingForSave {
    param($Existing, [string]$Family = 'qwen4exp', [string]$PresetName = '自定义', $Edited = $null, [string]$SeedText = '')
    $managed = @('temperature','top_p','top_k','min_p','presence_penalty','frequency_penalty',
                 'repetition_penalty','penalty_last_n','repeat_penalty','repeat_last_n','seed',
                 'experimental_speed_projection','strata_tune')
    if ($PresetName -eq '自定义') {
        $result = Merge-StrataSampling -Existing $Existing -Edited $Edited -SeedText $SeedText
        if ($Family -eq 'deepseek41') {
            foreach ($key in @('presence_penalty','frequency_penalty','repetition_penalty','penalty_last_n','repeat_penalty','repeat_last_n',
                               'experimental_speed_projection','strata_tune')) { $result.PSObject.Properties.Remove($key) }
        }
        return $result
    }
    $values = [ordered]@{}
    if ($null -ne $Existing) { foreach ($property in $Existing.PSObject.Properties) { $values[$property.Name] = $property.Value } }
    foreach ($key in $managed) { [void]$values.Remove($key) }
    if ($PresetName -ne '官方默认') {
        $thinking = $PresetName -ne '快速直答'
        $card = Get-StrataModelCardSampling -Family $Family -Thinking $thinking
        foreach ($key in $card.Keys) { $values[$key] = $card[$key] }
    }
    return [pscustomobject]$values
}

function Merge-StrataSharedDefaults {
    param($Existing, $Edited)
    $values = [ordered]@{}
    if ($null -ne $Existing) { foreach ($property in $Existing.PSObject.Properties) { $values[$property.Name] = $property.Value } }
    foreach ($key in @('reasoning_effort','reasoning_budget_tokens','temperature','top_p','top_k','seed','max_tokens','experimental_speed_projection')) {
        [void]$values.Remove($key)
    }
    if ($null -ne $Edited) { foreach ($property in $Edited.PSObject.Properties) { $values[$property.Name] = $property.Value } }
    return [pscustomobject]$values
}

function Get-StrataReasoningBudgetValue {
    param([string]$Mode, [int]$Value)
    if ($Mode -eq '官方默认') { return $null }
    if ($Mode -eq '不限制（0）') { return 0 }
    if ($Mode -ne '自定义上限' -or $Value -le 0) { throw '思考预算的自定义上限必须大于 0。' }
    return $Value
}

function Get-StrataReasoningEffortValue {
    param([string]$Family = 'qwen4exp', [string]$Choice, [int]$CustomNumber = 0)
    if ($Choice -in @('none','low','medium','high')) { return $Choice }
    throw '配置文件与共享默认值的思考强度仅支持 none/low/medium/high；DeepSeek 的 max 和 1–100 只能由 API 请求指定。'
}

function Test-StrataGenerationOverrides {
    param($Config, $Shared)
    if ($null -ne $Config.sampling -and @($Config.sampling.PSObject.Properties).Count -gt 0) { return $true }
    foreach ($key in @('reasoning_effort','reasoning_budget_tokens')) {
        $property = $Config.PSObject.Properties[$key]
        if ($null -ne $property -and $null -ne $property.Value) { return $true }
    }
    if ($null -ne $Shared) {
        foreach ($key in @('reasoning_effort','reasoning_budget_tokens','temperature','top_p','top_k','seed','max_tokens','experimental_speed_projection')) {
            $property = $Shared.PSObject.Properties[$key]
            if ($null -ne $property -and $null -ne $property.Value) { return $true }
        }
    }
    return $false
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

function Get-StrataInitialContext {
    param($Config)
    $fallback = if (Test-StrataDeepSeekConfig -Config $Config) { '8192' } else { '131072' }
    $argsList = [string[]]@($Config.args)
    for ($i = 0; $i -lt $argsList.Count - 1; $i++) {
        if ($argsList[$i] -eq '--max-context') { return [long]$argsList[$i + 1] }
    }
    return [long]$fallback
}

function Test-StrataDeepSeekExpertsSupported {
    param([string]$Version)
    try { return ([version]$Version -ge [version]'0.1.50') }
    catch { return $false }
}

function Get-StrataDeepSeekConfiguredEngineVersion {
    param($Config, [string]$Root = '', [string]$FallbackVersion = '')
    $exe = [string]$Config.exe
    if (-not $exe) { return $FallbackVersion }
    if (-not [IO.Path]::IsPathRooted($exe) -and $Root) { $exe = Join-Path $Root $exe }
    $directory = Split-Path -Parent $exe
    $build = Join-Path $directory 'BUILD.json'
    if (Test-Path -LiteralPath $build -PathType Leaf) {
        try {
            $version = [string]((Get-Content -LiteralPath $build -Raw -Encoding UTF8 | ConvertFrom-Json).version)
            if ($version -match '^\d+(?:\.\d+)+$') { return $version }
        } catch { }
    }
    $match = [regex]::Match((Split-Path -Leaf $directory), '^(\d+(?:\.\d+)+)(?:-|$)')
    if ($match.Success) { return $match.Groups[1].Value }
    return ''
}

function Get-StrataDeepSeekTpItems {
    param([string]$CurrentValue)
    $items = @('自动（引擎默认）','1','2')
    $number = 0
    if ([int]::TryParse($CurrentValue, [ref]$number) -and $number -gt 2) { $items += [string]$number }
    return $items
}

function Get-StrataQwenKvResidentChoice {
    param([string]$CurrentValue)
    $number = 0
    if (-not [int]::TryParse($CurrentValue, [ref]$number) -or $number -le 0) { return '关闭' }
    if ($number -lt 20480) { return '20480' }
    return [string]$number
}

function Get-StrataQwenKvResidentItems {
    param([string]$CurrentValue)
    $items = @('关闭','20480','32768','65536')
    $choice = Get-StrataQwenKvResidentChoice -CurrentValue $CurrentValue
    if ($items -notcontains $choice) { $items += $choice }
    return $items
}

function Get-StrataQwenParallelItems {
    param([string]$CurrentValue)
    $items = @('1','2','3','4','5','6','7','8')
    $number = 0
    if ([int]::TryParse($CurrentValue, [ref]$number) -and $number -gt 8 -and $number -le 1024) { $items += [string]$number }
    return $items
}

function Test-StrataDeepSeekGpuSelectionChanged {
    param([int[]]$Initial = @(), [int[]]$Selected = @(), [int]$AvailableCount = 0)
    if ($AvailableCount -le 0) { return $false }
    return ((@($Initial | Sort-Object) -join ',') -ne (@($Selected | Sort-Object) -join ','))
}

function Remove-StrataDeepSeekUnsupportedConfig {
    param($Config)
    $result = $Config | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    foreach ($name in @('drafting','mtp','vram_elastic','vram_segment_mib','pool_cores',
                       'expert_profile_save','expert_profile_save_every','layer_split',
                       'split_skip_if_fits','parallel','replicas','vision')) {
        $result.PSObject.Properties.Remove($name)
    }
    return $result
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
# Cache presets only touch RAM cache sizing and eviction. GPU share, mmap, drafting and sampling stay as set.
function Get-StrataDeepSeekPresets {
    param([int]$SsdCacheGb = 0)
    return [ordered]@{
        '自动（官方默认）' = [pscustomobject]@{ SsdCache = ''; SsdPolicy = '' }
        '热专家优先（LFU）' = [pscustomobject]@{ SsdCache = ''; SsdPolicy = 'lfu' }
        '省内存（关闭 RAM 缓存）' = [pscustomobject]@{ SsdCache = '0'; SsdPolicy = '' }
    }
}

function Test-StrataDeepSeekPresetMatch {
    param($Values, [System.Collections.IDictionary]$Controls)
    $cacheText = $Controls.Ssd.Text.Trim()
    if ($cacheText -ne [string]$Values.SsdCache) { return $false }
    if ((Get-StrataSsdPolicyValue ([string]$Controls.Policy.SelectedItem)) -ne (Get-StrataSsdPolicyValue ([string]$Values.SsdPolicy))) { return $false }
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
        Experts      = [string](& $read '--experts' '')
    }
}

function Get-StrataDeepSeekVisionStatus {
    param($Config, [string]$EngineVersion, [string]$Root = '')
    $status = [pscustomobject]@{ Available = $false; Enabled = $false; PackPath = ''; Reason = '' }
    try {
        if ([version]$EngineVersion -lt [version]'0.1.52') {
            $status.Reason = 'DeepSeek 图像输入需要 0.1.52 或更新的引擎。'
            return $status
        }
    } catch {
        $status.Reason = '无法确认 DeepSeek 引擎版本。'
        return $status
    }
    $args = [string[]]@(Get-StrataEffectiveArgs -Config $Config)
    $pack = ''
    $mode = ''
    for ($i = 0; $i -lt $args.Count; $i++) {
        if ($i + 1 -ge $args.Count -or $args[$i + 1].StartsWith('--')) { continue }
        if ($args[$i] -eq '--pack') { $pack = $args[$i + 1] }
        if ($args[$i] -eq '--vision') { $mode = $args[$i + 1].ToLowerInvariant() }
    }
    if (-not $pack) {
        $status.Reason = 'DeepSeek 配置没有模型 pack 路径。'
        return $status
    }
    if (-not [IO.Path]::IsPathRooted($pack)) {
        $base = if ($Config.cwd) { [string]$Config.cwd } elseif ($Root) { $Root } else { (Get-Location).Path }
        $pack = [IO.Path]::GetFullPath((Join-Path $base $pack))
    }
    $status.PackPath = $pack
    $metadata = Join-Path $pack 'ds4.txt'
    if (-not (Test-Path -LiteralPath $metadata -PathType Leaf)) {
        $status.Reason = '当前 DeepSeek pack 缺少 ds4.txt；请用官方 setup 检查模型包。'
        return $status
    }
    $content = Get-Content -LiteralPath $metadata -Raw -Encoding UTF8
    if ($content -notmatch '(?m)^image_token_id\s+\d+\s*$' -or
            $content -notmatch '(?m)^vision\.num_hidden_layers\s+[1-9]\d*\s*$') {
        $status.Reason = '当前 DeepSeek pack 没有视觉塔；请用官方 setup 补齐图像权重并重新生成模型包。'
        return $status
    }
    $status.Available = $true
    $status.Enabled = $mode -notin @('off','no','false','0')
    return $status
}

function Get-StrataSpeedSwitchSpec {
    param([Parameter(Mandatory=$true)][string]$Id)
    switch ($Id) {
        'faster_long_prompts' { return [pscustomobject]@{ DefaultOn = $false; Env = [ordered]@{ STRATA_KVA = '1' }; Legacy = $null } }
        'faster_12gb_nvidia' { return [pscustomobject]@{ DefaultOn = $true; Env = [ordered]@{ STRATA_ROUTE_PRIOR = '0' }; Legacy = $null } }
        'faster_radeon_9000' { return [pscustomobject]@{ DefaultOn = $true; Env = [ordered]@{ STRATA_PCIE_FRAC_DEFAULT = 'old' }; Legacy = $null } }
        'deepseek_speedups' {
            $legacy = [ordered]@{ DS4_FAST_ATTN = '0'; DS4_ATTN_SLAB = '0'; DS4_COPY_PIN = '0'; DS4_COPY_HUGETLB = '0'; DS4_STORE_SPARE = '0'; DS4_STORE_PUT = '0' }
            $envFlags = [ordered]@{ DS4_DEFAULTS = '026' }
            foreach ($key in $legacy.Keys) { $envFlags[$key] = $legacy[$key] }
            return [pscustomobject]@{ DefaultOn = $true; Env = $envFlags; Legacy = $legacy }
        }
        default { throw "未知的 Strata 引擎速度开关：$Id" }
    }
}

function Get-StrataSpeedSwitchIsOn {
    param($Config, [Parameter(Mandatory=$true)][string]$Id)
    $spec = Get-StrataSpeedSwitchSpec -Id $Id
    $envValues = $Config.env
    $matches = {
        param($expected)
        if ($null -eq $expected) { return $false }
        foreach ($key in $expected.Keys) {
            $property = if ($null -ne $envValues) { $envValues.PSObject.Properties[$key] } else { $null }
            if ($null -eq $property -or [string]$property.Value -cne [string]$expected[$key]) { return $false }
        }
        return $true
    }
    $set = (& $matches $spec.Env) -or (& $matches $spec.Legacy)
    return ($set -ne $spec.DefaultOn)
}

function Set-StrataSpeedSwitch {
    param($Config, [Parameter(Mandatory=$true)][string]$Id, [Parameter(Mandatory=$true)][bool]$Enabled)
    $spec = Get-StrataSpeedSwitchSpec -Id $Id
    $envValues = $Config.env
    if ($null -eq $envValues) {
        $envValues = [pscustomobject]@{}
        $Config | Add-Member -NotePropertyName env -NotePropertyValue $envValues -Force
    }
    foreach ($key in $spec.Env.Keys) { [void]$envValues.PSObject.Properties.Remove($key) }
    if ($Enabled -ne $spec.DefaultOn) {
        foreach ($key in $spec.Env.Keys) {
            $envValues | Add-Member -NotePropertyName $key -NotePropertyValue ([string]$spec.Env[$key]) -Force
        }
    }
    if ($envValues.PSObject.Properties.Count -eq 0) { [void]$Config.PSObject.Properties.Remove('env') }
}

function Get-StrataApplicableSpeedSwitches {
    param($Config, [string]$Backend, [object[]]$Gpus = @())
    if (Test-StrataDeepSeekConfig -Config $Config) { return @('deepseek_speedups') }
    $ids = @()
    $isFlash = -not [string]$Config.arch
    if ($isFlash -and $Backend -in @('cuda','hip')) { $ids += 'faster_long_prompts' }
    if ($isFlash -and $Backend -eq 'cuda') {
        foreach ($gpu in @($Gpus)) {
            $name = [string]$gpu.Name
            $vendor = [string]$gpu.Vendor
            $memory = [double]$gpu.MemoryMiB
            if (($vendor -eq 'nvidia' -or (-not $vendor -and $name -match 'NVIDIA|GeForce|\bRTX\b|\bGTX\b|Quadro|Tesla')) -and
                    $memory -gt 0 -and $memory -le 13 * 1024 -and $gpu.Integrated -ne $true) {
                $ids += 'faster_12gb_nvidia'
                break
            }
        }
    }
    if ($Backend -eq 'hip') {
        foreach ($gpu in @($Gpus)) {
            $name = [string]$gpu.Name
            $arch = [string]$gpu.Arch
            if ($arch -match '^gfx120[01]$' -or $name -match '(?i)\bRX\s*9\d{3}\b|\b(?:AI\s*PRO\s*)?R97\d{2}\b') {
                $ids += 'faster_radeon_9000'
                break
            }
        }
    }
    return $ids
}

function Set-StrataDeepSeekArgs {
    param([Collections.ArrayList]$List, $Settings)
    # The dsv41 engine has its own flags and treats an unknown one as a fatal error: drop the Qwen-only
    # flags the launcher writes for its engine before any DeepSeek value is saved.
    foreach ($flag in @(Get-StrataQwenOnlyFlags)) {
        Remove-StrataArgPair -List $List -Flag $flag
    }
    for ($i = $List.Count - 1; $i -ge 0; $i--) {
        if ([string]$List[$i] -ne '--vision') { continue }
        if ($i + 1 -ge $List.Count -or [string]$List[$i + 1] -notin @('on','off')) {
            Remove-StrataArgPair -List $List -Flag '--vision'
        }
    }
    $visionMode = (Get-StrataDeepSeekSetting $Settings 'VisionMode').ToLowerInvariant()
    if ($Settings.VisionSupported -eq $false) {
        Remove-StrataArgPair -List $List -Flag '--vision'
    } elseif ($visionMode -in @('on','off')) {
        Set-StrataArgPair -List $List -Flag '--vision' -Value $visionMode
    }
    Set-StrataArgPair -List $List -Flag '--max-context' -Value ([string]$Settings.Context)
    Set-StrataArgPair -List $List -Flag '--reserve-mib' -Value $Settings.ReserveMib
    Set-StrataArgPair -List $List -Flag '--cpu-threads' -Value $Settings.CpuThreads
    $dspark = ([string]$Settings.Dspark).ToLowerInvariant()
    if ($dspark -notin @('auto','on','off','none')) { $dspark = 'auto' }
    Set-StrataArgPair -List $List -Flag '--dspark' -Value $dspark
    Set-StrataArgPair -List $List -Flag '--dspark-conf' -Value $Settings.DsparkConf
    # The expert-placement knobs.  An empty value leaves the flag out, so the engine's own rule stays in force;
    # a value out of the engine's domain is dropped rather than written (dsv41 stops on a bad flag value).
    $ssdCache = (Get-StrataDeepSeekSetting $Settings 'SsdCache').Trim()
    if ($ssdCache -eq 'auto') { $ssdCache = '' }
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
    $experts = (Get-StrataDeepSeekSetting $Settings 'Experts').Trim()
    if ($Settings.ExpertsSupported -ne $true -or $experts -notin @('5','6')) { $experts = '' }
    Set-StrataArgPair -List $List -Flag '--experts' -Value $experts
    # "copy into RAM" and "RAM store" are two roads to the same place: copying every expert the GPU leaves
    # over already fills the memory, so a store budget on top of it would double-count.  One road at a time.
    if ($mmap -eq 'off') { Set-StrataArgPair -List $List -Flag '--ssd-cache' -Value '0' }
    return $List
}
