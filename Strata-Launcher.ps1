# Strata standalone Windows launcher. Uses only Windows PowerShell and WinForms.
param(
    [string]$ConfigPath = '',
    [switch]$CheckOnly,
    [switch]$ExpandAllSections
)

$ErrorActionPreference = 'Stop'
$LauncherPath = $MyInvocation.MyCommand.Path
$LauncherDir = Split-Path -Parent $LauncherPath
$VersionPath = Join-Path $LauncherDir 'VERSION.txt'
$LauncherVersion = if (Test-Path -LiteralPath $VersionPath -PathType Leaf) { (Get-Content -LiteralPath $VersionPath -Raw -Encoding UTF8).Trim() } else { 'unversioned' }
$EnvironmentModule = Join-Path $LauncherDir 'Strata-Launcher-Environment.ps1'
if (-not (Test-Path -LiteralPath $EnvironmentModule -PathType Leaf)) {
    $message = "启动器文件不完整，缺少：$EnvironmentModule"
    if ($CheckOnly) { Write-Output $message; exit 2 }
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show($message,'Strata 启动器无法启动','OK','Error') | Out-Null
    exit 2
}
. $EnvironmentModule
$LauncherEnvironment = Get-StrataLauncherEnvironment -LauncherDirectory $LauncherDir
if (-not $LauncherEnvironment.IsReady) {
    if ($CheckOnly) { Write-Output $LauncherEnvironment.Message; exit 2 }
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show($LauncherEnvironment.Message,'Strata 启动器位置或安装不完整','OK','Error') | Out-Null
    exit 2
}
if ($CheckOnly) {
    [pscustomobject]@{
        ready = $true
        root = $LauncherEnvironment.Root
        launcher = $LauncherEnvironment.LauncherDirectory
        launcher_version = $LauncherVersion
        strata_version = $LauncherEnvironment.StrataVersion
        engine_version = $LauncherEnvironment.EngineVersion
        deepseek_engine_version = $LauncherEnvironment.DeepSeekEngineVersion
        model_count = $LauncherEnvironment.ModelConfigs.Count
        unavailable_model_count = $LauncherEnvironment.UnavailableModels.Count
        engine_warning = $LauncherEnvironment.EngineWarning
        model_catalog_status = $LauncherEnvironment.ModelCatalogStatus
        model_catalog_source = $LauncherEnvironment.ModelCatalogSource
        model_catalog_count = $LauncherEnvironment.ModelCatalogCount
        model_catalog_error = $LauncherEnvironment.ModelCatalogError
    } | ConvertTo-Json -Compress
    exit 0
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$ThemeModule = Join-Path $LauncherDir 'Strata-Launcher-Theme.ps1'
if (-not (Test-Path -LiteralPath $ThemeModule -PathType Leaf)) {
    [Windows.Forms.MessageBox]::Show("启动器文件不完整，缺少：$ThemeModule",'Strata 启动器无法启动','OK','Error') | Out-Null
    exit 2
}
. $ThemeModule
$theme = Get-StrataLauncherTheme
$GpuPowerModule = Join-Path $LauncherDir 'Strata-Launcher-GpuPower.ps1'
if (-not (Test-Path -LiteralPath $GpuPowerModule -PathType Leaf)) {
    [Windows.Forms.MessageBox]::Show("启动器文件不完整，缺少：$GpuPowerModule",'Strata 启动器无法启动','OK','Error') | Out-Null
    exit 2
}
. $GpuPowerModule
$GpuPlacementModule = Join-Path $LauncherDir 'Strata-Launcher-GpuPlacement.ps1'
if (-not (Test-Path -LiteralPath $GpuPlacementModule -PathType Leaf)) {
    [Windows.Forms.MessageBox]::Show("启动器文件不完整，缺少：$GpuPlacementModule",'Strata 启动器无法启动','OK','Error') | Out-Null
    exit 2
}
. $GpuPlacementModule
$LanModule = Join-Path $LauncherDir 'Strata-Launcher-Lan.ps1'
if (-not (Test-Path -LiteralPath $LanModule -PathType Leaf)) {
    [Windows.Forms.MessageBox]::Show("启动器文件不完整，缺少：$LanModule",'Strata 启动器无法启动','OK','Error') | Out-Null
    exit 2
}
. $LanModule
function Initialize-StrataProcessTree {
if (-not ('StrataProcessTree' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class StrataProcessTree {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    private struct PROCESSENTRY32 {
        public uint dwSize;
        public uint cntUsage;
        public uint th32ProcessID;
        public IntPtr th32DefaultHeapID;
        public uint th32ModuleID;
        public uint cntThreads;
        public uint th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern bool Process32First(IntPtr snapshot, ref PROCESSENTRY32 entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern bool Process32Next(IntPtr snapshot, ref PROCESSENTRY32 entry);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder name, ref int size);

    public static int ParentProcessId(int processId) {
        const uint TH32CS_SNAPPROCESS = 0x00000002;
        IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot == new IntPtr(-1)) return 0;
        try {
            PROCESSENTRY32 entry = new PROCESSENTRY32();
            entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
            if (!Process32First(snapshot, ref entry)) return 0;
            do {
                if (entry.th32ProcessID == (uint)processId) return unchecked((int)entry.th32ParentProcessID);
            } while (Process32Next(snapshot, ref entry));
            return 0;
        } finally { CloseHandle(snapshot); }
    }

    public static string ProcessName(int processId) {
        const uint TH32CS_SNAPPROCESS = 0x00000002;
        IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot == new IntPtr(-1)) return "";
        try {
            PROCESSENTRY32 entry = new PROCESSENTRY32();
            entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
            if (!Process32First(snapshot, ref entry)) return "";
            do {
                if (entry.th32ProcessID == (uint)processId) return entry.szExeFile ?? "";
            } while (Process32Next(snapshot, ref entry));
            return "";
        } finally { CloseHandle(snapshot); }
    }

    public static int[] ProcessIdsByName(string exeName) {
        const uint TH32CS_SNAPPROCESS = 0x00000002;
        List<int> ids = new List<int>();
        IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot == new IntPtr(-1)) return ids.ToArray();
        try {
            PROCESSENTRY32 entry = new PROCESSENTRY32();
            entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
            if (!Process32First(snapshot, ref entry)) return ids.ToArray();
            do {
                if (String.Equals(entry.szExeFile, exeName, StringComparison.OrdinalIgnoreCase))
                    ids.Add(unchecked((int)entry.th32ProcessID));
            } while (Process32Next(snapshot, ref entry));
            return ids.ToArray();
        } finally { CloseHandle(snapshot); }
    }

    public static string FullProcessImageName(int processId) {
        const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
        if (process == IntPtr.Zero) return "";
        try {
            int size = 32768;
            StringBuilder name = new StringBuilder(size);
            return QueryFullProcessImageName(process, 0, name, ref size) ? name.ToString() : "";
        } finally { CloseHandle(process); }
    }
}
'@
}
}

