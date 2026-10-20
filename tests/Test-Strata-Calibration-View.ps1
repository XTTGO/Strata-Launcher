$ErrorActionPreference = 'Stop'

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) {
        throw "FAIL: $Message`r`nExpected: $Expected`r`nActual:   $Actual"
    }
}

function Assert-Contains([string]$Actual, [string]$Expected, [string]$Message) {
    if (-not $Actual.Contains($Expected)) {
        throw "FAIL: $Message`r`nMissing: $Expected`r`nActual:`r`n$Actual"
    }
}

function Assert-NotContains([string]$Actual, [string]$Unexpected, [string]$Message) {
    if ($Actual.Contains($Unexpected)) {
        throw "FAIL: $Message`r`nUnexpected: $Unexpected`r`nActual:`r`n$Actual"
    }
}

$viewModule = Join-Path (Resolve-Path 'launcher') 'Strata-Calibration-View.ps1'
if (-not (Test-Path -LiteralPath $viewModule)) {
    throw "FAIL: calibration view module is missing: $viewModule"
}
$viewSource = Get-Content -LiteralPath $viewModule -Raw -Encoding UTF8
. ([scriptblock]::Create($viewSource))

$cfg = [pscustomobject]@{
    model_name = 'qwen3.8-flash-next-iq3_s'
    args = @('--max-context','262144','--vision','--pcie-frac','0.20','--spec-min-p','0.70')
}
$record = [pscustomobject]@{
    date = '2026-10-09'
    tok_s = 106.4
    settings = [pscustomobject]@{
        '--pcie-frac' = '0.20'
        '--spec-min-p' = '0.70'
    }
}
$detail = [pscustomobject]@{
    engine_version = '0.1.41'
    date = '2026-10-09'
    engine_defaults = [pscustomobject]@{
        '--adapt-every' = '4'
        '--adapt-swaps' = '96'
        '--adapt-decay' = '0.70'
    }
    report = [pscustomobject]@{
        default = [pscustomobject]@{ pcie_frac = 0.55; spec_min_p = 0.50; pool_workers = 23 }
        workers = [pscustomobject]@{
            '23' = @(101.7,99.6)
            '15' = @(95.5,96.1)
            '12' = @(94.0,93.1)
            '6' = @(71.4,74.5)
        }
        adapt = [pscustomobject]@{
            'default' = @(107.8,105.0)
            '1/80/0.97' = @(110.5,107.7)
            '1/160/0.97' = @(108.8,105.6)
        }
        tok_s = 106.4
    }
}

$view = Get-StrataCalibrationView -Config $cfg -ModelLabel 'IQ3_S' -Record $record -Detail $detail

Assert-Equal $view.Title '性能校准 · IQ3_S · 256K · 视觉开启' 'title must name the actual calibration combination'
Assert-Equal $view.Summary '已校准 · 2026-10-09 · 106.4 tok/s' 'summary must retain date and final speed'
Assert-Contains $view.Details 'PCIe share 0.20（校准采用；基准 0.55）' 'PCIe value and baseline must be explicit'
Assert-Contains $view.Details 'MTP 门槛 0.70（校准采用；基准 0.50）' 'MTP value and baseline must be explicit'
Assert-Contains $view.Details 'CPU workers 自动 23（已实测，保留默认）' 'automatic worker count must be explicit'
Assert-Contains $view.Details '专家缓存：间隔 4 / 交换 96 / 衰减 0.70（已实测，保留默认）' 'expert cache defaults must be expanded'
Assert-Contains $view.Details '候选 80：109.1 tok/s（+2.5%）' 'best rejected cache candidate must show its measured gain'
Assert-Contains $view.Details '未超过 3% 采用门槛' 'the rejection threshold must be explained'

$legacyView = Get-StrataCalibrationView -Config $cfg -ModelLabel 'IQ3_S' -Record $record -Detail $null
Assert-Contains $legacyView.Details '详细报告未保存' 'old records must not pretend their defaults are known'

$mismatchedDetail = $detail | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$mismatchedDetail.date = '2026-10-08'
$mismatchedView = Get-StrataCalibrationView -Config $cfg -ModelLabel 'IQ3_S' -Record $record -Detail $mismatchedDetail
Assert-Contains $mismatchedView.Details '详细报告与当前校准记录不匹配' 'restored settings must not use a newer or older detail report'
Assert-NotContains $mismatchedView.Details '自动 23' 'mismatched details must not be presented as current'

$editingView = Get-StrataCalibrationView -Config $cfg -ModelLabel 'IQ3_S' -Record $null -Detail $null -ContextValue 524288 -WithVision $false
Assert-Equal $editingView.Title '性能校准 · IQ3_S · 512K · 纯文本' 'title must follow the current controls before settings are saved'

function Find-CalibrationRecord($Records, [string]$Suffix) {
    return ($Records.PSObject.Properties | Where-Object { $_.Name.EndsWith($Suffix,[StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1).Value
}

$officialStore = Get-Content -LiteralPath "$env:APPDATA\Strata\settings.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$detailStore = Get-Content -LiteralPath 'launcher\data\calibration-details.json' -Raw -Encoding UTF8 | ConvertFrom-Json
$installed = @(
    @{ Config='strata-iq3_s.json'; Label='IQ3_S'; Suffix='|qwen3.8-flash-next-iq3_s|262144|images'; Expected='CPU workers 自动 23（已实测，保留默认）' }
    @{ Config='strata-unsloth-ud-iq4_xs.json'; Label='UD-IQ4_XS'; Suffix='|qwen3.8-flash-next-unsloth-ud-iq4_xs|262144|images'; Expected='CPU workers 15（校准采用；基准自动 23）' }
    @{ Config='strata-unsloth-ud-q4_k_xl.json'; Label='UD-Q4_K_XL'; Suffix='|qwen3.8-flash-next-unsloth-ud-q4_k_xl|262144|text'; Expected='CPU workers 自动 23（已实测，保留默认）' }
)
foreach ($item in $installed) {
    $installedConfig = Get-Content -LiteralPath $item.Config -Raw -Encoding UTF8 | ConvertFrom-Json
    $installedRecord = Find-CalibrationRecord $officialStore.calibration $item.Suffix
    $installedDetail = Find-CalibrationRecord $detailStore.records $item.Suffix
    if (-not $installedDetail) { throw "FAIL: detailed report is missing for $($item.Label)" }
    $installedView = Get-StrataCalibrationView -Config $installedConfig -ModelLabel $item.Label -Record $installedRecord -Detail $installedDetail
    Assert-Contains $installedView.Details $item.Expected "$($item.Label) must show its measured CPU worker decision"
    Assert-Contains $installedView.Details '专家缓存：间隔 4 / 交换 96 / 衰减 0.70（已实测，保留默认）' "$($item.Label) must expand its measured expert-cache defaults"
    Assert-NotContains $installedView.Details '详细报告未保存' "$($item.Label) must not fall back to an incomplete historical display"
}

'PASS: calibration view'
