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
                 '--dspark','--dspark-conf','--ssd-cache','--prefill-chunk')
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
        PrefillChunk = [string](& $read '--prefill-chunk' '')
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
    Set-StrataArgPair -List $List -Flag '--ssd-cache' -Value $Settings.SsdCache
    Set-StrataArgPair -List $List -Flag '--prefill-chunk' -Value $Settings.PrefillChunk
    return $List
}