$Root = $LauncherEnvironment.Root
$LauncherData = Join-Path $LauncherDir 'data'
$CalibrationDetailsPath = Join-Path $LauncherData 'calibration-details.json'
$SettingsBackupDir = Join-Path $LauncherDir 'backups\settings'
$LegacyBackupDir = Join-Path $LauncherDir 'backups\legacy'
foreach ($directory in @($LauncherData,$SettingsBackupDir,$LegacyBackupDir)) {
    if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory -Force) }
}
$SelectionPath = Join-Path $LauncherData 'selected.txt'
$LegacySelectionPath = Join-Path $Root 'strata-launcher.selected.txt'
if (-not (Test-Path -LiteralPath $SelectionPath) -and (Test-Path -LiteralPath $LegacySelectionPath)) {
    Copy-Item -LiteralPath $LegacySelectionPath -Destination $SelectionPath
}
$OfficialSettingsPath = Join-Path $env:APPDATA 'Strata\settings.json'
$modelConfigs = [Collections.ArrayList]::new()
foreach ($modelConfig in $LauncherEnvironment.ModelConfigs) { [void]$modelConfigs.Add($modelConfig) }
if (-not $ConfigPath -and (Test-Path -LiteralPath $SelectionPath)) {
    $ConfigPath=(Get-Content -LiteralPath $SelectionPath -Raw -Encoding UTF8).Trim()
}
if ($ConfigPath) {
    try { $ConfigPath=[IO.Path]::GetFullPath($ConfigPath) } catch { $ConfigPath='' }
}
$selectedConfig=$modelConfigs | Where-Object { [string]::Equals($_.Path,$ConfigPath,[StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
if (-not $selectedConfig) {
    $selectedConfig=$modelConfigs | Where-Object { $_.ModelName -match 'iq3[_-]s' } | Select-Object -First 1
    if (-not $selectedConfig) { $selectedConfig=$modelConfigs[0] }
}
$ConfigPath=$selectedConfig.Path
$Py = $LauncherEnvironment.Python
$Server = $LauncherEnvironment.Server
$PidPath = Join-Path $LauncherData 'strata.pid.json'
$LanModePath = Join-Path $LauncherData 'lan-access.json'
$LanKeyPath = Join-Path $LauncherData 'lan-key.dpapi'
$LanFirewallEntry = Join-Path $LauncherDir 'Strata-Launcher-LanFirewall.ps1'
$CalibrationViewModule = Join-Path $LauncherDir 'Strata-Calibration-View.ps1'
if (-not (Test-Path -LiteralPath $CalibrationViewModule)) { throw '找不到 launcher\Strata-Calibration-View.ps1。' }
$CalibrationViewSource = Get-Content -LiteralPath $CalibrationViewModule -Raw -Encoding UTF8
. ([scriptblock]::Create($CalibrationViewSource))
$LauncherReloadModule = Join-Path $LauncherDir 'Strata-Launcher-Reload.ps1'
if (-not (Test-Path -LiteralPath $LauncherReloadModule)) { throw '找不到 launcher\Strata-Launcher-Reload.ps1。' }
$LauncherReloadSource = Get-Content -LiteralPath $LauncherReloadModule -Raw -Encoding UTF8
. ([scriptblock]::Create($LauncherReloadSource))
$LauncherSettingsModule = Join-Path $LauncherDir 'Strata-Launcher-Settings.ps1'
if (-not (Test-Path -LiteralPath $LauncherSettingsModule)) { throw '找不到 launcher\Strata-Launcher-Settings.ps1。' }
$LauncherSettingsSource = Get-Content -LiteralPath $LauncherSettingsModule -Raw -Encoding UTF8
. ([scriptblock]::Create($LauncherSettingsSource))
$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
# A config written before a DeepSeek engine upgrade names the engine folder that the upgrade deleted: repair the file
# (the server reads it) and the copy in memory (this window writes it back on save) before anything uses them.
$EnginePathRepairs = @(Repair-StrataEngineConfigFiles -Root $Root)
$cfg = Repair-StrataConfigEnginePath -Config $cfg -Root $Root
$cfg.args = @(Get-StrataEffectiveArgs -Config $cfg)
$initialEngineArgs = [string[]]@($cfg.args)
$isOwnPath = Test-StrataOwnPathConfig -Config $cfg
$isDeepSeek = Test-StrataDeepSeekConfig -Config $cfg
$deepSeekSettings = if ($isDeepSeek) { Get-StrataDeepSeekSettings -ArgsList ([string[]]@($cfg.args)) } else { $null }
$configStem=[IO.Path]::GetFileNameWithoutExtension($ConfigPath)
$sharedPath = Join-Path $Root ($configStem + '.shared-settings.json')
$shared = if (Test-Path -LiteralPath $sharedPath) { Get-Content -LiteralPath $sharedPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
$visionPath = Join-Path $Root ($configStem + '.vision.json')

function Arg-Value([string[]]$ArgsList, [string]$Flag, $Fallback) {
    $i = [Array]::IndexOf($ArgsList, $Flag)
    if ($i -ge 0 -and $i + 1 -lt $ArgsList.Count) { return $ArgsList[$i + 1] }
    return $Fallback
}
function Set-Arg([System.Collections.ArrayList]$List, [string]$Flag, $Value) {
    $i = $List.IndexOf($Flag)
    if ($null -eq $Value -or "$Value" -eq '') { if ($i -ge 0) { $List.RemoveAt($i); if ($i -lt $List.Count) { $List.RemoveAt($i) } }; return }
    if ($i -ge 0) { if ($i + 1 -lt $List.Count) { $List[$i + 1] = "$Value" } else { $List.Add("$Value") | Out-Null } }
    else { $List.Add($Flag) | Out-Null; $List.Add("$Value") | Out-Null }
}
function Num([string]$Text, [double]$Fallback) { $v = 0.0; if ([double]::TryParse($Text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return $v }; return $Fallback }
function Json-Clone($Object) { return ($Object | ConvertTo-Json -Depth 30 | ConvertFrom-Json) }
function Atomic-Json([string]$Path, $Object) {
    $tmp = "$Path.tmp"
    $json = $Object | ConvertTo-Json -Depth 30
    [IO.File]::WriteAllText($tmp, $json + "`r`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Backup-Once([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $destination=Join-Path $LegacyBackupDir ((Split-Path -Leaf $Path) + '.bak-launcher')
    if (-not (Test-Path -LiteralPath $destination)) { Copy-Item -LiteralPath $Path -Destination $destination }
}
function Backup-OfficialSettings([switch]$Snapshot) {
    if (-not (Test-Path -LiteralPath $OfficialSettingsPath)) { return $null }
    $current=Join-Path $SettingsBackupDir 'settings-current.json'
    Copy-Item -LiteralPath $OfficialSettingsPath -Destination $current -Force
    if (-not $Snapshot) { return $current }
    $stamp=[DateTime]::Now.ToString('yyyyMMdd-HHmmss')
    $snapshotPath=Join-Path $SettingsBackupDir ("settings-$stamp.json")
    Copy-Item -LiteralPath $OfficialSettingsPath -Destination $snapshotPath -Force
    return $snapshotPath
}
function Start-CmdCommand([string]$Command, [switch]$KeepOpen, [switch]$PassThru) {
    # Start-Process joins ArgumentList into one Windows command line. cmd.exe needs one more pair of quotes
    # around a /c or /k command whose executable path is itself quoted.
    $mode=if($KeepOpen){'/k'}else{'/c'}
    $wrapped='"' + $Command + '"'
    if($PassThru){ return Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d',$mode,$wrapped) -WorkingDirectory $Root -PassThru }
    Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d',$mode,$wrapped) -WorkingDirectory $Root | Out-Null
}
function Assert-InstallWritable {
    $probe = Join-Path $Root ('.strata-launcher-write-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($probe, 'write check', [Text.UTF8Encoding]::new($false))
    } catch {
        throw "当前启动器进程没有 Strata 根目录的写权限：$Root。请关闭这个窗口，然后从资源管理器双击 $LauncherDir\Strata-Launcher.bat 重新打开。原始错误：$($_.Exception.Message)"
    } finally {
        if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
    }
}
function Port-Busy([int]$Port) {
    $client = [Net.Sockets.TcpClient]::new()
    try { $task = $client.ConnectAsync('127.0.0.1', $Port); return $task.Wait(250) -and $client.Connected } catch { return $false } finally { $client.Dispose() }
}
function Get-StrataHealth([int]$Port) {
    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2
        if ($health.service -eq 'strata') { return $health }
    } catch { }
    return $null
}
function Test-ProcessDescendant([int]$ChildId, [int]$AncestorId) {
    $cursor=$ChildId
    for ($depth=0; $depth -lt 16; $depth++) {
        $parentId=[StrataProcessTree]::ParentProcessId($cursor)
        if ($parentId -le 0) { return $false }
        if ($parentId -eq $AncestorId) { return $true }
        $cursor=$parentId
    }
    return $false
}
function Get-StrataEnginePaths {
    return @(Get-StrataEngineExecutablePaths -Root $Root)
}
function Find-StrataServer([int]$Port) {
    Initialize-StrataProcessTree
    $script:StopLookupDetail = ''
    # The native model engine is the most reliable signal; walk the full parent chain because cmd may sit above Python.
    # Strata runs two engines: the Qwen one (engine\strata.exe) and DeepSeek's own (engine-dsv41\strata-dsv41.exe).
    $enginePaths = @(Get-StrataEnginePaths)
    $byRoot = @{}
    $engineList = @([StrataProcessTree]::ProcessIdsByName('strata.exe')) + @([StrataProcessTree]::ProcessIdsByName('strata-dsv41.exe'))
    $diagnostics = [Collections.ArrayList]::new()
    foreach ($engineId in $engineList) {
        try {
            $actualEnginePath = [StrataProcessTree]::FullProcessImageName($engineId)
            if (-not $actualEnginePath) {
                [void]$diagnostics.Add("无法读取模型引擎 PID $engineId 的完整路径，因此没有把它当作目标。")
                continue
            }
            $knownPath = $false
            foreach ($candidate in $enginePaths) {
                if ([string]::Equals([IO.Path]::GetFullPath($actualEnginePath), [IO.Path]::GetFullPath($candidate), [StringComparison]::OrdinalIgnoreCase)) { $knownPath = $true; break }
            }
            if (-not $knownPath) {
                [void]$diagnostics.Add("发现模型引擎 PID $engineId，但路径不是本安装：$actualEnginePath")
                continue
            }
            $pythonId=0; $pythonPath=''; $shellId=0; $cursor=$engineId; $chain=@($engineId)
            for ($depth=0; $depth -lt 10; $depth++) {
                $ancestorId=[StrataProcessTree]::ParentProcessId($cursor)
                if ($ancestorId -le 0) { break }
                $ancestorName=[StrataProcessTree]::ProcessName($ancestorId)
                if (-not $ancestorName) { break }
                $chain += $ancestorId
                if ($ancestorName -match '^python(w)?\.exe$' -and -not $pythonId) {
                    $pythonId=$ancestorId
                    $pythonPath=[StrataProcessTree]::FullProcessImageName($ancestorId)
                    if (-not $pythonPath) { $pythonPath=$ancestorName }
                }
                if ($ancestorName -ieq 'cmd.exe' -and -not $shellId) { $shellId=$ancestorId }
                $cursor=$ancestorId
            }
            $rootId=if ($shellId) {$shellId} else {$pythonId}
            if (-not $rootId) {
                [void]$diagnostics.Add("本安装的模型引擎 PID $engineId 已确认，但父链中没有找到 Python 服务或 cmd 控制台。")
                continue
            }
            if (-not $byRoot.ContainsKey($rootId)) {
                $byRoot[$rootId]=[pscustomobject]@{ ProcessId=$pythonId; StopId=$rootId; ShellId=$shellId; Executable=$(if($pythonPath){$pythonPath}else{$actualEnginePath}); EngineIds=[Collections.ArrayList]::new(); Model=''; Chain=[Collections.ArrayList]::new() }
            }
            [void]$byRoot[$rootId].EngineIds.Add($engineId)
            foreach ($chainId in $chain) { if (-not $byRoot[$rootId].Chain.Contains($chainId)) { [void]$byRoot[$rootId].Chain.Add($chainId) } }
        } catch { [void]$diagnostics.Add("无法读取模型引擎 PID $engineId 的映像或父链：$($_.Exception.Message)") }
    }
    if ($byRoot.Count -eq 1) { return @($byRoot.Values)[0] }
    if ($byRoot.Count -gt 1) {
        $script:StopLookupDetail="找到 $($byRoot.Count) 条不同的 Strata 进程树，不能安全地自动选一个。"
        return $null
    }

    # Also handle Strata's lazy/unloaded state, when its Python API server is alive without strata.exe.
    $health = Get-StrataHealth $Port
    if (-not $health) {
        if ($engineList.Count -eq 0) { $script:StopLookupDetail='系统进程列表中没有名为 strata 的进程，且当前端口没有返回 Strata /health。' }
        else { $script:StopLookupDetail=($diagnostics -join "`r`n") }
        return $null
    }
    if (Test-Path -LiteralPath $PidPath) {
        try {
            $saved=Get-Content -LiteralPath $PidPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $rootId=[int]$saved.root_pid
            $rootName=[StrataProcessTree]::ProcessName($rootId)
            if ($rootId -gt 0 -and $rootName -match '^(cmd|python|pythonw)\.exe$') {
                $pythonId=if($rootName -match '^python(w)?\.exe$'){$rootId}else{[int]$saved.python_pid}
                return [pscustomobject]@{ ProcessId=$pythonId; StopId=$rootId; ShellId=$(if($rootName -ieq 'cmd.exe'){$rootId}else{0}); Executable=$rootName; EngineIds=@(); Model=[string]$health.model; Chain=@($rootId) }
            }
            $script:StopLookupDetail='启动器 PID 记录已过期，记录中的进程不存在或类型不匹配。'
        } catch { $script:StopLookupDetail="启动器 PID 记录无法读取：$($_.Exception.Message)" }
    }
    if (-not $script:StopLookupDetail) { $script:StopLookupDetail="Strata API 有响应，但当前服务不是由新版启动器启动，且没有找到路径精确匹配本安装模型引擎（engine\strata.exe 或 engine-dsv41\strata-dsv41.exe）的进程树。请在原 Strata cmd 窗口按 Ctrl+C 关闭这一次；以后由启动器启动的服务会记录 PID。" }
    return $null
}
function Add-Row([System.Windows.Forms.TableLayoutPanel]$Table, [int]$Row, [string]$Label, [System.Windows.Forms.Control]$Control, [string]$Hint = '') {
    $Table.RowCount = [Math]::Max($Table.RowCount, $Row + 1)
    [void]$Table.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize))
    $l = [System.Windows.Forms.Label]::new(); $l.Text = $Label; $l.AutoSize = $true; $l.Anchor = 'Left'; $l.Margin = [System.Windows.Forms.Padding]::new(8,8,6,8)
    [void]$Table.Controls.Add($l, 0, $Row)
    if ($Control -is [Windows.Forms.CheckBox]) {
        $Control.AutoSize = $true
        $Control.MaximumSize = [Drawing.Size]::new(232,0)
    }
    $Control.Anchor = 'Left, Right'; $Control.Margin = [System.Windows.Forms.Padding]::new(4,5,12,5); [void]$Table.Controls.Add($Control, 1, $Row)
    if ($Hint) {
        $h = [System.Windows.Forms.Label]::new(); $h.Text = $Hint; $h.AutoSize = $true; $h.Tag = 'muted'
        $h.Margin = [System.Windows.Forms.Padding]::new(4,8,10,8); $h.MaximumSize = [Drawing.Size]::new(420,0)
        [void]$Table.Controls.Add($h, 2, $Row)
    }
    $script:row = $Row + 1
}
$script:Sections = [Collections.ArrayList]::new()
function Add-Section([string]$Key, [string]$Title, [string]$Subtitle) {
    if ($script:Sections.Count) { $script:Sections[$script:Sections.Count - 1].LastRow = $script:row - 1 }
    $header = New-StrataSectionHeader -Title $Title -Subtitle $Subtitle -Theme $theme -Collapsible
    $layout.RowCount = [Math]::Max($layout.RowCount, $script:row + 1)
    [void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 58))
    [void]$layout.Controls.Add($header, 0, $script:row)
    $layout.SetColumnSpan($header, 3)
    [void]$script:Sections.Add([pscustomobject]@{
        Key = $Key
        Header = $header
        FirstRow = $script:row + 1
        LastRow = -1
        Expanded = $true
    })
    $script:row++
}
function Make-Combo([string[]]$Items, [string]$Selected) { $c = [Windows.Forms.ComboBox]::new(); $c.DropDownStyle = 'DropDownList'; [void]$c.Items.AddRange($Items); if ($Items -contains $Selected) { $c.SelectedItem = $Selected } else { $c.SelectedIndex = 0 }; return $c }
function Make-Num([string]$Value, [decimal]$Min, [decimal]$Max, [decimal]$Step = 1) { $n = [Windows.Forms.NumericUpDown]::new(); $n.Minimum=$Min; $n.Maximum=$Max; $n.Increment=$Step; $n.DecimalPlaces=if ($Step -lt 1) { 2 } else { 0 }; $d=0.0; if ([double]::TryParse($Value,[ref]$d)) { $n.Value=[Math]::Min($Max,[Math]::Max($Min,[decimal]$d)) }; return $n }
function NText($Control) { return ([decimal]$Control.Value).ToString([Globalization.CultureInfo]::InvariantCulture) }
function Context-Value($Item) {
    $m=[regex]::Match([string]$Item,'^\s*(\d+)')
    if (-not $m.Success) { throw '上下文长度选项无效。' }
    return [long]$m.Groups[1].Value
}
function Context-Item([long]$Value) {
    $found=$script:ContextItems | Where-Object { (Context-Value $_) -eq $Value } | Select-Object -First 1
    if ($found) { return [string]$found }
    return ("{0}（自定义）" -f $Value)
}
function Context-Summary([long]$Value) {
    if ($isDeepSeek) {
        if ($Value -le 65536) { return "$(($Value / 1024))K 上下文（官方验证 8K，其余未验证）" }
        $scale=([double]$Value / 65536.0).ToString('0.###',[Globalization.CultureInfo]::InvariantCulture)
        return "$(($Value / 1024))K 上下文，YaRN ${scale}x（未验证）"
    }
    if ($Value -le 262144) { return "$(($Value / 1024))K 原生上下文" }
    $scale=([double]$Value / 262144.0).ToString('0.###',[Globalization.CultureInfo]::InvariantCulture)
    return "$(($Value / 1024))K 实验上下文，YaRN ${scale}x"
}
function Calibration-Record([long]$ContextValue, [bool]$WithVision) {
    if (-not (Test-Path -LiteralPath $OfficialSettingsPath)) { return $null }
    try {
        $store=Get-Content -LiteralPath $OfficialSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $store.calibration) { return $null }
        $mode=if($WithVision){'images'}else{'text'}
        $suffix="|$($cfg.model_name)|$ContextValue|$mode"
        foreach($property in $store.calibration.PSObject.Properties) {
            if ($property.Name.EndsWith($suffix,[StringComparison]::OrdinalIgnoreCase)) { return $property.Value }
        }
    } catch { }
    return $null
}
function Calibration-Setting($Settings, [string]$Flag, [string]$Fallback) {
    if ($Settings) {
        $property=$Settings.PSObject.Properties[$Flag]
        if ($property -and $null -ne $property.Value -and [string]$property.Value -ne '') { return [string]$property.Value }
    }
    return $Fallback
}
function Calibration-DetailRecord([long]$ContextValue, [bool]$WithVision) {
    if (-not (Test-Path -LiteralPath $CalibrationDetailsPath)) { return $null }
    try {
        $store=Get-Content -LiteralPath $CalibrationDetailsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $store.records) { return $null }
        $mode=if($WithVision){'images'}else{'text'}
        $suffix="|$($cfg.model_name)|$ContextValue|$mode"
        foreach($property in $store.records.PSObject.Properties) {
            if($property.Name.EndsWith($suffix,[StringComparison]::OrdinalIgnoreCase)){return $property.Value}
        }
    } catch { }
    return $null
}
[void](Backup-OfficialSettings)

$workArea = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$windowWidth = [Math]::Min(980,$workArea.Width)
$windowHeight = [Math]::Min(930,$workArea.Height)
$form = [Windows.Forms.Form]::new(); $form.Text = "Strata 启动器 v$LauncherVersion"; $form.StartPosition='CenterScreen'
$form.SuspendLayout()
$form.AutoScaleMode='Dpi'; $form.Size=[Drawing.Size]::new($windowWidth,$windowHeight); $form.MinimumSize=[Drawing.Size]::new(820,620)
$rootLayout = [Windows.Forms.TableLayoutPanel]::new(); $rootLayout.Dock='Fill'; $rootLayout.ColumnCount=1; $rootLayout.RowCount=4; $rootLayout.Padding=[Windows.Forms.Padding]::new(0)
$rootLayout.SuspendLayout()
[void]$rootLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent',100))
[void]$rootLayout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute',112))
[void]$rootLayout.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent',100))
[void]$rootLayout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute',38))
[void]$rootLayout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute',66))
$form.Controls.Add($rootLayout)
$hero = [Windows.Forms.TableLayoutPanel]::new(); $hero.Tag='hero'; $hero.Dock='Fill'; $hero.ColumnCount=2; $hero.RowCount=1; $hero.Padding=[Windows.Forms.Padding]::new(28,19,28,16)
[void]$hero.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent',72)); [void]$hero.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent',28))
$heroBrand = [Windows.Forms.TableLayoutPanel]::new(); $heroBrand.Tag='hero'; $heroBrand.Dock='Fill'; $heroBrand.ColumnCount=1; $heroBrand.RowCount=2
[void]$heroBrand.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute',48)); [void]$heroBrand.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent',100))
$heroTitle = [Windows.Forms.Label]::new(); $heroTitle.Text='STRATA CONTROL CENTER'; $heroTitle.Tag='hero-text'; $heroTitle.AutoSize=$true; $heroTitle.Font=[Drawing.Font]::new('Segoe UI Semibold',21,[Drawing.FontStyle]::Bold); $heroTitle.Margin=[Windows.Forms.Padding]::new(0)
$engineLabel = if ($isDeepSeek -and $LauncherEnvironment.DeepSeekEngineVersion) { "DeepSeek 引擎 $($LauncherEnvironment.DeepSeekEngineVersion)" } else { "引擎 $($LauncherEnvironment.EngineVersion)" }
$heroSubtitle = [Windows.Forms.Label]::new(); $heroSubtitle.Text="Strata $($LauncherEnvironment.StrataVersion)  ·  $engineLabel  ·  启动器 v$LauncherVersion"; $heroSubtitle.Tag='hero-muted'; $heroSubtitle.AutoSize=$true; $heroSubtitle.Font=[Drawing.Font]::new('Segoe UI',9); $heroSubtitle.Margin=[Windows.Forms.Padding]::new(2,0,0,0)
[void]$heroBrand.Controls.Add($heroTitle,0,0); [void]$heroBrand.Controls.Add($heroSubtitle,0,1)
$heroState = [Windows.Forms.Label]::new(); $heroState.Text=('●  CURRENT MODEL' + "`r`n" + [string]$selectedConfig.Label); $heroState.Tag='hero-text'; $heroState.Dock='Fill'; $heroState.TextAlign='MiddleLeft'; $heroState.AutoEllipsis=$true; $heroState.Padding=[Windows.Forms.Padding]::new(14,5,8,5); $heroState.BackColor=$theme.HeroSurface; $heroState.Font=[Drawing.Font]::new('Segoe UI Semibold',9,[Drawing.FontStyle]::Bold)
$modelToolTip=[Windows.Forms.ToolTip]::new(); $modelToolTip.SetToolTip($heroState, ([string]$selectedConfig.Label + "`r`n" + [string]$selectedConfig.ModelName + "`r`n" + [string]$selectedConfig.Path))
[void]$hero.Controls.Add($heroBrand,0,0); [void]$hero.Controls.Add($heroState,1,0); [void]$rootLayout.Controls.Add($hero,0,0)
$layout = [Windows.Forms.TableLayoutPanel]::new(); $layout.Dock='Fill'; $layout.AutoScroll=$true; $layout.ColumnCount=3; $layout.RowCount=0; $layout.Padding=[Windows.Forms.Padding]::new(18,6,18,12)
$layout.SuspendLayout()
[void]$layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Absolute',178)); [void]$layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Absolute',270)); [void]$layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent',100))
[void]$rootLayout.Controls.Add($layout,0,1)
$row=0
$script:ContextItems=@(
    '32768（32K，原生）',
    '65536（64K，原生）',
    '98304（96K，原生）',
    '131072（128K，原生）',
    '204800（200K，原生）',
    '262144（256K，原生上限）',
    '393216（384K，YaRN 1.5x，实验）',
    '524288（512K，YaRN 2x，实验）',
    '786432（768K，YaRN 3x，高级实验）',
    '1048576（1M，YaRN 4x，高级实验）'
)
if ($isOwnPath) { $script:ContextItems=@($script:ContextItems | Where-Object { (Context-Value $_) -le 262144 }) }
if ($isDeepSeek) {
    # The GGUF metadata says 64K native, YaRN x16 up to 1M; the official setup only checks 8192, so every
    # larger value is offered as unverified. The engine accepts it; the KV cache grows with it.
    $script:ContextItems=@(
        '8192（8K，官方默认）',
        '16384（16K，未验证）',
        '32768（32K，未验证）',
        '65536（64K，原生上限，未验证）',
        '131072（128K，YaRN ×2，未验证）',
        '262144（256K，YaRN ×4，未验证）',
        '524288（512K，YaRN ×8，未验证）',
        '1048576（1M，YaRN ×16，未验证）'
    )
}
$modelLabels=@($modelConfigs | ForEach-Object { $_.Label })
Add-Section 'model' 'MODEL & PRESET' '选择模型与常用使用方式'
$modelSelector=Make-Combo $modelLabels ([string]$selectedConfig.Label)
$modelSelector.Width=340
$modelSelector.DropDownWidth=360
$modelToolTip.SetToolTip($modelSelector, ([string]$selectedConfig.Label + "`r`n" + [string]$selectedConfig.ModelName + "`r`n" + [string]$selectedConfig.Path))
$modelSelector.Add_SelectedIndexChanged({
    $picked=$modelConfigs | Where-Object { $_.Label -eq [string]$modelSelector.SelectedItem } | Select-Object -First 1
    if ($picked) { $modelToolTip.SetToolTip($modelSelector, ([string]$picked.Label + "`r`n" + [string]$picked.ModelName + "`r`n" + [string]$picked.Path)) }
})
$modelSwitch=[Windows.Forms.Button]::new(); $modelSwitch.Text='切换'; $modelSwitch.Width=72; $modelSwitch.Height=25
$modelPanel=[Windows.Forms.FlowLayoutPanel]::new(); $modelPanel.FlowDirection='LeftToRight'; $modelPanel.WrapContents=$false; $modelPanel.Height=42; $modelPanel.Margin=[Windows.Forms.Padding]::new(0)
[void]$modelPanel.Controls.Add($modelSelector); [void]$modelPanel.Controls.Add($modelSwitch)
Add-Row $layout $row '当前模型' $modelPanel
$layout.SetColumnSpan($modelPanel,2)
$generationFamily=if($isDeepSeek){'deepseek41'}elseif($isOwnPath){'qwen35moe'}else{'qwen4exp'}
$initialPresetName=if(Test-StrataGenerationOverrides -Config $cfg -Shared $shared){'自定义'}else{'官方默认'}
$preset = Make-Combo @('官方默认','快速直答','日常通用','Agent / 深度思考','自定义') $initialPresetName; Add-Row $layout $row '使用预设' $preset '官方默认会清除旧采样覆盖；其余档位按当前模型家族的模型卡设置'
Add-Section 'generation' 'GENERATION' '生成质量、随机性与重复控制'
$initialEffort=if ($shared.reasoning_effort) {[string]$shared.reasoning_effort} elseif ($cfg.reasoning_effort) {[string]$cfg.reasoning_effort} else {'high'}
$effort = Make-Combo @('high','medium','low','none') $initialEffort; Add-Row $layout $row '默认思考强度' $effort $(if($isDeepSeek){'配置默认值仅支持这四项；API 请求可单独指定 max 或 1–100'}else{'Qwen 配置默认值；API 请求可覆盖'})
$initialCard=Get-StrataModelCardSampling -Family $generationFamily -Thinking ($initialEffort -ne 'none')
$temp = Make-Num ([string]$(if ($null -ne $shared.temperature) {$shared.temperature} elseif ($null -ne $cfg.sampling.temperature) {$cfg.sampling.temperature} else {$initialCard.temperature})) 0 2 0.05; Add-Row $layout $row 'Temperature' $temp '随机性；低值更稳定'
$topP = Make-Num ([string]$(if ($null -ne $shared.top_p) {$shared.top_p} elseif ($null -ne $cfg.sampling.top_p) {$cfg.sampling.top_p} else {$initialCard.top_p})) 0.01 1 0.01; Add-Row $layout $row 'Top-p' $topP '候选概率累计阈值'
$topK = Make-Num ([string]$(if ($null -ne $shared.top_k) {$shared.top_k} elseif ($null -ne $cfg.sampling.top_k) {$cfg.sampling.top_k} elseif($isDeepSeek){64}else{$initialCard.top_k})) 1 64 1; Add-Row $layout $row 'Top-k' $topK $(if($isDeepSeek){'DeepSeek 模型卡不指定此值；服务模式未覆盖时引擎使用 64'}else{'候选 token 数量；Qwen 模型卡为 20'})
$minP = Make-Num ([string]$cfg.sampling.min_p) 0 1 0.01; Add-Row $layout $row 'Min-p' $minP '低概率候选过滤；0 表示关闭'
$presenceFallback=if($initialCard.Contains('presence_penalty')){$initialCard.presence_penalty}else{0}
$presence = Make-Num ([string]$(if($null -ne $cfg.sampling.presence_penalty){$cfg.sampling.presence_penalty}else{$presenceFallback})) 0 2 0.1; if(-not $isDeepSeek){Add-Row $layout $row 'Presence penalty' $presence '降低重复话题倾向'}
$repeat = Make-Num ([string](Get-StrataSamplingValue -Sampling $cfg.sampling -Name 'repetition_penalty' -Alias 'repeat_penalty' -Fallback 1)) 0.5 2 0.05; if(-not $isDeepSeek){Add-Row $layout $row 'Repetition penalty' $repeat '重复 token 惩罚；1 表示关闭'}
$freq = Make-Num ([string]$cfg.sampling.frequency_penalty) 0 2 0.1; if(-not $isDeepSeek){Add-Row $layout $row 'Frequency penalty' $freq '按出现频次惩罚重复'}
$lastN = Make-Num ([string](Get-StrataSamplingValue -Sampling $cfg.sampling -Name 'penalty_last_n' -Alias 'repeat_last_n' -Fallback 64)) 0 4096 1; if(-not $isDeepSeek){Add-Row $layout $row '惩罚回看 token 数' $lastN 'penalty_last_n；0 表示关闭'}
$seedText = [Windows.Forms.TextBox]::new(); $seedText.Text=if ($null -ne $shared.seed) {[string]$shared.seed} elseif ($null -ne $cfg.sampling.seed) {[string]$cfg.sampling.seed} else {''}; Add-Row $layout $row '随机种子' $seedText '留空表示每次随机'
$maxOut = Make-Num ([string]$(if ($shared.max_tokens) {$shared.max_tokens} else {'0'})) 0 131072 128; Add-Row $layout $row 'API 默认最大输出' $maxOut '0 表示不设置服务端默认值'
$budgetSource=if($null -ne $shared.PSObject.Properties['reasoning_budget_tokens']){$shared.reasoning_budget_tokens}elseif($null -ne $cfg.PSObject.Properties['reasoning_budget_tokens']){$cfg.reasoning_budget_tokens}else{$null}
$budgetModeName=if($null -eq $budgetSource){'官方默认'}elseif([int]$budgetSource -eq 0){'不限制（0）'}else{'自定义上限'}
$reasonBudgetMode=Make-Combo @('官方默认','不限制（0）','自定义上限') $budgetModeName; Add-Row $layout $row '思考预算方式' $reasonBudgetMode $(if($isDeepSeek){'官方默认：DeepSeek 服务端使用默认预算；0：显式取消固定预算'}else{'官方默认：由服务端决定；0：显式取消固定预算'})
$reasonBudget = Make-Num ([string]$(if($null -ne $budgetSource -and [int]$budgetSource -gt 0){$budgetSource}else{'0'})) 0 131072 256; $reasonBudget.Enabled=($budgetModeName -eq '自定义上限'); Add-Row $layout $row '思考 token 上限' $reasonBudget '选择“自定义上限”时填写大于 0 的值'
$reasonBudgetMode.Add_SelectedIndexChanged({$reasonBudget.Enabled=([string]$reasonBudgetMode.SelectedItem -eq '自定义上限')})
Add-Section 'runtime' 'RUNTIME & MEMORY' '上下文、显存与服务运行参数'
$initialContext=Get-StrataInitialContext -Config $cfg
$initialContextItem=Context-Item $initialContext
if ($script:ContextItems -notcontains $initialContextItem) { $script:ContextItems += $initialContextItem }
$ctx = Make-Combo $script:ContextItems $initialContextItem; Add-Row $layout $row '上下文长度' $ctx $(if($isDeepSeek){'官方默认 8192；模型原生 64K，元数据支持 YaRN ×16 到 1M；官方只验证到 8192，更大更占显存/内存'}elseif($isOwnPath){'Qwen3.6 原生上限 256K，不使用 YaRN'}else{'超过 256K 自动使用 YaRN；更长会降低速度并增加内存占用'})
if ($isDeepSeek) {
    $dsPresetItems = @('自动（官方默认）','热专家优先（LFU）','省内存（关闭 RAM 缓存）','自定义')
    $dsPreset = Make-Combo $dsPresetItems '自动（官方默认）'; Add-Row $layout $row '专家缓存预设' $dsPreset '官方默认交给 DeepSeek 引擎自动选择容量；LFU 只改变淘汰策略，不固定缓存大小。'
    $dsReserve = Make-Num ([string]$deepSeekSettings.ReserveMib) 0 32768 128; Add-Row $layout $row '显存预留 MiB' $dsReserve '引擎的 --reserve-mib；0 = 自动（不写该参数）'
    $dsThreads = Make-Num ([string]$deepSeekSettings.CpuThreads) 0 128 1; Add-Row $layout $row 'CPU 线程数' $dsThreads '引擎的 --cpu-threads；0 = 引擎自动'
    $dsDspark = Make-Combo @('auto','on','off','none') ([string]$deepSeekSettings.Dspark); Add-Row $layout $row 'DSpark 草稿' $dsDspark 'auto：按引擎规则决定；off：仍加载草稿权重；none：完全不加载草稿'
    $script:DsConfiguredEngineVersion=Get-StrataDeepSeekConfiguredEngineVersion -Config $cfg -Root $Root -FallbackVersion ([string]$LauncherEnvironment.DeepSeekEngineVersion)
    $script:DsExpertsSupported=Test-StrataDeepSeekExpertsSupported -Version $script:DsConfiguredEngineVersion
    $dsSpeedChoice=if([string]$deepSeekSettings.Experts -eq '5'){'Faster（5 专家）'}elseif([string]$deepSeekSettings.Experts -eq '6'){'Full（6 专家）'}else{'自动（引擎默认）'}
    $dsSpeed=Make-Combo @('自动（引擎默认）','Faster（5 专家）','Full（6 专家）') $dsSpeedChoice
    $dsSpeed.Enabled=$script:DsExpertsSupported
    $dsSpeedHint=if($script:DsExpertsSupported){"当前配置引擎 $($script:DsConfiguredEngineVersion)：自动按显卡容量选择；Faster 每 token 用 5 个专家，Full 用 6 个"}else{"当前配置引擎 $($script:DsConfiguredEngineVersion) 低于 0.1.50 或版本未知；此选项已禁用，保存时不会写 --experts"}
    Add-Row $layout $row 'DeepSeek Speed' $dsSpeed $dsSpeedHint
    $dsConf = [Windows.Forms.TextBox]::new(); $dsConf.Text=[string]$deepSeekSettings.DsparkConf; $dsConf.Width=120; Add-Row $layout $row 'DSpark 置信度' $dsConf '留空 = 保留官方值/引擎默认（IST-DAS 官方写 0.65）；0 = 关闭草稿'
    $dsSsdHint = '留空 = 引擎按可用 RAM 与模型大小自动分配并保留约 12 GB；0 = 关闭 RAM 专家缓存；正数 = 自定义 GB。请勿填写 auto。'
    $dsSsd = [Windows.Forms.TextBox]::new(); $dsSsd.Text=[string]$deepSeekSettings.SsdCache; Add-Row $layout $row 'SSD 专家缓存' $dsSsd $dsSsdHint
    $dsPolicy = Make-Combo @('默认','lru','lfu','lfu→lru') (Get-StrataSsdPolicyItem ([string]$deepSeekSettings.SsdPolicy)); Add-Row $layout $row '专家缓存淘汰' $dsPolicy '默认 = 引擎的 lru；lfu 护住反复命中的热专家（缓存装不下全部专家时更划算）；lfu→lru 先比命中次数、同分再看时间'
    $dsMmap = Make-Combo @('默认','auto','on','off') (Get-StrataMmapItem ([string]$deepSeekSettings.MmapExperts)); Add-Row $layout $row '专家读盘方式' $dsMmap '默认/auto = 显存放不下的专家就地读（省内存、吃盘）；on = 强制就地读；off = 能放下的全拷进内存（省盘，选它会自动把专家缓存置 0）'
    $dsVram = Make-Num ([string]$deepSeekSettings.VramExperts) 0 1 0.05; Add-Row $layout $row '显存专家份额' $dsVram '0 = 引擎默认（用满）；0.9 = 只拿九成显存额度放专家，给长上下文和桌面留余量；范围 0–1'
    $dsPrefill = Make-Num ([string]$deepSeekSettings.PrefillChunk) 0 65536 256; Add-Row $layout $row '预填充分块' $dsPrefill '引擎的 --prefill-chunk；0 = 引擎自动；越大越省读盘次数，越占显存缓冲'
    $dsDblock = Make-Num ([string]$deepSeekSettings.DsparkBlock) 0 16 1; Add-Row $layout $row 'DSpark 草稿块' $dsDblock '0 = 包内默认；官方调优会试 3（草稿更短、命中更高）；范围 0–16'
    Connect-StrataDeepSeekPresetControls -Selector $dsPreset -Controls ([ordered]@{ Ssd = $dsSsd; Policy = $dsPolicy })
} else {
    $kv = Make-Combo @('fp16','int8','q4_0','k8v4') ([string](Arg-Value $cfg.args '--kv' 'fp16')); Add-Row $layout $row 'KV cache 格式' $kv 'fp16 = 引擎默认；量化格式更省显存，但可能影响速度或质量'
    $kvResidentCurrent=[string](Arg-Value $cfg.args '--kv-resident' '')
    $kvResidentChoice=Get-StrataQwenKvResidentChoice -CurrentValue $kvResidentCurrent
    $kvResident = Make-Combo (Get-StrataQwenKvResidentItems -CurrentValue $kvResidentCurrent) $kvResidentChoice; Add-Row $layout $row '驻留 KV token' $kvResident '关闭 = 引擎默认、全部 KV 留在显存；启用时引擎最少驻留 20480 token'
    $reserve = Make-Num ([string](Arg-Value $cfg.args '--vram-reserve-mib' '0')) 0 32768 128; Add-Row $layout $row '保留显存 MiB' $reserve '0 = 引擎默认；自定义值为桌面/视觉留出显存'
    $poolWorkers = Make-Num ([string](Arg-Value $cfg.args '--pool-workers' '0')) 0 128 1; Add-Row $layout $row 'CPU 线程数' $poolWorkers '引擎的专家池 worker 数；0 = 自动（物理核心 − 1，上限 32）；超过核心数可能更慢'
    if ($isOwnPath) {
        $kv.Enabled=$false; $kvResident.Enabled=$false; $reserve.Enabled=$false
        $expertVram=[string](Arg-Value $cfg.args '--expert-vram' '自动'); if($expertVram -ne '自动'){$expertVram+=' GiB'}
        $nativeInfo=[Windows.Forms.Label]::new(); $nativeInfo.Text="MTP $(Arg-Value $cfg.args '--mtp' '默认') · Prefill $(Arg-Value $cfg.args '--prefill' '默认') · Expert VRAM $expertVram"; $nativeInfo.AutoSize=$true
        Add-Row $layout $row '独立引擎参数' $nativeInfo '这些参数由官方 setup 管理；启动器保存时原样保留。'
    }
}
$parallelHint=if($isDeepSeek){'DeepSeek 引擎暂不支持并发请求；官方会忽略 --parallel'}else{'并发会增加显存和内存占用；实际槽位数可由引擎下调'}
$parallelCurrent=[string]$(if ($cfg.parallel) {$cfg.parallel} else {'1'})
$parallel = Make-Combo (Get-StrataQwenParallelItems -CurrentValue $parallelCurrent) $parallelCurrent; Add-Row $layout $row '并行请求数' $parallel $parallelHint
if ($isDeepSeek) { $parallel.Enabled=$false; $parallel.SelectedItem='1' }
Add-Section 'gpu_placement' 'GPU PLACEMENT · NVIDIA' $(if($isDeepSeek){'选择参与 DeepSeek 推理的显卡；引擎自行安排专家分层'}else{'为当前模型指定 Main / Helper / Off；多卡按模型层分工'})
$gpuPlacementCards=@(Get-StrataNvidiaPlacementCards)
$gpuPlacementBuild=$null
try {
    $buildPath=Join-Path $Root 'engine\BUILD.json'
    if (Test-Path -LiteralPath $buildPath -PathType Leaf) { $gpuPlacementBuild=Get-Content -LiteralPath $buildPath -Raw -Encoding UTF8 | ConvertFrom-Json }
} catch { $gpuPlacementBuild=$null }
$canEditGpuPlacement=Test-StrataCudaPlacementBuild -Build $gpuPlacementBuild -Cards $gpuPlacementCards
if ($isDeepSeek) {
    $deepSeekInitialCards=@()
    if ($null -ne $cfg.gpu) { $deepSeekInitialCards=@($cfg.gpu | ForEach-Object { [int]$_ }) }
    $deepSeekHasSavedRoles=($null -ne $cfg.PSObject.Properties['gpu_roles'] -and $null -ne $cfg.gpu_roles)
    if($deepSeekInitialCards.Count -eq 0 -and $deepSeekHasSavedRoles){
        $deepSeekInitialCards=@(Get-StrataGpuPlacementRoles -Config $cfg -Cards $gpuPlacementCards | Where-Object Role -NE 'off' | ForEach-Object {[int]$_.Index})
    }
    $deepSeekAllCards=($deepSeekInitialCards.Count -eq 0 -and -not $deepSeekHasSavedRoles)
    $deepSeekCardBoxes=@{}
    $deepSeekUiInitialCards=@()
    if($gpuPlacementCards.Count -eq 0){
        $deepSeekGpuNote=[Windows.Forms.Label]::new(); $deepSeekGpuNote.AutoSize=$true; $deepSeekGpuNote.Text='未检测到 NVIDIA 显卡；保存时保留现有 DeepSeek GPU 配置。'
        Add-Row $layout $row '推理显卡' $deepSeekGpuNote 'AMD 与其他后端的显卡选择请使用 Strata 官方命令行。'
    }
    foreach($card in $gpuPlacementCards){
        $memoryGiB=[Math]::Round([double]$card.MemoryMiB/1024,1)
        $pciLocation=Convert-StrataGpuPciBusIdToWindowsLocation ([string]$card.BusId)
        $cardLabel=if($pciLocation){
            if($pciLocation.Segment -eq 0){"GPU $($card.Index) · 总线 $($pciLocation.Bus)"}else{"GPU $($card.Index) · 段 $($pciLocation.Segment) 总线 $($pciLocation.Bus)"}
        }else{"GPU $($card.Index) · PCI $($card.BusId)"}
        $cardHint=if($pciLocation){"$($card.Name) · $memoryGiB GiB · $($pciLocation.Text)"}else{"$($card.Name) · $memoryGiB GiB · PCI $($card.BusId)"}
        $box=[Windows.Forms.CheckBox]::new(); $box.Text='参与推理'
        $enough = ([double]$card.MemoryMiB -ge 8192)
        $box.Checked=($enough -and ($deepSeekAllCards -or ($deepSeekInitialCards -contains [int]$card.Index)))
        if($box.Checked){$deepSeekUiInitialCards+=[int]$card.Index}
        $box.Enabled=$enough
        if (-not $enough) { $cardHint+=' · 显存不足 8 GiB，不能参与' }
        $deepSeekCardBoxes[[int]$card.Index]=$box
        Add-Row $layout $row $cardLabel $box $cardHint
    }
    $tpChoices=@(Get-StrataDeepSeekTpItems -CurrentValue ([string]$deepSeekSettings.Tp))
    $tpSelected=if([string]$deepSeekSettings.Tp -in $tpChoices){[string]$deepSeekSettings.Tp}else{'自动（引擎默认）'}
    $dsTp=Make-Combo $tpChoices $tpSelected
    Add-Row $layout $row '张量并行 --tp' $dsTp '自动 = 引擎默认（2 卡及以上为 2）；1 = 纯层切分，4 卡以上 AMD 时官方建议 1'
} else {
    $gpuPlacementEdit=[Windows.Forms.CheckBox]::new(); $gpuPlacementEdit.Text='修改当前模型的推理显卡分配'; $gpuPlacementEdit.Enabled=$canEditGpuPlacement
    $gpuPlacementHint=if($canEditGpuPlacement){'未勾选时保留模型原有 GPU 配置；勾选后选择每张卡的角色，保存或启动时生效。'}else{'未检测到与当前 CUDA 引擎兼容的 NVIDIA 显卡；原有 GPU 配置保持不变。'}
    Add-Row $layout $row '推理显卡' $gpuPlacementEdit $gpuPlacementHint
    $gpuPlacementSelectors=@{}
    $gpuPlacementRoles=@(Get-StrataGpuPlacementRoles -Config $cfg -Cards $gpuPlacementCards)
    foreach($card in $gpuPlacementCards){
        $role=@($gpuPlacementRoles | Where-Object Index -EQ $card.Index | Select-Object -First 1)
        $selectedRole=if($role.Count){[string]$role[0].Role}else{'off'}
        if($selectedRole -notin @('main','helper','off')){$selectedRole='off'}
        $cardSupported=Test-StrataCudaPlacementCard -Build $gpuPlacementBuild -Card $card
        if(-not $cardSupported){$selectedRole='off'}
        $roleControl=Make-Combo $(if($cardSupported){@('Off','Helper','Main')}else{@('Off')}) ($selectedRole.Substring(0,1).ToUpperInvariant()+$selectedRole.Substring(1))
        $roleControl.Enabled=$false
        $roleControl.Tag=$cardSupported
        $gpuPlacementSelectors[[int]$card.Index]=$roleControl
        $memoryGiB=[Math]::Round([double]$card.MemoryMiB/1024,1)
        $pciLocation=Convert-StrataGpuPciBusIdToWindowsLocation ([string]$card.BusId)
        $cardLabel=if($pciLocation){
            if($pciLocation.Segment -eq 0){"GPU $($card.Index) · 总线 $($pciLocation.Bus)"}else{"GPU $($card.Index) · 段 $($pciLocation.Segment) 总线 $($pciLocation.Bus)"}
        }else{"GPU $($card.Index) · PCI $($card.BusId)"}
        $cardHint=if($pciLocation){"$($card.Name) · $memoryGiB GiB · $($pciLocation.Text)"}else{"$($card.Name) · $memoryGiB GiB · PCI $($card.BusId)"}
        if(-not $cardSupported){$cardHint+=' · 当前 CUDA 引擎不支持'}
        Add-Row $layout $row $cardLabel $roleControl $cardHint
    }
    $gpuPlacementEdit.Add_CheckedChanged({foreach($selector in $gpuPlacementSelectors.Values){$selector.Enabled=($gpuPlacementEdit.Checked -and [bool]$selector.Tag)}})
}
Add-Section 'network' 'NETWORK & ACCESS' '端口、局域网与启动选项'
$port = Make-Num ([string]$cfg.port) 1024 65535 1; Add-Row $layout $row '服务端口' $port '默认 8080；监听范围由下方局域网开关决定'
$lanAccess = [Windows.Forms.CheckBox]::new(); $lanAccess.Text='LAN access：允许局域网设备访问'; $lanAccess.Checked=(Get-StrataLanMode $LanModePath)
Add-Row $layout $row '局域网访问' $lanAccess '默认关闭；下次由启动器启动时生效，必须使用 API key。不要做公网端口转发。'
$lanKeyCopy=[Windows.Forms.Button]::new(); $lanKeyCopy.Text='Copy API key · 复制密钥'; $lanKeyCopy.Width=210; $lanKeyCopy.Height=29; $lanKeyCopy.Enabled=$lanAccess.Checked
Add-Row $layout $row '访问密钥' $lanKeyCopy '仅按需复制到剪贴板；密钥由当前 Windows 用户加密保存，不写入模型配置或分享包。'
$lanFirewallPanel=[Windows.Forms.FlowLayoutPanel]::new(); $lanFirewallPanel.FlowDirection='LeftToRight'; $lanFirewallPanel.WrapContents=$false; $lanFirewallPanel.AutoSize=$true
$lanFirewallAdd=[Windows.Forms.Button]::new(); $lanFirewallAdd.Text='Firewall · 放行'; $lanFirewallAdd.Width=112; $lanFirewallAdd.Height=29; $lanFirewallAdd.Enabled=$lanAccess.Checked
$lanFirewallRemove=[Windows.Forms.Button]::new(); $lanFirewallRemove.Text='撤销放行'; $lanFirewallRemove.Width=100; $lanFirewallRemove.Height=29
[void]$lanFirewallPanel.Controls.Add($lanFirewallAdd); [void]$lanFirewallPanel.Controls.Add($lanFirewallRemove)
Add-Row $layout $row '防火墙' $lanFirewallPanel '独立点击并经管理员授权；只允许专用网络、本地子网、所选端口和 Strata Python。'
$lanAddressPanel=[Windows.Forms.FlowLayoutPanel]::new(); $lanAddressPanel.FlowDirection='TopDown'; $lanAddressPanel.WrapContents=$false; $lanAddressPanel.AutoSize=$true
Add-Row $layout $row '候选访问地址' $lanAddressPanel '点击某条地址即复制该条；不会打开网页。实际能否连接仍要从另一台同网段设备验证。HTTP 非加密。'
$lanIPs=@()
try { $lanIPs=@(Select-StrataLanIPv4Addresses @([Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) | ForEach-Object { $_.ToString() })) } catch {}
$updateLanAddress = {
    $candidateText=Get-StrataLanAddressText -Addresses $lanIPs -Port ([int]$port.Value)
    foreach ($old in @($lanAddressPanel.Controls)) { [void]$lanAddressPanel.Controls.Remove($old); $old.Dispose() }
    if ($candidateText) {
        foreach ($url in @($candidateText -split [regex]::Escape([Environment]::NewLine))) {
            $link=[Windows.Forms.LinkLabel]::new(); $link.Text=$url; $link.Tag=$url; $link.AutoSize=$true
            $link.LinkColor=$theme.Accent; $link.ActiveLinkColor=$theme.AccentHover; $link.VisitedLinkColor=$theme.Accent
            $link.LinkBehavior=[Windows.Forms.LinkBehavior]::AlwaysUnderline; $link.Cursor=[Windows.Forms.Cursors]::Hand
            $link.Margin=[Windows.Forms.Padding]::new(3,2,3,2)
            $link.Add_LinkClicked({
                param($sender,$eventArgs)
                try {
                    $address=[string]$sender.Tag
                    [Windows.Forms.Clipboard]::SetText($address)
                    $status.Text="已复制局域网地址：$address。请从另一台设备验证连接。"
                } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'复制地址失败','OK','Error') | Out-Null }
            })
            [void]$lanAddressPanel.Controls.Add($link)
        }
    } else {
        $none=[Windows.Forms.Label]::new(); $none.Text='未发现私有 IPv4；请用 ipconfig 查看本机地址'; $none.AutoSize=$true; $none.MaximumSize=[Drawing.Size]::new(250,0); $none.Tag='muted'
        [void]$lanAddressPanel.Controls.Add($none)
    }
}
& $updateLanAddress
$port.Add_ValueChanged($updateLanAddress)
$lanAccess.Add_CheckedChanged({ $lanKeyCopy.Enabled=$lanAccess.Checked; $lanFirewallAdd.Enabled=$lanAccess.Checked })
$vision = [Windows.Forms.CheckBox]::new(); $vision.Text='启用图像输入'; $vision.Checked=($null -ne $cfg.vision); Add-Row $layout $row '视觉' $vision '首次启用时查找已安装的视觉组件；关闭时保留视觉配置供以后恢复'
if ($isOwnPath -or $isDeepSeek) { $vision.Enabled=$false; $vision.Checked=$false }
$sharedDefaults = [Windows.Forms.CheckBox]::new(); $sharedDefaults.Text='保存为外部 API 客户端默认值'; $sharedDefaults.Checked=$true; Add-Row $layout $row 'API 默认参数' $sharedDefaults '请求未显式传参时生效；Agent 自己传的参数优先'
$openBrowser = [Windows.Forms.CheckBox]::new(); $openBrowser.Text='服务就绪后打开本机网页'; $openBrowser.Checked=$true; Add-Row $layout $row '启动后' $openBrowser ''

