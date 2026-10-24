$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class StrataGpuPlacementUiProbe {
    public delegate bool EnumProc(IntPtr handle, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr state);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr handle, StringBuilder text, int capacity);

    public static bool HasText(int pid, string fragment) {
        bool found = false;
        EnumWindows((top, unused) => {
            uint owner;
            GetWindowThreadProcessId(top, out owner);
            if (owner != pid) return true;
            EnumChildWindows(top, (child, nested) => {
                var text = new StringBuilder(512);
                GetWindowText(child, text, text.Capacity);
                if (text.ToString().IndexOf(fragment, StringComparison.OrdinalIgnoreCase) >= 0) {
                    found = true;
                    return false;
                }
                return true;
            }, IntPtr.Zero);
            return !found;
        }, IntPtr.Zero);
        return found;
    }
}
'@

$launcherRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$launcher = Join-Path $launcherRoot 'Strata-Launcher.ps1'
. (Join-Path $launcherRoot 'Strata-Launcher-GpuPlacement.ps1')
$cards = @(Get-StrataNvidiaPlacementCards)
$card0 = @($cards | Where-Object Index -EQ 0 | Select-Object -First 1)
$card1 = @($cards | Where-Object Index -EQ 1 | Select-Object -First 1)
if (-not $card0.Count -or -not $card1.Count) { throw 'UI smoke check requires NVIDIA GPU 0 and GPU 1' }
$card0Location = Convert-StrataGpuPciBusIdToWindowsLocation ([string]$card0[0].BusId)
$card1Location = Convert-StrataGpuPciBusIdToWindowsLocation ([string]$card1[0].BusId)
if (-not $card0Location -or -not $card1Location) { throw 'UI smoke check requires valid PCI locations' }
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$process = Start-Process -FilePath $powershell -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',('"' + $launcher + '"')
) -WorkingDirectory $launcherRoot -WindowStyle Hidden -PassThru
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 250
        $process.Refresh()
        $hasPlacement = [StrataGpuPlacementUiProbe]::HasText($process.Id,'GPU PLACEMENT')
        $hasEdit = [StrataGpuPlacementUiProbe]::HasText($process.Id,'修改当前模型的推理显卡分配')
        $hasCard0 = [StrataGpuPlacementUiProbe]::HasText($process.Id,"GPU 0 · 总线 $($card0Location.Bus)")
        $hasCard1 = [StrataGpuPlacementUiProbe]::HasText($process.Id,"GPU 1 · 总线 $($card1Location.Bus)")
        $hasCard0Location = [StrataGpuPlacementUiProbe]::HasText($process.Id,$card0Location.Text)
        $hasCard1Location = [StrataGpuPlacementUiProbe]::HasText($process.Id,$card1Location.Text)
    } while (-not $process.HasExited -and (-not $hasPlacement -or -not $hasEdit -or -not $hasCard0 -or -not $hasCard1 -or -not $hasCard0Location -or -not $hasCard1Location) -and [DateTime]::UtcNow -lt $deadline)
    if ($process.HasExited) { throw "Launcher exited before showing GPU placement controls: $($process.ExitCode)" }
    if (-not $hasPlacement -or -not $hasEdit -or -not $hasCard0 -or -not $hasCard1 -or -not $hasCard0Location -or -not $hasCard1Location) {
        throw "Launcher did not show both GPU role controls and Windows PCI locations: section=$hasPlacement edit=$hasEdit card0=$hasCard0 card1=$hasCard1 location0=$hasCard0Location location1=$hasCard1Location"
    }
    'PASS: launcher UI shows two detected GPUs and explicit placement edit control'
} finally {
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        [void]$process.WaitForExit(5000)
    }
}
