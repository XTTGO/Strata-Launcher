$ErrorActionPreference = 'Stop'

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw "FAIL: $Message (expected $Expected, got $Actual)" }
}

. (Join-Path $PSScriptRoot '..\Strata-Launcher-Settings.ps1')

function New-UsageControls {
    $controls = @{}
    foreach ($name in @('effort')) { $controls[$name] = [pscustomobject]@{ SelectedItem = 'high' } }
    foreach ($name in @('temperature','top_p','top_k','min_p','presence_penalty','repetition_penalty','frequency_penalty','penalty_last_n','max_tokens','reasoning_budget_tokens')) {
        $controls[$name] = [pscustomobject]@{ Value = [decimal]0 }
    }
    $controls.seed = [pscustomobject]@{ Text = '123' }
    return $controls
}

$controls = New-UsageControls
$labels = @('快速直答','日常通用','Agent / 深度思考')
foreach ($label in $labels) {
    Set-StrataUsagePresetControls -Name $label -Controls $controls
    Assert-Equal (Get-StrataUsagePresetName -Controls $controls) $label 'an applied preset must be recognized'
    if ($label -eq '快速直答') {
        Assert-Equal $controls.temperature.Value 0.7 'non-thinking mode should use the Qwen recommendation'
        Assert-Equal $controls.top_p.Value 0.8 'non-thinking mode should use the Qwen top_p recommendation'
        Assert-Equal $controls.presence_penalty.Value 1.5 'non-thinking mode should use the Qwen presence penalty recommendation'
    } else {
        Assert-Equal $controls.temperature.Value 1 'thinking modes should use the Qwen recommendation'
        Assert-Equal $controls.top_p.Value 0.95 'thinking modes should use the Qwen top_p recommendation'
        Assert-Equal $controls.presence_penalty.Value 0 'thinking modes should not add a presence penalty'
    }
    Assert-Equal $controls.repetition_penalty.Value 1 'presets must disable repetition penalty'
    Assert-Equal $controls.seed.Text '' 'preset must clear a fixed seed'
    Assert-Equal $controls.max_tokens.Value 0 'preset must clear a prior output cap'
    Assert-Equal $controls.reasoning_budget_tokens.Value 0 'preset must clear a prior thinking cap'
}
Assert-Equal $controls.effort.SelectedItem 'high' 'deep thinking should use high effort'
Set-StrataUsagePresetControls -Name '日常通用' -Controls $controls
Assert-Equal $controls.effort.SelectedItem 'medium' 'daily use should use medium effort'
Set-StrataUsagePresetControls -Name '快速直答' -Controls $controls
Assert-Equal $controls.effort.SelectedItem 'none' 'fast reply should disable thinking'

$controls.temperature.Value = [decimal]0.75
Assert-Equal (Get-StrataUsagePresetName -Controls $controls) '自定义' 'manual edits must remove the preset label'
$controls.temperature.Value = [decimal]0.7
Assert-Equal (Get-StrataUsagePresetName -Controls $controls) '快速直答' 'restoring exact values should restore the label'
$controls.seed.Text = '7'
Assert-Equal (Get-StrataUsagePresetName -Controls $controls) '自定义' 'a fixed seed must mark the preset custom'

