param(
    [string]$StrataRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$SourceOnly,
    [string]$ReleaseTag = ''
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($StrataRoot)
$startHere = Join-Path $root 'START-HERE.bat'
$officialUpdate = Join-Path $root 'UPDATE.bat'

function Invoke-GitChecked([string[]]$GitArguments, [string]$Step) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git -C $root @GitArguments | Out-Host
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($code -ne 0) { throw "$Step 失败（git 退出码 $code）。本地文件没有被重置或覆盖。" }
}

function Get-GitOutput([string[]]$GitArguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $root @GitArguments 2>$null)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ Code = $code; Lines = @($output) }
}

function Update-Source {
    if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
        Write-Host '此 Strata 安装不是 Git 检出，交由官方 UPDATE.bat 检查本机安装。'
        return $false
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw '这是 Git 安装，但找不到 git.exe；请先安装 Git for Windows。'
    }
    $top = Get-GitOutput @('rev-parse', '--show-toplevel')
    if ($top.Code -ne 0 -or @($top.Lines).Count -ne 1 -or
            -not [string]::Equals([IO.Path]::GetFullPath([string]$top.Lines[0]).TrimEnd('\'),
                                  $root.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Strata 根目录不是 Git 工作树顶层：$root"
    }
    $branch = Get-GitOutput @('symbolic-ref', '-q', '--short', 'HEAD')
    if ($branch.Code -ne 0) { throw '当前处于 detached HEAD；请先选择要更新的 Strata 分支。' }

    $upstream = Get-GitOutput @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')
    if ($upstream.Code -eq 0 -and @($upstream.Lines).Count -eq 1) {
        Write-Host "从上游 $($upstream.Lines[0]) 快进更新 Strata 源码 ..."
        Invoke-GitChecked @('pull', '--ff-only') '更新 Strata 源码'
        return $true
    }

    if (-not $ReleaseTag) {
        Write-Host '当前分支没有上游，读取 Strata 官方最新稳定 Release ...'
        $request = [Net.WebRequest]::Create('https://github.com/Niko1221/Strata/releases/latest')
        $request.Method = 'HEAD'
        $request.Timeout = 30000
        $response = $request.GetResponse()
        try { $releaseUrl = $response.ResponseUri.AbsoluteUri } finally { $response.Close() }
        if ($releaseUrl -notmatch '^https://github\.com/Niko1221/Strata/releases/tag/(v\d+\.\d+\.\d+)$') {
            throw "无法从官方最新稳定 Release 链接读取版本：$releaseUrl"
        }
        $ReleaseTag = $Matches[1]
    }
    if ($ReleaseTag -notmatch '^v\d+\.\d+\.\d+$') { throw "无效的稳定 Release 标签：$ReleaseTag" }
    Write-Host "当前分支 $($branch.Lines[0]) 没有上游；检查最新稳定 Release $ReleaseTag 的快进更新 ..."
    Invoke-GitChecked @('fetch', '--no-tags', 'origin', 'tag', $ReleaseTag) '获取 Strata 稳定版'
    $ancestor = Get-GitOutput @('merge-base', '--is-ancestor', 'HEAD', $ReleaseTag)
    if ($ancestor.Code -eq 1) {
        throw "当前分支不能快进到 $ReleaseTag；请先处理分支差异，启动器不会合并或重置。"
    }
    if ($ancestor.Code -ne 0) { throw '无法验证当前分支与稳定 Release 的关系。' }
    Invoke-GitChecked @('merge', '--ff-only', $ReleaseTag) '快进 Strata 源码'
    return $true
}

function Get-SourceEngineVersion {
    $cmakePath = Join-Path $root 'CMakeLists.txt'
    if (-not (Test-Path -LiteralPath $cmakePath -PathType Leaf)) { throw "更新后缺少：$cmakePath" }
    $cmake = Get-Content -LiteralPath $cmakePath -Raw -Encoding UTF8
    $sourceMatch = [regex]::Match($cmake, '(?m)^project\(strata\s+VERSION\s+(\d+(?:\.\d+)+)\b')
    if (-not $sourceMatch.Success) { throw '无法读取 Strata 源码的目标引擎版本。' }
    return $sourceMatch.Groups[1].Value
}

function Get-InstalledEngineVersion {
    $buildPath = Join-Path $root 'engine\BUILD.json'
    if (-not (Test-Path -LiteralPath $buildPath -PathType Leaf)) { return $null }
    $build = Get-Content -LiteralPath $buildPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $installedVersion = [string]$build.version
    if ($installedVersion -notmatch '^\d+(?:\.\d+)+$') { throw 'engine/BUILD.json 缺少有效版本号。' }
    return $installedVersion
}

function Invoke-SignedFeedEngineUpdate {
    $python = @(
        (Join-Path $root 'python\python.exe'),
        (Join-Path $root '.venv\Scripts\python.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $python) { throw '找不到 Strata 使用的 Python，无法从官方签名更新源获取引擎。' }
    if (-not (Test-Path -LiteralPath (Join-Path $root 'strata.py') -PathType Leaf)) {
        throw '当前 Strata 源码没有签名更新命令 strata.py。'
    }
    Write-Host '官方旧安装流程未装到源码要求的引擎版本；调用 Strata 的签名更新源并同步到旧版 engine 目录 ...'
    $bridge = 'import setup; result = setup.engine_from_feed(setup.engine_dir(13), updating=True); raise SystemExit(0 if result is not None else 6)'
    & $python -c $bridge | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "官方签名引擎更新失败（退出码 $LASTEXITCODE）。" }
}

function Assert-EngineUpdated {
    $buildPath = Join-Path $root 'engine\BUILD.json'
    $exePath = Join-Path $root 'engine\strata.exe'
    foreach ($file in @($buildPath, $exePath)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "更新后缺少：$file" }
    }
    $sourceVersion = Get-SourceEngineVersion
    $installedVersion = Get-InstalledEngineVersion
    $binaryOutput = (& $exePath --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $binaryOutput -notmatch '\bstrata\s+(\d+(?:\.\d+)+)\b') {
        throw "引擎可执行文件无法报告版本：$binaryOutput"
    }
    if ($Matches[1] -ne $installedVersion) {
        throw "引擎文件版本 $($Matches[1]) 与 BUILD.json 的 $installedVersion 不一致。"
    }
    if ([version]$installedVersion -lt [version]$sourceVersion) {
        throw "源码已更新，但引擎仍为 $installedVersion；当前源码目标为 $sourceVersion。请查看上方官方更新错误。"
    }
    Write-Host "更新验证通过：源码目标引擎 $sourceVersion；已安装引擎 $installedVersion。"
}

try {
    if (-not (Test-Path -LiteralPath $startHere -PathType Leaf) -or
            -not (Test-Path -LiteralPath $officialUpdate -PathType Leaf)) {
        throw "找不到官方 START-HERE.bat 或 UPDATE.bat：$root"
    }
    $sourceUpdated = Update-Source
    if ($SourceOnly) {
        Write-Host 'Strata 源码快进检查完成；按要求未运行引擎更新。'
        exit 0
    }
    Push-Location -LiteralPath $root
    try {
        if ($sourceUpdated) {
            Write-Host '运行官方 START-HERE.bat --update ...'
            & $startHere '--update'
        } else {
            & $officialUpdate
        }
        $updateExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($updateExit -ne 0) { throw "官方更新脚本退出码为 $updateExit。" }
    $sourceVersion = Get-SourceEngineVersion
    $installedVersion = Get-InstalledEngineVersion
    if (-not $installedVersion -or [version]$installedVersion -lt [version]$sourceVersion) {
        Invoke-SignedFeedEngineUpdate
    }
    Assert-EngineUpdated
    Write-Host 'Strata 源码及引擎更新完成。'
    exit 0
} catch {
    Write-Host "Strata 更新未完成：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
