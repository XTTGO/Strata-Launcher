function Get-CalibrationProperty($Object, [string]$Name, $Fallback = $null) {
    if ($null -ne $Object) {
        $property = $Object.PSObject.Properties[$Name]
        if ($property -and $null -ne $property.Value -and [string]$property.Value -ne '') {
            return $property.Value
        }
    }
    return $Fallback
}

function Get-CalibrationArg($Config, [string]$Flag, $Fallback = $null) {
    $argsList = @($Config.args)
    $index = [Array]::IndexOf($argsList, $Flag)
    if ($index -ge 0 -and $index + 1 -lt $argsList.Count) { return $argsList[$index + 1] }
    return $Fallback
}

function Format-CalibrationNumber($Value, [string]$Pattern = '0.0') {
    if ($null -eq $Value -or [string]$Value -eq '') { return '' }
    return ([double]$Value).ToString($Pattern, [Globalization.CultureInfo]::InvariantCulture)
}

function Get-CalibrationMedian($Values) {
    $numbers = @($Values | ForEach-Object { [double]$_ } | Sort-Object)
    if (-not $numbers.Count) { return $null }
    $middle = [int][Math]::Floor($numbers.Count / 2)
    if ($numbers.Count % 2) { return $numbers[$middle] }
    return ($numbers[$middle - 1] + $numbers[$middle]) / 2.0
}

function Format-CalibrationContext([long]$ContextValue) {
    if ($ContextValue -gt 0 -and $ContextValue % 1048576 -eq 0) { return "$(($ContextValue / 1048576))M" }
    if ($ContextValue -gt 0 -and $ContextValue % 1024 -eq 0) { return "$(($ContextValue / 1024))K" }
    return [string]$ContextValue
}

