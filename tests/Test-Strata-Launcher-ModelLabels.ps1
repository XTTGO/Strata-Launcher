$ErrorActionPreference='Stop'
. ([scriptblock]::Create((Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Strata-Launcher-Environment.ps1') -Raw -Encoding UTF8)))
# Creator/source matches setup.FAMILIES / setup.OWN_PATH_FAMILIES, MODELS repo,
# and docs/MODELS.md; it describes quantization rather than changing model identity.
$cases=@(
    @('qwen3.8-flash-next-q2_0','','Qwen3.8-Flash-Next (ISTA-DASLab GSQ-RCO) Q2_0'),
    @('qwen3.8-flash-next-iq2_xs','','Qwen3.8-Flash-Next (ISTA-DASLab GSQ-RCO) IQ2_XS'),
    @('qwen3.8-flash-next-iq3_xxs','','Qwen3.8-Flash-Next (ISTA-DASLab GSQ-RCO) IQ3_XXS'),
    @('qwen3.8-flash-next-iq3_s','','Qwen3.8-Flash-Next (ISTA-DASLab GSQ-RCO) IQ3_S'),
    @('qwen3.8-flash-next-unsloth-q8_0','','Qwen3.8-Flash-Next (Unsloth) Q8_0'),
    @('qwen3.8-flash-next-unsloth-ud-iq4_xs','','Qwen3.8-Flash-Next (Unsloth) UD-IQ4_XS'),
    @('qwen3.8-flash-next-unsloth-ud-q4_k_xl','','Qwen3.8-Flash-Next (Unsloth) UD-Q4_K_XL'),
    @('qwen3.8-flash-next-unsloth-ud-q5_k_xl','','Qwen3.8-Flash-Next (Unsloth) UD-Q5_K_XL'),
    @('qwen3.8-flash-next-unsloth-ud-q6_k_xl','','Qwen3.8-Flash-Next (Unsloth) UD-Q6_K_XL'),
    @('qwen3.8-flash-next-coder-iq1_m','','Qwen3.8-Flash-Next Coder (ISTA-DASLab GSQ-RCO) IQ1_M'),
    @('swift-1.5-iq2_xs','','Swift 1.5 (UkisAI GSQ-RCO) IQ2_XS'),
    @('swift-1.5-iq3_xxs','','Swift 1.5 (UkisAI GSQ-RCO) IQ3_XXS'),
    @('swift-1.5-iq3_s','','Swift 1.5 (UkisAI GSQ-RCO) IQ3_S'),
    @('qwen3.8-flash-next-nvfp4-nvfp4','','Qwen3.8-Flash-Next (sergqwer GPTQ) NVFP4'),
    @('qwen3.8-flash-next-nvfp4-nvfp4-nvidia','','Qwen3.8-Flash-Next (NVIDIA; sergqwer conversion) NVFP4'),
    @('qwen3.6-35b-a3b-ud-q4_k_xl','qwen35moe','Qwen3.6-35B-A3B (Unsloth MTP) UD-Q4_K_XL'),
    @('qwen3.6-35b-a3b-ud-q6_k_xl','qwen35moe','Qwen3.6-35B-A3B (Unsloth MTP) UD-Q6_K_XL'),
    @('qwen3.6-35b-a3b-q8_0','qwen35moe','Qwen3.6-35B-A3B (Unsloth MTP) Q8_0')
)
foreach($case in $cases){
    $actual=Get-StrataModelLabel -ModelName $case[0] -Arch $case[1]
    if($actual -cne $case[2]){throw "Wrong label for $($case[0]): $actual (expected $($case[2]))"}
}
$catalog=@(Get-StrataModelCatalog -LauncherDirectory (Join-Path $PSScriptRoot '..'))
if(-not $catalog.Count){throw 'Current setup returned no models.'}
$environment=Get-StrataLauncherEnvironment -LauncherDirectory (Join-Path $PSScriptRoot '..')
if($environment.ModelCatalogStatus -ne 'current-setup' -or $environment.ModelCatalogCount -ne $catalog.Count){
    throw 'Launcher did not load the current setup model catalog.'
}
foreach($case in $cases){
    if(-not ($catalog | Where-Object { $_.model_name -ieq $case[0] })){continue}
    $actual=Get-StrataModelLabel -ModelName $case[0] -Arch $case[1] -Catalog $catalog
    if($actual -cne $case[2]){throw "Catalog label for $($case[0]): $actual (expected $($case[2]))"}
}
$future=@([pscustomobject]@{model_name='new-model-iq4';arch='';label='New Model (HF: NewPublisher) IQ4'})
if((Get-StrataModelLabel -ModelName 'new-model-iq4' -Arch '' -Catalog $future) -cne $future[0].label){
    throw 'A future setup model was not selected from the extracted catalog.'
}
$unknown='local-private-model-name'
if((Get-StrataModelLabel -ModelName $unknown -Arch '') -ne $unknown){throw 'Unknown model name was changed.'}
$sameLabel=@(
    [pscustomobject]@{Label='Qwen3.8-Flash-Next (ISTA-DASLab GSQ-RCO) IQ3_S';Path='C:\models\strata-a.json';ModelName='qwen3.8-flash-next-iq3_s'},
    [pscustomobject]@{Label='Qwen3.8-Flash-Next (ISTA-DASLab GSQ-RCO) IQ3_S';Path='C:\models\strata-b.json';ModelName='qwen3.8-flash-next-iq3_s'}
)
Resolve-StrataModelLabelCollisions -ModelConfigs $sameLabel
if($sameLabel[0].Label -eq $sameLabel[1].Label){throw 'Two configs with one display label cannot be selected independently.'}
if($sameLabel[0].ModelName -ne 'qwen3.8-flash-next-iq3_s' -or $sameLabel[1].Path -ne 'C:\models\strata-b.json'){
    throw 'Display label mapping changed model identity.'
}
'Model labels passed.'
