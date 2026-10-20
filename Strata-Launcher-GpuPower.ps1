# Optional, system-wide NVIDIA power cap. Nothing here runs on Save or Start.
function Convert-StrataGpuPowerCsv([string]$Text) {
    foreach ($line in ($Text -split "`r?`n")) {
        if (-not $line.Trim()) { continue }
        $parts = @($line -split ',' | ForEach-Object { $_.Trim() })
        if ($parts.Count -ne 7 -or $parts[1] -notmatch '^GPU-[0-9a-fA-F-]{36}$') { continue }
        $values = [Collections.ArrayList]::new()
        $valid = $true
        foreach ($item in $parts[3..6]) {
            $number = 0.0
            if (-not [double]::TryParse($item,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -or
                [double]::IsNaN($number) -or [double]::IsInfinity($number)) { $valid=$false; break }
            [void]$values.Add($number)
        }
        if (-not $valid -or $values[2] -ge $values[3]) { continue }
        [pscustomobject]@{ Index=[int]$parts[0]; Uuid=$parts[1]; Name=$parts[2]; Current=$values[0]; Default=$values[1]; Minimum=$values[2]; Maximum=$values[3] }
    }
}

function Get-StrataNvidiaPowerGpus {
    $command = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
    if (-not $command) { return @() }
    $output = & $command.Source '--query-gpu=index,uuid,name,power.limit,power.default_limit,power.min_limit,power.max_limit' '--format=csv,noheader,nounits' 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    @(Convert-StrataGpuPowerCsv ($output -join "`n"))
}

function Get-StrataGpuPowerRestore([string]$Uuid, [string]$StatePath) {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return $null }
    $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    @($state.records | Where-Object { $_.uuid -eq $Uuid }) | Select-Object -First 1
}

function Save-StrataGpuPowerRestore([string]$Uuid, [string]$StatePath, [double]$Original, [double]$LastApplied) {
    $records = @()
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $records = @($state.records | Where-Object { $_.uuid -ne $Uuid })
    }
    if (-not [double]::IsNaN($Original)) {
        $records += [pscustomobject]@{ uuid=$Uuid; original=$Original; last_applied=$LastApplied }
    }
    $parent = Split-Path -Parent $StatePath
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    $temporary = $StatePath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary,([pscustomobject]@{ records=$records } | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
            $backup = $temporary + '.bak'
            [IO.File]::Replace($temporary,$StatePath,$backup)
            if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
        } else {
            [IO.File]::Move($temporary,$StatePath)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-StrataGpuPowerByUuid([string]$Uuid) {
    @(Get-StrataNvidiaPowerGpus | Where-Object { $_.Uuid -eq $Uuid }) | Select-Object -First 1
}

function Test-StrataNvidiaSmiTrusted([string]$Path, $Signature, $VersionInfo) {
    if ([IO.Path]::GetFileName($Path) -ine 'nvidia-smi.exe' -or $Signature.Status -ne 'Valid' -or
        $VersionInfo.CompanyName -ne 'NVIDIA Corporation' -or $VersionInfo.FileDescription -notlike 'NVIDIA-SMI*') {
        return $false
    }
    $subject = [string]$Signature.SignerCertificate.Subject
    if ($subject -like 'CN=NVIDIA Corporation,*') { return $true }
    $systemSmi = Join-Path $env:WINDIR 'System32\nvidia-smi.exe'
    return ($Signature.SignatureType -eq 'Catalog' -and
        $subject -like 'CN=Microsoft Windows Hardware Compatibility Publisher,*' -and
        [IO.Path]::GetFullPath($Path) -eq [IO.Path]::GetFullPath($systemSmi))
}

function Invoke-StrataNvidiaPowerSet([string]$Uuid, [int]$Watts) {
    if ($Uuid -notmatch '^GPU-[0-9a-fA-F-]{36}$') { throw 'GPU UUID 无效。' }
    $command = Get-Command 'nvidia-smi.exe' -ErrorAction Stop
    $signature = Get-AuthenticodeSignature -LiteralPath $command.Source
    $versionInfo = (Get-Item -LiteralPath $command.Source).VersionInfo
    if (-not (Test-StrataNvidiaSmiTrusted -Path $command.Source -Signature $signature -VersionInfo $versionInfo)) {
        throw 'nvidia-smi.exe 未通过可信数字签名和文件身份检查；不会以管理员权限运行。'
    }
    $process = Start-Process -FilePath $command.Source -ArgumentList @('-i',$Uuid,'-pl',([string]$Watts)) -Verb RunAs -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "显卡驱动拒绝功率设置（退出码 $($process.ExitCode)）。" }
}

