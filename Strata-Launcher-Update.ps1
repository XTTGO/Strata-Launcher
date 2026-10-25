param(
    [string]$StrataRoot = '',
    [switch]$SourceOnly,
    [switch]$VerifyOnly,
    [switch]$EngineOnly,
    [switch]$DeepSeekEngineOnly,
    [string]$ReleaseTag = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Strata-Launcher-Environment.ps1')
# The same rule the launcher uses: the parent folder, or a "Strata" folder beside the launcher.
$root = if ($StrataRoot) {
    [IO.Path]::GetFullPath($StrataRoot)
} else {
    [IO.Path]::GetFullPath((Resolve-StrataLauncherRoot -LauncherDirectory $PSScriptRoot))
}
$startHere = Join-Path $root 'START-HERE.bat'
$officialUpdate = Join-Path $root 'UPDATE.bat'

function Invoke-GitCommand([string[]]$GitArguments, [switch]$OpenSsl) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($OpenSsl) {
            $output = @(& git -c http.sslBackend=openssl -C $root @GitArguments 2>&1)
        } else {
            $output = @(& git -C $root @GitArguments 2>&1)
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ Code = $code; Lines = @($output | ForEach-Object { [string]$_ }) }
}

function Invoke-GitWithTlsRetry([string[]]$GitArguments) {
    $first = Invoke-GitCommand -GitArguments $GitArguments
    if ($first.Code -ne 0 -and $GitArguments.Count -gt 0 -and $GitArguments[0] -in @('fetch','pull') -and
            (($first.Lines -join "`n") -match '(?is)schannel:.*(?:handshake|SSL/TLS connection failed)')) {
        Write-Host 'Git 的 schannel TLS 握手失败；仅对本次 Git 命令改用 OpenSSL 重试（证书验证仍开启）...'
        $retry = Invoke-GitCommand -GitArguments $GitArguments -OpenSsl
        if ($retry.Code -ne 0) {
            return [pscustomobject]@{ Code = $retry.Code; Lines = @($first.Lines) + @($retry.Lines) }
        }
        return $retry
    }
    return $first
}

function Invoke-GitChecked([string[]]$GitArguments, [string]$Step) {
    $result = Invoke-GitWithTlsRetry -GitArguments $GitArguments
    foreach ($line in $result.Lines) { Write-Host $line }
    if ($result.Code -ne 0) { throw "$Step 失败（git 退出码 $($result.Code)）。本地文件没有被重置或覆盖。" }
}

function Get-GitOutput([string[]]$GitArguments) {
    return Invoke-GitWithTlsRetry -GitArguments $GitArguments
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
        if ($releaseUrl -notmatch '^https://github\.com/Niko1221/Strata/releases/tag/(v\d+(?:\.\d+)+)$') {
            throw "无法从官方最新稳定 Release 链接读取版本：$releaseUrl"
        }
        $ReleaseTag = $Matches[1]
    }
    if ($ReleaseTag -notmatch '^v\d+(?:\.\d+)+$') { throw "无效的稳定 Release 标签：$ReleaseTag" }
    Write-Host "当前分支 $($branch.Lines[0]) 没有上游；检查最新稳定 Release $ReleaseTag 的快进更新 ..."
    Invoke-GitChecked @('fetch', '--no-tags', 'origin', 'tag', $ReleaseTag) '获取 Strata 稳定版'
    # Official patch releases (0.2.4.1, 0.2.4.2, ...) are tags with committed release notes; the GitHub
    # "latest release" page may still point at the older three-part release, so take the newest tag that
    # carries docs/release-notes-<version>.md as well.
    $tagFetch = Get-GitOutput @('fetch', '--tags', '--force', 'origin')
    if ($tagFetch.Code -eq 0) {
        $hasNotes = { param($tag) (Get-GitOutput @('cat-file', '-e', ($tag + ':docs/release-notes-' + $tag.Substring(1) + '.md'))).Code -eq 0 }
        $newer = Get-StrataNewestReleaseTag -ReleaseTag $ReleaseTag -Tags @((Get-GitOutput @('tag', '--list', 'v*')).Lines) -HasNotes $hasNotes
        if ($newer) {
            Write-Host "官方标签 $($newer.Tag) 比 Release 页面（$ReleaseTag）新，且带有发布说明；按该标签更新。"
            $ReleaseTag = $newer.Tag
            Invoke-GitChecked @('fetch', '--no-tags', 'origin', 'tag', $ReleaseTag) '获取 Strata 稳定版'
        }
    }
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

