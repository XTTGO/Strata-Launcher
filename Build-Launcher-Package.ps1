param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'),
    [string]$StrataRoot = ''
)

$ErrorActionPreference = 'Stop'
$launcherDirectory = $PSScriptRoot
$sourceParent = Split-Path -Parent $launcherDirectory
if ([string]::IsNullOrWhiteSpace($StrataRoot)) {
    $StrataRoot = if (Test-Path -LiteralPath (Join-Path $sourceParent 'START-HERE.bat') -PathType Leaf) {
        $sourceParent
    } else {
        Join-Path $sourceParent 'Strata'
    }
}
$strataRoot = [IO.Path]::GetFullPath($StrataRoot)
$output = [IO.Path]::GetFullPath($OutputDirectory)

$topLevelFiles = @(
    'Strata-Launcher.bat',
    'Strata-Launcher.ps1',
    'Strata-Launcher-Environment.ps1',
    'Strata-Launcher-Theme.ps1',
    'Strata-Launcher-GpuPower.ps1',
    'Strata-Launcher-GpuPlacement.ps1',
    'Strata-Launcher-Lan.ps1',
    'Strata-Launcher-LanFirewall.ps1',
    'Strata-Launcher-Update.ps1',
    'Build-Launcher-Package.ps1',
    'Strata-Launcher-Reload.ps1',
    'Strata-Launcher-Settings.ps1',
    'Strata-Calibration-View.ps1',
    'Strata-Calibrate-Current.py',
    'Strata-LocalModel-Inspect.py',
    'model_catalog.py',
    'Benchmark-Launcher.ps1',
    'README.txt',
    'VERSION.txt',
    'CHANGELOG.md'
)
$missing = @($topLevelFiles | Where-Object {
    -not (Test-Path -LiteralPath (Join-Path $launcherDirectory $_) -PathType Leaf)
})
$benchmarkToolNames = @('needle_bench.py','serve_load.py')
foreach ($name in $benchmarkToolNames) {
    if (-not (Test-Path -LiteralPath (Join-Path $launcherDirectory (Join-Path 'benchmark\tools' $name)) -PathType Leaf)) {
        $missing += "benchmark\tools\$name"
    }
}
$licensePath = Join-Path $strataRoot 'LICENSE'
if (-not (Test-Path -LiteralPath $licensePath -PathType Leaf)) { $missing += '..\LICENSE' }
if ($missing.Count) { throw '无法构建分享包，缺少：' + ($missing -join ', ') }
$version = (Get-Content -LiteralPath (Join-Path $launcherDirectory 'VERSION.txt') -Raw -Encoding UTF8).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
    throw "启动器 VERSION.txt 不是有效版本号：$version"
}
$packageStem = "Strata-Launcher-v$version-for-existing-install"
$zipPath = Join-Path $output ($packageStem + '.zip')
$temporaryZip = Join-Path $output ($packageStem + '.tmp.zip')

[void](New-Item -ItemType Directory -Path $output -Force)
$temporaryRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('strata-launcher-package-' + [Guid]::NewGuid().ToString('N'))))
$systemTemporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $temporaryRoot.StartsWith($systemTemporaryRoot,[StringComparison]::OrdinalIgnoreCase)) {
    throw "临时打包目录不在系统临时目录中：$temporaryRoot"
}
$packageLauncher = Join-Path $temporaryRoot 'launcher'

try {
    [void](New-Item -ItemType Directory -Path $packageLauncher -Force)
    foreach ($name in $topLevelFiles) {
        Copy-Item -LiteralPath (Join-Path $launcherDirectory $name) -Destination (Join-Path $packageLauncher $name)
    }

    $packageBenchmark = Join-Path $packageLauncher 'benchmark'
    [void](New-Item -ItemType Directory -Path $packageBenchmark -Force)
    foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $launcherDirectory 'benchmark') -File |
        Where-Object { $_.Extension -in @('.py','.json','.ps1') } | Sort-Object Name)) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $packageBenchmark $file.Name)
    }
    $packageTools = Join-Path $packageBenchmark 'tools'
    [void](New-Item -ItemType Directory -Path $packageTools -Force)
    foreach ($name in $benchmarkToolNames) {
        Copy-Item -LiteralPath (Join-Path $launcherDirectory (Join-Path 'benchmark\tools' $name)) -Destination (Join-Path $packageTools $name)
    }
    Copy-Item -LiteralPath $licensePath -Destination (Join-Path $packageLauncher 'LICENSE-Strata.txt')

    if (Test-Path -LiteralPath $temporaryZip) { Remove-Item -LiteralPath $temporaryZip -Force }
    Compress-Archive -LiteralPath $packageLauncher -DestinationPath $temporaryZip -CompressionLevel Optimal
    Copy-Item -LiteralPath $temporaryZip -Destination $zipPath -Force
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $temporaryZip) {
        Remove-Item -LiteralPath $temporaryZip -Force
    }
}

Write-Output $zipPath
