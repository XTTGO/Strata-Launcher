# Launcher-owned LAN settings. No model JSON or command-line argument contains the API key.
Add-Type -AssemblyName System.Security

function Get-StrataLanMode([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $settings = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        return ($settings.enabled -eq $true)
    } catch {
        return $false
    }
}

function Set-StrataLanMode([string]$Path,[bool]$Enabled) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary,(([pscustomobject]@{ enabled=$Enabled }) | ConvertTo-Json) + "`r`n",[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-StrataLanKey([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $encrypted = [IO.File]::ReadAllBytes($Path)
        $raw = [Security.Cryptography.ProtectedData]::Unprotect(
            $encrypted,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        $key = [Text.Encoding]::ASCII.GetString($raw)
        if ($key -notmatch '^[A-Za-z0-9_-]{43}$') { throw 'invalid key format' }
        return $key
    } catch {
        throw 'LAN key cannot be decrypted by this Windows user. LAN startup is blocked. To recover, stop Strata, move launcher\data\lan-key.dpapi aside, then start again to create a new key; update trusted clients with the new key.'
    }
}

function New-StrataLanKey([string]$Path) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    $bytes = [byte[]]::new(32)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $key = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
    $encrypted = [Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::ASCII.GetBytes($key),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllBytes($temporary,$encrypted)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    return $key
}

function Get-StrataLanLaunchSettings([bool]$Enabled,[string]$KeyPath) {
    if (-not $Enabled) { return [pscustomobject]@{ Host='127.0.0.1'; ApiKey=$null } }
    $key = Get-StrataLanKey $KeyPath
    if (-not $key) { $key = New-StrataLanKey $KeyPath }
    if ($key -notmatch '^[A-Za-z0-9_-]{43}$') { throw 'Invalid LAN key; external startup is blocked.' }
    return [pscustomobject]@{ Host='0.0.0.0'; ApiKey=$key }
}

function Invoke-StrataLanWithKey([string]$ApiKey,[scriptblock]$Start) {
    if ($ApiKey -notmatch '^[A-Za-z0-9_-]{43}$') { throw 'Invalid LAN key; external startup is blocked.' }
    $previous = [Environment]::GetEnvironmentVariable('STRATA_API_KEY','Process')
    try {
        [Environment]::SetEnvironmentVariable('STRATA_API_KEY',$ApiKey,'Process')
        return (& $Start)
    } finally {
        [Environment]::SetEnvironmentVariable('STRATA_API_KEY',$previous,'Process')
    }
}

function Get-StrataLanStartCommand(
    [string]$PythonPath,[string]$ServerPath,[string]$ConfigPath,[int]$Port,[string]$HostAddress
) {
    if ($HostAddress -notin @('127.0.0.1','0.0.0.0')) { throw 'Unsupported Strata listen address.' }
    if ($Port -lt 1024 -or $Port -gt 65535) { throw 'Invalid Strata service port.' }
    foreach ($path in @($PythonPath,$ServerPath,$ConfigPath)) {
        if (-not [IO.Path]::IsPathRooted($path) -or $path.Contains('"')) { throw 'Invalid Strata launch path.' }
    }
    return ('"' + $PythonPath + '" "' + $ServerPath + '" --engine strata --config "' +
        $ConfigPath + '" --port ' + $Port + ' --host ' + $HostAddress)
}

function Select-StrataLanIPv4Addresses([string[]]$Addresses) {
    $private = [Collections.Generic.List[string]]::new()
    foreach ($text in $Addresses) {
        $address = $null
        if (-not [Net.IPAddress]::TryParse($text,[ref]$address) -or
            $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { continue }
        $bytes = $address.GetAddressBytes()
        if ($bytes[0] -eq 10 -or
            ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
            ($bytes[0] -eq 192 -and $bytes[1] -eq 168)) {
            [void]$private.Add($address.ToString())
        }
    }
    return @($private | Sort-Object -Unique)
}

function Get-StrataLanAddressText([string[]]$Addresses,[int]$Port) {
    if ($Port -lt 1024 -or $Port -gt 65535) { throw 'Invalid Strata service port.' }
    $private = @(Select-StrataLanIPv4Addresses $Addresses)
    if (-not $private.Count) { return '' }
    return (@($private | ForEach-Object { "http://${_}:$Port" }) -join [Environment]::NewLine)
}

function Resolve-StrataLanFirewallProgram([string]$VenvPythonPath) {
    if (-not (Test-Path -LiteralPath $VenvPythonPath -PathType Leaf)) { throw 'Strata virtual environment Python is missing.' }
    $runtime = @(& $VenvPythonPath -c 'import sys; print(sys._base_executable)')
    if ($LASTEXITCODE -ne 0 -or $runtime.Count -ne 1) { throw 'Could not resolve the Strata Python runtime image.' }
    $program = [string]$runtime[0]
    if (-not [IO.Path]::IsPathRooted($program) -or [IO.Path]::GetFileName($program) -ine 'python.exe' -or
        -not (Test-Path -LiteralPath $program -PathType Leaf)) {
        throw 'Resolved Strata Python runtime image is invalid.'
    }
    return [IO.Path]::GetFullPath($program)
}

function Get-StrataLanFirewallSpec([int]$Port,[string]$PythonPath) {
    if ($Port -lt 1024 -or $Port -gt 65535) { throw 'LAN firewall port must be between 1024 and 65535.' }
    if (-not [IO.Path]::IsPathRooted($PythonPath) -or [IO.Path]::GetFileName($PythonPath) -ine 'python.exe') {
        throw 'LAN firewall rule requires the Strata installation python.exe.'
    }
    return [pscustomobject]@{
        Name="StrataLauncher-LAN-$Port"
        DisplayName="Strata Launcher LAN TCP $Port"
        Group='Strata Launcher LAN'
        Direction='Inbound'
        Action='Allow'
        Protocol='TCP'
        LocalPort=$Port
        Program=[IO.Path]::GetFullPath($PythonPath)
        Profile='Private'
        RemoteAddress='LocalSubnet'
    }
}

function Add-StrataLanFirewallRule($Spec) {
    if ($Spec.Profile -ne 'Private' -or $Spec.RemoteAddress -ne 'LocalSubnet' -or
        $Spec.Group -ne 'Strata Launcher LAN' -or $Spec.Name -ne "StrataLauncher-LAN-$($Spec.LocalPort)" -or
        $Spec.Direction -ne 'Inbound' -or $Spec.Action -ne 'Allow' -or $Spec.Protocol -ne 'TCP' -or
        [IO.Path]::GetFileName([string]$Spec.Program) -ine 'python.exe') {
        throw 'Refusing an unscoped LAN firewall rule.'
    }
    $existing = Get-NetFirewallRule -Name $Spec.Name -ErrorAction SilentlyContinue
    if ($existing) { throw "A firewall rule named $($Spec.Name) already exists; inspect or remove it before adding a new one." }
    $parameters = @{
        Name=$Spec.Name; DisplayName=$Spec.DisplayName; Group=$Spec.Group
        Direction=$Spec.Direction; Action=$Spec.Action; Protocol=$Spec.Protocol
        LocalPort=$Spec.LocalPort; Program=$Spec.Program; Profile=$Spec.Profile
        RemoteAddress=$Spec.RemoteAddress
    }
    New-NetFirewallRule @parameters | Out-Null
}

function Remove-StrataLanFirewallRule($Spec) {
    $existing = Get-NetFirewallRule -Name $Spec.Name -ErrorAction SilentlyContinue
    if (-not $existing) { return }
    if ($existing.Group -ne 'Strata Launcher LAN' -or $existing.Name -ne $Spec.Name) {
        throw 'Refusing to remove a firewall rule not owned by Strata Launcher.'
    }
    Remove-NetFirewallRule -Name $Spec.Name
}
