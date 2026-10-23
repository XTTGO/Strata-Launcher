$ErrorActionPreference = 'Stop'
$launcher = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$updater = Join-Path $launcher 'Strata-Launcher-Update.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$temporaryParent = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.tmp'))
$probe = [IO.Path]::GetFullPath((Join-Path $temporaryParent ('official-update-' + [Guid]::NewGuid().ToString('N'))))
if (-not $probe.StartsWith($temporaryParent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test directory is outside tests/.tmp.'
}

function Invoke-TestGit([string[]]$GitArguments) {
    & git @GitArguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git test command failed: $($GitArguments -join ' ')" }
}

try {
    [void](New-Item -ItemType Directory -Path $probe -Force)
    $seed = Join-Path $probe 'seed'
    $remote = Join-Path $probe 'remote.git'
    $recipient = Join-Path $probe 'recipient Strata'
    Invoke-TestGit @('init', '-b', 'main', $seed)
    Invoke-TestGit @('-C', $seed, 'config', 'user.name', 'Launcher Test')
    Invoke-TestGit @('-C', $seed, 'config', 'user.email', 'launcher-test@example.invalid')
    [IO.File]::WriteAllText((Join-Path $seed 'START-HERE.bat'), '@echo off')
    [IO.File]::WriteAllText((Join-Path $seed 'UPDATE.bat'), '@echo off')
    [IO.File]::WriteAllText((Join-Path $seed 'version.txt'), 'one')
    Invoke-TestGit @('-C', $seed, 'add', '.')
    Invoke-TestGit @('-C', $seed, 'commit', '-m', 'first release')
    Invoke-TestGit @('-C', $seed, 'tag', 'v0.2.2')
    Invoke-TestGit @('init', '--bare', '-b', 'main', $remote)
    Invoke-TestGit @('-C', $seed, 'remote', 'add', 'origin', $remote)
    Invoke-TestGit @('-C', $seed, 'push', 'origin', 'main', '--tags')
    Invoke-TestGit @('clone', $remote, $recipient)
    Invoke-TestGit @('-C', $recipient, 'checkout', '-b', 'codex/no-upstream')

    [IO.File]::WriteAllText((Join-Path $seed 'version.txt'), 'two')
    Invoke-TestGit @('-C', $seed, 'commit', '-am', 'second release')
    Invoke-TestGit @('-C', $seed, 'tag', 'v0.2.3')
    Invoke-TestGit @('-C', $seed, 'push', 'origin', 'main', '--tags')
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $updater -StrataRoot $recipient -SourceOnly -ReleaseTag 'v0.2.3' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'No-upstream release update failed.' }
    $expected = (& git -C $seed rev-parse v0.2.3).Trim()
    $actual = (& git -C $recipient rev-parse HEAD).Trim()
    if ($actual -ne $expected) { throw 'The recipient branch did not fast-forward to the release.' }

    [IO.File]::WriteAllText((Join-Path $recipient 'version.txt'), 'local work')
    Invoke-TestGit @('-C', $recipient, 'config', 'user.name', 'Launcher Test')
    Invoke-TestGit @('-C', $recipient, 'config', 'user.email', 'launcher-test@example.invalid')
    Invoke-TestGit @('-C', $recipient, 'commit', '-am', 'local work')
    $savedHead = (& git -C $recipient rev-parse HEAD).Trim()
    [IO.File]::WriteAllText((Join-Path $seed 'version.txt'), 'three')
    Invoke-TestGit @('-C', $seed, 'commit', '-am', 'third release')
    Invoke-TestGit @('-C', $seed, 'tag', 'v0.2.4')
    Invoke-TestGit @('-C', $seed, 'push', 'origin', 'main', '--tags')
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $updater -StrataRoot $recipient -SourceOnly -ReleaseTag 'v0.2.4' | Out-Null
    if ($LASTEXITCODE -eq 0) { throw 'A diverged branch was accepted.' }
    if ((& git -C $recipient rev-parse HEAD).Trim() -ne $savedHead) { throw 'A diverged branch was changed.' }
    if ((Get-Content -LiteralPath (Join-Path $recipient 'version.txt') -Raw) -ne 'local work') {
        throw 'Local work was not preserved.'
    }
    'PASS: launcher update fast-forwards a no-upstream release and preserves diverged local work'
} finally {
    if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Recurse -Force }
}
