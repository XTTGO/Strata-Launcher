param(
    [Parameter(Mandatory=$true)][ValidateSet('Describe','Add','Remove')][string]$Action,
    [Parameter(Mandatory=$true)][int]$Port,
    [Parameter(Mandatory=$true)][string]$PythonPath
)

$ErrorActionPreference = 'Stop'
$module = Join-Path $PSScriptRoot 'Strata-Launcher-Lan.ps1'
if (-not (Test-Path -LiteralPath $module -PathType Leaf)) { throw 'Strata LAN helper is missing.' }
. $module
$spec = Get-StrataLanFirewallSpec -Port $Port -PythonPath $PythonPath
if (-not (Test-Path -LiteralPath $spec.Program -PathType Leaf)) { throw 'Strata Python executable is missing.' }

switch ($Action) {
    'Describe' { $spec | ConvertTo-Json -Depth 4 }
    'Add' { Add-StrataLanFirewallRule $spec; 'Firewall rule added.' }
    'Remove' { Remove-StrataLanFirewallRule $spec; 'Firewall rule removed or already absent.' }
}
