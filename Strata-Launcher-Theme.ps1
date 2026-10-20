# Shared visual system for the standalone Windows launcher.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Get-StrataLauncherTheme {
    [pscustomobject]@{
        Background  = [Drawing.ColorTranslator]::FromHtml('#F3F3F0')
        Surface     = [Drawing.ColorTranslator]::FromHtml('#FAFAF7')
        Ink         = [Drawing.ColorTranslator]::FromHtml('#2C2E2D')
        Muted       = [Drawing.ColorTranslator]::FromHtml('#6F7371')
        Border      = [Drawing.ColorTranslator]::FromHtml('#D4D6D2')
        Accent      = [Drawing.ColorTranslator]::FromHtml('#B34E42')
        AccentHover = [Drawing.ColorTranslator]::FromHtml('#963E35')
        DarkSurface = [Drawing.ColorTranslator]::FromHtml('#3B3D3C')
        DarkMuted   = [Drawing.ColorTranslator]::FromHtml('#8B8F8D')
        White       = [Drawing.ColorTranslator]::FromHtml('#FAFAF7')
        Hero        = [Drawing.ColorTranslator]::FromHtml('#E8E9E5')
        HeroSurface = [Drawing.ColorTranslator]::FromHtml('#DCDDDA')
    }
}

function Set-StrataButtonStyle {
    param(
        [Parameter(Mandatory=$true)][Windows.Forms.Button]$Button,
        [ValidateSet('Primary','Accent','Secondary','Danger','Ghost')][string]$Variant = 'Secondary',
        $Theme = (Get-StrataLauncherTheme)
    )

    $Button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $Button.FlatAppearance.BorderSize = 1
    $Button.Height = [Math]::Max(36,$Button.Height)
    $Button.Cursor = [Windows.Forms.Cursors]::Hand
    $Button.Font = [Drawing.Font]::new('Segoe UI',9,[Drawing.FontStyle]::Bold)
    $Button.Padding = [Windows.Forms.Padding]::new(8,0,8,1)

    switch ($Variant) {
        'Primary' {
            $Button.BackColor = $Theme.Ink
            $Button.ForeColor = $Theme.White
            $Button.FlatAppearance.BorderColor = $Theme.Ink
            $Button.FlatAppearance.MouseOverBackColor = $Theme.DarkSurface
        }
        'Accent' {
            $Button.BackColor = $Theme.Accent
            $Button.ForeColor = $Theme.White
            $Button.FlatAppearance.BorderColor = $Theme.Accent
            $Button.FlatAppearance.MouseOverBackColor = $Theme.AccentHover
        }
        'Danger' {
            $Button.BackColor = $Theme.Surface
            $Button.ForeColor = $Theme.Accent
            $Button.FlatAppearance.BorderColor = $Theme.Accent
            $Button.FlatAppearance.MouseOverBackColor = [Drawing.ColorTranslator]::FromHtml('#FCE8E5')
        }
        'Ghost' {
            $Button.BackColor = $Theme.Background
            $Button.ForeColor = $Theme.Ink
            $Button.FlatAppearance.BorderSize = 0
            $Button.FlatAppearance.MouseOverBackColor = $Theme.Surface
        }
        default {
            $Button.BackColor = $Theme.Surface
            $Button.ForeColor = $Theme.Ink
            $Button.FlatAppearance.BorderColor = $Theme.Border
            $Button.FlatAppearance.MouseOverBackColor = $Theme.Background
        }
    }
}

function New-StrataSectionHeader {
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [string]$Subtitle = '',
        $Theme = (Get-StrataLauncherTheme)
    )

    $panel = [Windows.Forms.Panel]::new()
    $panel.Height = 42
    $panel.Dock = 'Top'
    $panel.Margin = [Windows.Forms.Padding]::new(8,16,10,2)
    $panel.BackColor = $Theme.Background

    $bar = [Windows.Forms.Panel]::new()
    $bar.BackColor = $Theme.Accent
    $bar.Location = [Drawing.Point]::new(0,8)
    $bar.Size = [Drawing.Size]::new(4,24)

    $titleLabel = [Windows.Forms.Label]::new()
    $titleLabel.Text = $Title
    $titleLabel.AutoSize = $true
    $titleLabel.Location = [Drawing.Point]::new(14,4)
    $titleLabel.Font = [Drawing.Font]::new('Segoe UI Semibold',10,[Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = $Theme.Ink

    $subtitleLabel = [Windows.Forms.Label]::new()
    $subtitleLabel.Text = $Subtitle
    $subtitleLabel.Tag = 'muted'
    $subtitleLabel.AutoSize = $true
    $subtitleLabel.Location = [Drawing.Point]::new(15,23)
    $subtitleLabel.Font = [Drawing.Font]::new('Segoe UI',8)
    $subtitleLabel.ForeColor = $Theme.Muted

    [void]$panel.Controls.Add($bar)
    [void]$panel.Controls.Add($titleLabel)
    [void]$panel.Controls.Add($subtitleLabel)
    return $panel
}

function Set-StrataLauncherTheme {
    param(
        [Parameter(Mandatory=$true)][Windows.Forms.Control]$Root,
        $Theme = (Get-StrataLauncherTheme)
    )

    if ($Root -is [Windows.Forms.Form]) {
        $Root.BackColor = $Theme.Background
        $Root.ForeColor = $Theme.Ink
        $Root.Font = [Drawing.Font]::new('Segoe UI',9)
    } elseif ($Root.Tag -eq 'hero') {
        $Root.BackColor = $Theme.Hero
        $Root.ForeColor = $Theme.Ink
    } elseif ($Root.Tag -eq 'surface') {
        $Root.BackColor = $Theme.Surface
        $Root.ForeColor = $Theme.Ink
    } elseif ($Root -is [Windows.Forms.Label]) {
        if ($Root.Tag -eq 'muted') { $Root.ForeColor = $Theme.Muted }
        elseif ($Root.Tag -eq 'hero-muted') { $Root.ForeColor = $Theme.Muted }
        elseif ($Root.Tag -eq 'hero-text') { $Root.ForeColor = $Theme.Ink }
        else { $Root.ForeColor = $Theme.Ink }
    } elseif ($Root -is [Windows.Forms.TextBox] -or
              $Root -is [Windows.Forms.ComboBox] -or
              $Root -is [Windows.Forms.NumericUpDown]) {
        $Root.BackColor = $Theme.Surface
        $Root.ForeColor = $Theme.Ink
        $Root.Font = [Drawing.Font]::new('Segoe UI',9)
    } elseif ($Root -is [Windows.Forms.GroupBox]) {
        $Root.BackColor = $Theme.Surface
        $Root.ForeColor = $Theme.Ink
        $Root.Font = [Drawing.Font]::new('Segoe UI Semibold',9,[Drawing.FontStyle]::Bold)
    } elseif ($Root -is [Windows.Forms.CheckBox]) {
        $Root.ForeColor = $Theme.Ink
    } elseif ($Root -is [Windows.Forms.Button]) {
        $variant = if ($Root.Tag -and ([string]$Root.Tag).StartsWith('button:')) { ([string]$Root.Tag).Substring(7) } else { 'Secondary' }
        Set-StrataButtonStyle -Button $Root -Variant $variant -Theme $Theme
    }

    foreach ($child in $Root.Controls) {
        Set-StrataLauncherTheme -Root $child -Theme $Theme
    }
}
