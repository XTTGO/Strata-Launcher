$ErrorActionPreference = 'Stop'
$launcher = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$updater = Join-Path $launcher 'Strata-Launcher-Update.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$temporaryParent = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.tmp'))
$probe = [IO.Path]::GetFullPath((Join-Path $temporaryParent ('update-validation-' + [Guid]::NewGuid().ToString('N'))))
if (-not $probe.StartsWith($temporaryParent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test directory is outside tests/.tmp.'
}

try {
    [void](New-Item -ItemType Directory -Path (Join-Path $probe 'engine') -Force)
    [IO.File]::WriteAllText((Join-Path $probe 'START-HERE.bat'), '@echo off')
    [IO.File]::WriteAllText((Join-Path $probe 'UPDATE.bat'), '@echo off')
    [IO.File]::WriteAllText((Join-Path $probe 'setup.py'), 'MIN_ENGINE = (0, 1, 46)')
    [IO.File]::WriteAllText((Join-Path $probe 'CMakeLists.txt'), 'project(strata VERSION 0.1.49 LANGUAGES CXX)')
    [IO.File]::WriteAllText((Join-Path $probe 'engine\BUILD.json'), '{"version":"0.1.48","source":"prebuilt"}')
    $exe = Join-Path $probe 'engine\strata.exe'
    Add-Type -TypeDefinition 'using System; public class Program { public static int Main(string[] args) { Console.WriteLine("strata 0.1.48"); return 0; } }' -OutputType ConsoleApplication -OutputAssembly $exe

    & $powershell -NoProfile -ExecutionPolicy Bypass -File $updater -StrataRoot $probe -VerifyOnly | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'A compatible prebuilt 0.1.48 engine failed validation against the 0.1.49 source target.' }

    [IO.File]::WriteAllText((Join-Path $probe 'engine\BUILD.json'), '{"version":"0.1.48","source":"local"}')
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $updater -StrataRoot $probe -VerifyOnly | Out-Null
    if ($LASTEXITCODE -eq 0) { throw 'An outdated local build passed validation.' }

    [IO.File]::WriteAllText((Join-Path $probe 'engine\BUILD.json'), '{"version":"0.1.48","source":"prebuilt"}')
    [IO.File]::WriteAllText((Join-Path $probe 'setup.py'), 'MIN_ENGINE = (0, 1, 49)')
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $updater -StrataRoot $probe -VerifyOnly | Out-Null
    if ($LASTEXITCODE -eq 0) { throw 'A prebuilt engine below the official minimum passed validation.' }

    'PASS: updater validates prebuilt compatibility and rejects outdated engines'
} finally {
    if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Recurse -Force }
}