Add-Type -AssemblyName System.Windows.Forms
$selector = [Windows.Forms.ComboBox]::new()
[void]$selector.Items.AddRange(@('快速直答','日常通用','Agent / 深度思考','自定义'))
$selector.SelectedItem = '自定义'
$uiControls = @{}
$uiControls.effort = [Windows.Forms.ComboBox]::new()
[void]$uiControls.effort.Items.AddRange(@('none','medium','high'))
foreach ($name in @('temperature','top_p','top_k','min_p','presence_penalty','repetition_penalty','frequency_penalty','penalty_last_n','max_tokens','reasoning_budget_tokens')) {
    $uiControls[$name] = [Windows.Forms.NumericUpDown]::new()
    $uiControls[$name].Maximum = 131072
    $uiControls[$name].DecimalPlaces = 2
}
$uiControls.seed = [Windows.Forms.TextBox]::new()
Set-StrataUsagePresetControls -Name 'Agent / 深度思考' -Controls $uiControls
Connect-StrataUsagePresetControls -Selector $selector -Controls $uiControls
Assert-Equal $selector.SelectedItem 'Agent / 深度思考' 'existing matching values should show the preset'
$selector.SelectedItem = '快速直答'
Assert-Equal $uiControls.effort.SelectedItem 'none' 'choosing a preset must update actual controls'
$uiControls.temperature.Value = [decimal]0.75
Assert-Equal $selector.SelectedItem '自定义' 'manual numeric edits must clear a stale preset label'
$uiControls.temperature.Value = [decimal]0.7
Assert-Equal $selector.SelectedItem '快速直答' 'restoring exact values should rediscover the preset'
$uiControls.seed.Text = '7'
Assert-Equal $selector.SelectedItem '自定义' 'manual seed edits must clear a stale preset label'

$dsCard = Get-StrataModelCardSampling -Family 'deepseek41' -Thinking $true
Assert-Equal $dsCard.temperature 1 'DeepSeek model card temperature is one'
Assert-Equal $dsCard.top_p 1 'DeepSeek model card top_p is one'
if ($dsCard.Contains('top_k') -or $dsCard.Contains('presence_penalty')) { throw 'DeepSeek model card must not invent token or penalty defaults' }

$qwen38 = Get-StrataModelCardSampling -Family 'qwen4exp' -Thinking $true
Assert-Equal $qwen38.top_p 0.95 'Qwen3.8 thinking uses the Qwen model-card top_p'
if ($qwen38.Contains('presence_penalty')) { throw 'Qwen3.8 thinking card does not prescribe a presence penalty' }
$qwen36 = Get-StrataModelCardSampling -Family 'qwen35moe' -Thinking $true
Assert-Equal $qwen36.presence_penalty 1.5 'Qwen3.6 thinking keeps its distinct model-card penalty'

$dsControls = New-UsageControls
Set-StrataUsagePresetControls -Name '快速直答' -Family 'deepseek41' -Controls $dsControls
Assert-Equal $dsControls.temperature.Value 1 'DeepSeek direct-answer preset must not inherit Qwen temperature'
Assert-Equal $dsControls.top_p.Value 1 'DeepSeek direct-answer preset must not inherit Qwen top_p'
Assert-Equal $dsControls.effort.SelectedItem 'none' 'DeepSeek direct-answer preset turns off thinking'
Set-StrataUsagePresetControls -Name 'Agent / 深度思考' -Family 'qwen35moe' -Controls $dsControls
Assert-Equal $dsControls.presence_penalty.Value 1.5 'Qwen3.6 agent preset keeps its own model-card penalty'

$legacyDs = [pscustomobject]@{ temperature = 1; top_p = 0.95; top_k = 20; presence_penalty = 1.5; repetition_penalty = 1.2; future_key = 'keep' }
$officialDs = Get-StrataSamplingForSave -Existing $legacyDs -Family 'deepseek41' -PresetName '官方默认'
if ($officialDs.PSObject.Properties['temperature'] -or $officialDs.PSObject.Properties['top_p'] -or
    $officialDs.PSObject.Properties['top_k'] -or $officialDs.PSObject.Properties['presence_penalty']) {
    throw 'official default must clear legacy DeepSeek model sampling overrides'
}
Assert-Equal $officialDs.future_key 'keep' 'an unknown future sampling key stays untouched'
$agentDs = Get-StrataSamplingForSave -Existing $legacyDs -Family 'deepseek41' -PresetName 'Agent / 深度思考'
Assert-Equal $agentDs.temperature 1 'DeepSeek agent preset writes its model-card temperature'
Assert-Equal $agentDs.top_p 1 'DeepSeek agent preset writes its model-card top_p'
if ($agentDs.PSObject.Properties['top_k'] -or $agentDs.PSObject.Properties['presence_penalty']) {
    throw 'DeepSeek agent preset must not write Qwen-only model-card fields'
}

