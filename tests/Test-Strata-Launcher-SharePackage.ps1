$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}

$launcherRoot = (Resolve-Path 'launcher').Path
$builder = Join-Path $launcherRoot 'Build-Launcher-Package.ps1'
$version = (Get-Content -LiteralPath (Join-Path $launcherRoot 'VERSION.txt') -Raw -Encoding UTF8).Trim()
$probeBase = Join-Path ([IO.Path]::GetTempPath()) ('strata launcher package ' + [Guid]::NewGuid().ToString('N'))
$outputDirectory = Join-Path $probeBase 'output with spaces'
$expanded = Join-Path $probeBase 'expanded'

try {
    $zipOutput = & $builder -OutputDirectory $outputDirectory | Select-Object -Last 1
    Assert-True (Test-Path -LiteralPath $zipOutput -PathType Leaf) 'the share-package builder should produce a ZIP'
    Assert-True ([IO.Path]::GetFileName($zipOutput) -eq "Strata-Launcher-v$version-for-existing-install.zip") 'the ZIP name should show the launcher version'

    Expand-Archive -LiteralPath $zipOutput -DestinationPath $expanded
    $packagedLauncher = Join-Path $expanded 'launcher'
    Assert-True ((Get-Content -LiteralPath (Join-Path $packagedLauncher 'VERSION.txt') -Raw -Encoding UTF8).Trim() -eq $version) 'the ZIP name and packaged version should agree'
    foreach ($relative in @(
        'Strata-Launcher.bat',
        'Strata-Launcher.ps1',
        'Strata-Launcher-Environment.ps1',
        'Strata-Launcher-Settings.ps1',
        'Strata-Launcher-Theme.ps1',
        'Strata-Launcher-GpuPower.ps1',
        'Strata-Launcher-Lan.ps1',
        'Strata-Launcher-LanFirewall.ps1',
        'Build-Launcher-Package.ps1',
        'Strata-Launcher-Reload.ps1',
        'Strata-Calibration-View.ps1',
        'Strata-Calibrate-Current.py',
        'Benchmark-Launcher.ps1',
        'README.txt',
        'VERSION.txt',
        'CHANGELOG.md',
        'LICENSE-Strata.txt',
        'benchmark\runner.py',
        'benchmark\tools\needle_bench.py',
        'benchmark\tools\serve_load.py',
        'benchmark\capacity.py',
        'benchmark\agent_cases.json',
        'benchmark\Run-State.ps1'
    )) {
        Assert-True (Test-Path -LiteralPath (Join-Path $packagedLauncher $relative) -PathType Leaf) "the package should contain $relative"
    }
    foreach ($name in @('needle_bench.py','serve_load.py')) {
        $packaged = Join-Path $packagedLauncher (Join-Path 'benchmark\tools' $name)
        $source = Join-Path $launcherRoot (Join-Path 'benchmark\tools' $name)
        Assert-True ((Get-FileHash -LiteralPath $packaged -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash) "the packaged $name should match the tested source"
    }

    foreach ($privateDirectory in @('data','backups','reports','tests','docs','__pycache__','dist')) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $packagedLauncher $privateDirectory))) "the package should exclude $privateDirectory"
    }
    Assert-True (-not (Get-ChildItem -LiteralPath $packagedLauncher -Recurse -File | Where-Object { $_.Extension -in @('.pyc','.log') })) 'the package should exclude caches and logs'

    $text = (Get-ChildItem -LiteralPath $packagedLauncher -Recurse -File |
        Where-Object { $_.Extension -in @('.ps1','.bat','.py','.txt','.json','.md') } |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
    Assert-True ($text -notmatch [Regex]::Escape('D:\AI\Strata')) 'the package should not contain the author machine Strata path'
    Assert-True ($text -notmatch [Regex]::Escape('F:\AI\Strata-data')) 'the package should not contain the author machine data path'
    Assert-True ($text -notmatch 'XTT_AIGC') 'the package should not contain the author Windows account name'

    'PASS: share package contains only portable launcher runtime files'
} finally {
    if (Test-Path -LiteralPath $probeBase) {
        Remove-Item -LiteralPath $probeBase -Recurse -Force
    }
}
