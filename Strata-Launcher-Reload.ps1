function Invoke-StrataLauncherReload {
    param(
        [Parameter(Mandatory=$true)][string]$LauncherPath,
        [Parameter(Mandatory=$true)][string]$ConfigPath
    )

    & $LauncherPath -ConfigPath $ConfigPath
}