$legacyShared = [pscustomobject]@{ top_p = 0.95; top_k = 20; reasoning_effort = 'high'; reasoning_budget_tokens = 32768; max_tokens = 2048; experimental_speed_projection = $true; custom_key = 'keep' }
$resetShared = Merge-StrataSharedDefaults -Existing $legacyShared -Edited ([pscustomobject]@{})
foreach ($name in @('top_p','top_k','reasoning_effort','reasoning_budget_tokens','max_tokens','experimental_speed_projection')) {
    if ($resetShared.PSObject.Properties[$name]) { throw "official default must clear old shared $name" }
}
Assert-Equal $resetShared.custom_key 'keep' 'unrelated shared keys stay untouched'

if ($null -ne (Get-StrataReasoningBudgetValue -Mode '官方默认' -Value 0)) { throw 'the default budget must stay absent' }
Assert-Equal (Get-StrataReasoningBudgetValue -Mode '不限制（0）' -Value 0) 0 'explicit zero means no fixed thinking budget'
Assert-Equal (Get-StrataReasoningBudgetValue -Mode '自定义上限' -Value 4096) 4096 'positive custom budget is saved'
foreach($unsupported in @('max','85','自定义（1-100）')) {
    $badEffort = $false
    try { [void](Get-StrataReasoningEffortValue -Family 'deepseek41' -Choice $unsupported -CustomNumber 85) } catch { $badEffort = $true }
    if (-not $badEffort) { throw "Config/default effort $unsupported must be rejected; only DeepSeek API requests accept max or 1-100" }
}
if (Test-StrataGenerationOverrides -Config ([pscustomobject]@{ arch = 'deepseek41'; args = @('--pack','P') }) -Shared ([pscustomobject]@{})) {
    throw 'a fresh DeepSeek config should be eligible for official defaults'
}
if (-not (Test-StrataGenerationOverrides -Config ([pscustomobject]@{ arch = 'deepseek41'; sampling = [pscustomobject]@{ top_p = 0.95 } }) -Shared ([pscustomobject]@{}))) {
    throw 'legacy DeepSeek top_p must count as an override'
}

$officialSelector = [Windows.Forms.ComboBox]::new()
[void]$officialSelector.Items.AddRange(@('官方默认','快速直答','日常通用','Agent / 深度思考','自定义'))
$officialSelector.SelectedItem = '官方默认'
$officialControls = @{}
$officialControls.effort = [Windows.Forms.ComboBox]::new()
[void]$officialControls.effort.Items.AddRange(@('none','medium','high'))
foreach ($name in @('temperature','top_p','top_k','min_p','presence_penalty','repetition_penalty','frequency_penalty','penalty_last_n','max_tokens','reasoning_budget_tokens')) {
    $officialControls[$name] = [Windows.Forms.NumericUpDown]::new()
    $officialControls[$name].Maximum = 131072
    $officialControls[$name].DecimalPlaces = 2
}
$officialControls.seed = [Windows.Forms.TextBox]::new()
Set-StrataUsagePresetControls -Name '官方默认' -Family 'deepseek41' -Controls $officialControls
Connect-StrataUsagePresetControls -Selector $officialSelector -Controls $officialControls -Family 'deepseek41'
Assert-Equal $officialSelector.SelectedItem '官方默认' 'fresh official defaults should remain marked as official'
$officialControls.temperature.Value = [decimal]1.1
Assert-Equal $officialSelector.SelectedItem '自定义' 'editing an official default must leave official mode'
$officialSelector.SelectedItem = '官方默认'
Assert-Equal $officialSelector.SelectedItem '官方默认' 'reselecting official mode must survive control reset events'

'PASS: usage presets apply complete generation defaults and detect edits'
