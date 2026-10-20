$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) {
        throw "FAIL: $Message`r`nExpected: $Expected`r`nActual:   $Actual"
    }
}

$modulePath = Join-Path (Resolve-Path 'launcher').Path 'Strata-Launcher-Environment.ps1'
. $modulePath

$probeBase = Join-Path ([IO.Path]::GetTempPath()) ('strata launcher portability ' + [Guid]::NewGuid().ToString('N'))
$fakeRoot = Join-Path $probeBase 'Strata Install With Spaces'
$fakeLauncher = Join-Path $fakeRoot 'launcher'

try {
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
    )) {
        [IO.File]::WriteAllText($file, '')
    }

    $configPath = Join-Path $fakeRoot 'strata-portable.json'
    [IO.File]::WriteAllText(
        $configPath,
        '{"exe":"engine\\strata.exe","args":[],"model_name":"portable-test"}',
        [Text.UTF8Encoding]::new($false)
    )

    $environment = Get-StrataLauncherEnvironment -LauncherDirectory $fakeLauncher
    Assert-True $environment.IsReady 'a complete installed Strata layout should be accepted'
    Assert-Equal $environment.Root $fakeRoot 'the Strata root should be the launcher folder parent'
    Assert-Equal $environment.DefaultDataDirectory (Join-Path $probeBase 'Strata-data') 'the portable fallback data directory should be beside the Strata root'
    Assert-Equal $environment.ModelConfigs.Count 1 'one usable model profile should be discovered'
    Assert-Equal $environment.ModelConfigs[0].Path $configPath 'the discovered model path should belong to the recipient installation'

    $wrongLocation = Join-Path $probeBase 'Standalone launcher'
    [void](New-Item -ItemType Directory -Path $wrongLocation -Force)
    $invalid = Get-StrataLauncherEnvironment -LauncherDirectory $wrongLocation
    Assert-True (-not $invalid.IsReady) 'a launcher copied outside a Strata installation should be rejected'
    Assert-True ($invalid.Message -match 'Strata.*launcher|launcher.*Strata') 'the placement error should explain that launcher belongs inside the Strata root'
    Assert-True ($invalid.Missing -contains 'START-HERE.bat') 'the placement error should report a missing official entry point'

    'PASS: launcher environment follows the recipient Strata installation and rejects a wrong location'
} finally {
    if (Test-Path -LiteralPath $probeBase) {
        Remove-Item -LiteralPath $probeBase -Recurse -Force
    }
}