Add-Section 'gpu_power' 'GPU POWER · NVIDIA' '可选的系统级功率上限；仅点击应用或恢复时更改'
$gpuSelector=[Windows.Forms.ComboBox]::new(); $gpuSelector.DropDownStyle='DropDownList'; Add-Row $layout $row '显卡' $gpuSelector '只支持 NVIDIA；功率上限影响这张显卡上的所有程序'
$gpuPowerInfo=[Windows.Forms.Label]::new(); $gpuPowerInfo.AutoSize=$true; $gpuPowerInfo.MaximumSize=[Drawing.Size]::new(255,0); $gpuPowerInfo.Text='展开后读取显卡功率'; Add-Row $layout $row '当前状态' $gpuPowerInfo '会显示当前值、出厂默认值与驱动允许范围'
$gpuPowerWatts=Make-Num '100' 1 1000 1; $gpuPowerWatts.Enabled=$false; Add-Row $layout $row '目标功率 W' $gpuPowerWatts '手动应用；保存设置或启动 Strata 不会改变功率'
$gpuPowerButtons=[Windows.Forms.FlowLayoutPanel]::new(); $gpuPowerButtons.FlowDirection='LeftToRight'; $gpuPowerButtons.WrapContents=$false; $gpuPowerButtons.AutoSize=$true
$gpuPowerApply=[Windows.Forms.Button]::new(); $gpuPowerApply.Text='应用'; $gpuPowerApply.Width=65; $gpuPowerApply.Enabled=$false; $gpuPowerApply.Tag='button:Accent'
$gpuPowerRestore=[Windows.Forms.Button]::new(); $gpuPowerRestore.Text='恢复修改前'; $gpuPowerRestore.Width=110; $gpuPowerRestore.Enabled=$false; $gpuPowerRestore.Tag='button:Secondary'
$gpuPowerRefresh=[Windows.Forms.Button]::new(); $gpuPowerRefresh.Text='刷新'; $gpuPowerRefresh.Width=65; $gpuPowerRefresh.Tag='button:Secondary'
foreach($button in @($gpuPowerApply,$gpuPowerRestore,$gpuPowerRefresh)){[void]$gpuPowerButtons.Controls.Add($button)}
Add-Row $layout $row '功率操作' $gpuPowerButtons '写入可能触发 Windows 管理员授权；恢复的是修改前值，不是出厂默认值'

