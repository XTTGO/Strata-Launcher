$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}

$launcherRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $launcherRoot 'Strata-Launcher-Environment.ps1')

$probe = Join-Path ([IO.Path]::GetTempPath()) ('strata dsv41 engine ' + [Guid]::NewGuid().ToString('N'))
try {
    $old = Join-Path $probe 'engine-dsv41\0.1.98-windows-x86_64-cuda-cuda13'
    [void](New-Item -ItemType Directory -Path $old -Force)
    Set-Content -LiteralPath (Join-Path $old 'BUILD.json') -Value '{ "version": "0.1.98" }' -Encoding UTF8
    [void](New-Item -ItemType File -Path (Join-Path $old 'strata-dsv41.exe'))

    $first = Get-StrataDeepSeekEngineStatus -Root $probe
    Assert-True ($null -ne $first.InstalledVersion) 'the DeepSeek engine should be found'
    Assert-True ([string]$first.InstalledVersion -eq '0.1.98') 'the build.js version should be read'
    Assert-True ($first.Path -like '*0.1.98-windows-x86_64-cuda-cuda13\strata-dsv41.exe') 'the executable path should be returned'

    $new = Join-Path $probe 'engine-dsv41\0.1.99-windows-x86_64-cuda-cuda13'
    [void](New-Item -ItemType Directory -Path $new -Force)
    Set-Content -LiteralPath (Join-Path $new 'BUILD.json') -Value '{ "version": "0.1.99" }' -Encoding UTF8
    [void](New-Item -ItemType File -Path (Join-Path $new 'strata-dsv41.exe'))

    $paths = @(Get-StrataEngineExecutablePaths -Root $probe)
    Assert-True ($paths -contains (Join-Path $old 'strata-dsv41.exe')) 'the versioned dsv41 executable should be listed for stop/identity checks'

    $latest = Get-StrataDeepSeekEngineStatus -Root $probe
    Assert-True ([string]$latest.InstalledVersion -eq '0.1.99') 'the newest DeepSeek engine package should win'

    $empty = Join-Path $probe 'empty'
    [void](New-Item -ItemType Directory -Path $empty -Force)
    $missing = Get-StrataDeepSeekEngineStatus -Root $empty
    Assert-True ($null -eq $missing.InstalledVersion) 'no engine folder means no version'

    'PASS: the DeepSeek engine package is found and the newest version wins'
} finally {
    if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Recurse -Force }
}
