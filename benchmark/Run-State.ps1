function Get-BenchmarkTerminalState([string]$StatusState, [string]$ManifestState) {
    $terminalStates = @('completed','partial','cancelled','failed')
    if ($ManifestState -in $terminalStates) { return $ManifestState }
    if ($StatusState -in $terminalStates) { return $StatusState }
    return $StatusState
}
