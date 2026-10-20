$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\benchmark\Run-State.ps1')

if ((Get-BenchmarkTerminalState 'running' 'partial') -ne 'partial') {
    throw 'FAIL: the final manifest state must recover a stale running status file'
}
if ((Get-BenchmarkTerminalState 'running' 'running') -ne 'running') {
    throw 'FAIL: a still-running controller must not be treated as terminal'
}
if ((Get-BenchmarkTerminalState 'completed' 'partial') -ne 'partial') {
    throw 'FAIL: the final manifest must take precedence over a stale terminal status file'
}

'PASS: the final manifest recovers stale status files and distinguishes partial completion'