function Get-StrataCalibrationView {
    param(
        [Parameter(Mandatory=$true)]$Config,
        [Parameter(Mandatory=$true)][string]$ModelLabel,
        $Record,
        $Detail,
        [long]$ContextValue = 0,
        $WithVision = $null
    )

    if ($ContextValue -le 0) { $ContextValue = [long](Get-CalibrationArg $Config '--max-context' 0) }
    $visionEnabled = if ($null -ne $WithVision) { [bool]$WithVision } else { @($Config.args) -contains '--vision' }
    $visionText = if ($visionEnabled) { '视觉开启' } else { '纯文本' }
    $title = "性能校准 · $ModelLabel · $(Format-CalibrationContext $ContextValue) · $visionText"
    if (-not $Record) {
        return [pscustomobject]@{
            Title = $title
            Summary = '当前组合尚未校准'
            Details = '直接启动会沿用配置中的性能参数；保存并校准后会生成该组合的专属结果。'
        }
    }

    $speed = if ($null -ne $Record.tok_s) { ' · ' + (Format-CalibrationNumber $Record.tok_s '0.0') + ' tok/s' } else { '' }
    $summary = "已校准 · $($Record.date)$speed"
    $settings = $Record.settings

    $detailProblem = $null
    if (-not $Detail -or -not $Detail.report) {
        $detailProblem = '详细报告未保存；仅显示配置中的显式参数。'
    } elseif (($Detail.date -and $Record.date -and [string]$Detail.date -ne [string]$Record.date) -or
              ($null -ne $Detail.report.tok_s -and $null -ne $Record.tok_s -and
               [Math]::Abs([double]$Detail.report.tok_s - [double]$Record.tok_s) -gt 0.05)) {
        $detailProblem = '详细报告与当前校准记录不匹配；仅显示配置中的显式参数。'
    }
    if ($detailProblem) {
        $pcie = Get-CalibrationProperty $settings '--pcie-frac' (Get-CalibrationArg $Config '--pcie-frac' '引擎自动')
        $draft = Get-CalibrationProperty $settings '--spec-min-p' (Get-CalibrationArg $Config '--spec-min-p' '0.50')
        $details = "PCIe share $pcie　MTP 门槛 $draft`r`nCPU workers 自动（具体线程数未保存）`r`n专家缓存：引擎默认（具体数值未保存）`r`n$detailProblem"
        return [pscustomobject]@{ Title=$title; Summary=$summary; Details=$details }
    }

    $report = $Detail.report
    $defaults = $report.default
    $pcieSetting = Get-CalibrationProperty $settings '--pcie-frac'
    $pcieBase = Get-CalibrationProperty $defaults 'pcie_frac'
    $pcieValue = if ($null -ne $pcieSetting) { [string]$pcieSetting } else { Format-CalibrationNumber $pcieBase '0.00' }
    $pcieDecision = if ($null -ne $pcieSetting) { "校准采用；基准 $(Format-CalibrationNumber $pcieBase '0.00')" } else { '已实测，保留默认' }

    $draftSetting = Get-CalibrationProperty $settings '--spec-min-p'
    $draftBase = Get-CalibrationProperty $defaults 'spec_min_p' 0.5
    $draftValue = if ($null -ne $draftSetting) { [string]$draftSetting } else { Format-CalibrationNumber $draftBase '0.00' }
    $draftDecision = if ($null -ne $draftSetting) { "校准采用；基准 $(Format-CalibrationNumber $draftBase '0.00')" } else { '已实测，保留默认' }

    $workerSetting = Get-CalibrationProperty $settings '--pool-workers'
    $defaultWorkers = Get-CalibrationProperty $defaults 'pool_workers'
    if ($null -ne $workerSetting) {
        $workerText = "$workerSetting（校准采用；基准自动 $defaultWorkers）"
    } elseif ($null -ne $defaultWorkers) {
        $workerText = "自动 $defaultWorkers（已实测，保留默认）"
    } else {
        $workerText = '自动（已实测，保留默认）'
    }

    $engineDefaults = $Detail.engine_defaults
    $adaptEvery = Get-CalibrationProperty $settings '--adapt-every' (Get-CalibrationProperty $engineDefaults '--adapt-every' '4')
    $adaptSwaps = Get-CalibrationProperty $settings '--adapt-swaps' (Get-CalibrationProperty $engineDefaults '--adapt-swaps' '96')
    $adaptDecay = Get-CalibrationProperty $settings '--adapt-decay' (Get-CalibrationProperty $engineDefaults '--adapt-decay' '0.70')
    $adaptChanged = $null -ne (Get-CalibrationProperty $settings '--adapt-every') -or
                    $null -ne (Get-CalibrationProperty $settings '--adapt-swaps') -or
                    $null -ne (Get-CalibrationProperty $settings '--adapt-decay')
    $adaptDecision = if ($adaptChanged) { '校准采用' } else { '已实测，保留默认' }

    $lines = [Collections.ArrayList]::new()
    [void]$lines.Add("PCIe share $pcieValue（$pcieDecision）　MTP 门槛 $draftValue（$draftDecision）")
    [void]$lines.Add("CPU workers $workerText")
    [void]$lines.Add("专家缓存：间隔 $adaptEvery / 交换 $adaptSwaps / 衰减 $adaptDecay（$adaptDecision）")

    if (-not $adaptChanged -and $report.adapt) {
        $defaultRates = Get-CalibrationProperty $report.adapt 'default'
        $defaultRate = Get-CalibrationMedian $defaultRates
        $bestKey = $null
        $bestRate = $null
        foreach ($property in $report.adapt.PSObject.Properties) {
            if ($property.Name -eq 'default') { continue }
            $candidateRate = Get-CalibrationMedian $property.Value
            if ($null -ne $candidateRate -and ($null -eq $bestRate -or $candidateRate -gt $bestRate)) {
                $bestKey = $property.Name
                $bestRate = $candidateRate
            }
        }
        if ($bestKey -and $null -ne $defaultRate -and $defaultRate -gt 0 -and $bestRate -gt $defaultRate) {
            $parts = $bestKey.Split('/')
            $gain = (($bestRate / $defaultRate) - 1.0) * 100.0
            [void]$lines.Add("候选 $($parts[1])：$(Format-CalibrationNumber $bestRate '0.0') tok/s（+$(Format-CalibrationNumber $gain '0.0')%），未超过 3% 采用门槛")
        }
    }

    return [pscustomobject]@{ Title=$title; Summary=$summary; Details=($lines -join "`r`n") }
}
