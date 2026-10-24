#Requires -Version 5.1
<#
.SYNOPSIS
    按 docs/RELEASE.md 的规则发布一个 Strata Launcher 版本。

.DESCRIPTION
    一条命令走完：构建启动器包 -> 放进 releases\v<版本>\ 并写 SHA256SUMS.txt -> 校验包内版本号 ->
    git 提交并打标签 -> 推送 main 与标签 -> 建 GitHub Release 并上传 zip。

    凭据取自 Windows 凭据管理器（target: git:https://github.com），只在进程内使用，从不打印。
    git 必须用 openssl 后端（本机 schannel 会 SEC_E_NO_CREDENTIALS），脚本已写死。
    GitHub API 走 Python 的 requests（PowerShell 5.1 与 curl 在本机握手失败）。

.PARAMETER Version
    要发布的版本号，例如 0.1.9。必须与 VERSION.txt 一致；不一致时加 -Bump 由脚本改写 VERSION.txt。

.PARAMETER VerifyOnly
    只做一致性检查，不构建、不提交、不推送、不发 Release。发布后核对也用它。

.PARAMETER NoPush
    构建、提交、打标签，但不推送、不发 Release。

.PARAMETER NoRelease
    推送 main 与标签，但不建 GitHub Release（资产需自己上传）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Release-Launcher.ps1 -Version 0.1.9 -VerifyOnly

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Release-Launcher.ps1 -Version 0.1.9
#>
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$StrataRoot = 'D:\AI\Strata',
    [string]$PythonPath = '',
    [string]$Repo = 'XTTGO/Strata-Launcher',
    [switch]$Bump,
    [switch]$VerifyOnly,
    [switch]$NoPush,
    [switch]$NoRelease
)

$ErrorActionPreference = 'Stop'
# 放在仓库根目录或 tools\ 下都能用：脚本所在目录有构建脚本就是根目录，否则取上一级。
$thisDir = [IO.Path]::GetFullPath($PSScriptRoot)
$root = if (Test-Path -LiteralPath (Join-Path $thisDir 'Build-Launcher-Package.ps1')) {
    $thisDir
} else {
    [IO.Path]::GetFullPath((Split-Path -Parent $thisDir))
}
$versionPath = Join-Path $root 'VERSION.txt'
$releaseDir = Join-Path $root (Join-Path 'releases' ("v$Version"))
$notesPath = Join-Path $releaseDir 'RELEASE_NOTES.md'
$sumsPath = Join-Path $releaseDir 'SHA256SUMS.txt'
$zipName = "Strata-Launcher-v$Version-for-existing-install.zip"
$zipPath = Join-Path $releaseDir $zipName
$tag = "v$Version"

function Say([string]$Text) { Write-Host "== $Text" -ForegroundColor Cyan }
function Ok([string]$Text) { Write-Host "   OK  $Text" -ForegroundColor Green }
function Die([string]$Text) { throw $Text }

if ($Version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') { Die "版本号格式不对：$Version（示例 0.1.9 / 0.1.9-dev.1）" }
if (-not (Test-Path -LiteralPath (Join-Path $root 'Build-Launcher-Package.ps1'))) { Die "不在启动器仓库根目录：$root" }

$declared = (Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8).Trim()
if ($Bump -and -not $VerifyOnly) {
    if ($declared -ne $Version) {
        [IO.File]::WriteAllText($versionPath, $Version + "`r`n", [Text.UTF8Encoding]::new($false))
        Ok "VERSION.txt: $declared -> $Version（CHANGELOG / README / docs\deepseek-support-matrix.md 需要你手工同步）"
        $declared = $Version
    }
}

Say "检查 $tag"
if ($declared -ne $Version) { Die "VERSION.txt 是 $declared，与 $Version 不一致。先改版本号，或加 -Bump。" }
Ok "VERSION.txt = $declared"
if (-not (Test-Path -LiteralPath $notesPath -PathType Leaf)) { Die "缺少发布说明：$notesPath" }
Ok "RELEASE_NOTES.md 存在"
if (Test-Path -LiteralPath (Join-Path $root (Join-Path 'releases' ("v$Version")))) { Ok "release 目录已就绪" }

if ($VerifyOnly) {
    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) { Die "缺少发布包：$zipPath" }
    $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    if (-not (Test-Path -LiteralPath $sumsPath -PathType Leaf)) { Die "缺少 SHA256SUMS.txt" }
    $expected = (((Get-Content -LiteralPath $sumsPath -Raw) -split "`n")[0]).Split(' ')[0].Trim().ToUpperInvariant()
    if ($actual -ne $expected) { Die "包的哈希与 SHA256SUMS.txt 不一致：$actual vs $expected" }
    Ok "SHA-256 与 SHA256SUMS.txt 一致：$actual"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.Name -eq 'VERSION.txt' } | Select-Object -First 1
        if (-not $entry) { Die "包内没有 VERSION.txt" }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { $inside = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
    if ($inside -ne $Version) { Die "包内 VERSION.txt 是 $inside，不是 $Version" }
    Ok "包内 VERSION.txt = $Version"
    $tagCommit = git -C $root rev-parse --short "$tag^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) { Die "没有 $tag 标签；发布未完成" }
    $head = git -C $root rev-parse --short HEAD
    if ($tagCommit -ne $head) { Die "标签 $tag 指向 $tagCommit，HEAD 是 $head；请重新打标签" }
    Ok "标签 $tag -> $head"
    Say "核对通过：$tag 可以对外发布"
    exit 0
}

