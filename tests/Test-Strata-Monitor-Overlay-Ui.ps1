$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class StrataMonitorOverlayUiProbe {
    public delegate bool EnumProc(IntPtr handle, IntPtr state);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr state);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr state);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr handle, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr handle, StringBuilder text, int capacity);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr handle);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr handle, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr handle, int index);
    public static IntPtr Window(int processId, string title) {
        IntPtr found=IntPtr.Zero;
        EnumWindows((window,unused) => {
            uint owner; GetWindowThreadProcessId(window,out owner);
            if(owner != processId || !IsWindowVisible(window)) return true;
            var text=new StringBuilder(256); GetWindowText(window,text,text.Capacity);
            if(text.ToString().Contains(title)) { found=window; return false; }
            return true;
        },IntPtr.Zero);
        return found;
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
    public static bool ClickThrough(IntPtr handle) { return (GetWindowLong(handle,-20) & 0x20) != 0; }
}
'@

$launcherRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$strataRoot=Join-Path (Split-Path -Parent $launcherRoot) 'Strata'
$overlay=Join-Path $launcherRoot 'Strata-Monitor-Overlay.ps1'
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$process=Start-Process -FilePath $powershell -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',('"'+$overlay+'"'),
    '-StrataRoot',('"'+$strataRoot+'"'),'-Port','18500'
) -WorkingDirectory $launcherRoot -WindowStyle Hidden -PassThru
try {
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    $window=[IntPtr]::Zero
    do {
        Start-Sleep -Milliseconds 250
        $process.Refresh()
        if($process.HasExited){throw "Overlay exited before its window opened: $($process.ExitCode)"}
        $window=[StrataMonitorOverlayUiProbe]::Window($process.Id,'Strata Monitor')
    }while($window -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
    if($window -eq [IntPtr]::Zero){throw 'Overlay did not show a visible window'}
    foreach($fragment in @('生成速度','GPU · 独立读数','近期请求','透明度 85%')){
        if([StrataMonitorOverlayUiProbe]::Child($window,$fragment) -eq [IntPtr]::Zero){throw "Overlay omitted $fragment"}
    }
    $checkbox=[StrataMonitorOverlayUiProbe]::Child($window,'鼠标穿透')
    if($checkbox -eq [IntPtr]::Zero){throw 'Overlay omitted click-through control'}
    [StrataMonitorOverlayUiProbe]::Click($checkbox)
    Start-Sleep -Milliseconds 250
    if(-not [StrataMonitorOverlayUiProbe]::ClickThrough($window)){throw 'Click-through did not set the window style'}
    'PASS: overlay opens visibly and enables mouse click-through'
}finally{
    if(-not $process.HasExited){Stop-Process -Id $process.Id -Force;[void]$process.WaitForExit(5000)}
}
