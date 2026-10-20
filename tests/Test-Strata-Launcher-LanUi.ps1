$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class StrataLanUiProbe {
    public delegate bool EnumProc(IntPtr handle, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr state);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr handle, StringBuilder text, int capacity);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr handle, StringBuilder text, int capacity);
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr handle, uint message, IntPtr wParam, IntPtr lParam);

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

    public static int LanCheckboxState(int pid) {
        int result = -1;
        EnumWindows((top, unused) => {
            uint owner;
            GetWindowThreadProcessId(top, out owner);
            if (owner != pid) return true;
            EnumChildWindows(top, (child, nested) => {
                var kind = new StringBuilder(256);
                GetClassName(child, kind, kind.Capacity);
                var text = new StringBuilder(256);
                GetWindowText(child, text, text.Capacity);
                if (kind.ToString().Contains("BUTTON") && text.ToString().Contains("LAN access")) {
                    result = (int)SendMessage(child, 0x00F0, IntPtr.Zero, IntPtr.Zero).ToInt64();
                    return false;
                }
                return true;
            }, IntPtr.Zero);
            return result < 0;
        }, IntPtr.Zero);
        return result;
    }

    public static bool HasAddressLink(int pid) {
        bool found = false;
        EnumWindows((top, unused) => {
            uint owner;
            GetWindowThreadProcessId(top, out owner);
            if (owner != pid) return true;
            EnumChildWindows(top, (child, nested) => {
                var kind = new StringBuilder(256);
                GetClassName(child, kind, kind.Capacity);
                if (!kind.ToString().Contains("STATIC")) return true;
                var value = new StringBuilder(1024);
                GetWindowText(child, value, value.Capacity);
                if (value.ToString().Contains("http://")) {
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

$launcher = (Resolve-Path 'launcher\Strata-Launcher.ps1').Path
$workingDirectory = (Resolve-Path 'launcher').Path
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$keyPath = Join-Path $workingDirectory 'data\lan-key.dpapi'
$keyExisted = Test-Path -LiteralPath $keyPath
$process = Start-Process -FilePath $powershell -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',('"' + $launcher + '"')
) -WorkingDirectory $workingDirectory -PassThru
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(18)
    do {
        Start-Sleep -Milliseconds 250
        $process.Refresh()
        $hasMode = [StrataLanUiProbe]::HasText($process.Id,'LAN access')
        $hasKey = [StrataLanUiProbe]::HasText($process.Id,'Copy API key')
        $hasFirewall = [StrataLanUiProbe]::HasText($process.Id,'Firewall')
        $copyAddressCaption = ([char]0x590D).ToString() + [char]0x5236 + [char]0x5730 + [char]0x5740
        $hasCopyAddress = [StrataLanUiProbe]::HasText($process.Id,$copyAddressCaption)
        $hasAddressLink = [StrataLanUiProbe]::HasAddressLink($process.Id)
        $state = [StrataLanUiProbe]::LanCheckboxState($process.Id)
    } while (-not $process.HasExited -and (-not $hasMode -or -not $hasKey -or -not $hasFirewall -or -not $hasAddressLink -or $hasCopyAddress -or $state -lt 0) -and [DateTime]::UtcNow -lt $deadline)
    if ($process.HasExited) { throw "Launcher exited before showing LAN controls: $($process.ExitCode)" }
    if (-not $hasMode -or -not $hasKey -or -not $hasFirewall) { throw 'Launcher is missing LAN controls.' }
    if (-not $hasAddressLink -or $hasCopyAddress) { throw "Candidate LAN addresses should be links without an extra copy button. link=$hasAddressLink button=$hasCopyAddress" }
    if (-not (Test-Path -LiteralPath (Join-Path $workingDirectory 'data\lan-access.json')) -and $state -ne 0) {
        throw 'LAN checkbox was enabled by default.'
    }
    if (-not $keyExisted -and (Test-Path -LiteralPath $keyPath)) { throw 'Opening the launcher generated a key before LAN was enabled.' }
    'PASS: launcher UI exposes compact LAN links, key copy and explicit firewall controls'
} finally {
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        [void]$process.WaitForExit(5000)
    }
}
