param(
    [Parameter(Mandatory=$true)][string]$StrataRoot,
    [Parameter(Mandatory=$true)][ValidateRange(1024,65535)][int]$Port
)

$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'Strata-Launcher-Lan.ps1')
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class StrataMonitorWindow {
    const int GWL_EXSTYLE = -20;
    const int WS_EX_TRANSPARENT = 0x20;
    const int WS_EX_LAYERED = 0x80000;
    const uint SWP_NOSIZE = 0x0001, SWP_NOMOVE = 0x0002, SWP_NOZORDER = 0x0004, SWP_FRAMECHANGED = 0x0020;
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr handle, int index);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr handle, int index, int value);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr handle, IntPtr after, int x, int y, int width, int height, uint flags);
    public static void SetClickThrough(IntPtr handle, bool enabled) {
        int style = GetWindowLong(handle, GWL_EXSTYLE);
        int next = enabled ? style | WS_EX_TRANSPARENT | WS_EX_LAYERED : style & ~WS_EX_TRANSPARENT;
        SetWindowLong(handle, GWL_EXSTYLE, next);
        SetWindowPos(handle, IntPtr.Zero, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER | SWP_FRAMECHANGED);
    }
}
'@

$root=[IO.Path]::GetFullPath($StrataRoot)
$python=Join-Path $root '.venv\Scripts\python.exe'
$client=Join-Path $root 'strata_cli\client.py'
$helper=Join-Path $PSScriptRoot 'Strata-Monitor-Snapshot.py'
foreach($path in @($python,$client,$helper)){
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){ throw "监控缺少必要文件：$path" }
}
if($root.Contains('"') -or $helper.Contains('"')){throw '监控路径包含无法使用的引号。'}
$script:credential=[Environment]::GetEnvironmentVariable('STRATA_TELEMETRY_KEY','Process')
if(-not $script:credential){
    foreach($keyPath in @((Join-Path $PSScriptRoot 'data\lan-key.dpapi'),(Join-Path $root 'launcher\data\lan-key.dpapi'))){
        if(Test-Path -LiteralPath $keyPath -PathType Leaf){
            try{$script:credential=Get-StrataLanKey $keyPath}catch{$script:credential=$null}
            if($script:credential){break}
        }
    }
}

$bg=[Drawing.Color]::FromArgb(21,26,30)
$panelBg=[Drawing.Color]::FromArgb(30,37,42)
$fg=[Drawing.Color]::FromArgb(232,239,237)
$muted=[Drawing.Color]::FromArgb(157,170,173)
$green=[Drawing.Color]::FromArgb(44,205,156)
$form=[Windows.Forms.Form]::new()
$form.Text='Strata Monitor · 悬浮监控'
$form.ClientSize=[Drawing.Size]::new(540,515)
$form.FormBorderStyle='FixedToolWindow'
$form.MaximizeBox=$false
$form.MinimizeBox=$false
$form.TopMost=$true
$form.ShowInTaskbar=$false
$form.BackColor=$bg
$form.ForeColor=$fg
$form.Font=[Drawing.Font]::new('Segoe UI',9)
$form.StartPosition='Manual'
$area=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location=[Drawing.Point]::new([Math]::Max($area.Left,$area.Right-560),[Math]::Max($area.Top,$area.Top+32))
$form.Opacity=0.85

function New-MonitorLabel([string]$Text,[int]$X,[int]$Y,[int]$Width,[int]$Height,[int]$Size=9,[bool]$Bold=$false,[Drawing.Color]$Color=$fg){
    $label=[Windows.Forms.Label]::new()
    $label.Text=$Text; $label.Location=[Drawing.Point]::new($X,$Y)
    $label.Size=[Drawing.Size]::new($Width,$Height)
    $style=if($Bold){[Drawing.FontStyle]::Bold}else{[Drawing.FontStyle]::Regular}
    $label.Font=[Drawing.Font]::new('Segoe UI',$Size,$style)
    $label.ForeColor=$Color
    [void]$form.Controls.Add($label)
    return $label
}
function New-MonitorList([int]$Y,[int]$Height,[object[]]$Columns){
    $list=[Windows.Forms.ListView]::new()
    $list.Location=[Drawing.Point]::new(16,$Y); $list.Size=[Drawing.Size]::new(508,$Height)
    $list.View='Details'; $list.FullRowSelect=$false; $list.GridLines=$false
    $list.HeaderStyle='Nonclickable'; $list.BackColor=$panelBg; $list.ForeColor=$fg
    $list.BorderStyle='None'; $list.MultiSelect=$false; $list.HideSelection=$true
    foreach($column in $Columns){[void]$list.Columns.Add([string]$column[0],[int]$column[1])}
    [void]$form.Controls.Add($list)
    return $list
}
function Format-MonitorNumber($Value,[string]$Format){
    if($null -eq $Value){return '--'}
    try{return ([double]$Value).ToString($Format,[Globalization.CultureInfo]::InvariantCulture)}catch{return '--'}
}
function Format-MonitorGiB($Bytes){
    if($null -eq $Bytes){return '--'}
    return (Format-MonitorNumber ([double]$Bytes/1GB) '0.0')
}

