$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}

$launcherRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $launcherRoot 'Strata-Launcher-Environment.ps1')

$descends = { param($tag) $tag -ne 'v0.2.7.3' }
$newer = Get-StrataNewestReleaseTag -ReleaseTag 'v0.2.7' `
    -Tags @('v0.2.6.9','v0.2.7','v0.2.7.1','v0.2.7.2','v0.2.7.3','v0.2.8','v0.2.7-rc1') `
    -IsDescendant $descends
Assert-True ($null -ne $newer -and $newer.Tag -eq 'v0.2.7.2') 'choose the latest descendant patch of the published release'

$none = Get-StrataNewestReleaseTag -ReleaseTag 'v0.2.7' -Tags @('v0.2.7','v0.2.6.9','v0.2.8') -IsDescendant $descends
Assert-True ($null -eq $none) 'do not treat a newer release line or an older patch as this release patch'

$fromPatch = Get-StrataNewestReleaseTag -ReleaseTag 'v0.2.7.1' -Tags @('v0.2.7.1','v0.2.7.2') -IsDescendant $descends
Assert-True ($null -ne $fromPatch -and $fromPatch.Tag -eq 'v0.2.7.2') 'a release already on a patch still accepts its next patch'

$unrelated = Get-StrataNewestReleaseTag -ReleaseTag 'v0.2.7' -Tags @('v0.2.7.3') -IsDescendant $descends
Assert-True ($null -eq $unrelated) 'reject a tag that does not descend from the published release'

'PASS: the updater selects descendant patches only within the latest published release line'
