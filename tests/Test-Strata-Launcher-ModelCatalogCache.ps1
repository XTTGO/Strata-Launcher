$ErrorActionPreference='Stop'
. ([scriptblock]::Create((Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Strata-Launcher-Environment.ps1') -Raw -Encoding UTF8)))

$base=Join-Path ([IO.Path]::GetTempPath()) ('strata-catalog-cache-' + [Guid]::NewGuid().ToString('N'))
$root=Join-Path $base 'Strata'
$launcher=Join-Path $root 'launcher'
try {
    foreach($directory in @($launcher,(Join-Path $root '.venv\Scripts'),(Join-Path $root 'serve'),(Join-Path $root 'engine'),(Join-Path $root 'tools'))){
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    foreach($file in @('START-HERE.bat','UPDATE.bat','setup.py','serve\server.py','engine\strata.exe',
                      '.venv\Scripts\python.exe','tools\calibrate.py','tools\needle_bench.py','tools\serve_load.py')){
        [IO.File]::WriteAllText((Join-Path $root $file),'v1')
    }
    [IO.File]::WriteAllText((Join-Path $launcher 'model_catalog.py'),'helper-v1')
    [IO.File]::WriteAllText((Join-Path $root 'strata-a.json'),'{"exe":"strata.exe","args":[],"model_name":"model-a"}')

    $script:extractCalls=0
    function Read-StrataModelCatalogFromSetup {
        param([string]$LauncherDirectory)
        $script:extractCalls++
        [pscustomobject]@{model_name='model-a';arch='';label='Model A'}
        [pscustomobject]@{model_name='model-b';arch='';label='Model B'}
    }

    $first=Get-StrataLauncherEnvironment -LauncherDirectory $launcher
    if($script:extractCalls -ne 1 -or $first.ModelCatalogSource -ne 'extracted' -or $first.ModelConfigs.Count -ne 1 -or $first.ModelConfigs[0].Label -ne 'Model A'){
        throw 'First launch did not extract the official catalog.'
    }
    $second=Get-StrataLauncherEnvironment -LauncherDirectory $launcher
    if($script:extractCalls -ne 1 -or $second.ModelCatalogSource -ne 'cache'){
        throw 'Unchanged setup did not reuse the catalog cache.'
    }

    [IO.File]::WriteAllText((Join-Path $root 'strata-b.json'),'{"exe":"strata.exe","args":[],"model_name":"model-b"}')
    $withNewModel=Get-StrataLauncherEnvironment -LauncherDirectory $launcher
    if($script:extractCalls -ne 1 -or $withNewModel.ModelConfigs.Count -ne 2 -or
       -not ($withNewModel.ModelConfigs.Label -contains 'Model B')){
        throw 'A new local model config was not detected with an unchanged catalog.'
    }

    [IO.File]::WriteAllText((Join-Path $root 'setup.py'),'v2')
    $updated=Get-StrataLauncherEnvironment -LauncherDirectory $launcher
    if($script:extractCalls -ne 2 -or $updated.ModelCatalogSource -ne 'extracted'){
        throw 'Changed setup.py did not invalidate the catalog cache.'
    }
    [IO.File]::WriteAllText((Join-Path $launcher 'model_catalog.py'),'helper-v2')
    $updatedHelper=Get-StrataLauncherEnvironment -LauncherDirectory $launcher
    if($script:extractCalls -ne 3 -or $updatedHelper.ModelCatalogSource -ne 'extracted'){
        throw 'Changed launcher catalog helper did not invalidate the cache.'
    }
    'PASS: catalog cache skips unchanged setup, detects new configs, and invalidates on code changes'
} finally {
    $absoluteBase=[IO.Path]::GetFullPath($base)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(-not $absoluteBase.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)){
        throw "Refusing cleanup outside temp: $absoluteBase"
    }
    if(Test-Path -LiteralPath $absoluteBase){Remove-Item -LiteralPath $absoluteBase -Recurse -Force}
}
