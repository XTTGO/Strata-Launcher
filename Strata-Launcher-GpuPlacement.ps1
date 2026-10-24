# GPU inventory and the one-model CUDA placement written to Strata run configs.
function Convert-StrataGpuPlacementCsv([string]$Text) {
    foreach ($line in ($Text -split "`r?`n")) {
        $parts = @($line -split ',' | ForEach-Object { $_.Trim() })
        if ($parts.Count -ne 6) { continue }
        $index = 0
        $memory = 0
        $capability = 0.0
        if (-not [int]::TryParse($parts[0],[ref]$index) -or $index -lt 0 -or
            $parts[1] -notmatch '^GPU-[0-9a-fA-F-]{36}$' -or -not $parts[2] -or
            $parts[3] -notmatch '^(\d+)(?:\s*MiB)?$' -or
            -not [int]::TryParse($Matches[1],[ref]$memory) -or
            -not [double]::TryParse($parts[4],[Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture,[ref]$capability) -or
            $parts[5] -notmatch '^[0-9A-Fa-f:]+\.[0-9A-Fa-f]+$') { continue }
        [pscustomobject]@{
            Index=$index; Uuid=$parts[1]; Name=$parts[2]; MemoryMiB=$memory
            ComputeCapability=$capability; BusId=$parts[5]
        }
    }
}

function Convert-StrataGpuPciBusIdToWindowsLocation([string]$BusId) {
    if ($BusId -notmatch '^(?<segment>[0-9A-Fa-f]{4,8}):(?<bus>[0-9A-Fa-f]{2}):(?<device>[0-9A-Fa-f]{2})\.(?<function>[0-7])$') {
        return $null
    }
    $segment = [Convert]::ToUInt32($Matches['segment'],16)
    $bus = [Convert]::ToInt32($Matches['bus'],16)
    $device = [Convert]::ToInt32($Matches['device'],16)
    $function = [Convert]::ToInt32($Matches['function'],16)
    $text = if ($segment -eq 0) {
        "PCI 总线 $bus、设备 $device、功能 $function"
    } else {
        "PCI 段 $segment、总线 $bus、设备 $device、功能 $function"
    }
    [pscustomobject]@{
        Segment=$segment; Bus=$bus; Device=$device; Function=$function; Text=$text
    }
}

function Get-StrataNvidiaPlacementCards {
    $command = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
    if (-not $command) { return @() }
    $output = & $command.Source '--query-gpu=index,uuid,name,memory.total,compute_cap,pci.bus_id' '--format=csv,noheader,nounits' 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    @(Convert-StrataGpuPlacementCsv ($output -join "`n") | Sort-Object Index)
}

function Test-StrataCudaPlacementCard($Build, $Card) {
    if (-not $Build -or -not $Build.cuda -or -not $Card -or
        $Card.ComputeCapability -lt 7.5 -or $Card.MemoryMiB -lt 4096) { return $false }
    $arch = [int][Math]::Round([double]$Card.ComputeCapability * 10)
    return (@($Build.archs) -contains $arch -or [bool]$Build.ptx)
}

function Test-StrataCudaPlacementBuild($Build, [object[]]$Cards) {
    if (-not $Build -or -not $Build.cuda) { return $false }
    foreach ($card in @($Cards)) {
        if (Test-StrataCudaPlacementCard -Build $Build -Card $card) { return $true }
    }
    return $false
}

function Get-StrataGpuPlacementRoles($Config, [object[]]$Cards) {
    $fromRoles = $Config.PSObject.Properties['gpu_roles']
    $legacy = @()
    if ($Config.PSObject.Properties['gpu'] -and $null -ne $Config.gpu) { $legacy = @($Config.gpu) }
    $legacy = @($legacy | ForEach-Object { [string]$_ })
    foreach ($card in @($Cards)) {
        $key = [string]$card.Index
        $role = 'off'
        if ($fromRoles -and $fromRoles.Value -and $fromRoles.Value.PSObject.Properties[$key]) {
            $role = [string]$fromRoles.Value.PSObject.Properties[$key].Value
        } elseif ($legacy -contains $key) {
            $role = if ($legacy[-1] -eq $key) { 'main' } else { 'helper' }
        }
        [pscustomobject]@{ Index=$card.Index; Role=$role }
    }
}

function Get-StrataGpuPlacementRoleValue($Roles, [int]$Index) {
    if ($Roles.ContainsKey($Index)) { return [string]$Roles[$Index] }
    if ($Roles.ContainsKey([string]$Index)) { return [string]$Roles[[string]$Index] }
    return 'off'
}

function Get-StrataGpuCardFingerprint($Card) {
    $short = [string]$Card.Name
    foreach ($prefix in @('NVIDIA GeForce ','NVIDIA ','GeForce ')) {
        if ($short.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { $short=$short.Substring($prefix.Length); break }
    }
    return $short.Trim() + '|' + [string]$Card.BusId
}

function Test-StrataGpuCardFingerprint([string]$Saved, $Card) {
    $savedParts = @($Saved -split '\|',2)
    $currentParts = @((Get-StrataGpuCardFingerprint $Card) -split '\|',2)
    if ($savedParts[0] -ine $currentParts[0]) { return $false }
    if ($savedParts.Count -eq 1) { return $true }
    $savedBus = $savedParts[1] -replace '^0+(?=[0-9a-f]+:)', ''
    $currentBus = $currentParts[1] -replace '^0+(?=[0-9a-f]+:)', ''
    return $savedBus -ieq $currentBus
}

function Assert-StrataGpuPlacementIdentity($Config, [object[]]$Cards) {
    if (-not $Config.PSObject.Properties['gpu_cards'] -or -not $Config.gpu_cards) { return }
    foreach ($index in @($Config.gpu)) {
        $key = [string]$index
        $saved = $Config.gpu_cards.PSObject.Properties[$key]
        $card = @($Cards | Where-Object { [string]$_.Index -eq $key } | Select-Object -First 1)
        if (-not $saved -or -not $card.Count -or
            -not (Test-StrataGpuCardFingerprint -Saved ([string]$saved.Value) -Card $card[0])) {
            throw "GPU $key 的硬件身份与模型配置不符；请重新打开启动器并确认推理显卡分配。"
        }
    }
}

function Set-StrataGpuPlacementConfig($Config, [object[]]$Cards, [object[]]$CurrentCards, $Roles, $Build) {
    if (-not (Test-StrataCudaPlacementBuild -Build $Build -Cards $Cards)) {
        throw '当前引擎或显卡不支持此 NVIDIA 多卡设置。'
    }
    $original = @($Cards | Sort-Object Index)
    $current = @($CurrentCards | Sort-Object Index)
    if ($original.Count -ne $current.Count) { throw '显卡列表已变化，请重新打开启动器后再设置。' }
    for ($i=0; $i -lt $original.Count; $i++) {
        if ($original[$i].Index -ne $current[$i].Index -or
            $original[$i].Uuid -ne $current[$i].Uuid -or
            $original[$i].BusId -ne $current[$i].BusId) {
            throw '显卡编号或身份已变化，请重新打开启动器后再设置。'
        }
    }
    if (-not $Roles -or $Roles.Count -ne $original.Count) {
        throw '每张显卡都必须明确选择 Main、Helper 或 Off。'
    }
    $main = @()
    $helpers = @()
    $roleMap = [ordered]@{}
    $cardMap = [ordered]@{}
    foreach ($card in $original) {
        if (-not $Roles.ContainsKey([int]$card.Index) -and -not $Roles.ContainsKey([string]$card.Index)) {
            throw "GPU $($card.Index) 缺少角色选择。"
        }
        $role = Get-StrataGpuPlacementRoleValue -Roles $Roles -Index $card.Index
        if ($role -notin @('main','helper','off')) { throw "GPU $($card.Index) 的角色无效：$role" }
        $roleMap[[string]$card.Index] = $role
        $cardMap[[string]$card.Index] = Get-StrataGpuCardFingerprint $card
        if ($role -eq 'off') { continue }
        if (-not (Test-StrataCudaPlacementCard -Build $Build -Card $card)) {
            throw "GPU $($card.Index) 不满足 Strata CUDA 运行条件。"
        }
        if ($role -eq 'main') { $main += [int]$card.Index } else { $helpers += [int]$card.Index }
    }
    if ($main.Count -ne 1) { throw '必须且只能指定一张 Main 显卡。' }
    if ($helpers.Count -and @($original | Where-Object {
        (Get-StrataGpuPlacementRoleValue -Roles $Roles -Index $_.Index) -ne 'off' -and $_.MemoryMiB -lt 8192
    }).Count) { throw '多卡分层要求每张参与的显卡至少有 8 GiB 显存。' }
    $order = @($helpers | Sort-Object) + @($main)
    $result = $Config | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $result | Add-Member -NotePropertyName gpu_roles -NotePropertyValue ([pscustomobject]$roleMap) -Force
    $result | Add-Member -NotePropertyName gpu -NotePropertyValue $(if ($order.Count -eq 1) { $order[0] } else { [int[]]$order }) -Force
    $result | Add-Member -NotePropertyName gpu_order -NotePropertyValue 'as_given' -Force
    $result | Add-Member -NotePropertyName gpu_cards -NotePropertyValue ([pscustomobject]$cardMap) -Force
    if ($order.Count -gt 1) {
        $result | Add-Member -NotePropertyName layer_split -NotePropertyValue 'auto' -Force
    } else {
        $result.PSObject.Properties.Remove('layer_split')
    }
    return $result
}

function Set-StrataDeepSeekGpuConfig($Config, [object[]]$Cards, [object[]]$CurrentCards, [int[]]$Selected) {
    # DeepSeek's engine balances its own expert placement across the cards it sees, so the launcher only chooses
    # which cards take part: the server turns config "gpu" into CUDA_VISIBLE_DEVICES. No gpu_roles / layer_split.
    $original = @($Cards | Sort-Object Index)
    $current = @($CurrentCards | Sort-Object Index)
    if ($original.Count -ne $current.Count) { throw '显卡列表已变化，请重新打开启动器后再设置。' }
    for ($i = 0; $i -lt $original.Count; $i++) {
        if ($original[$i].Index -ne $current[$i].Index -or
            $original[$i].Uuid -ne $current[$i].Uuid -or
            $original[$i].BusId -ne $current[$i].BusId) {
            throw '显卡编号或身份已变化，请重新打开启动器后再设置。'
        }
    }
    $picked = @($Selected | ForEach-Object { [int]$_ } | Sort-Object -Unique)
    if (-not $picked.Count) { throw '至少选择一张显卡参与 DeepSeek 推理。' }
    foreach ($index in $picked) {
        $card = @($original | Where-Object Index -EQ $index | Select-Object -First 1)
        if (-not $card.Count) { throw "GPU $index 不在当前显卡列表中。" }
        if ([double]$card[0].MemoryMiB -lt 8192) {
            $gib = [Math]::Round([double]$card[0].MemoryMiB / 1024, 1)
            throw "GPU $index 只有 $gib GiB 显存；DeepSeek 至少需要 8 GiB。"
        }
    }
    $result = $Config | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $result | Add-Member -NotePropertyName gpu -NotePropertyValue $(if ($picked.Count -eq 1) { $picked[0] } else { [int[]]$picked }) -Force
    foreach ($name in @('gpu_roles','gpu_order','gpu_cards','layer_split')) {
        $result.PSObject.Properties.Remove($name)
    }
    return $result
}
