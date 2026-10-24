$ErrorActionPreference = 'Stop'

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) {
        throw "FAIL: $Message`r`nExpected: $Expected`r`nActual:   $Actual"
    }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}

$launcherRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$themeModule = Join-Path $launcherRoot 'Strata-Launcher-Theme.ps1'
if (-not (Test-Path -LiteralPath $themeModule -PathType Leaf)) {
    throw "FAIL: visual theme module is missing: $themeModule"
}

. $themeModule

$theme = Get-StrataLauncherTheme
Assert-Equal $theme.Background.Name 'fff3f3f0' 'the launcher background should use a nearly neutral paper gray'
Assert-Equal $theme.Surface.Name 'fffafaf7' 'cards and fields should use soft xuan-paper white instead of pure white'
Assert-Equal $theme.Ink.Name 'ff2c2e2d' 'text and primary actions should use neutral ink charcoal instead of pure black'
Assert-Equal $theme.Hero.Name 'ffe8e9e5' 'the header should use a pale ink-wash gray instead of beige'
Assert-Equal $theme.Accent.Name 'ffb34e42' 'the launcher should use a restrained cinnabar accent'
Assert-True ($theme.Surface.Name -ne 'ffffffff') 'the theme must not use pure white surfaces'
Assert-True ($theme.Ink.Name -ne 'ff000000') 'the theme must not use pure black ink'

$primary = [Windows.Forms.Button]::new()
Set-StrataButtonStyle -Button $primary -Variant Primary -Theme $theme
Assert-Equal $primary.FlatStyle ([Windows.Forms.FlatStyle]::Flat) 'primary actions should use flat modern buttons'
Assert-Equal $primary.BackColor.Name $theme.Ink.Name 'primary actions should use the ink surface'
Assert-Equal $primary.ForeColor.Name $theme.White.Name 'primary actions should use white text'
Assert-True ($primary.Height -ge 34) 'primary actions should have a comfortable hit target'

$accent = [Windows.Forms.Button]::new()
Set-StrataButtonStyle -Button $accent -Variant Accent -Theme $theme
Assert-Equal $accent.BackColor.Name $theme.Accent.Name 'accent actions should use the red accent'
Assert-Equal $accent.ForeColor.Name $theme.White.Name 'accent actions should use white text'

$section = New-StrataSectionHeader -Title 'MODEL & PRESET' -Subtitle 'Model and common usage mode' -Theme $theme
Assert-Equal $section.Height 42 'section headers should create consistent vertical rhythm'
Assert-Equal $section.Controls.Count 3 'section headers should include accent, title, and subtitle elements'
Assert-Equal $section.Controls[0].BackColor.Name $theme.Accent.Name 'section headers should carry the red accent bar'
$section.Dispose()

$collapsible = New-StrataSectionHeader -Title 'GENERATION' -Subtitle 'Advanced controls' -Theme $theme -Collapsible
$toggle = @($collapsible.Controls.Find('SectionToggle', $false))
Assert-Equal $toggle.Count 1 'a collapsible section should expose one keyboard-focusable toggle'
$table = [Windows.Forms.TableLayoutPanel]::new()
$table.ColumnCount = 1
$table.RowCount = 2
[void]$table.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 58))
[void]$table.RowStyles.Add([Windows.Forms.RowStyle]::new('AutoSize'))
$field = [Windows.Forms.TextBox]::new(); $field.Text = 'preserved setting'
[void]$table.Controls.Add($collapsible, 0, 0)
[void]$table.Controls.Add($field, 0, 1)
Set-StrataSectionExpanded -Layout $table -Header $collapsible -FirstRow 1 -LastRow 1 -Expanded $false
Assert-Equal $table.RowStyles[1].SizeType ([Windows.Forms.SizeType]::Absolute) 'collapsed rows should stop occupying layout space'
Assert-Equal $table.RowStyles[1].Height 0 'collapsed rows should have zero height'
Assert-True (-not $field.Visible) 'collapsed controls should be hidden'
Set-StrataSectionExpanded -Layout $table -Header $collapsible -FirstRow 1 -LastRow 1 -Expanded $true
Assert-Equal $table.RowStyles[1].SizeType ([Windows.Forms.SizeType]::AutoSize) 'expanded rows should regain their layout'
Assert-Equal $field.Text 'preserved setting' 'folding should preserve edited values'
Assert-True $field.Visible 'expanded controls should become visible again'
$table.Dispose()

$form = [Windows.Forms.Form]::new()
$panel = [Windows.Forms.Panel]::new()
$label = [Windows.Forms.Label]::new()
$hint = [Windows.Forms.Label]::new(); $hint.Tag = 'muted'
$panel.Controls.Add($label)
$panel.Controls.Add($hint)
$form.Controls.Add($panel)
Set-StrataLauncherTheme -Root $form -Theme $theme
Assert-Equal $form.BackColor.Name $theme.Background.Name 'the form should receive the theme background'
Assert-Equal $panel.BackColor.Name $theme.Background.Name 'layout containers should blend into the editorial background'
Assert-Equal $label.ForeColor.Name $theme.Ink.Name 'normal labels should use the primary ink color'
Assert-Equal $hint.ForeColor.Name $theme.Muted.Name 'muted labels should use the muted color'
$form.Dispose()

$launcherSource = Get-Content -LiteralPath (Join-Path $launcherRoot 'Strata-Launcher.ps1') -Raw -Encoding UTF8
Assert-True ($launcherSource.Contains('STRATA CONTROL CENTER')) 'the launcher should contain the new editorial header'
Assert-True ($launcherSource.Contains('Set-StrataLauncherTheme')) 'the launcher should apply the shared theme'

'PASS: launcher theme exposes the approved palette and modern control styling'
