param(
    [string]$StrataRoot = 'D:\AI\Strata',
    [string]$ConfigPath = 'D:\AI\Strata\strata-iq3_s.json',
    [int]$Port = 18080,
    [int]$StartupTimeoutSec = 600
)

$ErrorActionPreference = 'Stop'
$launcherRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $launcherRoot 'Strata-Launcher-GpuPlacement.ps1')
$python = Join-Path $StrataRoot '.venv\Scripts\python.exe'
$buildPath = Join-Path $StrataRoot 'engine\BUILD.json'
foreach ($path in @($python, $buildPath, $ConfigPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "缺少文件：$path" }
}
$cards = @(Get-StrataNvidiaPlacementCards)
if ($cards.Count -ne 2 -or @($cards | Where-Object { $_.Index -in @(0,1) }).Count -ne 2) {
    throw '此现场验收脚本要求 GPU 0 和 GPU 1 两张 NVIDIA 卡。'
}
$build = Get-Content -LiteralPath $buildPath -Raw | ConvertFrom-Json
$original = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$roles = @{ 0 = 'helper'; 1 = 'main' }
$config = Set-StrataGpuPlacementConfig -Config $original -Cards $cards -CurrentCards @(Get-StrataNvidiaPlacementCards) -Roles $roles -Build $build

$outDir = Join-Path $PSScriptRoot ('.tmp\multi-gpu-smoke-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$snapshotPath = Join-Path $outDir 'config.json'
$config.log = Join-Path $outDir 'engine.log'
$config.port = $Port
[IO.File]::WriteAllText($snapshotPath, ($config | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))

& $python (Join-Path $PSScriptRoot 'Strata-Launcher-MultiGpu-Smoke.py') $StrataRoot $snapshotPath "$Port" "$StartupTimeoutSec"
exit $LASTEXITCODE
