$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class BenchmarkModelListProbe {
    public delegate bool EnumProc(IntPtr handle, IntPtr state);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumProc callback, IntPtr state);

    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr state);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr handle, StringBuilder value, int capacity);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr handle, StringBuilder value, int capacity);

    [StructLayout(LayoutKind.Sequential)]
    private struct WindowRect { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr handle, out WindowRect rect);

    [DllImport("user32.dll")]
    private static extern bool MoveWindow(IntPtr handle, int x, int y, int width, int height, bool repaint);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr handle, uint message, IntPtr wParam, IntPtr lParam);

    public static int ItemCount(int processId) {
        int result = -1;
        EnumWindows((top, unused) => {
            uint owner;
            GetWindowThreadProcessId(top, out owner);
            if (owner != processId) return true;
            EnumChildWindows(top, (child, nested) => {
                var className = new StringBuilder(256);
                GetClassName(child, className, className.Capacity);
                if (className.ToString().Contains("LISTBOX")) {
                    result = (int)SendMessage(child, 0x018B, IntPtr.Zero, IntPtr.Zero).ToInt64();
                    return false;
                }
                return true;
            }, IntPtr.Zero);
            return result < 0;
        }, IntPtr.Zero);
        return result;
    }

    public static int ContextChoiceCount(int processId) {
        int result = 0;
        EnumWindows((top, unused) => {
            uint owner;
            GetWindowThreadProcessId(top, out owner);
            if (owner != processId) return true;
            EnumChildWindows(top, (child, nested) => {
                var className = new StringBuilder(256);
                GetClassName(child, className, className.Capacity);
                if (!className.ToString().Contains("BUTTON")) return true;
                var text = new StringBuilder(256);
                GetWindowText(child, text, text.Capacity);
                if (text.ToString() == "4K" || text.ToString() == "32K" ||
                    text.ToString() == "128K" || text.ToString() == "256K") result++;
                return true;
            }, IntPtr.Zero);
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public static int ComboChoiceCount(int processId, int expectedChoices) {
        int matches = 0;
        EnumWindows((top, unused) => {
            uint owner;
            GetWindowThreadProcessId(top, out owner);
            if (owner != processId) return true;
            EnumChildWindows(top, (child, nested) => {
                var className = new StringBuilder(256);
                GetClassName(child, className, className.Capacity);
                if (!className.ToString().Contains("COMBOBOX")) return true;
                if ((int)SendMessage(child, 0x0146, IntPtr.Zero, IntPtr.Zero).ToInt64() == expectedChoices) matches++;
                return true;
            }, IntPtr.Zero);
            return true;
        }, IntPtr.Zero);
        return matches;
    }

    public static bool HasLabel(int processId, string expected) {
        bool found = false;
        EnumWindows((top, unused) => {
            uint owner;
            GetWindowThreadProcessId(top, out owner);
            if (owner != processId) return true;
            EnumChildWindows(top, (child, nested) => {
                var text = new StringBuilder(256);
                GetWindowText(child, text, text.Capacity);
                if (text.ToString() == expected) { found = true; return false; }
                return true;
            }, IntPtr.Zero);
            return !found;
        }, IntPtr.Zero);
        return found;
    }

    public static int LabelTop(int processId, string expected) {
        int result = -1;
        EnumWindows((top, unused) => {
            uint owner;
            GetWindowThreadProcessId(top, out owner);
            if (owner != processId) return true;
            EnumChildWindows(top, (child, nested) => {
                var value = new StringBuilder(256);
                GetWindowText(child, value, value.Capacity);
                if (value.ToString() != expected) return true;
                WindowRect rect;
                if (GetWindowRect(child, out rect)) result = rect.Top;
                return false;
            }, IntPtr.Zero);
            return result < 0;
        }, IntPtr.Zero);
        return result;
    }

    public static bool ResizeMainWindow(int processId, int width, int height) {
        bool resized = false;
        EnumWindows((top, unused) => {
            uint owner;
            GetWindowThreadProcessId(top, out owner);
            if (owner != processId) return true;
            var title = new StringBuilder(256);
            GetWindowText(top, title, title.Capacity);
            if (!title.ToString().StartsWith("Strata 批量 Benchmark")) return true;
            WindowRect rect;
            if (GetWindowRect(top, out rect)) resized = MoveWindow(top, rect.Left, rect.Top, width, height, true);
            return false;
        }, IntPtr.Zero);
        return resized;
    }
}
'@

$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$launcher = (Resolve-Path 'launcher\Benchmark-Launcher.ps1').Path
$workingDirectory = (Resolve-Path 'launcher').Path
$root = Split-Path -Parent $workingDirectory
$expectedModelCount = @(Get-ChildItem -LiteralPath $root -Filter 'strata-*.json' -File | Where-Object {
    if ($_.Name -like '*.shared-settings.json') { return $false }
    try {
        $config = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        return [bool]($config.exe -and $config.args -is [array] -and $config.model_name)
    } catch { return $false }
}).Count
if ($expectedModelCount -lt 1) { throw 'FAIL: no valid model configuration found for UI verification' }
$process = Start-Process -FilePath $powershell -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',('"' + $launcher + '"')
) -WorkingDirectory $workingDirectory -PassThru

try {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 250
        $process.Refresh()
        $itemCount = [BenchmarkModelListProbe]::ItemCount($process.Id)
        $contextCount = [BenchmarkModelListProbe]::ContextChoiceCount($process.Id)
        $hasCap = [BenchmarkModelListProbe]::HasLabel($process.Id, '512K（实验）')
        $hasSweep = [BenchmarkModelListProbe]::HasLabel($process.Id, '多档上限测试')
    } while (-not $process.HasExited -and ($itemCount -lt 0 -or $contextCount -lt 7 -or -not $hasCap -or -not $hasSweep) -and [DateTime]::UtcNow -lt $deadline)

    if ($process.HasExited) { throw "FAIL: benchmark launcher exited early with code $($process.ExitCode)" }
    if ($itemCount -ne $expectedModelCount) { throw "FAIL: model selector shows $itemCount row(s), expected $expectedModelCount independently selectable rows" }
    if ($contextCount -ne 7) { throw "FAIL: expected four input selectors plus three matching model-cap labels; got $contextCount" }
    foreach($label in @('32K','64K','128K','256K','384K（实验）','512K（实验）')) {
        if (-not [BenchmarkModelListProbe]::HasLabel($process.Id, $label)) { throw "FAIL: missing selectable context cap $label" }
    }
    if (-not $hasSweep) { throw 'FAIL: per-tier full benchmark switch is missing' }
    if (-not [BenchmarkModelListProbe]::HasLabel($process.Id, '模型上限')) { throw 'FAIL: model context cap control is not clearly labeled' }
    if (-not [BenchmarkModelListProbe]::HasLabel($process.Id, '输入长度')) { throw 'FAIL: prompt length control is not clearly labeled' }
    if (-not [BenchmarkModelListProbe]::HasLabel($process.Id, '最大并发')) { throw 'FAIL: benchmark launcher does not show the max concurrency control' }
    if (-not [BenchmarkModelListProbe]::HasLabel($process.Id, '测试说明')) { throw 'FAIL: benchmark notes section is missing' }
    if (-not [BenchmarkModelListProbe]::ResizeMainWindow($process.Id, 760, 620)) { throw 'FAIL: could not verify layout at minimum window size' }
    Start-Sleep -Milliseconds 250
    $rows = @(
        @('预设','轮数','专用端口'),
        @('模型上限','512K（实验）'),
        @('多档上限测试','最大并发'),
        @('输入长度','4K')
    )
    $previousTop = -1
    foreach ($row in $rows) {
        $tops = @($row | ForEach-Object { [BenchmarkModelListProbe]::LabelTop($process.Id, $_) })
        if (@($tops | Where-Object { $_ -lt 0 }).Count) { throw "FAIL: layout label missing in row $($row -join ', ')" }
        $minTop = ($tops | Measure-Object -Minimum).Minimum
        $maxTop = ($tops | Measure-Object -Maximum).Maximum
        if ($maxTop - $minTop -gt 16) { throw "FAIL: test scale row wrapped out of order: $($row -join ', ')" }
        if ($minTop -le $previousTop) { throw "FAIL: test scale rows are out of order: $($row -join ', ')" }
        $previousTop = $minTop
    }
    "PASS: benchmark UI shows $expectedModelCount models and test scale controls in four stable rows"
} finally {
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        [void]$process.WaitForExit(5000)
    }
}
