$ErrorActionPreference = 'Stop'
$updater = Join-Path $PSScriptRoot '..\Strata-Launcher-Update.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($updater,[ref]$tokens,[ref]$parseErrors)
if (@($parseErrors).Count) { throw 'Updater cannot be parsed.' }
foreach ($definition in @($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false))) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$root = 'C:\strata-test'
$script:GitCalls = [Collections.ArrayList]::new()
$script:FailureMode = 'tls'

function git {
    [void]$script:GitCalls.Add([string[]]@($args))
    if ($script:FailureMode -eq 'generic') {
        'fatal: repository not found'
        $global:LASTEXITCODE = 128
        return
    }
    if ($script:GitCalls.Count -eq 1) {
        'fatal: unable to access https://github.com/Niko1221/Strata.git/: schannel: failed to receive handshake, SSL/TLS connection failed'
        $global:LASTEXITCODE = 128
        return
    }
    'mock fetch succeeded'
    $global:LASTEXITCODE = 0
}

Invoke-GitChecked @('fetch','--no-tags','origin','tag','v0.2.6') 'fetch release'
if ($script:GitCalls.Count -ne 2) { throw 'A schannel handshake failure should trigger one retry.' }
if ((@($script:GitCalls[1]) -join ' ') -notmatch 'http\.sslBackend=openssl') {
    throw 'Only the retry must switch Git to the verified OpenSSL TLS backend.'
}

$script:GitCalls.Clear()
$optional = Get-GitOutput @('fetch','--tags','--force','origin')
if ($optional.Code -ne 0 -or $script:GitCalls.Count -ne 2) {
    throw 'The optional tag fetch must use the same TLS retry.'
}

$script:GitCalls.Clear()
$script:FailureMode = 'generic'
$rejected = $false
try { Invoke-GitChecked @('fetch','origin') 'fetch release' } catch { $rejected = $true }
if (-not $rejected -or $script:GitCalls.Count -ne 1) {
    throw 'A non-TLS Git failure must not be retried.'
}

'PASS: updater retries schannel handshake failures with command-scoped OpenSSL only'
