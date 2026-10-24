$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Strata-Launcher-Environment.ps1')

$temporaryParent = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.tmp'))
$probe = [IO.Path]::GetFullPath((Join-Path $temporaryParent ('source-version-' + [Guid]::NewGuid().ToString('N'))))
if (-not $probe.StartsWith($temporaryParent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test directory is outside tests/.tmp.'
}

function Invoke-TestGit([string[]]$Arguments) {
    & git @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Git fixture failed: $($Arguments -join ' ')" }
}

try {
    [void](New-Item -ItemType Directory -Path $probe)
    $root = Join-Path $probe 'Strata'
    $plain = Join-Path $probe 'unversioned'
    [void](New-Item -ItemType Directory -Path $plain)
    Invoke-TestGit @('init', '-b', 'main', $root)
    Invoke-TestGit @('-C', $root, 'config', 'user.name', 'Launcher Test')
    Invoke-TestGit @('-C', $root, 'config', 'user.email', 'launcher-test@example.invalid')
    [IO.File]::WriteAllText((Join-Path $root 'version.txt'), 'release')
    Invoke-TestGit @('-C', $root, 'add', 'version.txt')
    Invoke-TestGit @('-C', $root, 'commit', '-m', 'release')
    Invoke-TestGit @('-C', $root, 'tag', 'v0.2.4')
    if ((Get-StrataSourceVersion -Root $root) -ne 'v0.2.4') {
        throw 'An exact official tag should appear as the Strata source version.'
    }
    [IO.File]::WriteAllText((Join-Path $root 'version.txt'), 'development')
    Invoke-TestGit @('-C', $root, 'commit', '-am', 'next commit')
    if ((Get-StrataSourceVersion -Root $root) -notmatch '^v0\.2\.4-1-g[0-9a-f]+$') {
        throw 'A checkout ahead of the tag must be visibly identified as a development revision.'
    }
    if ((Get-StrataSourceVersion -Root $plain) -ne '未知') {
        throw 'An unversioned source folder must not claim a release number.'
    }
    'PASS: official tag, development revision, and unversioned source are distinguished'
} finally {
    if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Recurse -Force }
}