$title=New-MonitorLabel 'STRATA MONITOR' 16 11 300 27 13 $true $green
$connection=New-MonitorLabel "连接中 · 127.0.0.1:$Port" 16 40 500 22 9 $false $muted
[void](New-MonitorLabel '生成速度' 16 74 170 22 9 $false $muted)
$speed=New-MonitorLabel '-- tok/s' 16 96 220 35 20 $true $fg
$work=New-MonitorLabel '活跃 --  ·  排队 --  ·  预填充 -- tok/s' 230 105 300 23 9 $false $muted
$chart=[Windows.Forms.Panel]::new(); $chart.Location=[Drawing.Point]::new(16,137); $chart.Size=[Drawing.Size]::new(508,42); $chart.BackColor=$panelBg
[void]$form.Controls.Add($chart)
$script:speedHistory=[Collections.Generic.List[double]]::new()
$chart.Add_Paint({
    param($sender,$eventArgs)
    $values=$script:speedHistory.ToArray()
    if($values.Length -eq 0){return}
    $max=1.0
    foreach($value in $values){if(-not [double]::IsNaN($value)){$max=[Math]::Max($max,$value)}}
    $barWidth=[Math]::Max(3,[Math]::Floor(($chart.Width-12)/20)-3)
    $step=($chart.Width-12)/20.0
    $start=[Math]::Max(0,$values.Length-20)
    $brush=[Drawing.SolidBrush]::new($green)
    try{
        for($i=$start;$i -lt $values.Length;$i++){
            if([double]::IsNaN($values[$i])){continue}
            $height=[Math]::Max(2,[Math]::Floor(($chart.Height-8)*$values[$i]/$max))
            $x=[Math]::Floor(6+($i-$start)*$step)
            $eventArgs.Graphics.FillRectangle($brush,$x,$chart.Height-$height-4,$barWidth,$height)
        }
    }finally{$brush.Dispose()}
})
[void](New-MonitorLabel 'GPU · 独立读数' 16 190 300 23 10 $true $fg)
$gpuList=New-MonitorList 214 105 @(@('显卡',160),@('负载',70),@('显存 GiB',170),@('温度',75))
$ram=New-MonitorLabel '系统内存：-- / -- GiB' 16 325 500 22 9 $false $muted
[void](New-MonitorLabel '近期请求 · 不含请求正文' 16 354 320 23 10 $true $fg)
$requestList=New-MonitorList 378 91 @(@('时间',85),@('状态',110),@('输入',90),@('输出',90),@('耗时',95))
$opacityLabel=New-MonitorLabel '透明度 85%' 16 481 100 23 9 $false $muted
$opacity=[Windows.Forms.TrackBar]::new(); $opacity.Minimum=50; $opacity.Maximum=100; $opacity.TickFrequency=10; $opacity.Value=85
$opacity.Location=[Drawing.Point]::new(110,474); $opacity.Size=[Drawing.Size]::new(225,39); $opacity.BackColor=$bg
[void]$form.Controls.Add($opacity)
$clickThrough=[Windows.Forms.CheckBox]::new(); $clickThrough.Text='鼠标穿透'; $clickThrough.Location=[Drawing.Point]::new(375,480)
$clickThrough.Size=[Drawing.Size]::new(135,23); $clickThrough.ForeColor=$fg
[void]$form.Controls.Add($clickThrough)