Add-Section 'tools' 'TOOLS & BENCHMARK' '性能校准、官方维护与对比报告'
$calibrationGroup=[Windows.Forms.GroupBox]::new(); $calibrationGroup.Tag='surface'; $calibrationGroup.Text='性能校准'; $calibrationGroup.Dock='Top'; $calibrationGroup.AutoSize=$true; $calibrationGroup.AutoSizeMode='GrowAndShrink'; $calibrationGroup.Padding=[Windows.Forms.Padding]::new(10,6,10,8); $calibrationGroup.Margin=[Windows.Forms.Padding]::new(8,10,10,6)
$calibrationLayout=[Windows.Forms.TableLayoutPanel]::new(); $calibrationLayout.Dock='Top'; $calibrationLayout.AutoSize=$true; $calibrationLayout.ColumnCount=2; $calibrationLayout.RowCount=2
[void]$calibrationLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent',100)); [void]$calibrationLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Absolute',146))
$calibrationState=[Windows.Forms.Label]::new(); $calibrationState.AutoSize=$true; $calibrationState.Margin=[Windows.Forms.Padding]::new(4,5,8,2); $calibrationState.Font=[Drawing.Font]::new($form.Font,[Drawing.FontStyle]::Bold)
$calibrationDetails=[Windows.Forms.Label]::new(); $calibrationDetails.Tag='muted'; $calibrationDetails.AutoSize=$true; $calibrationDetails.Margin=[Windows.Forms.Padding]::new(4,2,8,5); $calibrationDetails.MaximumSize=[Drawing.Size]::new(610,0)
$calibrate = [Windows.Forms.Button]::new(); $calibrate.Text='保存并校准'; $calibrate.Width=130; $calibrate.Height=30; $calibrate.Anchor='Right'
if ($isOwnPath) { $calibrate.Enabled=$false; $calibrate.Text='独立引擎无需校准' }
if ($isDeepSeek) { $calibrate.Enabled=$true; $calibrate.Text='官方调优' }
[void]$calibrationLayout.Controls.Add($calibrationState,0,0); [void]$calibrationLayout.Controls.Add($calibrationDetails,0,1); [void]$calibrationLayout.Controls.Add($calibrate,1,0); $calibrationLayout.SetRowSpan($calibrate,2)
if ($isDeepSeek) {
    $planPredict = [Windows.Forms.Button]::new(); $planPredict.Text='规划预测'; $planPredict.Width=130; $planPredict.Height=30; $planPredict.Anchor='Right'
    [void]$calibrationLayout.Controls.Add($planPredict,1,1); $calibrationLayout.SetRowSpan($calibrate,1)
}
$calibrationGroup.Controls.Add($calibrationLayout)
$layout.RowCount=[Math]::Max($layout.RowCount,$row+1); [void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)); [void]$layout.Controls.Add($calibrationGroup,0,$row); $layout.SetColumnSpan($calibrationGroup,3); $row++

