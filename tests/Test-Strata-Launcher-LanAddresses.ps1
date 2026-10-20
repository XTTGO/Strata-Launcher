$ErrorActionPreference = 'Stop'
. (Resolve-Path 'launcher\Strata-Launcher-Lan.ps1').Path

$actual = Get-StrataLanAddressText -Addresses @('192.168.1.8','10.0.0.4') -Port 8080
$expected = "http://10.0.0.4:8080$([Environment]::NewLine)http://192.168.1.8:8080"
if ($actual -ne $expected) { throw "Candidate addresses are not copy-ready lines: $actual" }
if ((Get-StrataLanAddressText -Addresses @('192.168.1.8') -Port 8188) -ne 'http://192.168.1.8:8188') {
    throw 'Candidate address did not follow the selected port.'
}
if (Get-StrataLanAddressText -Addresses @('127.0.0.1','8.8.8.8') -Port 8080) {
    throw 'Non-LAN addresses must not become copyable candidate URLs.'
}
'PASS: candidate addresses are copy-ready and track the chosen port'
