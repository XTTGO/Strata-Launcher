$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}

$repoLauncher = (Resolve-Path 'launcher').Path
$version = (Get-Content -LiteralPath (Join-Path $repoLauncher 'VERSION.txt') -Raw -Encoding UTF8).Trim()
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$probeBase = Join-Path ([IO.Path]::GetTempPath()) ('strata launcher entry ' + [Guid]::NewGuid().ToString('N'))

try {
    $fakeRoot = Join-Path $probeBase 'Recipient Strata'
    $fakeLauncher = Join-Path $fakeRoot 'launcher'
    foreach ($directory in @(
        $fakeLauncher,
        (Join-Path $fakeRoot '.venv\Scripts'),
        (Join-Path $fakeRoot 'serve'),
        (Join-Path $fakeRoot 'engine'),
        (Join-Path $fakeRoot 'tools')
    )) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    foreach ($file in @(
        (Join-Path $fakeRoot '.venv\Scripts\python.exe'),
        (Join-Path $fakeRoot 'serve\server.py'),
        (Join-Path $fakeRoot 'engine\strata.exe'),
        (Join-Path $fakeRoot 'START-HERE.bat'),
        (Join-Path $fakeRoot 'UPDATE.bat'),
        (Join-Path $fakeRoot 'tools\calibrate.py'),
        (Join-Path $fakeRoot 'tools\needle_bench.py'),
        (Join-Path $fakeRoot 'tools\serve_load.py')
    )) { [IO.File]::WriteAllText($file, '') }
    [IO.File]::WriteAllText(
        (Join-Path $fakeRoot 'strata-recipient.json'),
        '{"exe":"engine\\strata.exe","args":[],"model_name":"recipient-model"}',
        [Text.UTF8Encoding]::new($false)
    )
    Copy-Item (Join-Path $repoLauncher 'Strata-Launcher.ps1') $fakeLauncher
    Copy-Item (Join-Path $repoLauncher 'Strata-Launcher-Environment.ps1') $fakeLauncher
    Copy-Item (Join-Path $repoLauncher 'VERSION.txt') $fakeLauncher

    $entry = Join-Path $fakeLauncher 'Strata-Launcher.ps1'
    $output = & $powershell -NoProfile -ExecutionPolicy Bypass -File $entry -CheckOnly 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    Assert-True ($exitCode -eq 0) "the real launcher entry should accept a recipient install; exit=$exitCode output=$output"
    $result = $output | ConvertFrom-Json
    Assert-True ($result.root -eq $fakeRoot) 'the real launcher entry should report its recipient Strata root'
    Assert-True ($result.model_count -eq 1) 'the real launcher entry should see the recipient model config'
    Assert-True ($result.launcher_version -eq $version) 'the real launcher entry should report the packaged launcher version'
    Assert-True ($result.model_catalog_status -eq 'fallback') 'an unavailable setup catalog should leave the launcher usable'

    $wrongLauncher = Join-Path $probeBase 'launcher by itself'
    [void](New-Item -ItemType Directory -Path $wrongLauncher -Force)
    Copy-Item (Join-Path $repoLauncher 'Strata-Launcher.ps1') $wrongLauncher
    Copy-Item (Join-Path $repoLauncher 'Strata-Launcher-Environment.ps1') $wrongLauncher
    $wrongEntry = Join-Path $wrongLauncher 'Strata-Launcher.ps1'
    $wrongOutput = & $powershell -NoProfile -ExecutionPolicy Bypass -File $wrongEntry -CheckOnly 2>&1 | Out-String
    $wrongExitCode = $LASTEXITCODE
    Assert-True ($wrongExitCode -ne 0) 'the real launcher entry should reject a launcher folder outside Strata'
    Assert-True ($wrongOutput -match 'START-HERE\.bat') 'the real launcher entry should explain what is missing'

    'PASS: real launcher entry validates portable placement without opening the UI'
} finally {
    if (Test-Path -LiteralPath $probeBase) {
        Remove-Item -LiteralPath $probeBase -Recurse -Force
    }
}
