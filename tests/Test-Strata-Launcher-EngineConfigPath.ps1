$ErrorActionPreference = 'Stop'
$launcher = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $launcher 'Strata-Launcher-Environment.ps1')
$temporaryParent = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.tmp'))
$probe = [IO.Path]::GetFullPath((Join-Path $temporaryParent ('engine-config-' + [Guid]::NewGuid().ToString('N'))))
if (-not $probe.StartsWith($temporaryParent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test directory is outside tests/.tmp.'
}

function Assert-True($condition, [string]$message) {
    if (-not $condition) { throw $message }
}
function Esc([string]$text) { return $text.Replace('\', '\\') }
function Hash([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }

try {
    $oldFolder = Join-Path $probe 'engine-dsv41\0.1.40-windows-x86_64-cuda-cuda13'
    $newFolder = Join-Path $probe 'engine-dsv41\0.1.53-windows-x86_64-cuda-cuda13'
    $oldExe = Join-Path $oldFolder 'strata-dsv41.exe'
    $newExe = Join-Path $newFolder 'strata-dsv41.exe'
    [void](New-Item -ItemType Directory -Path $newFolder -Force)
    [IO.File]::WriteAllText($newExe, 'engine')

    # 1. the object in memory: the engine it names is gone, an installed one is adopted; other lib_dirs stay
    $config = [pscustomobject]@{ exe = $oldExe; lib_dirs = @($oldFolder, 'C:\keep\me'); args = @('--pack', 'P') }
    $fixed = Repair-StrataConfigEnginePath -Config $config -Root $probe
    Assert-True ($fixed.exe -eq $newExe) "The config's exe is $($fixed.exe), expected $newExe."
    Assert-True ($fixed.lib_dirs[0] -eq $newFolder) "lib_dirs[0] is $($fixed.lib_dirs[0]), expected $newFolder."
    Assert-True ($fixed.lib_dirs[1] -eq 'C:\keep\me') 'Unrelated lib_dirs entries must stay.'

    # 2. a config whose engine is still there is never touched
    $working = [pscustomobject]@{ exe = $newExe; lib_dirs = @($newFolder) }
    $same = Repair-StrataConfigEnginePath -Config $working -Root $probe
    Assert-True ($same.exe -eq $newExe) 'A working config must keep its engine.'

    # 3. an engine outside engine-dsv41 is not this function's business
    $qwen = [pscustomobject]@{ exe = (Join-Path $probe 'engine\strata.exe') }
    $untouched = Repair-StrataConfigEnginePath -Config $qwen -Root $probe
    Assert-True ($untouched.exe -eq (Join-Path $probe 'engine\strata.exe')) 'A non-DeepSeek engine must not be re-pointed.'

    # 4. on disk: only the engine folder path changes, the rest of the file stays byte for byte
    $stalePath = Join-Path $probe 'strata-deepseek-stale.json'
    $staleText = '{"exe": "' + (Esc $oldExe) + '", "args": ["--pack", "P"], "lib_dirs": ["' + (Esc $oldFolder) + '"], "port": 8080}'
    [IO.File]::WriteAllText($stalePath, $staleText)
    $repairs = @(Repair-StrataEngineConfigFiles -Root $probe)
    Assert-True ($repairs.Count -eq 1) "Expected one repaired file, got $($repairs.Count)."
    $after = Get-Content -LiteralPath $stalePath -Raw
    Assert-True ($after -notmatch '0\.1\.40') 'The stale engine folder is still named in the config.'
    $parsed = $after | ConvertFrom-Json
    Assert-True ($parsed.exe -eq $newExe) "The file's exe is $($parsed.exe), expected $newExe."
    Assert-True ($parsed.lib_dirs[0] -eq $newFolder) 'The file lib_dirs entry was not re-pointed.'
    Assert-True ($parsed.port -eq 8080 -and $parsed.args[1] -eq 'P') 'The rest of the config must survive the repair.'

    # 5. a config that still works, and a shared-settings file that only mentions the engine, are left alone
    $workingPath = Join-Path $probe 'strata-deepseek-working.json'
    [IO.File]::WriteAllText($workingPath, '{"exe": "' + (Esc $newExe) + '", "args": []}')
    $beforeWorking = Hash $workingPath
    $sharedPath = Join-Path $probe 'strata-deepseek-working.shared-settings.json'
    [IO.File]::WriteAllText($sharedPath, '{"note": "' + (Esc $oldFolder) + '"}')
    $beforeShared = Hash $sharedPath
    $again = @(Repair-StrataEngineConfigFiles -Root $probe)
    Assert-True ($again.Count -eq 0) "A second pass must repair nothing, it repaired $($again.Count)."
    Assert-True ((Hash $workingPath) -eq $beforeWorking) 'A working config was rewritten.'
    Assert-True ((Hash $sharedPath) -eq $beforeShared) 'A shared-settings file was rewritten.'

    'PASS: a DeepSeek config whose engine folder is gone is re-pointed in memory and on disk; working configs and other engines are untouched'
} finally {
    if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Recurse -Force }
}