$menu=[Windows.Forms.ContextMenuStrip]::new()
$unlockItem=[Windows.Forms.ToolStripMenuItem]::new('解除鼠标穿透')
$showItem=[Windows.Forms.ToolStripMenuItem]::new('显示悬浮窗')
$exitItem=[Windows.Forms.ToolStripMenuItem]::new('退出监控')
[void]$menu.Items.Add($unlockItem); [void]$menu.Items.Add($showItem); [void]$menu.Items.Add($exitItem)
$tray=[Windows.Forms.NotifyIcon]::new(); $tray.Icon=[Drawing.SystemIcons]::Information
$tray.Text='Strata Monitor · 右键解除鼠标穿透'; $tray.ContextMenuStrip=$menu; $tray.Visible=$true
$opacity.Add_ValueChanged({$form.Opacity=$opacity.Value/100.0;$opacityLabel.Text="透明度 $($opacity.Value)%"})
$clickThrough.Add_CheckedChanged({
    [StrataMonitorWindow]::SetClickThrough($form.Handle,$clickThrough.Checked)
    $unlockItem.Enabled=$clickThrough.Checked
    $tray.Text=if($clickThrough.Checked){'Strata Monitor · 右键解除鼠标穿透'}else{'Strata Monitor · 右键打开或退出'}
})
$unlockItem.Add_Click({$clickThrough.Checked=$false;$form.Activate()})
$showItem.Add_Click({$form.Show();$form.Activate()})
$exitItem.Add_Click({$form.Close()})
$tray.Add_DoubleClick({$clickThrough.Checked=$false;$form.Show();$form.Activate()})
$unlockItem.Enabled=$false

$script:pending=$null
$script:nextPoll=[DateTime]::MinValue
$script:lastInstance=''
function Clear-MonitorReadings([string]$Reason){
    $connection.Text=$Reason
    $connection.ForeColor=$muted
    $speed.Text='-- tok/s'; $work.Text='活跃 --  ·  排队 --  ·  预填充 -- tok/s'
    $ram.Text='系统内存：-- / -- GiB'
    $gpuList.Items.Clear(); $requestList.Items.Clear()
    $script:speedHistory.Add([double]::NaN)
    if($script:speedHistory.Count -gt 20){$script:speedHistory.RemoveAt(0)}
    $chart.Invalidate()
}
function Show-MonitorSnapshot($Snapshot){
    if(-not $Snapshot.ok){
        $reason=switch([string]$Snapshot.kind){
            'auth' {'需要遥测密钥'}
            'incompatible' {'遥测版本不兼容'}
            'disconnected' {'服务未连接，等待重试'}
            default {'遥测暂不可用'}
        }
        Clear-MonitorReadings "$reason · 127.0.0.1:$Port"
        return
    }
    if($Snapshot.instance_id -and $script:lastInstance -and $Snapshot.instance_id -ne $script:lastInstance){$script:speedHistory.Clear()}
    $script:lastInstance=[string]$Snapshot.instance_id
    $state=if(-not $Snapshot.telemetry_available){'无实时遥测'}elseif($Snapshot.loaded){'运行中'}else{'模型未加载'}
    $model=if($Snapshot.model){[string]$Snapshot.model}else{'未知模型'}
    if($model.Length -gt 44){$model=$model.Substring(0,41)+'...'}
    $connection.Text="$state · $model · 127.0.0.1:$Port"
    $connection.ForeColor=if($Snapshot.telemetry_available){$green}else{$muted}
    $speed.Text="$(Format-MonitorNumber $Snapshot.answer_tok_s '0.0') tok/s"
    $work.Text="活跃 $(Format-MonitorNumber $Snapshot.active '0')  ·  排队 $(Format-MonitorNumber $Snapshot.queued '0')  ·  预填充 $(Format-MonitorNumber $Snapshot.prefill_tok_s '0.0') tok/s"
    $sample=if($null -eq $Snapshot.answer_tok_s){[double]::NaN}else{[double]$Snapshot.answer_tok_s}
    $script:speedHistory.Add($sample)
    if($script:speedHistory.Count -gt 20){$script:speedHistory.RemoveAt(0)}
    $chart.Invalidate()
    $gpuList.BeginUpdate(); try{
        $gpuList.Items.Clear()
        foreach($gpu in @($Snapshot.devices)){
            if($null -eq $gpu){continue}
            $index=Format-MonitorNumber $gpu.index '0'
            $name=[string]$gpu.name
            if($name.Length -gt 17){$name=$name.Substring(0,14)+'...'}
            $item=[Windows.Forms.ListViewItem]::new("GPU $index $name")
            [void]$item.SubItems.Add("$(Format-MonitorNumber $gpu.util '0')%")
            [void]$item.SubItems.Add("$(Format-MonitorGiB $gpu.mem_used) / $(Format-MonitorGiB $gpu.mem_total)")
            [void]$item.SubItems.Add("$(Format-MonitorNumber $gpu.temp '0')°C")
            [void]$gpuList.Items.Add($item)
        }
    }finally{$gpuList.EndUpdate()}
    $ram.Text="系统内存：$(Format-MonitorGiB $Snapshot.ram_used) / $(Format-MonitorGiB $Snapshot.ram_total) GiB"
    $requestList.BeginUpdate(); try{
        $requestList.Items.Clear()
        foreach($request in @($Snapshot.recent)){
            if($null -eq $request){continue}
            $time='--'
            if($null -ne $request.time){
                try{$time=([DateTime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc).AddSeconds([double]$request.time).ToLocalTime()).ToString('HH:mm:ss')}catch{}
            }
            $item=[Windows.Forms.ListViewItem]::new($time)
            [void]$item.SubItems.Add([string]$request.finish)
            [void]$item.SubItems.Add((Format-MonitorNumber $request.prompt_tokens '0'))
            [void]$item.SubItems.Add((Format-MonitorNumber $request.output_tokens '0'))
            [void]$item.SubItems.Add("$(Format-MonitorNumber $request.duration_s '0.0') s")
            [void]$requestList.Items.Add($item)
        }
    }finally{$requestList.EndUpdate()}
}

