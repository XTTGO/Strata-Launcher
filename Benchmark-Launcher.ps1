# Strata batch benchmark UI. All long-running work is delegated to benchmark.runner.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$LauncherDir = $PSScriptRoot
$VersionPath = Join-Path $LauncherDir 'VERSION.txt'
$LauncherVersion = if (Test-Path -LiteralPath $VersionPath -PathType Leaf) { (Get-Content -LiteralPath $VersionPath -Raw -Encoding UTF8).Trim() } else { 'unversioned' }
$RunStateHelper = Join-Path $LauncherDir 'benchmark\Run-State.ps1'
. $RunStateHelper
$Root = Split-Path -Parent $LauncherDir
$Py = Join-Path $Root '.venv\Scripts\python.exe'
$RunnerModule = 'benchmark.runner'
$DataDir = Join-Path $LauncherDir 'data'
$ReportsDir = Join-Path $LauncherDir 'reports'
$SettingsPath = Join-Path $DataDir 'benchmark-settings.json'
$PointerPath = Join-Path $DataDir 'benchmark-current.json'
foreach ($directory in @($DataDir,$ReportsDir)) { if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory -Force) } }

function Quote-Arg([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + (($Value -replace '(\\*)"','$1$1\"') -replace '(\\+)$','$1$1') + '"'
}
function New-RunnerStartInfo([string[]]$Arguments, [switch]$Redirect) {
    if (-not (Test-Path -LiteralPath $Py)) { throw "找不到 Strata 私有 Python：$Py" }
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=$Py
    $all=@('-m',$RunnerModule) + $Arguments
    $psi.Arguments=($all | ForEach-Object { Quote-Arg ([string]$_) }) -join ' '
    $psi.WorkingDirectory=$LauncherDir
    $psi.UseShellExecute=$false
    $psi.CreateNoWindow=$true
    if($Redirect){$psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true}
    return $psi
}
function Invoke-RunnerJson([string[]]$Arguments) {
    $p=[Diagnostics.Process]::new(); $p.StartInfo=New-RunnerStartInfo $Arguments -Redirect
    if(-not $p.Start()){throw '无法启动 Benchmark 控制器。'}
    $stdout=$p.StandardOutput.ReadToEnd(); $stderr=$p.StandardError.ReadToEnd(); $p.WaitForExit()
    if($p.ExitCode -ne 0){throw $(if($stderr){$stderr.Trim()}else{"控制器退出码：$($p.ExitCode)"})}
    $result=$stdout | ConvertFrom-Json
    return $result | ForEach-Object { $_ }
}
function Atomic-Json([string]$Path,$Value) {
    $tmp=$Path+'.tmp'; [IO.File]::WriteAllText($tmp,($Value | ConvertTo-Json -Depth 20)+"`r`n",[Text.UTF8Encoding]::new($false)); Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Load-UiSettings {
    if(Test-Path -LiteralPath $SettingsPath){
        try{
            $value=Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if([int]$value.preset_schema_version -ge 4){
                $storedTiers=@($value.context_tiers)
                if($value.sweep_context_tiers -and $storedTiers.Count -lt 2){$value.sweep_context_tiers=$false}
                if(-not $value.sweep_context_tiers -and $storedTiers.Count -gt 1){$value.context_tiers=@($storedTiers|Sort-Object|Select-Object -First 1)}
                return $value
            }
            $oldPreset=switch([string]$value.preset){'full'{'full'} 'stress'{'capacity'} 'capacity'{'capacity'} 'long'{'long'} 'parallel'{'parallel'} default{'standard'}}
            $oldPort=if($value.port){[int]$value.port}else{8188}
            return Get-PresetUiSettings $oldPreset $oldPort
        }catch{}
    }
    return Get-PresetUiSettings 'standard' 8188
}
function Get-PresetId($Value) {
    switch([string]$Value){'日常速测'{'standard'} '日常完整'{'full'} '长文对照'{'long'} '并发专项'{'parallel'} '容量极限'{'capacity'} '长文压力'{'capacity'} default{[string]$Value}}
}
function Get-PresetUiSettings([string]$PresetId,[int]$PortNumber) {
    $spec=$script:PresetSpecs.$PresetId
    if($null -eq $spec){throw "未知 Benchmark 预设：$PresetId"}
    return [pscustomobject]@{preset=$PresetId;rounds=[int]$spec.rounds;context_tiers=@([int]$spec.context_tier);sweep_context_tiers=$false;max_concurrency=[int]$spec.load_clients[-1];port=$PortNumber;stages=@($spec.stages);context_lengths=@($spec.performance|ForEach-Object{[string]$_[0]});context_lengths_version=2;preset_schema_version=5}
}
function Get-SavedContextLengths($Settings,[string]$PresetName) {
    $lengths=@($Settings.context_lengths)
    if([int]$Settings.context_lengths_version -lt 2){$lengths=@('4k') + $lengths}
    if($null -eq $Settings.PSObject.Properties['context_lengths']){
        $lengths=if($PresetName -eq 'full'){@('4k','32k','128k','256k')}else{@('4k','32k','128k')}
    }
    return $lengths
}
function Save-UiSettings {
    $stages=@($stageBoxes.GetEnumerator() | Where-Object {$_.Value.Checked} | ForEach-Object {$_.Key})
    $contextLengths=@($contextBoxes.GetEnumerator() | Where-Object {$_.Value.Checked} | ForEach-Object {$_.Key})
    $selectedTiers=@($tierBoxes.GetEnumerator() | Where-Object {$_.Value.Checked} | ForEach-Object {[int]$_.Key})
    $settings=[ordered]@{preset=(Get-PresetId $preset.SelectedItem);rounds=[int]$rounds.Value;context_tiers=$selectedTiers;sweep_context_tiers=[bool]$tierSweep.Checked;max_concurrency=[int]$maxConcurrency.Value;port=[int]$port.Value;stages=$stages;context_lengths=$contextLengths;context_lengths_version=2;preset_schema_version=5}
    Atomic-Json $SettingsPath $settings
}

$models=@(Invoke-RunnerJson @('list-models','--root',$Root))
if(-not $models.Count){[Windows.Forms.MessageBox]::Show('没有找到有效的 strata-*.json 模型配置。','无法打开 Benchmark','OK','Error')|Out-Null; return}
$script:PresetSpecs=Invoke-RunnerJson @('list-presets')
$saved=Load-UiSettings

$form=[Windows.Forms.Form]::new(); $form.Text="Strata 批量 Benchmark v$LauncherVersion"; $form.StartPosition='CenterScreen'; $form.AutoScaleMode='Dpi'; $form.Size=[Drawing.Size]::new(860,760); $form.MinimumSize=[Drawing.Size]::new(760,620)
$layout=[Windows.Forms.TableLayoutPanel]::new(); $layout.Dock='Fill'; $layout.Padding=[Windows.Forms.Padding]::new(14); $layout.ColumnCount=1; $layout.RowCount=8
[void]$layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent',100))
[void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute',48)); [void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent',45)); [void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute',190)); [void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute',86)); [void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent',55)); [void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute',28)); [void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute',38)); [void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute',50)); $form.Controls.Add($layout)