Say "构建启动器包"
$built = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Build-Launcher-Package.ps1') -StrataRoot $StrataRoot 2>&1 | Select-Object -Last 1
$built = "$built".Trim()
if (-not (Test-Path -LiteralPath $built -PathType Leaf)) { Die "构建失败，没有产出包：$built" }
[void](New-Item -ItemType Directory -Path $releaseDir -Force)
Copy-Item -LiteralPath $built -Destination $zipPath -Force
Ok ("包已放入 releases：{0}（{1:N0} 字节）" -f $zipName, (Get-Item $zipPath).Length)

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
[IO.File]::WriteAllText($sumsPath, "$hash  $zipName`n", [Text.UTF8Encoding]::new($false))
Ok "SHA256SUMS.txt = $hash"

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $entry = $zip.Entries | Where-Object { $_.Name -eq 'VERSION.txt' } | Select-Object -First 1
    if (-not $entry) { Die "包内没有 VERSION.txt" }
    $reader = [IO.StreamReader]::new($entry.Open())
    try { $inside = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
} finally { $zip.Dispose() }
if ($inside -ne $Version) { Die "包内 VERSION.txt 是 $inside，不是 $Version（构建脚本是不是没读到新版本？）" }
Ok "包内 VERSION.txt = $Version"

Say "提交并打标签"
$strataVersion = ''
try { $strataVersion = (git -C $StrataRoot describe --tags --abbrev=0 2>$null) } catch { }
$message = if ($strataVersion) { "Release Strata Launcher v$Version for Strata $strataVersion" } else { "Release Strata Launcher v$Version" }
git -C $root add -- "$versionPath" (Join-Path 'releases' "v$Version")
if ($LASTEXITCODE -ne 0) { Die "git add 失败" }
$pending = git -C $root status --porcelain -- "$versionPath" (Join-Path 'releases' "v$Version")
if ($pending) {
    git -C $root commit -m $message | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "git commit 失败" }
    Ok "已提交：$message"
} else {
    Ok "没有需要提交的改动（沿用现有提交）"
}
git -C $root tag -d $tag 2>$null | Out-Null
git -C $root tag $tag
if ($LASTEXITCODE -ne 0) { Die "打标签失败" }
Ok "标签 $tag -> $(git -C $root rev-parse --short HEAD)"

if ($NoPush) { Say "已停在本地（-NoPush）：未推送、未建 Release"; exit 0 }

