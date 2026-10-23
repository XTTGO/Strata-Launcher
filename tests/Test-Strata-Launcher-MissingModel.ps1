$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\Strata-Launcher-Environment.ps1')

$base=Join-Path ([IO.Path]::GetTempPath()) ('strata-missing-model-' + [Guid]::NewGuid().ToString('N'))
$root=Join-Path $base 'Strata'
$launcher=Join-Path $root 'launcher'
try {
    foreach($directory in @($launcher,(Join-Path $root '.venv\Scripts'),(Join-Path $root 'serve'),
                            (Join-Path $root 'engine'),(Join-Path $root 'tools'),(Join-Path $root 'models'))){
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    foreach($file in @('START-HERE.bat','UPDATE.bat','setup.py','serve\server.py','engine\strata.exe',
                      '.venv\Scripts\python.exe','tools\calibrate.py','tools\needle_bench.py','tools\serve_load.py')){
        [IO.File]::WriteAllText((Join-Path $root $file),'fixture')
    }
    [IO.File]::WriteAllText((Join-Path $launcher 'model_catalog.py'),'fixture')
    function Read-StrataModelCatalogFromSetup {
        param([string]$LauncherDirectory)
        [pscustomobject]@{model_name='model-a';arch='';label='Model A'}
        [pscustomobject]@{model_name='model-b';arch='';label='Model B'}
    }

    $a=Join-Path $root 'models\a.gguf'
    $b=Join-Path $root 'models\b.gguf'
    [IO.File]::WriteAllText($a,'weight')
    [IO.File]::WriteAllText((Join-Path $root 'strata-a.json'),
        '{"exe":"strata.exe","args":["--native","models/a.gguf"],"model_name":"model-a"}')
    [IO.File]::WriteAllText((Join-Path $root 'strata-b.json'),
        '{"exe":"strata.exe","args":["--native","models/b.gguf"],"model_name":"model-b"}')

    $first=Get-StrataLauncherEnvironment -LauncherDirectory $launcher
    if(-not $first.IsReady -or $first.ModelConfigs.Count -ne 1 -or $first.ModelConfigs[0].ModelName -ne 'model-a' -or
       $first.UnavailableModels.Count -ne 1 -or $first.UnavailableModels[0].ModelName -ne 'model-b'){
        throw 'A deleted model GGUF still appears in the selectable list.'
    }
    [IO.File]::WriteAllText($b,'weight')
    $restored=Get-StrataLauncherEnvironment -LauncherDirectory $launcher
    if($restored.ModelConfigs.Count -ne 2 -or $restored.UnavailableModels.Count -ne 0){
        throw 'Restoring model files did not restore the selectable model.'
    }
    [IO.File]::WriteAllText((Join-Path $root 'strata-b.json'),
        '{"exe":"strata.exe","args":["--native","models/old.gguf"],"user_args":["--native","models/b.gguf"],"model_name":"model-b"}')
    $overridden=Get-StrataLauncherEnvironment -LauncherDirectory $launcher
    if($overridden.ModelConfigs.Count -ne 2){
        throw 'A valid user_args model path did not override the stale base path.'
    }
    $secondShard=Join-Path $root 'models\a-part2.gguf'
    [IO.File]::WriteAllText((Join-Path $root 'strata-a.json'),
        '{"exe":"strata.exe","args":["--native","models/a.gguf","--ple-gguf","models/a-part2.gguf"],"model_name":"model-a"}')
    $missingShard=Get-StrataLauncherEnvironment -LauncherDirectory $launcher
    if($missingShard.ModelConfigs.Count -ne 1 -or $missingShard.ModelConfigs[0].ModelName -ne 'model-b'){
        throw 'A missing secondary GGUF shard still appears in the selectable list.'
    }
    [IO.File]::WriteAllText($secondShard,'weight')
    $pack=Join-Path $root 'models\pack-a'
    [void](New-Item -ItemType Directory -Path $pack)
    [IO.File]::WriteAllText((Join-Path $root 'strata-a.json'),
        '{"exe":"strata.exe","args":["--pack","models/missing-pack","--native","models/a.gguf","--native-dense-gguf","models/a.gguf"],"user_args":["--pack","models/pack-a"],"model_name":"model-a"}')
    $packOverride=Get-StrataLauncherEnvironment -LauncherDirectory $launcher
    if($packOverride.ModelConfigs.Count -ne 2){
        throw 'A valid user_args pack path did not override the stale base path.'
    }
    Remove-Item -LiteralPath $pack -Recurse -Force
    $missingPack=Get-StrataLauncherEnvironment -LauncherDirectory $launcher
    if($missingPack.ModelConfigs.Count -ne 1 -or $missingPack.ModelConfigs[0].ModelName -ne 'model-b'){
        throw 'A missing expert pack folder still appears in the selectable list.'
    }
    Remove-Item -LiteralPath $a -Force
    Remove-Item -LiteralPath $b -Force
    $empty=Get-StrataLauncherEnvironment -LauncherDirectory $launcher
    if($empty.IsReady -or $empty.ModelConfigs.Count -ne 0 -or -not ([string]$empty.Message).Contains('GGUF')){
        throw "All missing model files did not produce a clear not-ready state: ready=$($empty.IsReady), count=$($empty.ModelConfigs.Count), message=$($empty.Message)"
    }
    if(-not (Test-Path -LiteralPath (Join-Path $root 'strata-a.json'))){
        throw 'Model inventory removed an official run config.'
    }
    'PASS: missing model files are hidden, restored files return, and configs remain untouched'
} finally {
    $absoluteBase=[IO.Path]::GetFullPath($base)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if(-not $absoluteBase.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)){
        throw "Refusing cleanup outside temp: $absoluteBase"
    }
    if(Test-Path -LiteralPath $absoluteBase){Remove-Item -LiteralPath $absoluteBase -Recurse -Force}
}