$title=[Windows.Forms.Label]::new(); $title.Text='批量比较本机 Strata 模型'; $title.Font=[Drawing.Font]::new($form.Font.FontFamily,14,[Drawing.FontStyle]::Bold); $title.Dock='Fill'; $title.TextAlign='MiddleLeft'; [void]$layout.Controls.Add($title,0,0)

$modelGroup=[Windows.Forms.GroupBox]::new(); $modelGroup.Text='模型（benchmark 配置副本；不修改原配置）'; $modelGroup.Dock='Fill'; $modelGroup.Padding=[Windows.Forms.Padding]::new(10)
$modelList=[Windows.Forms.CheckedListBox]::new(); $modelList.Dock='Fill'; $modelList.CheckOnClick=$true
foreach($model in $models){$label="$($model.model_name)  [$([IO.Path]::GetFileName([string]$model.config_path))]"; $index=$modelList.Items.Add($label); $modelList.SetItemChecked($index,$true)}
$modelGroup.Controls.Add($modelList); [void]$layout.Controls.Add($modelGroup,0,1)

$options=[Windows.Forms.GroupBox]::new(); $options.Text='测试规模'; $options.Dock='Fill'
$optionGrid=[Windows.Forms.TableLayoutPanel]::new(); $optionGrid.Dock='Fill'; $optionGrid.ColumnCount=2; $optionGrid.RowCount=4; $optionGrid.Padding=[Windows.Forms.Padding]::new(10,4,8,4)
[void]$optionGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Absolute',82)); [void]$optionGrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent',100))
for($row=0;$row -lt 4;$row++){[void]$optionGrid.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent',25))}
$runLabel=[Windows.Forms.Label]::new(); $runLabel.Text='运行设置'; $runLabel.Dock='Fill'; $runLabel.TextAlign='MiddleLeft'
$strategyLabel=[Windows.Forms.Label]::new(); $strategyLabel.Text='测试策略'; $strategyLabel.Dock='Fill'; $strategyLabel.TextAlign='MiddleLeft'
$runFlow=[Windows.Forms.FlowLayoutPanel]::new(); $runFlow.Dock='Fill'; $runFlow.WrapContents=$false; $runFlow.AutoScroll=$true; $runFlow.Padding=[Windows.Forms.Padding]::new(0,3,0,0); $runFlow.Margin=[Windows.Forms.Padding]::new(0)
$tierFlow=[Windows.Forms.FlowLayoutPanel]::new(); $tierFlow.Dock='Fill'; $tierFlow.WrapContents=$false; $tierFlow.AutoScroll=$true; $tierFlow.Padding=[Windows.Forms.Padding]::new(0,3,0,0); $tierFlow.Margin=[Windows.Forms.Padding]::new(0)
$strategyFlow=[Windows.Forms.FlowLayoutPanel]::new(); $strategyFlow.Dock='Fill'; $strategyFlow.WrapContents=$false; $strategyFlow.AutoScroll=$true; $strategyFlow.Padding=[Windows.Forms.Padding]::new(0,3,0,0); $strategyFlow.Margin=[Windows.Forms.Padding]::new(0)
$inputFlow=[Windows.Forms.FlowLayoutPanel]::new(); $inputFlow.Dock='Fill'; $inputFlow.WrapContents=$false; $inputFlow.AutoScroll=$true; $inputFlow.Padding=[Windows.Forms.Padding]::new(0,3,0,0); $inputFlow.Margin=[Windows.Forms.Padding]::new(0)
$presetLabel=[Windows.Forms.Label]::new(); $presetLabel.Text='预设'; $presetLabel.AutoSize=$true; $presetLabel.Margin=[Windows.Forms.Padding]::new(4,7,4,0)
$preset=[Windows.Forms.ComboBox]::new(); $preset.DropDownStyle='DropDownList'; [void]$preset.Items.AddRange(@('日常速测','日常完整','长文对照','并发专项','容量极限')); $preset.SelectedItem=$(switch([string]$saved.preset){'full'{'日常完整'} 'long'{'长文对照'} 'parallel'{'并发专项'} 'capacity'{'容量极限'} default{'日常速测'}}); $preset.Width=112
$roundLabel=[Windows.Forms.Label]::new(); $roundLabel.Text='轮数'; $roundLabel.AutoSize=$true; $roundLabel.Margin=[Windows.Forms.Padding]::new(18,7,4,0)
$rounds=[Windows.Forms.NumericUpDown]::new(); $rounds.Minimum=1; $rounds.Maximum=20; $savedRounds=if($null -ne $saved.rounds){[int]$saved.rounds}else{3}; $rounds.Value=[Math]::Max(1,[Math]::Min(20,$savedRounds)); $rounds.Width=70
$portLabel=[Windows.Forms.Label]::new(); $portLabel.Text='专用端口'; $portLabel.AutoSize=$true; $portLabel.Margin=[Windows.Forms.Padding]::new(18,7,4,0)
$port=[Windows.Forms.NumericUpDown]::new(); $port.Minimum=1024; $port.Maximum=65535; $port.Value=[Math]::Max(1024,[Math]::Min(65535,[int]$saved.port)); $port.Width=90
$modelContextLabel=[Windows.Forms.Label]::new(); $modelContextLabel.Text='模型上限'; $modelContextLabel.Dock='Fill'; $modelContextLabel.TextAlign='MiddleLeft'
$contextOptions=[ordered]@{'32K'=32768;'64K'=65536;'128K'=131072;'256K'=262144;'384K（实验）'=393216;'512K（实验）'=524288}
$savedTiers=if($null -ne $saved.PSObject.Properties['context_tiers']){@($saved.context_tiers)}elseif($null -ne $saved.max_context){@([int]$saved.max_context)}else{@()}
$tierBoxes=[ordered]@{}; foreach($choice in $contextOptions.Keys){$value=[int]$contextOptions[$choice];$box=[Windows.Forms.CheckBox]::new();$box.Text=$choice;$box.AutoSize=$true;$box.Margin=[Windows.Forms.Padding]::new(4,5,4,0);$box.Checked=($savedTiers -contains $value);$tierBoxes[[string]$value]=$box}
$tierSweep=[Windows.Forms.CheckBox]::new();$tierSweep.Text='多档上限测试';$tierSweep.AutoSize=$true;$tierSweep.Margin=[Windows.Forms.Padding]::new(12,5,4,0);$tierSweep.Checked=($saved.sweep_context_tiers -eq $true)
foreach($box in $tierBoxes.Values){
    $box.Add_CheckedChanged({
        if($this.Checked -and -not $tierSweep.Checked){
            foreach($other in $tierBoxes.Values){if(-not [object]::ReferenceEquals($other,$this)){$other.Checked=$false}}
        }
    })
}
$tierSweep.Add_CheckedChanged({
    if(-not $tierSweep.Checked){
        $first=@($tierBoxes.GetEnumerator()|Where-Object{$_.Value.Checked}|Sort-Object{[int]$_.Key}|Select-Object -First 1)
        if($first.Count){foreach($entry in $tierBoxes.GetEnumerator()){if($entry.Key -ne $first[0].Key){$entry.Value.Checked=$false}}}
    }
})
$concurrencyLabel=[Windows.Forms.Label]::new(); $concurrencyLabel.Text='最大并发'; $concurrencyLabel.AutoSize=$true; $concurrencyLabel.Margin=[Windows.Forms.Padding]::new(16,7,4,0)
$maxConcurrency=[Windows.Forms.NumericUpDown]::new(); $maxConcurrency.Minimum=1; $maxConcurrency.Maximum=4; $savedConcurrency=if($null -ne $saved.max_concurrency){[int]$saved.max_concurrency}else{2}; $maxConcurrency.Value=[Math]::Max(1,[Math]::Min(4,$savedConcurrency)); $maxConcurrency.Width=60
$contextLabel=[Windows.Forms.Label]::new(); $contextLabel.Text='输入长度'; $contextLabel.Dock='Fill'; $contextLabel.TextAlign='MiddleLeft'
$contextBoxes=[ordered]@{}; $contextNames=[ordered]@{'1k'='1K';'4k'='4K';'32k'='32K';'128k'='128K';'256k'='256K'}
$savedLengths=@(Get-SavedContextLengths $saved (Get-PresetId $preset.SelectedItem))
foreach($entry in $contextNames.GetEnumerator()){$cb=[Windows.Forms.CheckBox]::new();$cb.Text=$entry.Value;$cb.AutoSize=$true;$cb.Margin=[Windows.Forms.Padding]::new(4,5,8,0);$cb.Checked=($savedLengths -contains $entry.Key);$contextBoxes[$entry.Key]=$cb}
foreach($control in @($presetLabel,$preset,$roundLabel,$rounds,$portLabel,$port)){[void]$runFlow.Controls.Add($control)}
foreach($box in $tierBoxes.Values){[void]$tierFlow.Controls.Add($box)}
foreach($control in @($tierSweep,$concurrencyLabel,$maxConcurrency)){[void]$strategyFlow.Controls.Add($control)}
foreach($cb in $contextBoxes.Values){[void]$inputFlow.Controls.Add($cb)}
$scaleRows=@(@($runLabel,$runFlow),@($modelContextLabel,$tierFlow),@($strategyLabel,$strategyFlow),@($contextLabel,$inputFlow))
for($row=0;$row -lt $scaleRows.Count;$row++){[void]$optionGrid.Controls.Add($scaleRows[$row][0],0,$row); [void]$optionGrid.Controls.Add($scaleRows[$row][1],1,$row)}
$options.Controls.Add($optionGrid); [void]$layout.Controls.Add($options,0,2)

$stageGroup=[Windows.Forms.GroupBox]::new(); $stageGroup.Text='测试项目'; $stageGroup.Dock='Fill'
$stageFlow=[Windows.Forms.FlowLayoutPanel]::new(); $stageFlow.Dock='Fill'; $stageFlow.Padding=[Windows.Forms.Padding]::new(10,10,4,4); $stageFlow.WrapContents=$true
$stageNames=[ordered]@{performance='基础性能';cache='对话缓存';agent='Agent 内置题集';needle='长上下文召回';load='并发性能';stability='短时稳定性';capacity='上下文容量探测'}; $stageBoxes=[ordered]@{}
foreach($entry in $stageNames.GetEnumerator()){$cb=[Windows.Forms.CheckBox]::new();$cb.Text=$entry.Value;$cb.AutoSize=$true;$cb.Margin=[Windows.Forms.Padding]::new(6,5,14,3);$cb.Checked=(@($saved.stages)-contains $entry.Key);$stageBoxes[$entry.Key]=$cb;[void]$stageFlow.Controls.Add($cb)}
$stageGroup.Controls.Add($stageFlow); [void]$layout.Controls.Add($stageGroup,0,3)

$infoGroup=[Windows.Forms.GroupBox]::new(); $infoGroup.Text='测试说明'; $infoGroup.Dock='Fill'; $infoGroup.Padding=[Windows.Forms.Padding]::new(10,4,10,8)
$info=[Windows.Forms.RichTextBox]::new(); $info.Dock='Fill'; $info.ReadOnly=$true; $info.BorderStyle='None'; $info.ScrollBars='Vertical'; $info.BackColor=[Drawing.SystemColors]::Window; $info.DetectUrls=$false; $info.TabStop=$false
$infoHeadingFont=[Drawing.Font]::new($form.Font,[Drawing.FontStyle]::Bold)
$infoSections=@(
    @('五种预设',@('日常速测：1K / 4K 性能，4K 双路并发；1 轮。','日常完整：增加 32K 性能与召回、缓存、Agent 和稳定性；3 轮，4K 并发。','长文对照：32K / 128K 性能与召回；不运行并发或容量探测。','并发专项：4K / 32K 输入，各测 1 路和 2 路，每档 2 组。','容量极限：256K 性能、召回和接近上限的容量探测；不运行并发。','预设默认使用原生 256K 上限；切换预设会重置项目、输入及轮数，之后可手动调整。')),
    @('输入与并发的关系',@('模型上限决定加载容量；输入长度决定基础性能提示词规模。','召回和并发按当前预设的工作负载档位，从勾选输入中取交集；如交集为空，启动前报错。','并发实际输入 token、缓存复用和输出时间重叠均需校验；未证实重叠时不算并发成功。')),
    @('工作负载与有效性',@('基础性能每种输入最多生成 256 tokens；核验真实输入、冷缓存、有效输出及速度指标。','缓存用例把首轮输入校准到约 32K，连续 3 轮对话；首轮允许少量公共前缀复用，追问必须复用足够长的前缀。','长上下文召回按当前模型 tokenizer 校准每道题；实测长度偏差超过 5% 算失败，失败题仍计入应测题数。','短时稳定性只把返回有效内容和输出 token 的请求记为成功。','容量探测只在容量极限预设中默认开启；证据不足不会显示成未执行。','轮数作用于性能、缓存和 Agent；并发组数由预设单独控制。')),
    @('对照条件与并发',@('测试默认使用报告内的阶段配置副本，不改日常模型 JSON。','保留各模型原有的 PCIe、MTP、CPU workers、专家缓存和调整参数；统一 KV=int8、驻留=32768、显存预留=3072 MiB。','普通与并发阶段关闭提示词缓存；缓存项目单独开启。并发阶段申请并核验引擎槽数。','各阶段重新加载模型，耗时更长；报告保存最终参数和原配置哈希。')),
    @('能力题集',@('日常速测使用 7 题；日常完整使用 9 题。检验格式、工具调用、简单检索和代码修正；通过数不是通用智力分数。','报告分开显示请求是否成功和题目断言是否通过，并保留原始回答。')),
    @('模型上限与多档测试',@('通常只勾选一个上限；不勾选时沿用各模型一致的原配置。','开启“多档上限测试”后至少勾选两个档位，每个档位会重复当前预设和已选项目；装不下的输入在该档跳过。','多档测试会重复模型加载、缓存和并发等阶段；开始前会显示计划启动次数及请求数。','384K 和 512K 会启用实验性 YaRN；容量探测的真实 token 数以服务返回值为准。')),
    @('运行前与报告',@('开始前请先停止日常 Strata。','测试只写入报告目录中的配置副本，不修改日常模型 JSON。',('报告目录：' + $ReportsDir)))
)
foreach($section in $infoSections){
    $info.SelectionStart=$info.TextLength; $info.SelectionFont=$infoHeadingFont; $info.SelectionColor=[Drawing.Color]::FromArgb(31,73,112); $info.AppendText($section[0] + "`r`n")
    $info.SelectionStart=$info.TextLength; $info.SelectionFont=$form.Font; $info.SelectionColor=[Drawing.SystemColors]::ControlText
    foreach($line in $section[1]){$info.AppendText("• $line`r`n")}
    $info.AppendText("`r`n")
}
$info.SelectionStart=0; $info.SelectionLength=0
$infoGroup.Controls.Add($info); [void]$layout.Controls.Add($infoGroup,0,4)

$status=[Windows.Forms.Label]::new(); $status.Dock='Fill'; $status.Text='准备就绪'; $status.AutoEllipsis=$true; [void]$layout.Controls.Add($status,0,5)
$progress=[Windows.Forms.ProgressBar]::new(); $progress.Dock='Fill'; $progress.Minimum=0; $progress.Maximum=100; [void]$layout.Controls.Add($progress,0,6)

$buttons=[Windows.Forms.FlowLayoutPanel]::new(); $buttons.Dock='Fill'; $buttons.FlowDirection='RightToLeft'; $buttons.WrapContents=$false; $buttons.Padding=[Windows.Forms.Padding]::new(0,7,0,0)
$start=[Windows.Forms.Button]::new(); $start.Text='开始测试'; $start.Width=120; $start.Height=30
$cancel=[Windows.Forms.Button]::new(); $cancel.Text='安全停止'; $cancel.Width=120; $cancel.Height=30; $cancel.Enabled=$false
$openReport=[Windows.Forms.Button]::new(); $openReport.Text='打开报告'; $openReport.Width=120; $openReport.Height=30; $openReport.Enabled=$false
$openDir=[Windows.Forms.Button]::new(); $openDir.Text='报告目录'; $openDir.Width=120; $openDir.Height=30; $openDir.Enabled=$false
foreach($button in @($start,$cancel,$openReport,$openDir)){[void]$buttons.Controls.Add($button)}; [void]$layout.Controls.Add($buttons,0,7)

$script:Controller=$null; $script:RunDir=''; $script:LastState=''; $script:ControllerOutputSaved=$false
$timer=[Windows.Forms.Timer]::new(); $timer.Interval=1000

function Set-PresetDefaults {
    $id=Get-PresetId $preset.SelectedItem
    $spec=$script:PresetSpecs.$id
    foreach($key in $stageBoxes.Keys){$stageBoxes[$key].Checked=(@($spec.stages) -contains $key)}
    $defaultLengths=@($spec.performance|ForEach-Object{[string]$_[0]})
    foreach($entry in $contextBoxes.GetEnumerator()){$entry.Value.Checked=($defaultLengths -contains $entry.Key)}
    foreach($entry in $tierBoxes.GetEnumerator()){$entry.Value.Checked=([int]$entry.Key -eq [int]$spec.context_tier)}
    $tierSweep.Checked=$false
    $rounds.Value=[int]$spec.rounds
    $maxConcurrency.Value=[int]$spec.load_clients[-1]
}
$preset.Add_SelectedIndexChanged({Set-PresetDefaults})

function Selected-ModelPaths {
    $result=[Collections.Generic.List[string]]::new()
    for($i=0;$i -lt $modelList.Items.Count;$i++){if($modelList.GetItemChecked($i)){[void]$result.Add([string]$models[$i].config_path)}}
    return @($result)
}
function Update-RunState {
    if(-not $script:RunDir -and (Test-Path -LiteralPath $PointerPath)){
        try{$pointer=Get-Content -LiteralPath $PointerPath -Raw -Encoding UTF8|ConvertFrom-Json;$script:RunDir=[string]$pointer.run_dir;$openDir.Enabled=(Test-Path -LiteralPath $script:RunDir)}catch{}
    }
    if($script:RunDir){
        $statusPath=Join-Path $script:RunDir 'status.json'
        if(Test-Path -LiteralPath $statusPath){
            try{
                $state=Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8|ConvertFrom-Json
                $script:LastState=[string]$state.state; $status.Text=[string]$state.message
                if($state.model_id){$status.Text += " · $($state.model_id)"}; if($state.stage){$status.Text += " · $($state.stage)"}
                $current=if($null -ne $state.current){[int]$state.current}else{0}; $total=if($null -ne $state.total){[int]$state.total}else{0}; $progress.Value=if($total -gt 0){[Math]::Min(100,[int](100*$current/$total))}else{0}
                $openReport.Enabled=(Test-Path -LiteralPath (Join-Path $script:RunDir 'report.html'))
                if($script:LastState -in @('completed','partial','cancelled','failed')){$start.Enabled=$true;$cancel.Enabled=$false;$timer.Stop();if($script:LastState -eq 'completed'){$progress.Value=100}}
            }catch{$status.Text='状态文件正在更新，稍后重试…'}
        }
    }
    if($script:Controller -and $script:Controller.HasExited -and -not $script:ControllerOutputSaved){
        $out=$script:Controller.StandardOutput.ReadToEnd(); $err=$script:Controller.StandardError.ReadToEnd(); $log=Join-Path $DataDir ('benchmark-controller-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log'); [IO.File]::WriteAllText($log,$out+"`r`n"+$err,[Text.UTF8Encoding]::new($false)); $script:ControllerOutputSaved=$true
        if(-not $script:RunDir -and $err){$status.Text=$err.Trim();$start.Enabled=$true;$cancel.Enabled=$false;$timer.Stop()}
    }
    if($script:Controller -and $script:Controller.HasExited -and $script:RunDir){
        try{
            $manifest=Get-Content -LiteralPath (Join-Path $script:RunDir 'run-manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
            $terminal=Get-BenchmarkTerminalState $script:LastState ([string]$manifest.state)
            if($terminal -in @('completed','partial','cancelled','failed')){
                $script:LastState=$terminal
                if($terminal -eq 'partial'){$status.Text='测试部分完成：请查看未执行或失败阶段'}
                elseif($terminal -eq 'completed'){$status.Text='测试完成'}
                elseif($terminal -eq 'cancelled'){$status.Text='测试已安全停止'}
                else{$status.Text='测试失败'}
                $start.Enabled=$true;$cancel.Enabled=$false;$timer.Stop();if($terminal -eq 'completed'){$progress.Value=100}
            }
        }catch{}
    }
}
$timer.Add_Tick({Update-RunState})

$start.Add_Click({
    try{
        $selected=Selected-ModelPaths; if(-not $selected.Count){throw '请至少选择一个模型。'}
        $stages=@($stageBoxes.GetEnumerator()|Where-Object{$_.Value.Checked}|ForEach-Object{$_.Key}); if(-not $stages.Count){throw '请至少选择一个测试项目。'}
        $contexts=@($contextBoxes.GetEnumerator()|Where-Object{$_.Value.Checked}|ForEach-Object{$_.Key}); if(-not $contexts.Count -and @($stages | Where-Object{$_ -in @('performance','needle','load')}).Count){throw '请至少选择一个输入长度。'}
        $selectedTiers=@($tierBoxes.GetEnumerator()|Where-Object{$_.Value.Checked}|ForEach-Object{[int]$_.Key}|Sort-Object)
        if($tierSweep.Checked -and $selectedTiers.Count -lt 2){throw '多档上限测试至少需要勾选两个模型上限档位。'}
        if(-not $tierSweep.Checked -and $selectedTiers.Count -gt 1){throw '当前勾选了多个模型上限；请开启多档上限测试或只保留一个档位。'}
        if(($stages -contains 'capacity') -and -not $selectedTiers.Count){throw '容量探测需要至少勾选一个模型上限档位。'}
        $effectiveTiers=$selectedTiers
        $capDescription=if(-not $effectiveTiers.Count){'沿用各模型原配置'}else{($effectiveTiers|ForEach-Object{"$([int]($_/1024))K"}) -join ' / '}
        $presetId=Get-PresetId $preset.SelectedItem
        $spec=$script:PresetSpecs.$presetId
        $needleLengths=@($contexts|Where-Object{$_ -in @($spec.needle_lengths)})
        $loadLengths=@($contexts|Where-Object{$_ -in @($spec.load_lengths)})
        if(($stages -contains 'needle') -and -not $needleLengths.Count){throw '当前输入长度没有该预设的召回工作负载；请切换预设或选择其召回输入档位。'}
        if(($stages -contains 'load') -and -not $loadLengths.Count){throw '当前输入长度没有该预设的并发工作负载；请切换预设或选择其并发输入档位。'}
        $estimateArgs=@('estimate','--preset',$presetId,'--preset-policy','--rounds',[string][int]$rounds.Value,'--context-lengths',($contexts -join ','),'--max-concurrency',[string][int]$maxConcurrency.Value,'--stages',($stages -join ','))
        if($selectedTiers.Count){$estimateArgs += @('--context-tiers',($selectedTiers -join ','))}else{$estimateArgs += '--source-context'}
        if($tierSweep.Checked){$estimateArgs += '--sweep-context-tiers'}
        foreach($path in $selected){$estimateArgs += @('--model',$path)}
        $estimate=Invoke-RunnerJson $estimateArgs
        $expensive="预设：$($preset.SelectedItem)`r`n实际运行的模型上限：$capDescription`r`n已选输入：$($contexts -join ' / ')；性能、缓存和 Agent 按 $([int]$rounds.Value) 轮采样。"
        if($stages -contains 'load'){$expensive += "`r`n并发客户端：1 到 $([int]$maxConcurrency.Value)；并发输入：$($loadLengths -join ' / ')；每档 $([int]$spec.load_rounds) 组。"}
        $expensive += "`r`n对照条件默认生效：保留每个模型的原有调优，统一测试资源、缓存与并发槽位；配置副本保存在报告中。"
        $expensive += "`r`n计划启动服务 $([int]$estimate.planned_server_starts) 次（含阶段重启）。"
        $expensive += "`r`n计划工作量：性能 $([int]$estimate.performance_requests)、缓存 $([int]$estimate.cache_requests)、Agent $([int]$estimate.agent_requests)、召回 $([int]$estimate.needle_requests)、稳定性 $([int]$estimate.stability_requests)、容量 $([int]$estimate.capacity_requests) 次请求；并发 $([int]$estimate.load_bursts) 组。"
        if($tierSweep.Checked){$expensive += "`r`n以上项目会按 $($effectiveTiers.Count) 个上限档位分别执行；不适用的输入会在对应档位跳过。"}
        if($effectiveTiers -contains 524288){$expensive += "`r`n注意：512K 会启用 YaRN ×2 实验配置，可能耗时很久或因内存不足启动失败。"}
        $answer=[Windows.Forms.MessageBox]::Show("$expensive`r`n`r`n测试前请确认日常 Strata 已停止。开始后可使用【安全停止】保留部分报告。",'开始批量 Benchmark','OKCancel','Information'); if($answer -ne 'OK'){return}
        Save-UiSettings
        if(Test-Path -LiteralPath $PointerPath){Remove-Item -LiteralPath $PointerPath -Force}
        $args=@('run','--root',$Root,'--preset',$presetId,'--preset-policy','--rounds',[string][int]$rounds.Value,'--context-lengths',($contexts -join ','),'--max-concurrency',[string][int]$maxConcurrency.Value,'--port',[string][int]$port.Value,'--stages',($stages -join ','),'--report-root',$ReportsDir,'--pointer',$PointerPath)
        if($selectedTiers.Count){$args += @('--context-tiers',($selectedTiers -join ','))}else{$args += '--source-context'}
        if($tierSweep.Checked){$args += '--sweep-context-tiers'}
        foreach($path in $selected){$args += @('--model',$path)}
        $script:Controller=[Diagnostics.Process]::new(); $script:Controller.StartInfo=New-RunnerStartInfo $args -Redirect; if(-not $script:Controller.Start()){throw '无法启动 Benchmark 控制器。'}
        $script:RunDir='';$script:LastState='';$script:ControllerOutputSaved=$false;$start.Enabled=$false;$cancel.Enabled=$true;$openReport.Enabled=$false;$openDir.Enabled=$false;$progress.Value=0;$status.Text='控制器已启动，正在执行预检…';$timer.Start()
    }catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Benchmark 启动失败','OK','Error')|Out-Null}
})
$cancel.Add_Click({
    try{if(-not $script:RunDir){throw '运行目录尚未建立，请稍后再试。'}; [void](Invoke-RunnerJson @('cancel','--run-dir',$script:RunDir));$status.Text='已请求安全停止，正在结束本次模型进程并生成部分报告…';$cancel.Enabled=$false}catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'停止请求失败','OK','Error')|Out-Null}
})
$openDir.Add_Click({if($script:RunDir -and (Test-Path -LiteralPath $script:RunDir)){Start-Process explorer.exe -ArgumentList @($script:RunDir)}})
$openReport.Add_Click({$path=Join-Path $script:RunDir 'report.html';if(Test-Path -LiteralPath $path){Start-Process $path}})
$form.Add_FormClosing({param($sender,$e);$active=(($script:Controller -and -not $script:Controller.HasExited) -or ($script:RunDir -and $script:LastState -notin @('completed','partial','cancelled','failed')));if($active){$answer=[Windows.Forms.MessageBox]::Show('Benchmark 仍在运行。选择“是”请求安全停止并关闭窗口；选择“否”让测试继续在后台运行。','Benchmark 正在运行','YesNoCancel','Warning');if($answer -eq 'Cancel'){$e.Cancel=$true;return};if($answer -eq 'Yes' -and $script:RunDir){try{[void](Invoke-RunnerJson @('cancel','--run-dir',$script:RunDir))}catch{}}};$timer.Stop();$timer.Dispose()})

if(Test-Path -LiteralPath $PointerPath){
    try{
        $pointer=Get-Content -LiteralPath $PointerPath -Raw -Encoding UTF8|ConvertFrom-Json; $candidate=[string]$pointer.run_dir; $candidateStatus=Join-Path $candidate 'status.json'
        if($candidate -and (Test-Path -LiteralPath $candidateStatus)){$state=Get-Content -LiteralPath $candidateStatus -Raw -Encoding UTF8|ConvertFrom-Json;if([string]$state.state -notin @('completed','partial','cancelled','failed')){$script:RunDir=$candidate;$script:LastState=[string]$state.state;$start.Enabled=$false;$cancel.Enabled=$true;$openDir.Enabled=$true;$timer.Start();Update-RunState}}
    }catch{}
}

[void]$form.ShowDialog()

