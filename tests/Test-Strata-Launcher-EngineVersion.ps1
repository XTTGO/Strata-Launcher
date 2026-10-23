$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\Strata-Launcher-Environment.ps1')

$base=Join-Path ([IO.Path]::GetTempPath()) ('strata-engine-version-' + [Guid]::NewGuid().ToString('N'))
$root=Join-Path $base 'Strata'
$launcher=Join-Path $root 'launcher'
try {
    foreach($directory in @($launcher,(Join-Path $root '.venv\Scripts'),(Join-Path $root 'serve'),
                            (Join-Path $root 'engine'),(Join-Path $root 'tools'))){
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    foreach($file in @('START-HERE.bat','UPDATE.bat','serve\server.py','engine\strata.exe',
                      '.venv\Scripts\python.exe','tools\calibrate.py','tools\needle_bench.py','tools\serve_load.py')){
        [IO.File]::WriteAllText((Join-Path $root $file),'fixture')
    }
    [IO.File]::WriteAllText((Join-Path $launcher 'model_catalog.py'),'fixture')
    [IO.File]::WriteAllText((Join-Path $root 'setup.py'),'MIN_ENGINE = (0, 1, 46)')
    [IO.File]::WriteAllText((Join-Path $root 'strata-a.json'),
        '{"exe":"strata.exe","args":[],"model_name":"model-a"}')
    function Read-StrataModelCatalogFromSetup {
        param([string]$LauncherDirectory)
        [pscustomobject]@{model_name='model-a';arch='';label='Model A'}
    }

    [IO.File]::WriteAllText((Join-Path $root 'engine\BUILD.json'),'{"version":"0.1.45"}')
    $old=Get-StrataLauncherEnvironment -LauncherDirectory $launcher
    if(-not $old.IsReady -or -not ([string]$old.EngineWarning).Contains('0.1.46')){
        throw 'An older engine should remain usable with a visible warning.'
    }
    [IO.File]::WriteAllText((Join-Path $root 'engine\BUILD.json'),'{"version":"0.1.47"}')
    $current=Get-StrataLauncherEnvironment -LauncherDirectory $launcher
    if(-not $current.IsReady -or $current.EngineWarning){throw "A current engine was rejected or warned: $($current.Message)"}
    [IO.File]::WriteAllText((Join-Path $root 'CMakeLists.txt'),'project(strata VERSION 0.1.48 LANGUAGES CXX)')
    $sourceAhead=Get-StrataLauncherEnvironment -LauncherDirectory $launcher
    if(-not $sourceAhead.IsReady -or -not ([string]$sourceAhead.EngineWarning).Contains('0.1.48')){
        throw 'The current source version should warn about an older engine even when MIN_ENGINE is lower.'
    }
    [IO.File]::WriteAllText((Join-Path $root 'engine\BUILD.json'),'{"version":"0.1.48"}')
    $updated=Get-StrataLauncherEnvironment -LauncherDirectory $launcher
    if(-not $updated.IsReady -or $updated.EngineWarning){throw 'The engine matching current source should pass.'}
    Remove-Item -LiteralPath (Join-Path $root 'engine\BUILD.json') -Force
    $missing=Get-StrataLauncherEnvironment -LauncherDirectory $launcher
    if($missing.IsReady -or -not ([string]$missing.Message).Contains('BUILD.json')){
        throw 'An engine update without BUILD.json passed the environment check.'
    }
    'PASS: engine version and incomplete update are detected'
} finally {
    $absoluteBase=[IO.Path]::GetFullPath($base)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if(-not $absoluteBase.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)){
        throw "Refusing cleanup outside temp: $absoluteBase"
    }
    if(Test-Path -LiteralPath $absoluteBase){Remove-Item -LiteralPath $absoluteBase -Recurse -Force}
}
