$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class StrataMonitorLaunchUiProbe {
    public delegate bool EnumProc(IntPtr handle, IntPtr state);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr state);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr state);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr handle, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr handle, StringBuilder text, int capacity);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr handle);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr handle, uint message, IntPtr wparam, IntPtr lparam);
    public static IntPtr[] VisibleWindows(string title, int processId) {
        var windows=new List<IntPtr>();
        EnumWindows((window,unused) => {
            uint owner; GetWindowThreadProcessId(window,out owner);
            if(processId != 0 && owner != processId) return true;
            if(!IsWindowVisible(window)) return true;
            var text=new StringBuilder(256); GetWindowText(window,text,text.Capacity);
            if(text.ToString().Contains(title)) windows.Add(window);
            return true;
        },IntPtr.Zero);
        return windows.ToArray();
    }
    public static IntPtr Child(IntPtr parent, string textFragment) {
        IntPtr found=IntPtr.Zero;
        EnumChildWindows(parent,(child,unused) => {
            var text=new StringBuilder(512); GetWindowText(child,text,text.Capacity);
            if(text.ToString().Contains(textFragment)) { found=child; return false; }
            return true;
        },IntPtr.Zero);
        return found;
    }
    public static void Click(IntPtr handle) { SendMessage(handle,0x00F5,IntPtr.Zero,IntPtr.Zero); }
    public static int ProcessId(IntPtr handle) { uint pid; GetWindowThreadProcessId(handle,out pid); return (int)pid; }
}
'@

$launcherRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$launcher=Join-Path $launcherRoot 'Strata-Launcher.ps1'
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$existing=@([StrataMonitorLaunchUiProbe]::VisibleWindows('Strata Monitor',0))
$launcherProcess=Start-Process -FilePath $powershell -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',('"'+$launcher+'"'),'-ExpandAllSections'
) -WorkingDirectory $launcherRoot -PassThru
$overlayPid=0
try {
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    $button=[IntPtr]::Zero
    do {
        Start-Sleep -Milliseconds 250
        $launcherProcess.Refresh()
        if($launcherProcess.HasExited){throw "Launcher exited before monitor button appeared: $($launcherProcess.ExitCode)"}
        $window=@([StrataMonitorLaunchUiProbe]::VisibleWindows('Strata',$launcherProcess.Id) | Select-Object -First 1)
        if($window.Count){$button=[StrataMonitorLaunchUiProbe]::Child($window[0],'悬浮监控')}
    }while($button -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
    if($button -eq [IntPtr]::Zero){throw 'Launcher did not show the overlay button'}
    [StrataMonitorLaunchUiProbe]::Click($button)
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 250
        $opened=@([StrataMonitorLaunchUiProbe]::VisibleWindows('Strata Monitor',0) | Where-Object { $_ -notin $existing })
    }while(-not $opened.Count -and [DateTime]::UtcNow -lt $deadline)
    if(-not $opened.Count){throw 'Clicking the launcher button did not open the visible overlay'}
    $overlayPid=[StrataMonitorLaunchUiProbe]::ProcessId($opened[0])
    'PASS: launcher monitor button opens a visible independent overlay'
}finally{
    if($overlayPid){Stop-Process -Id $overlayPid -Force -ErrorAction SilentlyContinue}
    if(-not $launcherProcess.HasExited){Stop-Process -Id $launcherProcess.Id -Force;[void]$launcherProcess.WaitForExit(5000)}
}