$officialToolsGroup=[Windows.Forms.GroupBox]::new(); $officialToolsGroup.Tag='surface'; $officialToolsGroup.Text='官方工具'; $officialToolsGroup.Dock='Top'; $officialToolsGroup.AutoSize=$true; $officialToolsGroup.AutoSizeMode='GrowAndShrink'; $officialToolsGroup.Padding=[Windows.Forms.Padding]::new(10,6,10,8); $officialToolsGroup.Margin=[Windows.Forms.Padding]::new(8,6,10,6)
$officialToolsLayout=[Windows.Forms.TableLayoutPanel]::new(); $officialToolsLayout.Dock='Top'; $officialToolsLayout.AutoSize=$true; $officialToolsLayout.ColumnCount=4; $officialToolsLayout.RowCount=5
foreach ($column in 1..4) { [void]$officialToolsLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent',25)) }
$officialImportInfo=[Windows.Forms.Label]::new(); $officialImportInfo.Tag='muted'; $officialImportInfo.AutoSize=$true; $officialImportInfo.Margin=[Windows.Forms.Padding]::new(4,3,8,7); $officialImportInfo.MaximumSize=[Drawing.Size]::new(690,0); $officialImportInfo.Text='直接调用官方脚本。导入和更新前会先备份官方设置；不会改变下方“保存并启动”的 server.py 启动方式。'
[void]$officialToolsLayout.Controls.Add($officialImportInfo,0,0); $officialToolsLayout.SetColumnSpan($officialImportInfo,4)
$officialImport=[Windows.Forms.Button]::new(); $officialImport.Text='导入本地模型'; $officialImport.Dock='Fill'; $officialImport.Height=29; $officialImport.Margin=[Windows.Forms.Padding]::new(4,2,4,3)
$officialStart=[Windows.Forms.Button]::new(); $officialStart.Text='官方 START-HERE'; $officialStart.Dock='Fill'; $officialStart.Height=29; $officialStart.Margin=[Windows.Forms.Padding]::new(4,2,4,3)
$officialCheck=[Windows.Forms.Button]::new(); $officialCheck.Text='环境检查'; $officialCheck.Dock='Fill'; $officialCheck.Height=29; $officialCheck.Margin=[Windows.Forms.Padding]::new(4,2,4,3)
$officialUpdate=[Windows.Forms.Button]::new(); $officialUpdate.Text='官方更新'; $officialUpdate.Dock='Fill'; $officialUpdate.Height=29; $officialUpdate.Margin=[Windows.Forms.Padding]::new(4,2,4,3)
$backupSettings=[Windows.Forms.Button]::new(); $backupSettings.Text='立即备份设置'; $backupSettings.Dock='Fill'; $backupSettings.Height=29; $backupSettings.Margin=[Windows.Forms.Padding]::new(4,2,4,3)
$refreshModels=[Windows.Forms.Button]::new(); $refreshModels.Text='刷新模型列表'; $refreshModels.Dock='Fill'; $refreshModels.Height=29; $refreshModels.Margin=[Windows.Forms.Padding]::new(4,2,4,3)
$updateEngine=[Windows.Forms.Button]::new(); $updateEngine.Text='更新引擎（Qwen）'; $updateEngine.Dock='Fill'; $updateEngine.Height=29; $updateEngine.Margin=[Windows.Forms.Padding]::new(4,2,4,3)
$updateDeepSeekEngine=[Windows.Forms.Button]::new(); $updateDeepSeekEngine.Text='更新引擎（DeepSeek）'; $updateDeepSeekEngine.Dock='Fill'; $updateDeepSeekEngine.Height=29; $updateDeepSeekEngine.Margin=[Windows.Forms.Padding]::new(4,2,4,3)
if (-not $LauncherEnvironment.DeepSeekEngineVersion) { $updateDeepSeekEngine.Enabled=$false; $updateDeepSeekEngine.Text='无 DeepSeek 引擎' }
$officialMonitor=[Windows.Forms.Button]::new(); $officialMonitor.Text='官方实时监控'; $officialMonitor.Dock='Fill'; $officialMonitor.Height=31; $officialMonitor.Margin=[Windows.Forms.Padding]::new(4,5,4,3)
$monitorOverlay=[Windows.Forms.Button]::new(); $monitorOverlay.Text='悬浮监控'; $monitorOverlay.Dock='Fill'; $monitorOverlay.Height=31; $monitorOverlay.Margin=[Windows.Forms.Padding]::new(4,5,4,3)
$benchmark=[Windows.Forms.Button]::new(); $benchmark.Text='批量 Benchmark 与对比报告'; $benchmark.Dock='Fill'; $benchmark.Height=31; $benchmark.Margin=[Windows.Forms.Padding]::new(4,5,4,3)
if ($isDeepSeek) { $benchmark.Enabled=$false; $benchmark.Text='批量 Benchmark（DeepSeek 不适用，请用官方调优/规划预测）' }
[void]$officialToolsLayout.Controls.Add($officialImport,0,1); [void]$officialToolsLayout.Controls.Add($officialStart,1,1); [void]$officialToolsLayout.Controls.Add($officialCheck,2,1); [void]$officialToolsLayout.Controls.Add($backupSettings,3,1)
[void]$officialToolsLayout.Controls.Add($officialUpdate,0,2); [void]$officialToolsLayout.Controls.Add($updateEngine,1,2); [void]$officialToolsLayout.Controls.Add($updateDeepSeekEngine,2,2); [void]$officialToolsLayout.Controls.Add($refreshModels,3,2)
[void]$officialToolsLayout.Controls.Add($officialMonitor,0,3); $officialToolsLayout.SetColumnSpan($officialMonitor,2)
[void]$officialToolsLayout.Controls.Add($monitorOverlay,2,3); $officialToolsLayout.SetColumnSpan($monitorOverlay,2)
[void]$officialToolsLayout.Controls.Add($benchmark,0,4); $officialToolsLayout.SetColumnSpan($benchmark,4)
$officialToolsGroup.Controls.Add($officialToolsLayout)
$layout.RowCount=[Math]::Max($layout.RowCount,$row+1); [void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)); [void]$layout.Controls.Add($officialToolsGroup,0,$row); $layout.SetColumnSpan($officialToolsGroup,3); $row++
$script:Sections[$script:Sections.Count - 1].LastRow = $row - 1

function Refresh-CalibrationPanel {
    if ($isDeepSeek) {
        $calibrationGroup.Text='DeepSeek-V4.1-Flash'
        $calibrationState.Text='官方调优与规划预测'
        $calibrationDetails.Text='“官方调优”运行 tools/dsv41/tune.py（quick）；“规划预测”运行 strata launch --plan，只读显示显卡/RAM 分配与预计速度。'
        return
    }
    if ($isOwnPath) {
        $calibrationGroup.Text='Qwen3.6 独立引擎'
        $calibrationState.Text='不适用 Flash-Next 性能校准'
        $calibrationDetails.Text='MTP、Prefill 和专家显存由官方 setup 配置；启动器会保留这些参数。'
        return
    }
    $contextValue=Context-Value $ctx.SelectedItem
    $record=Calibration-Record $contextValue $vision.Checked
    $detail=Calibration-DetailRecord $contextValue $vision.Checked
    $modelLabel=([string]$selectedConfig.Label -replace '（.*$','').Trim()
    $view=Get-StrataCalibrationView -Config $cfg -ModelLabel $modelLabel -Record $record -Detail $detail -ContextValue $contextValue -WithVision $vision.Checked
    $calibrationGroup.Text=$view.Title
    $calibrationState.Text=$view.Summary
    $calibrationDetails.Text=$view.Details
}
$script:CalibrationDirty = $true
$refreshCalibrationIfVisible = {
    $script:CalibrationDirty = $true
    if ($script:SectionsByKey -and $script:SectionsByKey['tools'].Expanded) {
        Refresh-CalibrationPanel
        $script:CalibrationDirty = $false
    }
}
$ctx.Add_SelectedIndexChanged($refreshCalibrationIfVisible)
$vision.Add_CheckedChanged($refreshCalibrationIfVisible)

