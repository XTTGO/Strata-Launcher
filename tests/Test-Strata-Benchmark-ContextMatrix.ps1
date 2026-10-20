$ErrorActionPreference = 'Stop'

$source = (Resolve-Path 'launcher\Benchmark-Launcher.ps1').Path
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Benchmark launcher has a PowerShell parse error.' }
foreach ($name in @('Atomic-Json', 'Load-UiSettings', 'Save-UiSettings', 'Get-SavedContextLengths', 'Get-PresetId', 'Get-PresetUiSettings', 'Set-PresetDefaults')) {
    $definition = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (-not $definition) { throw "Missing settings function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

$testRoot = (Resolve-Path 'launcher\tests\.tmp').Path
$testDirectory = Join-Path $testRoot ('strata-benchmark-settings-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testDirectory)
try {
    $script:PresetSpecs=(& (Resolve-Path '.venv\Scripts\python.exe').Path -m launcher.benchmark.runner list-presets) | ConvertFrom-Json
    $SettingsPath = Join-Path $testDirectory 'benchmark-settings.json'
    $preset = [pscustomobject]@{ SelectedItem = 'standard' }
    $rounds = [pscustomobject]@{ Value = 1 }
    $maxConcurrency = [pscustomobject]@{ Value = 2 }
    $port = [pscustomobject]@{ Value = 8188 }
    $tierSweep = [pscustomobject]@{ Checked = $false }
    $stageBoxes = [ordered]@{ capacity = [pscustomobject]@{ Checked = $true } }
    $contextBoxes = [ordered]@{ '4k' = [pscustomobject]@{ Checked = $false } }
    $tierBoxes = [ordered]@{
        '32768' = [pscustomobject]@{ Checked = $false }
        '131072' = [pscustomobject]@{ Checked = $true }
        '262144' = [pscustomobject]@{ Checked = $false }
        '524288' = [pscustomobject]@{ Checked = $true }
    }
    Save-UiSettings
    $saved = Load-UiSettings
    if (@($saved.context_tiers).Count -ne 1 -or @($saved.context_tiers)[0] -ne 131072) {
        throw 'Legacy multi-selection without multi-tier mode was not reduced to its old effective tier.'
    }
    if ($saved.sweep_context_tiers -ne $false) { throw 'The disabled sweep switch was not persisted.' }
    if ($null -ne $saved.PSObject.Properties['uniform_config']) { throw 'Obsolete uniform switch was persisted.' }
    if (@($saved.context_lengths).Count -ne 0) { throw 'Capacity-only input selection was not persisted.' }
    if (@(Get-SavedContextLengths $saved 'standard').Count -ne 0) {
        throw 'An explicitly empty capacity-only input selection was replaced with defaults.'
    }
    [IO.File]::WriteAllText($SettingsPath, '{"preset":"full","rounds":3,"context_tiers":[262144,524288],"sweep_context_tiers":true,"context_lengths":["4k","32k","128k","256k"],"port":8188}')
    $migrated=Load-UiSettings
    if ($migrated.preset -ne 'full' -or @($migrated.context_tiers).Count -ne 1 -or $migrated.context_tiers[0] -ne 262144 -or $migrated.sweep_context_tiers -or @($migrated.context_lengths) -contains '256k') {
        throw 'Old full settings still launch the expensive matrix after migration.'
    }
    [IO.File]::WriteAllText($SettingsPath, '{"preset":"stress","preset_schema_version":3,"context_tiers":[262144,524288],"context_lengths":["128k","256k"],"port":8188}')
    $migratedStress=Load-UiSettings
    if ($migratedStress.preset -ne 'capacity' -or @($migratedStress.context_lengths).Count -ne 1 -or $migratedStress.context_lengths[0] -ne '256k') {
        throw 'Old stress settings were not migrated to the isolated capacity preset.'
    }

    $tierSweep.Checked = $true
    Save-UiSettings
    if ((Load-UiSettings).sweep_context_tiers -ne $true) { throw 'The enabled sweep switch was not persisted.' }
    if ((Get-Content -LiteralPath $source -Raw) -match '\$uniformConfig') { throw 'Obsolete uniform checkbox remains in UI.' }
    $preset.SelectedItem = 'standard'
    $stageBoxes = [ordered]@{
        performance = [pscustomobject]@{ Checked = $false }
        cache = [pscustomobject]@{ Checked = $false }
        agent = [pscustomobject]@{ Checked = $false }
        needle = [pscustomobject]@{ Checked = $false }
        load = [pscustomobject]@{ Checked = $false }
        stability = [pscustomobject]@{ Checked = $true }
        capacity = [pscustomobject]@{ Checked = $true }
    }
    $contextBoxes = [ordered]@{
        '1k' = [pscustomobject]@{ Checked = $false }
        '4k' = [pscustomobject]@{ Checked = $false }
        '32k' = [pscustomobject]@{ Checked = $false }
        '128k' = [pscustomobject]@{ Checked = $false }
        '256k' = [pscustomobject]@{ Checked = $false }
    }
    Set-PresetDefaults
    if (-not $contextBoxes['4k'].Checked -or -not $contextBoxes['1k'].Checked -or
        $contextBoxes['32k'].Checked -or $contextBoxes['128k'].Checked -or $contextBoxes['256k'].Checked) {
        throw 'Standard preset does not restore its documented 1K/4K inputs.'
    }
    if (-not $tierBoxes['262144'].Checked -or $tierSweep.Checked -or $rounds.Value -ne 1) { throw 'Standard should use one native 256K tier and one round.' }
    $preset.SelectedItem = 'full'
    Set-PresetDefaults
    if (-not $contextBoxes['1k'].Checked -or -not $contextBoxes['4k'].Checked -or -not $contextBoxes['32k'].Checked -or $contextBoxes['128k'].Checked -or $contextBoxes['256k'].Checked -or
        -not $stageBoxes['stability'].Checked -or $stageBoxes['capacity'].Checked) {
        throw 'Full preset does not restore its daily inputs and stages.'
    }
    if ($rounds.Value -ne 3 -or -not $tierBoxes['262144'].Checked -or $tierSweep.Checked) { throw 'Full should use one native 256K tier and three rounds.' }
    $preset.SelectedItem = 'long'
    Set-PresetDefaults
    if (-not $contextBoxes['32k'].Checked -or -not $contextBoxes['128k'].Checked -or $contextBoxes['256k'].Checked -or $stageBoxes['capacity'].Checked -or $stageBoxes['load'].Checked) { throw 'Long preset should isolate 32K/128K input and recall.' }
    $preset.SelectedItem = 'parallel'
    Set-PresetDefaults
    if (-not $stageBoxes['load'].Checked -or $stageBoxes['capacity'].Checked -or -not $contextBoxes['4k'].Checked -or -not $contextBoxes['32k'].Checked -or $contextBoxes['128k'].Checked) { throw 'Parallel preset should isolate short and medium concurrency.' }
    $preset.SelectedItem = 'capacity'
    Set-PresetDefaults
    if (-not $stageBoxes['capacity'].Checked -or $stageBoxes['load'].Checked -or -not $contextBoxes['256k'].Checked -or $contextBoxes['128k'].Checked -or $rounds.Value -ne 1) { throw 'Capacity preset should not include long concurrency.' }
    if ($maxConcurrency.Value -ne 2) { throw 'Preset should default to at most two clients.' }
    'PASS: context tiers, sweep and capacity-only selection persist'
} finally {
    if ($testDirectory.StartsWith($testRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $testDirectory)) {
        Remove-Item -LiteralPath $testDirectory -Recurse -Force
    }
}
