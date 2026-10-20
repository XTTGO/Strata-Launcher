$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Strata-Launcher-Settings.ps1')

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) { throw "FAIL: $Message (expected $Expected, got $Actual)" }
}

$fixture = Join-Path $PSScriptRoot ('vision-fixture-' + [Guid]::NewGuid().ToString('N'))
$root = Join-Path $fixture 'Strata'
$modelDirectory = Join-Path $fixture 'Strata-data\models\ud_q4_k_xl'
$model = Join-Path $modelDirectory 'Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf'
$mmproj = Join-Path $fixture 'Strata-data\models\mmproj-Qwen3.8-Flash-Next-BF16.gguf'
$exe = Join-Path $root 'engine\strata-vision.exe'
$build = Join-Path $root 'engine\BUILD.json'
$sidecar = Join-Path $root 'strata-unsloth-ud-q4_k_xl.vision.json'

try {
    [void](New-Item -ItemType Directory -Path $modelDirectory -Force)
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $exe) -Force)
    foreach ($path in @($model,$mmproj,$exe)) { [IO.File]::WriteAllBytes($path,[byte[]]@(1)) }
    [IO.File]::WriteAllText($build,'{"vision":"gpu"}',[Text.UTF8Encoding]::new($false))

    $config = [pscustomobject]@{
        model_name = 'qwen3.8-flash-next-unsloth-ud-q4_k_xl'
        args = @('--pack','pack','--native',$model)
    }
    $first = Get-StrataVisionConfigForSave -Config $config -SidecarPath $sidecar -Root $root
    Assert-Equal $first.exe $exe 'first-time vision should use the installed helper'
    Assert-Equal $first.mmproj $mmproj 'first-time vision should find the sibling models encoder'
    Assert-Equal $first.model $model 'first-time vision should use the selected model'
    Assert-Equal $first.gpu $true 'first-time vision should use the GPU encoder'
    Assert-Equal $first.max_tokens 1024 'first-time vision should use the setup token limit'

    $custom = Join-Path $fixture 'Strata-data\models\custom-mmproj.gguf'
    [IO.File]::WriteAllBytes($custom,[byte[]]@(1))
    $saved = [pscustomobject]@{ exe=$exe; mmproj=$custom; model=$model; gpu=$false; max_tokens=768 }
    [IO.File]::WriteAllText($sidecar,($saved | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $restored = Get-StrataVisionConfigForSave -Config $config -SidecarPath $sidecar -Root $root
    Assert-Equal $restored.mmproj $custom 'saved custom mmproj should take precedence'
    Assert-Equal $restored.gpu $false 'saved CPU choice should take precedence'
    Assert-Equal $restored.max_tokens 768 'saved token limit should take precedence'

    $config | Add-Member -NotePropertyName vision -NotePropertyValue $saved
    $embedded = Get-StrataVisionConfigForSave -Config $config -SidecarPath $sidecar -Root $root
    Assert-Equal $embedded.mmproj $custom 'embedded vision should remain in use'

    $config.PSObject.Properties.Remove('vision')
    Remove-Item -LiteralPath $sidecar
    Remove-Item -LiteralPath $mmproj
    try { [void](Get-StrataVisionConfigForSave -Config $config -SidecarPath $sidecar -Root $root); throw 'Expected missing encoder failure.' }
    catch {
        if ($_.Exception.Message -eq 'Expected missing encoder failure.') { throw }
        if ($_.Exception.Message -notlike '*mmproj-Qwen3.8-Flash-Next-BF16.gguf*') { throw }
    }

    [IO.File]::WriteAllBytes($mmproj,[byte[]]@(1))
    [IO.File]::WriteAllText($build,'{"vision":"cpu"}',[Text.UTF8Encoding]::new($false))
    $cpu = Get-StrataVisionConfigForSave -Config $config -SidecarPath $sidecar -Root $root
    Assert-Equal $cpu.gpu $false 'CPU-only vision build should not request GPU encoding'
    Assert-Equal $cpu.max_tokens 300 'CPU vision should use the setup token limit'

    [IO.File]::WriteAllText($build,'{"vision":"gpu"}',[Text.UTF8Encoding]::new($false))
    $swiftDirectory = Join-Path $fixture 'Strata-data\models\swift-iq3_s'
    [void](New-Item -ItemType Directory -Path $swiftDirectory -Force)
    $swiftModel = Join-Path $swiftDirectory 'Swift-Qwen3.8-Flash-Next-IQ3_S-00001-of-00002.gguf'
    $swiftMmproj = Join-Path $fixture 'Strata-data\models\mmproj-Swift-Qwen3.8-Flash-Next-BF16.gguf'
    foreach ($path in @($swiftModel,$swiftMmproj)) { [IO.File]::WriteAllBytes($path,[byte[]]@(1)) }
    $swift = [pscustomobject]@{model_name='swift-1.5-iq3_s';args=@('--native',$swiftModel)}
    $swiftVision = Get-StrataVisionConfigForSave -Config $swift -SidecarPath $sidecar -Root $root
    Assert-Equal $swiftVision.mmproj $swiftMmproj 'Swift should use its own vision encoder'

    'PASS: first-time vision creates settings and preserves existing choices'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $testRoot = [IO.Path]::GetFullPath($PSScriptRoot)
    if ($resolved.StartsWith($testRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