$usageControls=@{
    effort=$effort; temperature=$temp; top_p=$topP; top_k=$topK; min_p=$minP
    presence_penalty=$presence; repetition_penalty=$repeat; frequency_penalty=$freq
    penalty_last_n=$lastN; seed=$seedText; max_tokens=$maxOut; reasoning_budget_tokens=$reasonBudget
    budget_mode=$reasonBudgetMode
}
Connect-StrataUsagePresetControls -Selector $preset -Controls $usageControls -Family $generationFamily
$modelSwitch.Add_Click({
    try {
        $picked=$modelConfigs | Where-Object { $_.Label -eq [string]$modelSelector.SelectedItem } | Select-Object -First 1
        if (-not $picked) { throw '没有找到所选模型的配置文件。' }
        $latest=Get-Content -LiteralPath $picked.Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if (@(Get-StrataMissingModelFiles -Config $latest -ConfigPath $picked.Path).Count) {
            throw '所选模型的 GGUF 文件或专家包已缺失。请刷新模型列表。'
        }
        if ([string]::Equals($picked.Path,$ConfigPath,[StringComparison]::OrdinalIgnoreCase)) {
            $status.Text='当前已经是这个模型。'
            return
        }
        $tmp=$SelectionPath + '.tmp'
        [IO.File]::WriteAllText($tmp,$picked.Path + "`r`n",[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $SelectionPath -Force
        $form.Tag=$picked.Path
        $form.Close()
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'模型切换失败','OK','Error') | Out-Null }
})
$buttons = [Windows.Forms.FlowLayoutPanel]::new(); $buttons.Tag='surface'; $buttons.Dock='Fill'; $buttons.FlowDirection='RightToLeft'; $buttons.WrapContents=$false; $buttons.Padding=[Windows.Forms.Padding]::new(18,11,18,8)
$start = [Windows.Forms.Button]::new(); $start.Tag='button:Primary'; $start.Text='▶  保存并启动'; $start.Width=150
$save = [Windows.Forms.Button]::new(); $save.Tag='button:Secondary'; $save.Text='仅保存设置'; $save.Width=130
$stop = [Windows.Forms.Button]::new(); $stop.Tag='button:Danger'; $stop.Text='停止 Strata'; $stop.Width=130
$buttons.Controls.Add($start); $buttons.Controls.Add($save); $buttons.Controls.Add($stop); [void]$rootLayout.Controls.Add($buttons,0,3)
$status = [Windows.Forms.Label]::new(); $status.Tag='muted'; $status.Dock='Fill'; $status.AutoEllipsis=$true; $status.Text='●  配置文件：' + $ConfigPath; $status.Padding=[Windows.Forms.Padding]::new(22,9,18,0); [void]$rootLayout.Controls.Add($status,0,2)
if ($LauncherEnvironment.ModelCatalogStatus -ne 'current-setup') {
    $status.Text += ' · 官方模型目录读取失败，名称使用兼容映射'
    $modelToolTip.SetToolTip($status, [string]$LauncherEnvironment.ModelCatalogError)
}
if ($LauncherEnvironment.UnavailableModels.Count) {
    $status.Text += " · 已隐藏 $($LauncherEnvironment.UnavailableModels.Count) 个模型组件缺失的配置"
}
if ($LauncherEnvironment.EngineWarning) {
    $status.Text += ' · 引擎版本偏旧，旧版仍可启动'
    $modelToolTip.SetToolTip($status, [string]$LauncherEnvironment.EngineWarning)
}
if ($EnginePathRepairs.Count) {
    $status.Text += " · 已修正 $($EnginePathRepairs.Count) 个模型配置的引擎路径"
    $modelToolTip.SetToolTip($status, (($EnginePathRepairs | ForEach-Object { "$($_.Config) → $(Split-Path -Leaf $_.To)" }) -join "`r`n"))
}

$modelSwitch.Tag='button:Secondary'; $calibrate.Tag='button:Secondary'; $benchmark.Tag='button:Accent'
$lanKeyCopy.Tag='button:Secondary'; $lanFirewallAdd.Tag='button:Secondary'; $lanFirewallRemove.Tag='button:Secondary'
foreach ($toolButton in @($officialImport,$officialStart,$officialCheck,$officialUpdate,$updateEngine,$updateDeepSeekEngine,$backupSettings,$refreshModels)) { $toolButton.Tag='button:Secondary' }
Set-StrataLauncherTheme -Root $form -Theme $theme

$UiSectionsPath = Join-Path $LauncherData 'ui-sections.json'
$sectionDefaults = @{model=$true; generation=$false; runtime=$true; gpu_placement=$true; network=$false; gpu_power=$false; tools=$false}
$storedSections = @{}
if (Test-Path -LiteralPath $UiSectionsPath -PathType Leaf) {
    try {
        $savedUiState = Get-Content -LiteralPath $UiSectionsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($savedUiState.schema -eq 1 -and $savedUiState.expanded) {
            foreach ($property in $savedUiState.expanded.PSObject.Properties) {
                if ($property.Value -is [bool]) { $storedSections[$property.Name] = $property.Value }
            }
        }
    } catch { }
}
$script:SectionsByKey = @{}
$script:GpuPowerInitialized = $false
function Save-SectionStates {
    $expanded = [ordered]@{}
    foreach ($entry in $script:Sections) { $expanded[$entry.Key] = [bool]$entry.Expanded }
    Atomic-Json $UiSectionsPath ([pscustomobject]@{schema=1; expanded=$expanded})
}
foreach ($entry in $script:Sections) {
    $script:SectionsByKey[$entry.Key] = $entry
    $entry.Expanded = if ($ExpandAllSections) { $true } elseif ($storedSections.ContainsKey($entry.Key)) { [bool]$storedSections[$entry.Key] } else { [bool]$sectionDefaults[$entry.Key] }
    Set-StrataSectionExpanded -Layout $layout -Header $entry.Header -FirstRow $entry.FirstRow -LastRow $entry.LastRow -Expanded $entry.Expanded
    $toggle = @($entry.Header.Controls.Find('SectionToggle', $false)) | Select-Object -First 1
    $toggle.AccessibleName = $entry.Key
    $toggle.Add_Click({
        param($sender, $eventArgs)
        $current = $script:SectionsByKey[[string]$sender.AccessibleName]
        $expanded = -not $current.Expanded
        Set-StrataSectionExpanded -Layout $layout -Header $current.Header -FirstRow $current.FirstRow -LastRow $current.LastRow -Expanded $expanded
        $current.Expanded = $expanded
        try { Save-SectionStates } catch { $status.Text = '折叠状态未能保存；本次窗口仍可正常使用。' }
        if ($expanded -and $current.Key -eq 'gpu_power' -and -not $script:GpuPowerInitialized) {
            try { Refresh-GpuPowerUi } catch { $gpuPowerInfo.Text = '显卡功率读取失败：' + $_.Exception.Message }
        }
        if ($expanded -and $current.Key -eq 'tools' -and $script:CalibrationDirty) {
            Refresh-CalibrationPanel
            $script:CalibrationDirty = $false
        }
    })
}
if ($script:SectionsByKey['tools'].Expanded) {
    Refresh-CalibrationPanel
    $script:CalibrationDirty = $false
}

$GpuPowerStatePath=Join-Path $LauncherData 'gpu-power-restore.json'
$script:GpuPowerRows=@()
function Update-GpuPowerSelection {
    $index=$gpuSelector.SelectedIndex
    if($index -lt 0 -or $index -ge $script:GpuPowerRows.Count){$gpuPowerWatts.Enabled=$false;$gpuPowerApply.Enabled=$false;$gpuPowerRestore.Enabled=$false;return}
    $gpu=$script:GpuPowerRows[$index]
    $gpuPowerInfo.Text=('{0:0} W 当前 / {1:0} W 默认 / {2:0}–{3:0} W 可设' -f $gpu.Current,$gpu.Default,$gpu.Minimum,$gpu.Maximum)
    $gpuPowerWatts.Minimum=[decimal][Math]::Ceiling($gpu.Minimum)
    $gpuPowerWatts.Maximum=[decimal][Math]::Floor($gpu.Maximum)
    $gpuPowerWatts.Value=[Math]::Min($gpuPowerWatts.Maximum,[Math]::Max($gpuPowerWatts.Minimum,[decimal][Math]::Round($gpu.Current)))
    $gpuPowerWatts.Enabled=$true;$gpuPowerApply.Enabled=$true
    try {
        $record=Get-StrataGpuPowerRestore -Uuid $gpu.Uuid -StatePath $GpuPowerStatePath
        $gpuPowerRestore.Enabled=($null -ne $record -and [Math]::Abs([double]$gpu.Current-[double]$record.last_applied) -le 0.5)
        if($record -and -not $gpuPowerRestore.Enabled){$gpuPowerInfo.Text+='；外部程序已改动，恢复暂不可用'}
    } catch { $gpuPowerRestore.Enabled=$false;$gpuPowerInfo.Text+='；恢复记录无法读取' }
}
function Refresh-GpuPowerUi {
    $previous=if($gpuSelector.SelectedIndex -ge 0 -and $gpuSelector.SelectedIndex -lt $script:GpuPowerRows.Count){$script:GpuPowerRows[$gpuSelector.SelectedIndex].Uuid}else{''}
    $script:GpuPowerRows=@(Get-StrataNvidiaPowerGpus)
    $gpuSelector.Items.Clear()
    foreach($gpu in $script:GpuPowerRows){[void]$gpuSelector.Items.Add("$($gpu.Index) · $($gpu.Name)")}
    if($script:GpuPowerRows.Count){
        $index=0
        for($i=0;$i -lt $script:GpuPowerRows.Count;$i++){if($script:GpuPowerRows[$i].Uuid -eq $previous){$index=$i;break}}
        $gpuSelector.SelectedIndex=$index
        Update-GpuPowerSelection
    } else {
        $gpuPowerInfo.Text='未检测到支持功率上限读写的 NVIDIA 显卡'
        $gpuPowerWatts.Enabled=$false;$gpuPowerApply.Enabled=$false;$gpuPowerRestore.Enabled=$false
    }
    $script:GpuPowerInitialized = $true
}
$gpuSelector.Add_SelectedIndexChanged({Update-GpuPowerSelection})
$gpuPowerRefresh.Add_Click({try{Refresh-GpuPowerUi}catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'刷新显卡失败','OK','Error')|Out-Null}})
$gpuPowerApply.Add_Click({
    try {
        $gpu=$script:GpuPowerRows[$gpuSelector.SelectedIndex]
        $watts=[int]$gpuPowerWatts.Value
        $record=Get-StrataGpuPowerRestore -Uuid $gpu.Uuid -StatePath $GpuPowerStatePath
        $adopt=$false
        if($record -and [Math]::Abs([double]$gpu.Current-[double]$record.last_applied) -gt 0.5){
            $takeover=[Windows.Forms.MessageBox]::Show("检测到其他程序已把功率改为 $($gpu.Current) W。继续将放弃原来记录的 $($record.original) W 恢复基线，改以当前值为新基线。是否继续？",'确认接管外部设置','YesNo','Warning')
            if($takeover -ne [Windows.Forms.DialogResult]::Yes){return}
            $adopt=$true
        }
        $answer=[Windows.Forms.MessageBox]::Show("将 $($gpu.Name) 的系统级功率上限设为 $watts W。此设置影响其他程序，可能需要管理员授权。`r`n`r`n当前为 $($gpu.Current) W；只在这里点击恢复修改前才会恢复。继续吗？",'确认显卡功率','YesNo','Warning')
        if($answer -ne [Windows.Forms.DialogResult]::Yes){return}
        [void](Set-StrataGpuPowerLimit -Uuid $gpu.Uuid -Watts $watts -StatePath $GpuPowerStatePath -AdoptCurrent:$adopt -ExpectedCurrent ([double]$gpu.Current))
        Refresh-GpuPowerUi
        $status.Text="显卡功率已读回确认：$watts W。"
    } catch {Refresh-GpuPowerUi;[Windows.Forms.MessageBox]::Show($_.Exception.Message,'显卡功率设置失败','OK','Error')|Out-Null}
})
$gpuPowerRestore.Add_Click({
    try {
        $gpu=$script:GpuPowerRows[$gpuSelector.SelectedIndex]
        $record=Get-StrataGpuPowerRestore -Uuid $gpu.Uuid -StatePath $GpuPowerStatePath
        $answer=[Windows.Forms.MessageBox]::Show("恢复 $($gpu.Name) 到本启动器修改前的 $($record.original) W？这不是出厂默认值。",'确认恢复功率','YesNo','Question')
        if($answer -ne [Windows.Forms.DialogResult]::Yes){return}
        [void](Restore-StrataGpuPowerLimit -Uuid $gpu.Uuid -StatePath $GpuPowerStatePath)
        Refresh-GpuPowerUi
        $status.Text='显卡功率已恢复并读回确认。'
    } catch {Refresh-GpuPowerUi;[Windows.Forms.MessageBox]::Show($_.Exception.Message,'恢复显卡功率失败','OK','Error')|Out-Null}
})
if ($script:SectionsByKey['gpu_power'].Expanded) {
    try { Refresh-GpuPowerUi } catch { $gpuPowerInfo.Text='显卡功率读取失败：'+$_.Exception.Message }
}

