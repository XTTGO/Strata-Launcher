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

'PASS: usage presets apply complete generation defaults and detect edits'