function Get-StrataFeedModelConfig {
    # The signed feed test-starts the new engine with an installed model. Left to itself the updater picks one by
    # id, and a DeepSeek config sends its dsv41 flags to the Strata (Qwen) engine, which rejects --eos: the test
    # start then looks like a broken engine (seen on 2026-10-25 with engine 0.1.50). Offer only configs that
    # start engine\strata.exe.
    foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Filter 'strata-*.json' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if ($file.Name -like '*.shared-settings.json' -or $file.Name -like '*.vision.json') { continue }
        try {
            $candidate = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch { continue }
        if ([string]$candidate.arch -eq 'deepseek41') { continue }
        $exe = [string]$candidate.exe
        if (-not $exe -or $exe -match 'dsv41') { continue }
        if ((Split-Path -Leaf ($exe -replace '/', '\')) -notmatch '^strata(?:\.exe)?$') { continue }
        return $file.FullName
    }
    return ''
}

function Test-TransferTruncated([string]$Text) {
    # The official downloader resumes across runs (the partial file is keyed by the package's SHA-256) but has no
    # retry inside one run: a dropped connection ends the step although the bytes so far are intact and the CDN
    # answers Range requests from exactly there. These are its own wordings for that case.
    return ($Text -match 'the partial file is kept' -or
            $Text -match 'delivered \d+ of \d+ bytes' -or
            $Text -match 'was interrupted after \d+ of \d+ bytes')
}

function Invoke-FeedUpdateCommand {
    param([string]$Python, [string[]]$FeedArguments)

    # A native command's stderr arrives as an error record: with $ErrorActionPreference = 'Stop' its first line would
    # end the script and hide the reason, so this call captures stderr like any other output.
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $text = (& $Python @FeedArguments 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    $status = ''
    $note = ''
    try {
        $parsed = $text | ConvertFrom-Json
        $engine = @(@($parsed.results) | Where-Object { $_.component -eq 'engine' })[0]
        if ($engine) {
            $status = [string]$engine.status
            $note = ([string]$engine.note).Trim()
        }
    } catch { }
    return [pscustomobject]@{ Code = $code; Text = $text; Status = $status; Note = $note }
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
    $modelConfig = Get-StrataFeedModelConfig

    [string[]]$feedArguments = @('strata.py', 'update', '--no-control', '--output', 'json')
    if ($modelConfig) { $feedArguments += @('--model-config', $modelConfig) }
    Write-Host '从 Strata 官方签名更新源取本机最新引擎（签名、逐文件哈希、试启动通过后才替换）...'
    if ($modelConfig) { Write-Host "  官方试启动使用：$modelConfig" }
    # `strata.py` and `python -c` resolve the Strata sources against the working directory, so run from the root:
    # the caller may sit anywhere (a terminal, the launcher's own folder).
    $previousStore = $env:STRATA_COMPONENTS_DIR
    Push-Location -LiteralPath $root
    try {
        # engine_from_feed stages into setup.home()/engine-feed and copies from there. The update must use the same
        # store: left to its default the updater installs into the per-user component folder, engine_from_feed then
        # finds only the old engine there and "updates" engine\ with the version already installed.
        $store = @(& $python -c "import setup; print(setup.home() / 'engine-feed')" 2>$null |
            Where-Object { ([string]$_).Trim() -match 'engine-feed$' })[-1]
        if (-not $store) { $store = Join-Path $root 'engine-feed' }
        $env:STRATA_COMPONENTS_DIR = ([string]$store).Trim()
        $run = Invoke-FeedUpdateCommand -Python $python -FeedArguments $feedArguments
        $transferAttempt = 1
        while ((Test-TransferTruncated $run.Text) -and $transferAttempt -lt 4) {
            $transferAttempt++
            Write-Host "  下载被中断，续传（第 $transferAttempt/4 次，接着已下载的部分）..."
            $run = Invoke-FeedUpdateCommand -Python $python -FeedArguments $feedArguments
        }
        if (($run.Status -eq 'failed-before' -or $run.Text -match 'failed its test start') -and
                $run.Text -notmatch 'was rolled back from') {
            # The updater holds a version for a day after a failed test start. A test start that used the wrong
            # model config says nothing about the engine, and --force runs every check again: one retry, never a
            # loop. A rollback (skipped) is the user's decision and is left alone.
            Write-Host "签名更新源记着该版本试启动失败（$($run.Note)）；换用能启动 engine 的模型配置重试一次 ..."
            $feedArguments += '--force'
            $run = Invoke-FeedUpdateCommand -Python $python -FeedArguments $feedArguments
        }
        if ($run.Code -ne 0) {
            $why = if ($run.Note) { $run.Note } elseif ($run.Text) { $run.Text } else { "退出码 $($run.Code)" }
            if ($why.Length -gt 600) { $why = $why.Substring(0, 600) + ' ...' }
            throw "官方签名更新源没有装上新引擎：$why"
        }
        if ($run.Note) { Write-Host "  $($run.Note)" }
        # The update staged the verified engine in the component store; engine_from_feed then copies it into
        # engine\ (its own update call is a no-op now, the store already holds the newest version).
        $bridge = 'import setup; result = setup.engine_from_feed(setup.engine_dir(13), updating=True); raise SystemExit(0 if result is not None else 6)'
        & $python -c $bridge | Out-Host
        $bridgeExit = $LASTEXITCODE
    } finally {
        if ($null -eq $previousStore) {
            Remove-Item Env:STRATA_COMPONENTS_DIR -ErrorAction SilentlyContinue
        } else {
            $env:STRATA_COMPONENTS_DIR = $previousStore
        }
        Pop-Location
    }
    if ($bridgeExit -ne 0) { throw "官方签名引擎更新失败（退出码 $bridgeExit）。" }
}

function Invoke-EngineOnly {
    # The official UPDATE.bat only replaces a ready-made engine that is below MIN_ENGINE, so a release's newer
    # engine (0.2.6 ships 0.1.50 while MIN_ENGINE stays 0.1.46) never arrives on an existing install. This path
    # takes the newest engine the signed feed offers for this PC, with the checks the official update uses.
    $status = Get-StrataEngineVersionStatus -Root $root
    if ($status.InstallSource -eq 'local') {
        throw "当前 engine 是本地编译引擎（$($status.InstalledVersion)）；启动器不会用预编译包替换它。请用官方 setup.py --build 重新编译引擎。"
    }
    # A DeepSeek-only install has no Qwen engine and no config that could test-start one: the official updater would
    # download the package and fail the question probe against the DeepSeek config. Say it instead of downloading.
    if (-not (Get-StrataFeedModelConfig) -and -not (Test-Path -LiteralPath (Join-Path $root 'engine\strata.exe') -PathType Leaf)) {
        throw '这个安装没有 Qwen 引擎（engine\strata.exe），也没有能启动它的模型配置（strata-*.json 里只有 DeepSeek）：官方试启动需要一个 Qwen 模型。先装一个 Qwen 模型，再用这个按钮。'
    }
    $exePath = Join-Path $root 'engine\strata.exe'
    if (Test-Path -LiteralPath $exePath -PathType Leaf) {
        try {
            $stream = [IO.File]::Open($exePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $stream.Close()
        } catch {
            throw 'engine\strata.exe 正在被占用：请先停止 Strata（以及任何直接运行的模型），再更新引擎。'
        }
    }
    $before = Get-InstalledEngineVersion
    $label = if ($before) { $before } else { '未安装' }
    Write-Host "当前引擎：$label。官方更新只在低于兼容下限时替换引擎，这里直接取签名更新源里这台机器的最新版 ..."
    Invoke-SignedFeedEngineUpdate
    Assert-EngineUpdated
    $after = Get-InstalledEngineVersion
    Write-Host "引擎更新完成：$label → $after。"
    if ($before -and $after -eq $before) {
        Write-Host '签名更新源已是最新版本，engine 目录没有被替换。'
        return
    }
    Write-Host '旧引擎保留在 engine\.previous；回退：.venv\Scripts\python.exe setup.py --rollback-engine'
}

function Invoke-DeepSeekEngineOnly {
    # DeepSeek-V4.1-Flash runs its own engine package (engine-dsv41\, feed member "dsv41"). Neither UPDATE.bat nor
    # `strata update` touches it: official setup upgrades it only inside the DeepSeek install flow
    # (setup.install_dsv41 -> setup.upgrade_dsv41_engine). This calls that same upgrade, so the engine can arrive
    # without re-running the model install; its test start only runs `strata-dsv41 --version` (no model, no GPU).
    $deepSeek = Get-StrataDeepSeekEngineStatus -Root $root
    if (-not $deepSeek.InstalledVersion -or -not $deepSeek.Path) {
        throw "这个安装没有 DeepSeek 引擎（engine-dsv41 里没有 strata-dsv41.exe），没有可更新的对象。"
    }
    try {
        $stream = [IO.File]::Open($deepSeek.Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $stream.Close()
    } catch {
        throw 'strata-dsv41.exe 正在被占用：请先停止 Strata（DeepSeek 模型还在运行），再更新引擎。'
    }
    $python = @(
        (Join-Path $root 'python\python.exe'),
        (Join-Path $root '.venv\Scripts\python.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $python) { throw '找不到 Strata 使用的 Python，无法从官方签名更新源获取 DeepSeek 引擎。' }
    if (-not (Test-Path -LiteralPath (Join-Path $root 'strata.py') -PathType Leaf)) {
        throw '当前 Strata 源码没有签名更新命令 strata.py。'
    }
    $before = [string]$deepSeek.InstalledVersion
    Write-Host "当前 DeepSeek 引擎：$before（$($deepSeek.Directory)）"
    Write-Host '从 Strata 官方签名更新源取 DeepSeek 引擎（签名、逐文件哈希、--version 试启动通过后才切换）...'
    # Single-quoted here-string: the Python below must reach the interpreter unchanged.
    $bridge = @'
import json, sys
from pathlib import Path

# A script file puts its own folder on sys.path, not the working directory: the Strata root comes in as argv[1].
sys.path.insert(0, sys.argv[1])
import setup


def version_of(exe):
    try:
        return json.loads((Path(exe).parent / "BUILD.json").read_text(encoding="utf-8"))["version"]
    except Exception:
        return Path(exe).parent.name.split("-")[0]


eng = setup.ROOT / "engine"
exe = setup.dsv41_exe(eng)
old = version_of(exe) if exe else None
new = setup.upgrade_dsv41_engine(eng, exe) if exe else None
now = version_of(new) if new else old
print("DSV41_RESULT " + json.dumps({"before": old, "after": now}))
raise SystemExit(0 if now else 6)
'@
    # A file, not `python -c`: PowerShell 5's native argument passing breaks on the embedded quotes of even a
    # short Python program, and the interpreter reads the file as UTF-8 regardless of the console code page.
    $bridgePath = Join-Path ([IO.Path]::GetTempPath()) ('strata-dsv41-update-' + [Guid]::NewGuid().ToString('N') + '.py')
    [IO.File]::WriteAllText($bridgePath, $bridge, [Text.UTF8Encoding]::new($false))
    Push-Location -LiteralPath $root
    # A native command's stderr arrives as an error record: with $ErrorActionPreference = 'Stop' its first line would
    # end the script and hide the reason, so this call captures stderr like any other output.
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $transferAttempt = 1
    try {
        while ($true) {
            $output = (& $python $bridgePath $root 2>&1 | Out-String).Trim()
            $bridgeExit = $LASTEXITCODE
            # A dropped transfer is worth another attempt: the partial file continues where it stopped.
            if (-not (Test-TransferTruncated $output) -or $transferAttempt -ge 4) { break }
            $transferAttempt++
            Write-Host "  下载被中断，续传（第 $transferAttempt/4 次，接着已下载的部分）..."
        }
    } finally {
        $ErrorActionPreference = $previousErrorAction
        Pop-Location
        Remove-Item -LiteralPath $bridgePath -Force -ErrorAction SilentlyContinue
    }
    foreach ($line in @($output -split "`r?`n" | Where-Object { $_ -notmatch '^DSV41_RESULT ' -and $_.Trim() })) {
        Write-Host "  $line"
    }
    $resultLine = @($output -split "`r?`n" | Where-Object { $_ -match '^DSV41_RESULT ' })[-1]
    if (-not $resultLine) {
        if ($bridgeExit -ne 0) { throw "官方签名源没有完成 DeepSeek 引擎更新（退出码 $bridgeExit）。" }
        throw 'DeepSeek 引擎更新没有返回结果；请查看上面的输出。'
    }
    $result = $resultLine.Substring('DSV41_RESULT '.Length) | ConvertFrom-Json
    $after = [string]$result.after
    if (-not $after) { throw '更新后无法读取 DeepSeek 引擎版本。' }
    $refusal = @($output -split "`r?`n" | Where-Object { $_ -match 'could not be installed|could not be checked|could not be fetched|could not resume' })[-1]
    if ($after -eq $before -and $refusal) {
        throw "DeepSeek 引擎保持 $before：官方签名源没有装上新版本——$($refusal.Trim())"
    }
    if ($after -eq $before) {
        Write-Host "DeepSeek 引擎保持 $before：签名源没有更新的版本。"
    } else {
        Write-Host "DeepSeek 引擎已更新：$before → $after（官方流程只保留一代，旧目录已删除）。"
    }
    $verify = Get-StrataDeepSeekEngineStatus -Root $root
    if (-not $verify.InstalledVersion -or [string]$verify.InstalledVersion -ne $after) {
        throw "更新后 engine-dsv41 的版本（$($verify.InstalledVersion)）与更新程序报告的 $after 不一致。"
    }
    $binary = (& $verify.Path --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $binary -notmatch '\d+(?:\.\d+)+') { throw "strata-dsv41.exe 无法报告版本：$binary" }
    Write-Host "验证通过：$binary（$($verify.Path)）"
    foreach ($fixed in @(Repair-StrataEngineConfigFiles -Root $root -NewEngineExe ([string]$verify.Path))) {
        Write-Host "  已把 $($fixed.Config) 的引擎路径改到 $(Split-Path -Leaf $fixed.To)（官方升级只保留一代，旧目录已被删除）"
    }
}

function Assert-EngineUpdated {
    $buildPath = Join-Path $root 'engine\BUILD.json'
    $exePath = Join-Path $root 'engine\strata.exe'
    foreach ($file in @($buildPath, $exePath)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "更新后缺少：$file" }
    }
    $sourceVersion = Get-SourceEngineVersion
    $installedVersion = Get-InstalledEngineVersion
    $engineStatus = Get-StrataEngineVersionStatus -Root $root
    if ($engineStatus.Issue) { throw $engineStatus.Issue }
    if (-not $engineStatus.RequiredVersion) { throw '无法读取 Strata 官方 MIN_ENGINE 兼容下限。' }
    $binaryOutput = (& $exePath --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $binaryOutput -notmatch '\bstrata\s+(\d+(?:\.\d+)+)\b') {
        throw "引擎可执行文件无法报告版本：$binaryOutput"
    }
    if ($Matches[1] -ne $installedVersion) {
        throw "引擎文件版本 $($Matches[1]) 与 BUILD.json 的 $installedVersion 不一致。"
    }
    if ([version]$installedVersion -lt $engineStatus.RequiredVersion) {
        if ($engineStatus.InstallSource -eq 'local') {
            throw "本地编译引擎仍为 $installedVersion，低于当前源码构建目标 $($engineStatus.RequiredVersion)；请重新编译。"
        }
        throw "预编译引擎仍为 $installedVersion，低于 Strata 官方兼容下限 $($engineStatus.RequiredVersion)；请查看上方官方更新错误。"
    }
    Write-Host "更新验证通过：源码构建目标 $sourceVersion；官方兼容下限 $($engineStatus.MinimumVersion)；已安装引擎 $installedVersion ($($engineStatus.InstallSource))。"
}

try {
    if (-not (Test-Path -LiteralPath $startHere -PathType Leaf) -or
            -not (Test-Path -LiteralPath $officialUpdate -PathType Leaf)) {
        throw "找不到官方 START-HERE.bat 或 UPDATE.bat：$root"
    }
    if ($VerifyOnly) {
        Assert-EngineUpdated
        exit 0
    }
    if ($EngineOnly) {
        Invoke-EngineOnly
        exit 0
    }
    if ($DeepSeekEngineOnly) {
        Invoke-DeepSeekEngineOnly
        exit 0
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
    $engineStatus = Get-StrataEngineVersionStatus -Root $root
    if ($engineStatus.Issue) { throw $engineStatus.Issue }
    if (-not $engineStatus.RequiredVersion) { throw '无法读取 Strata 官方 MIN_ENGINE 兼容下限。' }
    if ($engineStatus.InstallSource -ne 'local' -and
            (-not $engineStatus.InstalledVersion -or $engineStatus.InstalledVersion -lt $engineStatus.RequiredVersion)) {
        Invoke-SignedFeedEngineUpdate
    }
    Assert-EngineUpdated
    Write-Host 'Strata 源码更新和引擎兼容性验证完成。'
    exit 0
} catch {
    Write-Host "Strata 更新未完成：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