$officialImport.Add_Click({
    try {
        Assert-InstallWritable
        $p=[int]$port.Value
        if (Port-Busy $p) {
            [Windows.Forms.MessageBox]::Show("端口 $p 上的 Strata 正在运行。官方 setup 可能需要检查或更新引擎，请先点击【停止 Strata】，再导入模型。",'请先停止 Strata','OK','Warning') | Out-Null
            return
        }
        $startHere=Join-Path $Root 'START-HERE.bat'
        if (-not (Test-Path -LiteralPath $startHere)) { throw '找不到官方 START-HERE.bat。' }
        $dataDir=''
        if (Test-Path -LiteralPath $OfficialSettingsPath) {
            try { $dataDir=[string]((Get-Content -LiteralPath $OfficialSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json).data_dir) } catch { }
        }
        if (-not $dataDir) { $dataDir=$LauncherEnvironment.DefaultDataDirectory }
        $picker=[Windows.Forms.FolderBrowserDialog]::new()
        $picker.Description='选择只包含一个官方支持模型及其完整 GGUF 分片的目录。'
        $picker.ShowNewFolderButton=$false
        $modelRoot=Join-Path $dataDir 'models'
        if (Test-Path -LiteralPath $modelRoot) { $picker.SelectedPath=$modelRoot }
        if ($picker.ShowDialog($form) -ne [Windows.Forms.DialogResult]::OK) { return }
        $ggufDir=$picker.SelectedPath
        if ($ggufDir -match '[%!]' -or $dataDir -match '[%!]' -or $Root -match '[%!]') { throw '路径包含 % 或 !，官方 cmd 入口无法安全传递。请换一个目录名。' }
        $inspectHelper=Join-Path $LauncherDir 'Strata-LocalModel-Inspect.py'
        if (-not (Test-Path -LiteralPath $inspectHelper -PathType Leaf)) { throw '缺少本地模型检查脚本。请重新安装启动器。' }
        $inspectOutput=(& $Py $inspectHelper $ggufDir 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "本地模型检查失败：$inspectOutput" }
        $detected=$inspectOutput | ConvertFrom-Json
        $answer=[Windows.Forms.MessageBox]::Show("将打开 Strata 官方 setup：`r`n`r`n本地模型目录：$ggufDir`r`n已识别：$($detected.family) / $($detected.model)，$($detected.shards) 个文件预检通过`r`n数据目录：$dataDir`r`n`r`n官方 setup 会再校验模型文件，并可能下载其他必要文件；下载源沿用 Strata 官方默认设置。完成后请重新打开启动器。",'官方导入本地模型','OKCancel','Information')
        if ($answer -ne [Windows.Forms.DialogResult]::OK) { return }
        [void](Backup-OfficialSettings -Snapshot)
        $cmd='call "' + $startHere + '" --setup --family ' + $detected.family + ' --model ' + $detected.model + ' --gguf-dir "' + $ggufDir + '" --data-dir "' + $dataDir + '" --no-start'
        Start-CmdCommand $cmd -KeepOpen
        $status.Text='官方模型导入已启动；完成后重新打开启动器即可看到新模型。'
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'官方导入启动失败','OK','Error') | Out-Null }
})
$officialStart.Add_Click({
    try {
        $p=[int]$port.Value
        if (Port-Busy $p) { [Windows.Forms.MessageBox]::Show("端口 $p 已被占用。请先停止当前 Strata，再使用官方 START-HERE。",'端口占用','OK','Warning') | Out-Null; return }
        $startHere=Join-Path $Root 'START-HERE.bat'
        if (-not (Test-Path -LiteralPath $startHere)) { throw '找不到官方 START-HERE.bat。' }
        [void](Backup-OfficialSettings)
        Start-CmdCommand ('call "' + $startHere + '"') -KeepOpen
        $status.Text='已打开官方 START-HERE；它使用官方设置和官方启动流程。'
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'官方启动失败','OK','Error') | Out-Null }
})
$officialCheck.Add_Click({
    try {
        $startHere=Join-Path $Root 'START-HERE.bat'
        if (-not (Test-Path -LiteralPath $startHere)) { throw '找不到官方 START-HERE.bat。' }
        Start-CmdCommand ('call "' + $startHere + '" --check') -KeepOpen
        $status.Text='官方环境检查已在独立窗口启动。'
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'环境检查启动失败','OK','Error') | Out-Null }
})
$officialUpdate.Add_Click({
    try {
        $p=[int]$port.Value
        if (Port-Busy $p) { [Windows.Forms.MessageBox]::Show("端口 $p 上的 Strata 正在运行。请先停止服务，再执行官方更新。",'请先停止 Strata','OK','Warning') | Out-Null; return }
        $update=Join-Path $LauncherDir 'Strata-Launcher-Update.ps1'
        if (-not (Test-Path -LiteralPath $update)) { throw '找不到启动器更新脚本 Strata-Launcher-Update.ps1。' }
        $answer=[Windows.Forms.MessageBox]::Show("更新器会安全地快进 Strata 源码，再运行官方安装更新。`r`n没有上游分支时只跟随最新稳定 Release；不能快进时会停止，不会覆盖本地改动。`r`n模型文件不会重新下载。`r`n`r`n现在继续吗？",'官方更新','OKCancel','Information')
        if ($answer -ne [Windows.Forms.DialogResult]::OK) { return }
        [void](Backup-OfficialSettings -Snapshot)
        Start-CmdCommand ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $update + '" -StrataRoot "' + $Root + '"') -KeepOpen
        $status.Text='更新窗口已打开；请以窗口末尾的版本校验结果为准。'
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'官方更新启动失败','OK','Error') | Out-Null }
})
$updateEngine.Add_Click({
    try {
        $p=[int]$port.Value
        if (Port-Busy $p) { [Windows.Forms.MessageBox]::Show("端口 $p 上的 Strata 正在运行。请先点击【停止 Strata】，再更新引擎。",'请先停止 Strata','OK','Warning') | Out-Null; return }
        $update=Join-Path $LauncherDir 'Strata-Launcher-Update.ps1'
        if (-not (Test-Path -LiteralPath $update)) { throw '找不到启动器更新脚本 Strata-Launcher-Update.ps1。' }
        $current=[string]$LauncherEnvironment.EngineVersion
        $answer=[Windows.Forms.MessageBox]::Show("从 Strata 官方签名更新源取这台电脑的最新引擎，替换 engine\（Qwen3.6 / Qwen3.8 / Swift 模型使用；DeepSeek 的 engine-dsv41 用旁边的 DeepSeek 按钮）。`r`n`r`n当前引擎：$current`r`n官方更新只在引擎低于兼容下限时才替换，所以平时不会升到最新；这个按钮直接取最新版，需要联网，下载约数百 MB。`r`n`r`n签名、逐文件哈希与试启动都通过后才会替换；旧引擎保留在 engine\.previous，可用官方 setup.py --rollback-engine 回退。模型文件和官方设置不会改动。`r`n`r`n现在继续吗？",'更新 Qwen 引擎','OKCancel','Information')
        if ($answer -ne [Windows.Forms.DialogResult]::OK) { return }
        Start-CmdCommand ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $update + '" -StrataRoot "' + $Root + '" -EngineOnly') -KeepOpen
        $status.Text='引擎更新窗口已打开；完成后重新打开启动器查看引擎版本。'
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'引擎更新启动失败','OK','Error') | Out-Null }
})
$updateDeepSeekEngine.Add_Click({
    try {
        $p=[int]$port.Value
        if (Port-Busy $p) { [Windows.Forms.MessageBox]::Show("端口 $p 上的 Strata 正在运行。请先点击【停止 Strata】，再更新 DeepSeek 引擎。",'请先停止 Strata','OK','Warning') | Out-Null; return }
        if (-not $LauncherEnvironment.DeepSeekEngineVersion) {
            [Windows.Forms.MessageBox]::Show("这个安装没有 DeepSeek 引擎（engine-dsv41 里没有 strata-dsv41.exe），没有可更新的对象。",'没有 DeepSeek 引擎','OK','Information') | Out-Null
            return
        }
        $update=Join-Path $LauncherDir 'Strata-Launcher-Update.ps1'
        if (-not (Test-Path -LiteralPath $update)) { throw '找不到启动器更新脚本 Strata-Launcher-Update.ps1。' }
        $current=[string]$LauncherEnvironment.DeepSeekEngineVersion
        $answer=[Windows.Forms.MessageBox]::Show("从 Strata 官方签名更新源取 DeepSeek 引擎，替换 engine-dsv41（DeepSeek-V4.1-Flash 专用；官方 UPDATE.bat 与 strata update 都不管它）。`r`n`r`n当前 DeepSeek 引擎：$current`r`n走的是官方安装流程末尾同一个升级函数：签名与逐文件哈希校验、只跑一次 strata-dsv41 --version 试启动，通过后才切到新包，旧的一代随后删除（只保留一代）。需要联网，下载约 400 MB。`r`n`r`n模型文件、模型配置和官方设置不会改动。`r`n`r`n现在继续吗？",'更新 DeepSeek 引擎','OKCancel','Information')
        if ($answer -ne [Windows.Forms.DialogResult]::OK) { return }
        Start-CmdCommand ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $update + '" -StrataRoot "' + $Root + '" -DeepSeekEngineOnly') -KeepOpen
        $status.Text='DeepSeek 引擎更新窗口已打开；完成后重新打开启动器查看引擎版本。'
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'DeepSeek 引擎更新启动失败','OK','Error') | Out-Null }
})
$backupSettings.Add_Click({
    try {
        $snapshot=Backup-OfficialSettings -Snapshot
        if (-not $snapshot) { throw "尚未找到官方设置文件：$OfficialSettingsPath" }
        $status.Text='官方设置已备份：' + $snapshot
        [Windows.Forms.MessageBox]::Show("设置备份已保存：`r`n$snapshot",'备份完成','OK','Information') | Out-Null
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'备份失败','OK','Error') | Out-Null }
})
$refreshModels.Add_Click({
    try {
        $fresh=Get-StrataLauncherEnvironment -LauncherDirectory $LauncherDir
        if (-not $fresh.IsReady) { throw $fresh.Message }
        $target=$fresh.ModelConfigs | Where-Object { [string]::Equals($_.Path,$ConfigPath,[StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if (-not $target) { $target=$fresh.ModelConfigs[0] }
        $tmp=$SelectionPath + '.tmp'
        [IO.File]::WriteAllText($tmp,$target.Path + "`r`n",[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $SelectionPath -Force
        $form.Tag=$target.Path
        $form.Close()
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'刷新失败','OK','Error') | Out-Null }
})
$officialMonitor.Add_Click({
    try {
        $p=[int]$port.Value
        $url=Get-StrataMonitorUrl -Port $p -Health (Get-StrataHealth $p)
        if (-not $url) {
            [Windows.Forms.MessageBox]::Show("端口 $p 上没有运行中的 Strata 服务。请先启动 Strata，再打开官方实时监控。",'官方实时监控暂不可用','OK','Information') | Out-Null
            return
        }
        Start-Process -FilePath $url | Out-Null
        $status.Text="已在默认浏览器打开官方实时监控：$url"
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'官方实时监控打开失败','OK','Error') | Out-Null }
})
$monitorOverlay.Add_Click({
    try {
        $overlayPath=Join-Path $LauncherDir 'Strata-Monitor-Overlay.ps1'
        if(-not (Test-Path -LiteralPath $overlayPath -PathType Leaf)){throw '找不到 Strata-Monitor-Overlay.ps1。'}
        $p=[int]$port.Value
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',('"'+$overlayPath+'"'),
            '-StrataRoot',('"'+$Root+'"'),'-Port',[string]$p
        ) -WorkingDirectory $LauncherDir -WindowStyle Hidden | Out-Null
        $status.Text="已打开悬浮监控；服务未运行时会等待，鼠标穿透可从托盘解除。端口：$p"
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'悬浮监控打开失败','OK','Error') | Out-Null }
})
$benchmark.Add_Click({
    try {
        $benchmarkLauncher=Join-Path $LauncherDir 'Benchmark-Launcher.ps1'
        if (-not (Test-Path -LiteralPath $benchmarkLauncher)) { throw '找不到 launcher\Benchmark-Launcher.ps1。' }
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$benchmarkLauncher) -WorkingDirectory $LauncherDir | Out-Null
        $status.Text='已打开批量 Benchmark；测试开始前会检查日常 Strata 是否已停止。'
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Benchmark 打开失败','OK','Error') | Out-Null }
})

function Save-Settings {
    Assert-InstallWritable
    if ($lanAccess.Checked) { [void](Get-StrataLanLaunchSettings -Enabled $true -KeyPath $LanKeyPath) }
    $new = Json-Clone $cfg
    # An engine upgrade can replace the engine's folder while this window is open; never write the stale path back.
    $new = Repair-StrataConfigEnginePath -Config $new -Root $Root
    $a = [Collections.ArrayList]::new(); foreach ($item in $new.args) { [void]$a.Add([string]$item) }
    $contextValue=Context-Value $ctx.SelectedItem
    if ($isDeepSeek) {
        # dsv41 rejects unknown flags, so save only its own arguments and keep the official ones as they are.
        $ssdText = $dsSsd.Text.Trim()
        $deepSeekSave=[pscustomobject]@{
            Context      = $contextValue
            ReserveMib   = $(if ([decimal]$dsReserve.Value -gt 0) { NText $dsReserve } else { '' })
            CpuThreads   = $(if ([decimal]$dsThreads.Value -gt 0) { NText $dsThreads } else { '' })
            Dspark       = [string]$dsDspark.SelectedItem
            DsparkConf   = $dsConf.Text.Trim()
            SsdCache     = $ssdText
            SsdPolicy    = Get-StrataSsdPolicyValue ([string]$dsPolicy.SelectedItem)
            MmapExperts  = Get-StrataMmapValue ([string]$dsMmap.SelectedItem)
            VramExperts  = $(if ([decimal]$dsVram.Value -gt 0) { NText $dsVram } else { '' })
            PrefillChunk = $(if ([decimal]$dsPrefill.Value -gt 0) { NText $dsPrefill } else { '' })
            DsparkBlock  = $(if ([decimal]$dsDblock.Value -gt 0) { NText $dsDblock } else { '' })
            Tp           = $(if ($dsTp.SelectedIndex -le 0) { '' } else { ([string]$dsTp.SelectedItem).Trim() })
            Experts      = $(if ($dsSpeed.SelectedIndex -eq 1) { '5' } elseif ($dsSpeed.SelectedIndex -eq 2) { '6' } else { '' })
            ExpertsSupported = [bool]$script:DsExpertsSupported
        }
        $confValue=[double]0
        if ($deepSeekSave.DsparkConf -and (-not [double]::TryParse($deepSeekSave.DsparkConf,[ref]$confValue) -or $confValue -lt 0 -or $confValue -gt 1)) {
            throw 'DSpark 置信度必须是 0 到 1 之间的数字，或留空以保留官方值。'
        }
        if ($deepSeekSave.SsdCache -eq 'auto') { $deepSeekSave.SsdCache='' }
        $ssdValue=[double]0
        if ($deepSeekSave.SsdCache -and (-not [double]::TryParse($deepSeekSave.SsdCache,[ref]$ssdValue) -or $ssdValue -lt 0)) {
            throw 'SSD 专家缓存必须填 GB 数字，或留空表示自动。'
        }
        if ($ssdValue -gt 1024) { throw 'SSD 专家缓存最多填 1024 GB。' }
        Set-StrataDeepSeekArgs -List $a -Settings $deepSeekSave | Out-Null
        if ($new.vision) { Atomic-Json $visionPath $new.vision; $new.PSObject.Properties.Remove('vision') }
        $new.PSObject.Properties.Remove('parallel')
        $selectedCards=@()
        foreach ($index in $deepSeekCardBoxes.Keys) { if ($deepSeekCardBoxes[$index].Checked) { $selectedCards += [int]$index } }
        if (Test-StrataDeepSeekGpuSelectionChanged -Initial ([int[]]$deepSeekUiInitialCards) -Selected ([int[]]$selectedCards) -AvailableCount $gpuPlacementCards.Count) {
            $new = Set-StrataDeepSeekGpuConfig -Config $new -Cards $gpuPlacementCards -CurrentCards @(Get-StrataNvidiaPlacementCards) -Selected ([int[]]$selectedCards)
        } elseif ($gpuPlacementCards.Count -gt 0 -and $new.PSObject.Properties['gpu_cards']) {
            Assert-StrataGpuPlacementIdentity -Config $new -Cards @(Get-StrataNvidiaPlacementCards)
        }
        $new = Remove-StrataDeepSeekUnsupportedConfig -Config $new
    } elseif ($isOwnPath) {
        $a = [Collections.ArrayList]::new()
        foreach ($item in (Set-StrataNativeContextArgs -ArgsList @($new.args) -MaxContext $contextValue)) { [void]$a.Add([string]$item) }
    } else {
    Set-Arg $a '--max-context' ([string]$contextValue)
    if ($contextValue -gt 262144) {
        $ropeScale=([double]$contextValue / 262144.0).ToString('0.###',[Globalization.CultureInfo]::InvariantCulture)
        Set-Arg $a '--rope-scaling' 'yarn'
        Set-Arg $a '--rope-scale' $ropeScale
    } else {
        Set-Arg $a '--rope-scaling' $null
        Set-Arg $a '--rope-scale' $null
    }
    Set-Arg $a '--kv' $(if([string]$kv.SelectedItem -eq 'fp16'){$null}else{[string]$kv.SelectedItem})
    if ($kvResident.SelectedItem -eq '关闭') { Set-Arg $a '--kv-resident' $null } else { Set-Arg $a '--kv-resident' ([string]$kvResident.SelectedItem) }
    Set-Arg $a '--vram-reserve-mib' $(if([int]$reserve.Value -gt 0){NText $reserve}else{$null})
    if ($vision.Checked) {
        $new | Add-Member -NotePropertyName vision -NotePropertyValue (Get-StrataVisionConfigForSave -Config $new -SidecarPath $visionPath -Root $Root) -Force
        if ($a -notcontains '--vision') { $a.Add('--vision') | Out-Null }
    } else {
        if ($new.vision) { Atomic-Json $visionPath $new.vision; $new.PSObject.Properties.Remove('vision') }
        while ($a.Contains('--vision')) { $a.Remove('--vision') }
    }
    $poolValue=[int]$poolWorkers.Value
    Set-Arg $a '--pool-workers' $(if ($poolValue -gt 0) { [string]$poolValue } else { $null })
    }
    $new.args = @($a); $new.port = [int]$port.Value
    Sync-StrataUserArgsForSave -Config $new -OriginalArgs $initialEngineArgs
    if (-not $isDeepSeek) {
        if($gpuPlacementEdit.Checked){
            $selectedRoles=@{}
            foreach($card in $gpuPlacementCards){$selectedRoles[[int]$card.Index]=([string]$gpuPlacementSelectors[[int]$card.Index].SelectedItem).ToLowerInvariant()}
            $new=Set-StrataGpuPlacementConfig -Config $new -Cards $gpuPlacementCards -CurrentCards @(Get-StrataNvidiaPlacementCards) -Roles $selectedRoles -Build $gpuPlacementBuild
        } else {
            if($new.PSObject.Properties['gpu_cards']){Assert-StrataGpuPlacementIdentity -Config $new -Cards @(Get-StrataNvidiaPlacementCards)}
        }
    }
    if ([int]$parallel.SelectedItem -le 1) { $new.PSObject.Properties.Remove('parallel') } else { $new | Add-Member -NotePropertyName parallel -NotePropertyValue ([int]$parallel.SelectedItem) -Force }
    $selectedPreset=[string]$preset.SelectedItem
    $sampling=[pscustomobject]@{temperature=[double](NText $temp);top_p=[double](NText $topP);top_k=[int]$topK.Value;min_p=[double](NText $minP);presence_penalty=[double](NText $presence);repetition_penalty=[double](NText $repeat);frequency_penalty=[double](NText $freq);penalty_last_n=[int]$lastN.Value}
    $savedSampling=Get-StrataSamplingForSave -Existing $new.sampling -Family $generationFamily -PresetName $selectedPreset -Edited $sampling -SeedText $seedText.Text
    if(@($savedSampling.PSObject.Properties).Count -gt 0){$new | Add-Member -NotePropertyName sampling -NotePropertyValue $savedSampling -Force}else{$new.PSObject.Properties.Remove('sampling')}
    $effortValue=Get-StrataReasoningEffortValue -Family $generationFamily -Choice ([string]$effort.SelectedItem)
    $budgetValue=Get-StrataReasoningBudgetValue -Mode ([string]$reasonBudgetMode.SelectedItem) -Value ([int]$reasonBudget.Value)
    if($selectedPreset -eq '官方默认'){$new.PSObject.Properties.Remove('reasoning_effort');$new.PSObject.Properties.Remove('reasoning_budget_tokens')}
    else{
        $new | Add-Member -NotePropertyName reasoning_effort -NotePropertyValue $effortValue -Force
        if($null -ne $budgetValue){$new | Add-Member -NotePropertyName reasoning_budget_tokens -NotePropertyValue $budgetValue -Force}else{$new.PSObject.Properties.Remove('reasoning_budget_tokens')}
    }
    Backup-Once $ConfigPath; Atomic-Json $ConfigPath $new
    $s=[ordered]@{}
    if($sharedDefaults.Checked -and $selectedPreset -ne '官方默认'){
        $s.reasoning_effort=$effortValue
        if($null -ne $new.sampling){foreach($key in @('temperature','top_p','top_k')){if($null -ne $new.sampling.PSObject.Properties[$key]){$s[$key]=$new.sampling.$key}}}
        if($null -ne $budgetValue){$s.reasoning_budget_tokens=$budgetValue}
        if([int]$maxOut.Value -gt 0){$s.max_tokens=[int]$maxOut.Value}
        if($seedText.Text.Trim() -and $null -ne $new.sampling.seed){$s.seed=[long]$new.sampling.seed}
    }
    if (Test-Path -LiteralPath $sharedPath) { Backup-Once $sharedPath }; Atomic-Json $sharedPath (Merge-StrataSharedDefaults -Existing $shared -Edited ([pscustomobject]$s))
    Set-StrataLanMode -Path $LanModePath -Enabled ([bool]$lanAccess.Checked)
    return $new
}
$save.Add_Click({ try { [void](Save-Settings); $summary=Context-Summary (Context-Value $ctx.SelectedItem); $lanNotice=if($lanAccess.Checked){'局域网访问将在下次启动时生效；如需远程连接，还要单独确认防火墙放行。'}else{'局域网访问已关闭；下次启动只监听本机。若曾创建防火墙规则，可点击撤销放行。'}; $status.Text="设置已保存：$summary。"; [Windows.Forms.MessageBox]::Show("Strata 设置已保存。`r`n$summary`r`n$lanNotice",'完成','OK','Information') | Out-Null } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'保存失败','OK','Error') | Out-Null } })
$lanKeyCopy.Add_Click({
    try {
        if (-not $lanAccess.Checked) { throw '请先勾选局域网访问。' }
        $network=Get-StrataLanLaunchSettings -Enabled $true -KeyPath $LanKeyPath
        [Windows.Forms.Clipboard]::SetText($network.ApiKey)
        $status.Text='API key 已复制到剪贴板；仅粘贴到可信设备的 Strata 客户端。'
        [Windows.Forms.MessageBox]::Show('API key 已复制。远端网页在 About > Settings 中填写；API 客户端作为 Bearer key 使用。剪贴板中的密钥请勿分享给无关人员。','局域网访问密钥','OK','Information') | Out-Null
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'复制密钥失败','OK','Error') | Out-Null }
})
$lanFirewallAdd.Add_Click({
    try {
        if (-not $lanAccess.Checked) { throw '请先勾选局域网访问。' }
        if (-not (Test-Path -LiteralPath $LanFirewallEntry -PathType Leaf)) { throw "缺少防火墙辅助脚本：$LanFirewallEntry" }
        $p=[int]$port.Value
        $runtimeProgram=Resolve-StrataLanFirewallProgram -VenvPythonPath $Py
        $spec=Get-StrataLanFirewallSpec -Port $p -PythonPath $runtimeProgram
        $answer=[Windows.Forms.MessageBox]::Show("将请求 Windows 管理员授权，创建入站规则：`r`n程序：$($spec.Program)`r`n端口：$p / TCP`r`n网络：仅专用网络`r`n来源：仅本地子网`r`n`r`n不会开放公网；当前网络若设为公用网络，此规则不会生效。确认继续？",'确认放行局域网','OKCancel','Warning')
        if ($answer -ne [Windows.Forms.DialogResult]::OK) { return }
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $LanFirewallEntry + '"'),'-Action','Add','-Port',([string]$p),'-PythonPath',('"' + $runtimeProgram + '"'))
        $result=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
        if ($result.ExitCode -ne 0) { throw "防火墙放行未完成（退出码 $($result.ExitCode)）；没有将其标记为成功。" }
        $status.Text="已放行专用网络本地子网访问端口 $p；请从另一设备测试。"
        [Windows.Forms.MessageBox]::Show($status.Text,'防火墙规则已创建','OK','Information') | Out-Null
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'防火墙放行失败','OK','Error') | Out-Null }
})
$lanFirewallRemove.Add_Click({
    try {
        if (-not (Test-Path -LiteralPath $LanFirewallEntry -PathType Leaf)) { throw "缺少防火墙辅助脚本：$LanFirewallEntry" }
        $p=[int]$port.Value
        $runtimeProgram=Resolve-StrataLanFirewallProgram -VenvPythonPath $Py
        $spec=Get-StrataLanFirewallSpec -Port $p -PythonPath $runtimeProgram
        $answer=[Windows.Forms.MessageBox]::Show("仅撤销本启动器创建的端口 $p 规则（$($spec.Name)），不会删除其他防火墙规则。确认继续？",'确认撤销放行','OKCancel','Question')
        if ($answer -ne [Windows.Forms.DialogResult]::OK) { return }
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $LanFirewallEntry + '"'),'-Action','Remove','-Port',([string]$p),'-PythonPath',('"' + $runtimeProgram + '"'))
        $result=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
        if ($result.ExitCode -ne 0) { throw "防火墙规则撤销未完成（退出码 $($result.ExitCode)）。" }
        $status.Text="端口 $p 的启动器局域网规则已撤销（若原本存在）。"
        [Windows.Forms.MessageBox]::Show($status.Text,'防火墙规则已处理','OK','Information') | Out-Null
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'撤销放行失败','OK','Error') | Out-Null }
})
$calibrate.Add_Click({
    try {
        if ($isDeepSeek) {
            $p=[int]$port.Value
            if (Port-Busy $p) { [Windows.Forms.MessageBox]::Show("端口 $p 上的 Strata 正在运行。官方调优需要独占显卡，请先点击【停止 Strata】，再运行调优。",'无法调优','OK','Warning') | Out-Null; return }
            [void](Save-Settings)
            if (-not (Test-Path -LiteralPath $Py)) { throw '找不到 Strata 私有 Python 环境，无法运行官方调优。' }
            $tuner=Join-Path $Root 'tools\dsv41\tune.py'
            if (-not (Test-Path -LiteralPath $tuner -PathType Leaf)) { throw '找不到官方 DeepSeek 调优器 tools\dsv41\tune.py；请先运行官方更新。' }
            $cmd='"' + $Py + '" "' + $tuner + '" --config "' + $ConfigPath + '" --mode quick'
            Start-CmdCommand $cmd -KeepOpen
            $status.Text='DeepSeek 官方调优已在独立窗口启动；通常需要 5–10 分钟。'
            [Windows.Forms.MessageBox]::Show("已保存当前设置并启动官方 DeepSeek 调优（quick）。`r`n`r`n它会多次起停引擎、只保留收益超过 5% 的设置，结果写入当前配置。完成后关闭调优窗口，再重新打开启动器。",'官方调优','OK','Information') | Out-Null
            $form.Close()
            return
        }
        $p=[int]$port.Value
        if (Port-Busy $p) { [Windows.Forms.MessageBox]::Show("端口 $p 上的 Strata 正在运行。性能校准需要独占显卡，请先点击【停止 Strata】，再运行校准。",'无法校准','OK','Warning') | Out-Null; return }
        [void](Save-Settings)
        if (-not (Test-Path -LiteralPath $Py)) { throw '找不到 Strata 私有 Python 环境，无法运行校准。' }
        $calibrationHelper=Join-Path $LauncherDir 'Strata-Calibrate-Current.py'
        if (-not (Test-Path -LiteralPath $calibrationHelper)) { throw '找不到 launcher\Strata-Calibrate-Current.py，无法运行官方校准。' }
        $cmd='"' + $Py + '" "' + $calibrationHelper + '" "' + $ConfigPath + '"'
        Start-CmdCommand $cmd -KeepOpen
        $status.Text='官方性能校准已在独立窗口启动；通常需要 5–10 分钟。'
        [Windows.Forms.MessageBox]::Show("已保存当前设置并启动 Strata 官方性能校准。`r`n`r`n校准只使用本地文件，不下载或更新程序。它会多次加载模型，电脑可能暂时变慢。完成后关闭校准窗口，再重新打开启动器。",'性能校准','OK','Information') | Out-Null
        $form.Close()
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'校准启动失败','OK','Error') | Out-Null }
})
if ($isDeepSeek) {
    $planPredict.Add_Click({
        try {
            $dataDir=''
            if (Test-Path -LiteralPath $OfficialSettingsPath) {
                try { $dataDir=[string]((Get-Content -LiteralPath $OfficialSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json).data_dir) } catch { }
            }
            if (-not $dataDir) { $dataDir=$LauncherEnvironment.DefaultDataDirectory }
            if (-not (Test-Path -LiteralPath $Py)) { throw '找不到 Strata 私有 Python 环境，无法运行官方规划预测。' }
            $strataPy=Join-Path $Root 'strata.py'
            if (-not (Test-Path -LiteralPath $strataPy -PathType Leaf)) { throw '找不到官方 strata.py；请先运行官方更新。' }
            $modelKey=Get-StrataDeepSeekModelKey $ConfigPath
            if (-not $modelKey) { throw '无法从配置文件名推断 DeepSeek 模型规格；请直接运行：strata launch --model <规格> --plan' }
            $cmd='"' + $Py + '" "' + $strataPy + '" launch --model ' + $modelKey + ' --family deepseek41 --data-dir "' + $dataDir + '" --plan'
            Start-CmdCommand $cmd -KeepOpen
            $status.Text='已在独立窗口运行官方规划预测（只读，不改变任何设置）。'
        } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'规划预测失败','OK','Error') | Out-Null }
    })
}
$stop.Add_Click({
    try {
        $p=[int]$port.Value
        $target=Find-StrataServer $p
        if (-not $target) {
            $detail=if($script:StopLookupDetail){"`r`n`r`n诊断：`r`n$script:StopLookupDetail"}else{''}
            [Windows.Forms.MessageBox]::Show("没有找到可安全结束的 Strata 进程树。没有结束任何进程。$detail",'未找到 Strata 服务','OK','Information') | Out-Null
            return
        }
        $engineText=if ($target.EngineIds.Count) { '模型引擎 PID：' + ($target.EngineIds -join ', ') } else { '模型引擎当前未加载（lazy/unloaded）' }
        $shellText=if ($target.ShellId) { "会同时关闭 Strata 的 cmd 控制台（PID $($target.ShellId)）。" } else { '没有关联的 cmd 控制台。' }
        $pythonText=if($target.ProcessId){"Python PID $($target.ProcessId)"}else{'Python 服务未出现在父链中，按 Strata 专属 cmd 控制台识别'}
        $answer=[Windows.Forms.MessageBox]::Show("确认停止 Strata 服务及整个关联进程树？`r`n$pythonText`r`n$engineText`r`n根进程 PID：$($target.StopId)`r`n$($target.Executable)`r`n$shellText`r`n`r`n正在生成的回答会中断。",'停止 Strata','YesNo','Warning')
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
        if ($target.ProcessId) {
            $checkName=[StrataProcessTree]::ProcessName([int]$target.ProcessId)
            $checkExe=[StrataProcessTree]::FullProcessImageName([int]$target.ProcessId)
            if ($checkName -notmatch '^python(w)?\.exe$' -or -not $checkExe -or
                -not [string]::Equals([IO.Path]::GetFullPath($checkExe),[IO.Path]::GetFullPath($target.Executable),[StringComparison]::OrdinalIgnoreCase)) {
                throw 'Python 服务进程在确认期间发生变化；为避免结束错误进程，本次已取消。'
            }
        }
        foreach ($engineId in $target.EngineIds) {
            try {
                $engineImage=[StrataProcessTree]::FullProcessImageName([int]$engineId)
                $belongs=if($target.ShellId){Test-ProcessDescendant $engineId $target.ShellId}else{Test-ProcessDescendant $engineId $target.ProcessId}
                $knownImage=$false
                if ($engineImage) {
                    foreach ($candidate in @(Get-StrataEnginePaths)) {
                        if ([string]::Equals([IO.Path]::GetFullPath($engineImage),[IO.Path]::GetFullPath($candidate),[StringComparison]::OrdinalIgnoreCase)) { $knownImage=$true; break }
                    }
                }
                if (-not $engineImage -or -not $knownImage -or -not $belongs) { throw 'engine process changed' }
            } catch { throw '模型引擎进程在确认期间发生变化；为避免结束错误进程，本次已取消。' }
        }
        if (-not $target.EngineIds.Count) {
            $healthAgain=Get-StrataHealth $p
            if (-not $healthAgain -or $healthAgain.model -ne $target.Model) { throw 'Strata 服务身份在确认期间发生变化；为避免结束错误进程，本次已取消。' }
        }
        if ($target.ShellId) {
            $shellName=[StrataProcessTree]::ProcessName([int]$target.ShellId)
            if ($shellName -ine 'cmd.exe') {
                throw 'Strata cmd 控制台进程在确认期间发生变化；为避免结束错误进程，本次已取消。'
            }
        }
        $taskkill=Join-Path $env:SystemRoot 'System32\taskkill.exe'
        $result=Start-Process -FilePath $taskkill -ArgumentList @('/PID',([string]$target.StopId),'/T','/F') -Wait -PassThru -NoNewWindow
        $stoppedEarly=$false
        if ($result.ExitCode -ne 0) {
            # taskkill 128：根进程在确认期间已自行退出（例如 Strata 已停止）。只有子进程也都不在时才按“已停止”处理。
            $survivors=@()
            if ($target.ProcessId -and [StrataProcessTree]::ProcessName([int]$target.ProcessId)) { $survivors += [int]$target.ProcessId }
            foreach ($engineId in $target.EngineIds) { if ([StrataProcessTree]::ProcessName([int]$engineId)) { $survivors += [int]$engineId } }
            if ($survivors.Count) {
                throw "taskkill 退出码 $($result.ExitCode)：根进程已不存在，但仍有 Strata 子进程在运行（PID $($survivors -join ', ')）。请用任务管理器结束它们。"
            }
            $stoppedEarly=$true
        }
        $deadline=[DateTime]::UtcNow.AddSeconds(15)
        while ((Port-Busy $p) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 500 }
        if (Port-Busy $p) { $status.Text="Strata 进程树已结束，但端口 $p 仍被占用；没有触碰占用者。" }
        else {
            if (Test-Path -LiteralPath $PidPath) { Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue }
            $status.Text=if ($stoppedEarly) { "Strata 在确认时已自行退出（无需停止）；端口 $p 已释放。" } else { 'Strata 服务及模型引擎已停止。现在可以保存并启动新配置。' }
        }
        [Windows.Forms.MessageBox]::Show($status.Text,'停止结果','OK','Information') | Out-Null
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'停止失败','OK','Error') | Out-Null }
})
$start.Add_Click({
    try {
        $p=[int]$port.Value
        if (Port-Busy $p) { [Windows.Forms.MessageBox]::Show("端口 $p 已被占用。为避免关闭或覆盖正在运行的服务，本次没有启动。请先确认占用程序后再试。",'端口占用','OK','Warning') | Out-Null; return }
        $latest=Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (@(Get-StrataMissingModelFiles -Config $latest -ConfigPath $ConfigPath).Count) {
            throw '当前模型的 GGUF 文件或专家包已缺失。请刷新模型列表。'
        }
        $new=Save-Settings
        if (-not (Test-Path -LiteralPath $Py) -or -not (Test-Path -LiteralPath $Server)) { throw '找不到 Strata Python 环境或 server.py。' }
        $network=Get-StrataLanLaunchSettings -Enabled ([bool]$lanAccess.Checked) -KeyPath $LanKeyPath
        $cmd=Get-StrataLanStartCommand -PythonPath $Py -ServerPath $Server -ConfigPath $ConfigPath -Port $p -HostAddress $network.Host
        $launched=if($lanAccess.Checked){Invoke-StrataLanWithKey -ApiKey $network.ApiKey -Start { Start-CmdCommand $cmd -PassThru }}else{Start-CmdCommand $cmd -PassThru}
        Atomic-Json $PidPath ([pscustomobject]@{ root_pid=$launched.Id; python_pid=0; port=$p; config=$ConfigPath; lan_enabled=[bool]$lanAccess.Checked; started_at=[DateTime]::UtcNow.ToString('o') })
        $status.Text=if($lanAccess.Checked){'正在以局域网模式启动 Strata；API key 已启用。请确认防火墙规则，并从另一设备验证连接。'}else{'正在启动仅本机 Strata，日志窗口已打开。'}
        if ($openBrowser.Checked) {
            $timer=[Windows.Forms.Timer]::new(); $timer.Interval=3000
            $timer.Tag=[pscustomobject]@{ Port=$p; Tries=0; LanEnabled=[bool]$lanAccess.Checked; LanAddresses=@($lanIPs) }
            $timer.Add_Tick({
                param($sender,$eventArgs)
                $state=$sender.Tag; $state.Tries++
                if (Port-Busy $state.Port) {
                    $sender.Stop(); $sender.Dispose()
                    Start-Process "http://127.0.0.1:$($state.Port)"
                    $status.Text=if($state.LanEnabled){"Strata 本机已响应；局域网候选地址：$((@($state.LanAddresses | ForEach-Object { "http://${_}:$($state.Port)" })) -join '  ')。请从另一设备验证。"}else{"Strata 已响应：http://127.0.0.1:$($state.Port)"}
                } elseif ($state.Tries -ge 120) {
                    $sender.Stop(); $sender.Dispose()
                    $status.Text='等待超时；请检查启动日志窗口。'
                }
            })
            $timer.Start()
        }
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'启动失败','OK','Error') | Out-Null }
})
$layout.ResumeLayout($true)
$rootLayout.ResumeLayout($true)
$form.ResumeLayout($true)
[void]$form.ShowDialog()
$nextConfig=[string]$form.Tag
$form.Dispose()
if ($nextConfig) {
    Invoke-StrataLauncherReload -LauncherPath $LauncherPath -ConfigPath $nextConfig
}