function Start-MonitorPoll {
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=$python
    $psi.Arguments='"'+$helper+'" --strata-root "'+$root+'" --port '+$Port
    $psi.WorkingDirectory=$root
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $psi.StandardOutputEncoding=[Text.Encoding]::UTF8
    $psi.StandardErrorEncoding=[Text.Encoding]::UTF8
    if($script:credential){$psi.EnvironmentVariables['STRATA_MONITOR_CREDENTIAL']=$script:credential}
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$psi
    if(-not $process.Start()){throw '无法启动 Strata 遥测读取器。'}
    $script:pending=[pscustomobject]@{
        Process=$process; Output=$process.StandardOutput.ReadToEndAsync()
        Error=$process.StandardError.ReadToEndAsync(); Started=[DateTime]::UtcNow
    }
}

$timer=[Windows.Forms.Timer]::new(); $timer.Interval=250
$timer.Add_Tick({
    if($script:pending){
        $poll=$script:pending
        if($poll.Process.HasExited){
            try{
                $output=$poll.Output.Result
                $snapshot=$output | ConvertFrom-Json -ErrorAction Stop
                Show-MonitorSnapshot $snapshot
            }catch{Clear-MonitorReadings "遥测读取失败 · 127.0.0.1:$Port"}
            finally{$poll.Process.Dispose();$script:pending=$null;$script:nextPoll=[DateTime]::UtcNow.AddSeconds(2)}
        }elseif(([DateTime]::UtcNow-$poll.Started).TotalSeconds -gt 6){
            try{$poll.Process.Kill()}catch{}
            $poll.Process.Dispose(); $script:pending=$null
            Clear-MonitorReadings "遥测超时 · 127.0.0.1:$Port"
            $script:nextPoll=[DateTime]::UtcNow.AddSeconds(2)
        }
    }
    if(-not $script:pending -and [DateTime]::UtcNow -ge $script:nextPoll){
        try{Start-MonitorPoll}catch{Clear-MonitorReadings "遥测启动失败 · 127.0.0.1:$Port";$script:nextPoll=[DateTime]::UtcNow.AddSeconds(3)}
    }
})
$form.Add_Shown({$timer.Start()})
$form.Add_FormClosed({
    $timer.Stop(); $timer.Dispose()
    if($script:pending){try{if(-not $script:pending.Process.HasExited){$script:pending.Process.Kill()}}catch{};$script:pending.Process.Dispose()}
    $tray.Visible=$false; $tray.Dispose(); $menu.Dispose()
})
[void]$form.ShowDialog()
