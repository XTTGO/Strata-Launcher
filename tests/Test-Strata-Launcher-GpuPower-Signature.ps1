$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Strata-Launcher-GpuPower.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}

if (-not (Get-Command Test-StrataNvidiaSmiTrusted -ErrorAction SilentlyContinue)) {
    throw 'FAIL: GPU power trust check does not support Windows catalog signatures'
}

$systemSmi = Join-Path $env:WINDIR 'System32\nvidia-smi.exe'
$nvidiaInfo = [pscustomobject]@{ CompanyName='NVIDIA Corporation'; FileDescription='NVIDIA-SMI 610.62' }
$catalog = [pscustomobject]@{
    Status='Valid'
    SignatureType='Catalog'
    SignerCertificate=[pscustomobject]@{ Subject='CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation, C=US' }
}
$embedded = [pscustomobject]@{
    Status='Valid'
    SignatureType='Authenticode'
    SignerCertificate=[pscustomobject]@{ Subject='CN=NVIDIA Corporation, O=NVIDIA Corporation, C=US' }
}

Assert-True (Test-StrataNvidiaSmiTrusted -Path $systemSmi -Signature $catalog -VersionInfo $nvidiaInfo) 'valid Windows catalog signature on the NVIDIA SMI in System32 must be accepted'
Assert-True (Test-StrataNvidiaSmiTrusted -Path 'C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe' -Signature $embedded -VersionInfo $nvidiaInfo) 'valid NVIDIA embedded signature must be accepted'
Assert-True (-not (Test-StrataNvidiaSmiTrusted -Path 'C:\Temp\nvidia-smi.exe' -Signature $catalog -VersionInfo $nvidiaInfo)) 'catalog exception must not elevate arbitrary PATH locations'
Assert-True (-not (Test-StrataNvidiaSmiTrusted -Path $systemSmi -Signature ([pscustomobject]@{Status='NotSigned';SignatureType='None';SignerCertificate=$null}) -VersionInfo $nvidiaInfo)) 'unsigned executable must be rejected'
Assert-True (-not (Test-StrataNvidiaSmiTrusted -Path $systemSmi -Signature $catalog -VersionInfo ([pscustomobject]@{CompanyName='Other';FileDescription='Other tool'}))) 'non NVIDIA-SMI binary must be rejected'

$actual = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
if ($actual) {
    $signature = Get-AuthenticodeSignature -LiteralPath $actual.Source
    $info = (Get-Item -LiteralPath $actual.Source).VersionInfo
    Assert-True (Test-StrataNvidiaSmiTrusted -Path $actual.Source -Signature $signature -VersionInfo $info) 'installed NVIDIA SMI must pass the same check used before elevation'
    function Start-Process { throw 'SAFE_LAUNCH_INTERCEPT' }
    try {
        try {
            Invoke-StrataNvidiaPowerSet -Uuid 'GPU-af64da72-8fa1-a3c0-69e5-b2fd0861cc77' -Watts 259
            throw 'FAIL: elevation boundary was not reached'
        } catch {
            Assert-True ($_.Exception.Message -eq 'SAFE_LAUNCH_INTERCEPT') 'real Windows PowerShell signature check must reach the intercepted elevation boundary'
        }
    } finally {
        Remove-Item function:Start-Process
    }
}

'PASS: signed NVIDIA SMI accepted on Windows PowerShell; unsigned and unrelated files blocked'
