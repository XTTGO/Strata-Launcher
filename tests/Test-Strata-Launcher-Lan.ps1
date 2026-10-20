$ErrorActionPreference = 'Stop'
$launcher = (Resolve-Path 'launcher').Path
$module = Join-Path $launcher 'Strata-Launcher-Lan.ps1'
if (-not (Test-Path -LiteralPath $module)) { throw 'LAN helper is missing.' }
. $module

$testRoot = [IO.Path]::GetFullPath((Join-Path $launcher ('tests\lan-test-' + [Guid]::NewGuid().ToString('N'))))
[void](New-Item -ItemType Directory -Path $testRoot)
try {
    $keyPath = Join-Path $testRoot 'lan-key.dat'
    $modePath = Join-Path $testRoot 'lan-mode.json'

    $local = Get-StrataLanLaunchSettings -Enabled $false -KeyPath $keyPath
    if ($local.Host -ne '127.0.0.1' -or $local.ApiKey -or (Test-Path -LiteralPath $keyPath)) {
        throw 'Default/local mode created a key or exposed a LAN listener.'
    }

    $lan = Get-StrataLanLaunchSettings -Enabled $true -KeyPath $keyPath
    if ($lan.Host -ne '0.0.0.0' -or $lan.ApiKey -notmatch '^[A-Za-z0-9_-]{43}$') {
        throw 'LAN mode did not require a 256-bit URL-safe API key.'
    }
    $onDisk = [IO.File]::ReadAllBytes($keyPath)
    if ([Text.Encoding]::UTF8.GetString($onDisk).Contains($lan.ApiKey)) {
        throw 'Plaintext API key was written to disk.'
    }
    if ((Get-StrataLanLaunchSettings -Enabled $true -KeyPath $keyPath).ApiKey -ne $lan.ApiKey) {
        throw 'LAN key changed between starts.'
    }

    Set-StrataLanMode -Path $modePath -Enabled $true
    if (-not (Get-StrataLanMode -Path $modePath)) { throw 'Enabled LAN mode was not persisted.' }
    Set-StrataLanMode -Path $modePath -Enabled $false
    if (Get-StrataLanMode -Path $modePath) { throw 'Disabled LAN mode was not persisted.' }

    $before = [Environment]::GetEnvironmentVariable('STRATA_API_KEY','Process')
    $observed = Invoke-StrataLanWithKey -ApiKey $lan.ApiKey -Start { [Environment]::GetEnvironmentVariable('STRATA_API_KEY','Process') }
    if ($observed -ne $lan.ApiKey) { throw 'Started child did not inherit the LAN key.' }
    if ([Environment]::GetEnvironmentVariable('STRATA_API_KEY','Process') -ne $before) {
        throw 'Launcher process kept the temporary API key.'
    }
    $threw = $false
    try { [void](Invoke-StrataLanWithKey -ApiKey $lan.ApiKey -Start { throw 'start failed' }) } catch { $threw = $true }
    if (-not $threw -or [Environment]::GetEnvironmentVariable('STRATA_API_KEY','Process') -ne $before) {
        throw 'Launcher process kept the key after a failed start.'
    }

    $command = Get-StrataLanStartCommand -PythonPath 'D:\AI\Strata\.venv\Scripts\python.exe' -ServerPath 'D:\AI\Strata\serve\server.py' -ConfigPath 'D:\AI\Strata\strata-iq3_s.json' -Port 8080 -HostAddress $lan.Host
    if ($command -notmatch '--host 0\.0\.0\.0' -or $command.Contains($lan.ApiKey)) {
        throw 'LAN start command does not bind externally or leaks the API key in process arguments.'
    }
    $localCommand = Get-StrataLanStartCommand -PythonPath 'D:\AI\Strata\.venv\Scripts\python.exe' -ServerPath 'D:\AI\Strata\serve\server.py' -ConfigPath 'D:\AI\Strata\strata-iq3_s.json' -Port 8080 -HostAddress $local.Host
    if ($localCommand -notmatch '--host 127\.0\.0\.1') { throw 'Local start command did not override a possibly public config host.' }

    $addresses = @(Select-StrataLanIPv4Addresses @('192.168.1.20','10.2.3.4','172.20.0.8','169.254.4.5','8.8.8.8','127.0.0.1'))
    if (($addresses -join ',') -ne '10.2.3.4,172.20.0.8,192.168.1.20') {
        throw 'LAN address hint includes public, loopback or link-local addresses.'
    }

    $runtimeProgram = Resolve-StrataLanFirewallProgram -VenvPythonPath 'D:\AI\Strata\.venv\Scripts\python.exe'
    $expectedProgram = & 'D:\AI\Strata\.venv\Scripts\python.exe' -c 'import sys; print(sys._base_executable)'
    if (-not [string]::Equals($runtimeProgram,[string]$expectedProgram,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Firewall program does not match the Python runtime image.'
    }
    $spec = Get-StrataLanFirewallSpec -Port 8080 -PythonPath $runtimeProgram
    if ($spec.Profile -ne 'Private' -or $spec.RemoteAddress -ne 'LocalSubnet' -or
        $spec.LocalPort -ne 8080 -or $spec.Program -ne $runtimeProgram) {
        throw 'Firewall rule would expose more than the chosen Strata program/port/private subnet.'
    }
    $script:existingRule = $null
    $script:createdRule = $null
    $script:removedRule = $null
    function Get-NetFirewallRule { param($Name,$ErrorAction) return $script:existingRule }
    function New-NetFirewallRule {
        param($Name,$DisplayName,$Group,$Direction,$Action,$Protocol,$LocalPort,$Program,$Profile,$RemoteAddress)
        $script:createdRule = [pscustomobject]@{Name=$Name;DisplayName=$DisplayName;Group=$Group;Direction=$Direction;Action=$Action;Protocol=$Protocol;LocalPort=$LocalPort;Program=$Program;Profile=$Profile;RemoteAddress=$RemoteAddress}
        $script:existingRule = $script:createdRule
    }
    function Remove-NetFirewallRule { param($Name) $script:removedRule=$Name }
    [void](Add-StrataLanFirewallRule $spec)
    if (-not $script:createdRule -or $script:createdRule.Program -ne $spec.Program -or
        $script:createdRule.Profile -ne 'Private' -or $script:createdRule.RemoteAddress -ne 'LocalSubnet') {
        throw 'The firewall mutation did not keep the scoped program/private/subnet settings.'
    }
    $unsafe = $spec | Select-Object *
    $unsafe.Program = 'C:\Windows\System32\cmd.exe'
    $script:existingRule = $null
    $rejectedProgram = $false
    try { [void](Add-StrataLanFirewallRule $unsafe) } catch { $rejectedProgram=$true }
    if (-not $rejectedProgram) { throw 'Firewall helper accepted a non-Python program.' }
    $rejectedForeign = $false
    $script:existingRule = [pscustomobject]@{ Name=$spec.Name; Group='Another application' }
    try { [void](Remove-StrataLanFirewallRule $spec) } catch { $rejectedForeign=$true }
    if (-not $rejectedForeign -or $script:removedRule) { throw 'A foreign firewall rule could be removed.' }
    $script:existingRule = $script:createdRule
    [void](Remove-StrataLanFirewallRule $spec)
    if ($script:removedRule -ne $spec.Name) { throw 'Owned firewall rule was not removed by exact name.' }

    $firewallEntry = Join-Path $launcher 'Strata-Launcher-LanFirewall.ps1'
    if (-not (Test-Path -LiteralPath $firewallEntry)) { throw 'Elevated firewall entry is missing.' }
    $description = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $firewallEntry -Action Describe -Port 8080 -PythonPath $runtimeProgram
    if ($LASTEXITCODE -ne 0) { throw 'Firewall entry rejected a safe describe request.' }
    $described = $description | ConvertFrom-Json
    if ($described.Profile -ne 'Private' -or $described.RemoteAddress -ne 'LocalSubnet') {
        throw 'Elevated firewall entry returned an unscoped rule.'
    }

    [IO.File]::WriteAllBytes($keyPath,[byte[]](1,2,3))
    $rejected = $false
    try { [void](Get-StrataLanLaunchSettings -Enabled $true -KeyPath $keyPath) } catch {
        $rejected = $true
        if ($_.Exception.Message -notmatch 'lan-key\.dpapi|key file') {
            throw 'Unreadable key error did not identify the recovery target.'
        }
    }
    if (-not $rejected) { throw 'Unreadable key did not fail closed.' }

    'PASS: LAN stays opt-in, key is protected and reused, launch env is temporary, firewall scope is private subnet'
} finally {
    $safeRoot = [IO.Path]::GetFullPath((Join-Path $launcher 'tests')) + [IO.Path]::DirectorySeparatorChar
    if ($testRoot.StartsWith($safeRoot,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