function Set-StrataGpuPowerLimit([string]$Uuid, [int]$Watts, [string]$StatePath, [switch]$AdoptCurrent,
    [double]$ExpectedCurrent = [double]::NaN,
    [scriptblock]$Query = { param($id) Get-StrataGpuPowerByUuid $id },
    [scriptblock]$Set = { param($id,$value) Invoke-StrataNvidiaPowerSet $id $value }) {
    $gpu = & $Query $Uuid
    if (-not $gpu -or $gpu.Uuid -ne $Uuid) { throw '显卡已断开或不支持读取功率范围。' }
    if (-not [double]::IsNaN($ExpectedCurrent) -and [Math]::Abs([double]$gpu.Current - $ExpectedCurrent) -gt 0.5) {
        throw '确认期间显卡功率发生变化；已取消，请刷新后重试。'
    }
    if ([Math]::Abs([double]$gpu.Current - [Math]::Round([double]$gpu.Current)) -gt 0.01) {
        throw '当前功率不是整数瓦，无法保证准确恢复修改前值。'
    }
    if ($Watts -lt $gpu.Minimum -or $Watts -gt $gpu.Maximum) { throw "功率必须在 $($gpu.Minimum)–$($gpu.Maximum) W 之间。" }
    $record = Get-StrataGpuPowerRestore -Uuid $Uuid -StatePath $StatePath
    if ($record -and [Math]::Abs([double]$gpu.Current - [double]$record.last_applied) -gt 0.5) {
        if (-not $AdoptCurrent) { throw '显卡功率已被其他程序修改；为避免覆盖，先刷新并确认现值。' }
        $record = $null
    }
    $original = if ($record) { [double]$record.original } else { [double]$gpu.Current }
    # Record the intended cap before touching the driver. If the process dies after
    # nvidia-smi succeeds, the original cap is still recoverable on next launch.
    Save-StrataGpuPowerRestore -Uuid $Uuid -StatePath $StatePath -Original $original -LastApplied $Watts
    try {
        & $Set $Uuid $Watts
    } catch {
        $failure = $_
        try {
            $afterFailure = & $Query $Uuid
            if ($afterFailure -and [Math]::Abs([double]$afterFailure.Current - [double]$gpu.Current) -le 0.5) {
                if ($record) {
                    Save-StrataGpuPowerRestore -Uuid $Uuid -StatePath $StatePath -Original $original -LastApplied ([double]$gpu.Current)
                } else {
                    Save-StrataGpuPowerRestore -Uuid $Uuid -StatePath $StatePath -Original ([double]::NaN) -LastApplied 0
                }
            }
        } catch { }
        throw $failure
    }
    $after = & $Query $Uuid
    if (-not $after -or [Math]::Abs([double]$after.Current - $Watts) -gt 0.5) {
        throw '驱动命令已返回，但功率读回与目标不符；请刷新查看实际值。'
    }
    $after
}

function Restore-StrataGpuPowerLimit([string]$Uuid, [string]$StatePath,
    [scriptblock]$Query = { param($id) Get-StrataGpuPowerByUuid $id },
    [scriptblock]$Set = { param($id,$value) Invoke-StrataNvidiaPowerSet $id $value }) {
    $record = Get-StrataGpuPowerRestore -Uuid $Uuid -StatePath $StatePath
    if (-not $record) { throw '没有由此启动器记录的修改前功率。' }
    $gpu = & $Query $Uuid
    if (-not $gpu -or [Math]::Abs([double]$gpu.Current - [double]$record.last_applied) -gt 0.5) {
        throw '显卡功率已被其他程序修改；不会覆盖当前设置。'
    }
    $original = [double]$record.original
    if ($original -lt $gpu.Minimum -or $original -gt $gpu.Maximum) { throw '修改前的功率已超出驱动当前允许范围。' }
    & $Set $Uuid ([int][Math]::Round($original))
    $after = & $Query $Uuid
    if (-not $after -or [Math]::Abs([double]$after.Current - $original) -gt 0.5) { throw '恢复命令已返回，但功率读回不符；请刷新查看实际值。' }
    Save-StrataGpuPowerRestore -Uuid $Uuid -StatePath $StatePath -Original ([double]::NaN) -LastApplied 0
    $after
}