Say "推送 main 与标签（openssl 后端）"
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class StrataReleaseCredential {
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool CredRead(string target, int type, int flags, out IntPtr credential);
  [DllImport("advapi32.dll")] static extern void CredFree(IntPtr cred);
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct CREDENTIAL { public int Flags; public int Type; public string TargetName; public string Comment; public long LastWritten; public int CredentialBlobSize; public IntPtr CredentialBlob; public int Persist; public int AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName; }
  public static string[] Read(string target) { IntPtr p; if (!CredRead(target,1,0,out p)) return null; try { CREDENTIAL c=(CREDENTIAL)Marshal.PtrToStructure(p,typeof(CREDENTIAL)); return new string[]{ c.UserName, c.CredentialBlobSize>0?Marshal.PtrToStringUni(c.CredentialBlob,c.CredentialBlobSize/2):"" }; } finally { CredFree(p); } }
}
'@ -Language CSharp
$cred = [StrataReleaseCredential]::Read('git:https://github.com')
if (-not $cred -or -not $cred[1]) { Die "凭据管理器里没有 git:https://github.com；先 git push 一次让 Git Credential Manager 存下凭据" }
$secret = $cred[1]
$url = "https://$($cred[0]):$secret@github.com/$Repo.git"
$env:GIT_TERMINAL_PROMPT = '0'
$mask = { param($t) (("$t") -replace [regex]::Escape($secret), '<redacted>') }
$pushMain = git -c http.sslBackend=openssl -C $root push $url main 2>&1
Write-Host (& $mask ($pushMain -join "`n"))
if ($LASTEXITCODE -ne 0) { Die "推送 main 失败" }
$pushTag = git -c http.sslBackend=openssl -C $root push $url $tag 2>&1
Write-Host (& $mask ($pushTag -join "`n"))
if ($LASTEXITCODE -ne 0) { Die "推送标签失败" }
git -C $root fetch origin --quiet
Ok "main 与 $tag 已推送"

if ($NoRelease) { Say "已推送（-NoRelease）：Release 与资产需手工创建"; exit 0 }

Say "创建 GitHub Release 并上传资产"
if (-not $PythonPath) {
    $candidates = @(
        (Join-Path $StrataRoot '.venv\Scripts\python.exe'),
        (Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
    )
    $PythonPath = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}
if (-not $PythonPath) { Die "找不到带 requests 的 Python；用 -PythonPath 指定（例如 D:\AI\Strata\.venv\Scripts\python.exe）" }
$uploader = Join-Path $env:TEMP ("strata-release-upload-" + [Guid]::NewGuid().ToString('N') + '.py')
$script = @'
import os, sys, requests
token = os.environ['GH_TOKEN']
repo, tag = os.environ['GH_REPO'], os.environ['GH_TAG']
asset, notes = os.environ['GH_ASSET'], os.environ['GH_NOTES']
with open(notes, encoding='utf-8') as fh:
    lines = fh.read().splitlines()
if lines and lines[0].startswith('# '):
    lines = lines[1:]
body = '\n'.join(lines).strip()
headers = {'Authorization': f'Bearer {token}', 'Accept': 'application/vnd.github+json',
           'X-GitHub-Api-Version': '2022-11-28'}
r = requests.post(f'https://api.github.com/repos/{repo}/releases',
                  json={'tag_name': tag, 'name': f'Strata Launcher {tag}', 'body': body,
                        'draft': False, 'prerelease': False}, headers=headers, timeout=60)
print('RELEASE_STATUS', r.status_code)
if r.status_code >= 400:
    print(r.text[:800]); sys.exit(1)
release = r.json()
print('RELEASE_URL', release['html_url'])
with open(asset, 'rb') as fh:
    up = requests.post(f'https://uploads.github.com/repos/{repo}/releases/{release["id"]}/assets',
                       params={'name': os.path.basename(asset)}, data=fh,
                       headers={**headers, 'Content-Type': 'application/zip'}, timeout=600)
print('ASSET_STATUS', up.status_code)
if up.status_code >= 400:
    print(up.text[:800]); sys.exit(1)
print('ASSET_URL', up.json()['browser_download_url'])
print('ASSET_SIZE', up.json()['size'])
'@
[IO.File]::WriteAllText($uploader, $script, [Text.UTF8Encoding]::new($false))
try {
    $env:GH_TOKEN = $secret
    $env:GH_REPO = $Repo
    $env:GH_TAG = $tag
    $env:GH_ASSET = $zipPath
    $env:GH_NOTES = $notesPath
    & $PythonPath $uploader
    if ($LASTEXITCODE -ne 0) { Die "创建 Release 或上传资产失败" }
} finally {
    $env:GH_TOKEN = $null; $env:GH_REPO = $null; $env:GH_TAG = $null
    $env:GH_ASSET = $null; $env:GH_NOTES = $null
    Remove-Item -LiteralPath $uploader -Force -ErrorAction SilentlyContinue
}

Say "$tag 已发布"
Write-Host "   核对：powershell -NoProfile -ExecutionPolicy Bypass -File tools\Release-Launcher.ps1 -Version $Version -VerifyOnly"
