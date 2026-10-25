$ErrorActionPreference = 'Stop'
$launcher = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$updater = Join-Path $launcher 'Strata-Launcher-Update.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$temporaryParent = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.tmp'))
$probe = [IO.Path]::GetFullPath((Join-Path $temporaryParent ('engine-only-' + [Guid]::NewGuid().ToString('N'))))
if (-not $probe.StartsWith($temporaryParent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test directory is outside tests/.tmp.'
}

function New-StrataStub([string]$Path, [string]$Marker) {
    # Records every call, and the text of any argument that names a file: the DeepSeek bridge is passed as a
    # script file, so its content has to be captured this way.
    $source = 'using System; using System.IO; public class Program { public static int Main(string[] args) { ' +
        'File.AppendAllText(@"' + $Marker + '", string.Join(" ", args) + Environment.NewLine); ' +
        'foreach (var a in args) { try { if (File.Exists(a)) File.AppendAllText(@"' + $Marker + '", File.ReadAllText(a) + Environment.NewLine); } catch { } } ' +
        'Console.WriteLine("DSV41_RESULT {\"before\": \"0.1.49.2\", \"after\": \"0.1.49.2\"}"); return 0; } }'
    Add-Type -TypeDefinition $source -OutputType ConsoleApplication -OutputAssembly $Path
}

function Invoke-Updater([string[]]$Arguments) {
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $updater -StrataRoot $probe @Arguments | Out-Null
    return $LASTEXITCODE
}

try {
    [void](New-Item -ItemType Directory -Path (Join-Path $probe 'engine') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $probe 'python') -Force)
    [IO.File]::WriteAllText((Join-Path $probe 'START-HERE.bat'), '@echo off')
    # UPDATE.bat leaves a marker so the test can prove -EngineOnly never runs the official update.
    [IO.File]::WriteAllText((Join-Path $probe 'UPDATE.bat'), '@echo off' + "`r`n" + 'echo called> "%~dp0update-called.txt"')
    [IO.File]::WriteAllText((Join-Path $probe 'setup.py'), 'MIN_ENGINE = (0, 1, 46)')
    [IO.File]::WriteAllText((Join-Path $probe 'CMakeLists.txt'), 'project(strata VERSION 0.1.51 LANGUAGES CXX)')
    [IO.File]::WriteAllText((Join-Path $probe 'strata.py'), '# placeholder for the signed-feed command')
    [IO.File]::WriteAllText((Join-Path $probe 'engine\BUILD.json'), '{"version":"0.1.48","source":"prebuilt"}')
    Add-Type -TypeDefinition 'using System; public class Program { public static int Main(string[] args) { Console.WriteLine("strata 0.1.48"); return 0; } }' -OutputType ConsoleApplication -OutputAssembly (Join-Path $probe 'engine\strata.exe')

    $feedMarker = Join-Path $probe 'python-called.txt'
    $updateMarker = Join-Path $probe 'update-called.txt'
    New-StrataStub (Join-Path $probe 'python\python.exe') $feedMarker

    # 1. the Strata (Qwen) engine: the signed feed is used, the official UPDATE.bat is not
    if ((Invoke-Updater @('-EngineOnly')) -ne 0) { throw 'Engine-only update failed on a prebuilt engine that is already compatible.' }
    if (-not (Test-Path -LiteralPath $feedMarker -PathType Leaf)) { throw 'Engine-only update did not call the signed update feed.' }
    $calls = Get-Content -LiteralPath $feedMarker -Raw
    if ($calls -notmatch 'update --no-control') { throw 'Engine-only update did not run the signed-feed update command.' }
    if ($calls -notmatch 'engine_from_feed') { throw 'The signed update feed bridge was not the command that ran.' }
    if (Test-Path -LiteralPath $updateMarker) { throw 'Engine-only update ran the official UPDATE.bat.' }

    # 2. a locally compiled engine is never replaced by a prebuilt package
    [IO.File]::WriteAllText((Join-Path $probe 'engine\BUILD.json'), '{"version":"0.1.48","source":"local"}')
    Remove-Item -LiteralPath $feedMarker -Force -ErrorAction SilentlyContinue
    if ((Invoke-Updater @('-EngineOnly')) -eq 0) { throw 'Engine-only update replaced a locally compiled engine.' }
    if (Test-Path -LiteralPath $feedMarker) { throw 'Engine-only update called the signed update feed for a locally compiled engine.' }
    if (Test-Path -LiteralPath $updateMarker) { throw 'Engine-only update ran the official UPDATE.bat.' }

    # 3. the DeepSeek engine has its own package and its own update path
    [IO.File]::WriteAllText((Join-Path $probe 'engine\BUILD.json'), '{"version":"0.1.48","source":"prebuilt"}')
    $dsDir = Join-Path $probe 'engine-dsv41\0.1.49.2-windows-x86_64-cuda-cuda13'
    [void](New-Item -ItemType Directory -Path $dsDir -Force)
    [IO.File]::WriteAllText((Join-Path $dsDir 'BUILD.json'), '{"version":"0.1.49.2"}')
    Add-Type -TypeDefinition 'using System; public class Program { public static int Main(string[] args) { Console.WriteLine("strata-dsv41 0.1.49.2"); return 0; } }' -OutputType ConsoleApplication -OutputAssembly (Join-Path $dsDir 'strata-dsv41.exe')
    Remove-Item -LiteralPath $feedMarker -Force -ErrorAction SilentlyContinue
    if ((Invoke-Updater @('-DeepSeekEngineOnly')) -ne 0) { throw 'DeepSeek engine-only update failed on an installed DeepSeek engine.' }
    if (-not (Test-Path -LiteralPath $feedMarker -PathType Leaf)) { throw 'DeepSeek engine-only update did not call the upgrade bridge.' }
    $calls = Get-Content -LiteralPath $feedMarker -Raw
    if ($calls -notmatch 'upgrade_dsv41_engine') { throw 'DeepSeek engine-only update did not call setup.upgrade_dsv41_engine.' }
    if (Test-Path -LiteralPath $updateMarker) { throw 'DeepSeek engine-only update ran the official UPDATE.bat.' }

    # 4. an install without the DeepSeek engine refuses instead of downloading one
    Remove-Item -LiteralPath $dsDir -Recurse -Force
    if ((Invoke-Updater @('-DeepSeekEngineOnly')) -eq 0) { throw 'DeepSeek engine-only update accepted an install without a DeepSeek engine.' }

    # 5. a dropped transfer is retried by resuming, instead of ending the update after one attempt
    [void](New-Item -ItemType Directory -Path $dsDir -Force)
    [IO.File]::WriteAllText((Join-Path $dsDir 'BUILD.json'), '{"version":"0.1.49.2"}')
    Add-Type -TypeDefinition 'using System; public class Program { public static int Main(string[] args) { Console.WriteLine("strata-dsv41 0.1.49.2"); return 0; } }' -OutputType ConsoleApplication -OutputAssembly (Join-Path $dsDir 'strata-dsv41.exe')
    $countPath = Join-Path $probe 'bridge-calls.txt'
    $truncating = 'using System; using System.IO; public class Program { public static int Main(string[] args) { ' +
        'int n = 0; if (File.Exists(@"' + $countPath + '")) int.TryParse(File.ReadAllText(@"' + $countPath + '"), out n); ' +
        'File.WriteAllText(@"' + $countPath + '", (n + 1).ToString()); ' +
        'if (n == 0) Console.WriteLine("A newer DeepSeek engine is available but could not be installed: delivered 126138234 of 417419650 bytes; the partial file is kept and the next try resumes it; still using 0.1.49.2."); ' +
        'Console.WriteLine("DSV41_RESULT {\"before\": \"0.1.49.2\", \"after\": \"0.1.49.2\"}"); return 0; } }'
    Add-Type -TypeDefinition $truncating -OutputType ConsoleApplication -OutputAssembly (Join-Path $probe 'python\python.exe')
    if ((Invoke-Updater @('-DeepSeekEngineOnly')) -ne 0) { throw 'A retried transfer ended the DeepSeek engine update with an error.' }
    $bridgeCalls = if (Test-Path -LiteralPath $countPath) { [int](Get-Content -LiteralPath $countPath -Raw) } else { 0 }
    if ($bridgeCalls -ne 2) { throw "A truncated transfer was not retried (bridge ran $bridgeCalls time(s), expected 2)." }

    # 6. after an upgrade the run config still names the old engine folder: it must be re-pointed, or the model
    #    cannot start (the official upgrade deletes the old folder and does not touch run configs).
    $newDsDir = Join-Path $probe 'engine-dsv41\0.1.51-windows-x86_64-cuda-cuda13'
    [void](New-Item -ItemType Directory -Path $newDsDir -Force)
    [IO.File]::WriteAllText((Join-Path $newDsDir 'BUILD.json'), '{"version":"0.1.51"}')
    Add-Type -TypeDefinition 'using System; public class Program { public static int Main(string[] args) { Console.WriteLine("strata-dsv41 0.1.51"); return 0; } }' -OutputType ConsoleApplication -OutputAssembly (Join-Path $newDsDir 'strata-dsv41.exe')
    $oldExe = Join-Path $dsDir 'strata-dsv41.exe'
    $newExe = Join-Path $newDsDir 'strata-dsv41.exe'
    $dsConfig = Join-Path $probe 'strata-deepseek-test.json'
    $configText = '{"exe": "' + $oldExe.Replace('\', '\\') + '", "args": [], "model_name": "deepseek-test", "lib_dirs": ["' + $dsDir.Replace('\', '\\') + '"]}'
    [IO.File]::WriteAllText($dsConfig, $configText)
    $resultStub = 'using System; public class Program { public static int Main(string[] args) { Console.WriteLine("DSV41_RESULT {\"before\": \"0.1.51\", \"after\": \"0.1.51\"}"); return 0; } }'
    Add-Type -TypeDefinition $resultStub -OutputType ConsoleApplication -OutputAssembly (Join-Path $probe 'python\python.exe')
    if ((Invoke-Updater @('-DeepSeekEngineOnly')) -ne 0) { throw 'The DeepSeek engine update failed while re-pointing a run config.' }
    $after = Get-Content -LiteralPath $dsConfig -Raw
    if ($after -notmatch [regex]::Escape('0.1.51-windows-x86_64-cuda-cuda13')) { throw 'The run config was not re-pointed to the new engine folder.' }
    if ($after -match [regex]::Escape('0.1.49.2-windows-x86_64-cuda-cuda13')) { throw 'The run config still names the old engine folder.' }
    $parsed = $after | ConvertFrom-Json
    if ($parsed.exe -ne $newExe) { throw "The run config's exe is $($parsed.exe), expected $newExe." }
    if ($parsed.lib_dirs[0] -ne $newDsDir) { throw "The run config's lib_dirs is $($parsed.lib_dirs[0]), expected $newDsDir." }

    # 7. a DeepSeek-only install is told, instead of downloading a Qwen engine it has no model to test-start
    Remove-Item -LiteralPath (Join-Path $probe 'engine') -Recurse -Force
    Remove-Item -LiteralPath $feedMarker -Force -ErrorAction SilentlyContinue
    if ((Invoke-Updater @('-EngineOnly')) -eq 0) { throw 'A DeepSeek-only install accepted the Qwen engine update.' }
    if (Test-Path -LiteralPath $feedMarker) { throw 'A DeepSeek-only install called the signed update feed anyway.' }

    'PASS: engine-only updates use the signed feed, resume a dropped transfer, re-point run configs after a DeepSeek upgrade, refuse a DeepSeek-only install, and leave UPDATE.bat and local builds alone'
} finally {
    if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Recurse -Force }
}
