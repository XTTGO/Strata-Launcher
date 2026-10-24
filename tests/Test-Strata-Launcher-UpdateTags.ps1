$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}

$launcherRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $launcherRoot 'Strata-Launcher-Environment.ps1')

$notes = @('v0.2.4.2')
$hasNotes = { param($tag) $notes -contains $tag }

$newer = Get-StrataNewestReleaseTag -ReleaseTag 'v0.2.4' -Tags @('v0.2.3.1','v0.2.4','v0.2.4.2','v0.2.5','not-a-version') -HasNotes $hasNotes
Assert-True ($null -ne $newer -and $newer.Tag -eq 'v0.2.4.2') 'the newest tag that carries release notes should win'

$none = Get-StrataNewestReleaseTag -ReleaseTag 'v0.2.4' -Tags @('v0.2.4','v0.2.3.1') -HasNotes $hasNotes
Assert-True ($null -eq $none) 'nothing newer means no change'

$skipNotes = Get-StrataNewestReleaseTag -ReleaseTag 'v0.2.4' -Tags @('v0.2.4.2','v0.2.5') -HasNotes $hasNotes
Assert-True ($null -ne $skipNotes -and $skipNotes.Tag -eq 'v0.2.4.2') 'a newer tag without release notes is skipped'

$fromPatch = Get-StrataNewestReleaseTag -ReleaseTag 'v0.2.4.2' -Tags @('v0.2.4.2','v0.2.4.1') -HasNotes $hasNotes
Assert-True ($null -eq $fromPatch) 'a patch release equal to HEAD is not newer'

'PASS: the updater picks the newest official tag that carries release notes'
