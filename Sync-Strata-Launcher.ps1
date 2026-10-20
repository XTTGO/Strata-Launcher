param(
    [string]$StrataRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Strata')
)

$ErrorActionPreference = 'Stop'
$source = [IO.Path]::GetFullPath($PSScriptRoot)
$strata = [IO.Path]::GetFullPath($StrataRoot)
$target = [IO.Path]::GetFullPath((Join-Path $strata 'launcher'))
if ($source.TrimEnd('\') -eq $target.TrimEnd('\')) {
    throw '开发目录和运行目录相同；请从独立的 Strata-Launcher 开发仓库执行同步。'
}
if (-not (Test-Path -LiteralPath (Join-Path $strata 'START-HERE.bat') -PathType Leaf)) {
    throw "目标不是已安装的 Strata 根目录：$strata"
}
if (-not (Test-Path -LiteralPath $target -PathType Container)) {
    throw "目标启动器目录不存在：$target"
}

$builder = Join-Path $source 'Build-Launcher-Package.ps1'
$package = & $builder -StrataRoot $strata | Select-Object -Last 1
$temporaryRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('strata-launcher-sync-' + [Guid]::NewGuid().ToString('N'))))
$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $temporaryRoot.StartsWith($temporaryParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw "临时同步目录不在系统临时目录中：$temporaryRoot"
}
$protected = @('data', 'backups', 'reports', 'tests', 'docs', 'dist', '.git', '.gitignore', 'marketing')
$manifestPath = Join-Path $target '.launcher-sync-manifest.json'

try {
    Expand-Archive -LiteralPath $package -DestinationPath $temporaryRoot
    $expanded = [IO.Path]::GetFullPath((Join-Path $temporaryRoot 'launcher'))
    $expandedPrefix = $expanded.TrimEnd('\') + '\'
    $targetPrefix = $target.TrimEnd('\') + '\'
    $files = @(Get-ChildItem -LiteralPath $expanded -Recurse -File)
    $relativeFiles = @()
    foreach ($file in $files) {
        if (-not $file.FullName.StartsWith($expandedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "包内文件超出启动器目录：$($file.FullName)"
        }
        $relative = $file.FullName.Substring($expandedPrefix.Length)
        if (($relative -split '[\\/]')[0] -in $protected) {
            throw "包中包含本机私有目录：$relative"
        }
        $destination = [IO.Path]::GetFullPath((Join-Path $target $relative))
        if (-not $destination.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "同步目标越界：$destination"
        }
        $relativeFiles += $relative
    }

    $previous = @()
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $saved = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $saved.files) { $previous = @($saved.files) }
    }
    $stale = @($previous | Where-Object { $_ -notin $relativeFiles })
    foreach ($relative in $stale) {
        if (($relative -split '[\\/]')[0] -in $protected) {
            throw "历史清单包含私有目录，拒绝删除：$relative"
        }
        $path = [IO.Path]::GetFullPath((Join-Path $target $relative))
        if (-not $path.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "历史清单目标越界：$path"
        }
    }

    foreach ($file in $files) {
        $relative = $file.FullName.Substring($expandedPrefix.Length)
        $destination = Join-Path $target $relative
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force)
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    }
    foreach ($relative in $stale) {
        $path = Join-Path $target $relative
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    $manifest = [ordered]@{
        version = (Get-Content -LiteralPath (Join-Path $source 'VERSION.txt') -Raw -Encoding UTF8).Trim()
        source = $source
        files = @($relativeFiles | Sort-Object)
    }
    $manifestTemp = Join-Path $target ('.launcher-sync-manifest-' + [Guid]::NewGuid().ToString('N') + '.json')
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestTemp -Encoding UTF8
    Move-Item -LiteralPath $manifestTemp -Destination $manifestPath -Force
    [pscustomobject]@{Version=$manifest.version;Source=$source;Target=$target;Copied=$files.Count;Removed=$stale.Count}
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
