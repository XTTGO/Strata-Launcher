function Get-StrataLauncherEnvironment {
    param(
        [Parameter(Mandatory=$true)][string]$LauncherDirectory
    )

    $launcher = [IO.Path]::GetFullPath($LauncherDirectory)
    $root = Resolve-StrataLauncherRoot -LauncherDirectory $launcher
    $rootParent = Split-Path -Parent $root
    $defaultDataDirectory = Join-Path $rootParent 'Strata-data'

    $hasDeepSeekConfig = $false
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter 'strata-*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $candidate = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$candidate.arch -eq 'deepseek41' -or ([string]$candidate.exe) -match 'strata-dsv41|engine-dsv41') { $hasDeepSeekConfig = $true; break }
        } catch { }
    }
    $deepSeekEngine = Get-StrataDeepSeekEngineStatus -Root $root
    $required = [ordered]@{
        'START-HERE.bat' = Join-Path $root 'START-HERE.bat'
        '.venv\Scripts\python.exe' = Join-Path $root '.venv\Scripts\python.exe'
        'serve\server.py' = Join-Path $root 'serve\server.py'
        'UPDATE.bat' = Join-Path $root 'UPDATE.bat'
        'tools\calibrate.py' = Join-Path $root 'tools\calibrate.py'
        'tools\needle_bench.py' = Join-Path $root 'tools\needle_bench.py'
        'tools\serve_load.py' = Join-Path $root 'tools\serve_load.py'
    }
    $missing = @($required.GetEnumerator() | Where-Object {
        -not (Test-Path -LiteralPath $_.Value -PathType Leaf)
    } | ForEach-Object { $_.Key })
    $hasQwenEngine = Test-Path -LiteralPath (Join-Path $root 'engine\strata.exe') -PathType Leaf
    $deepSeekCovers = ($hasDeepSeekConfig -and $null -ne $deepSeekEngine.InstalledVersion)
    if (-not $hasQwenEngine -and -not $deepSeekCovers) { $missing += 'engine\strata.exe' }
    $engineStatus = Get-StrataEngineVersionStatus -Root $root
    $strataVersion = Get-StrataSourceVersion -Root $root
    $engineIssue = [string]$engineStatus.Issue
    $engineWarning = [string]$engineStatus.Warning
    if ($engineIssue -and -not $deepSeekCovers) { $missing += $engineIssue }

    $modelCatalog = @()
    $catalogError = ''
    $catalogSource = ''
    try {
        $modelCatalog = @(Get-StrataModelCatalog -LauncherDirectory $launcher -Source ([ref]$catalogSource))
        if (-not $modelCatalog.Count) { throw '官方 setup 未返回支持模型清单。' }
    } catch {
        $catalogError = $_.Exception.Message
    }

    $modelConfigs = [Collections.ArrayList]::new()
    $unavailableModels = [Collections.ArrayList]::new()
    if (Test-Path -LiteralPath $root -PathType Container) {
        foreach ($file in (Get-ChildItem -LiteralPath $root -File -Filter 'strata-*.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*.shared-settings.json' } | Sort-Object Name)) {
            try {
                $candidate = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if (-not $candidate.exe -or $null -eq $candidate.args -or -not $candidate.model_name) { continue }
                $missingModelFiles = @(Get-StrataMissingModelFiles -Config $candidate -ConfigPath $file.FullName)
                if ($missingModelFiles.Count) {
                    [void]$unavailableModels.Add([pscustomobject]@{
                        ModelName = [string]$candidate.model_name
                        Path = $file.FullName
                        MissingFiles = $missingModelFiles
                    })
                    continue
                }
                $label = Get-StrataModelLabel -ModelName ([string]$candidate.model_name) -Arch ([string]$candidate.arch) -Catalog $modelCatalog
                [void]$modelConfigs.Add([pscustomobject]@{
                    Label = $label
                    Path = $file.FullName
                    ModelName = [string]$candidate.model_name
                })
            } catch { }
        }
    }
    Resolve-StrataModelLabelCollisions -ModelConfigs @($modelConfigs)
    if (-not $modelConfigs.Count) {
        $missing += $(if ($unavailableModels.Count) { '模型文件或专家包（配置仍在，但引用的组件已缺失）' } else { 'strata-*.json（至少一个可用模型配置）' })
    }

    $message = ''
    if ($missing.Count) {
        if ($engineIssue -and $missing.Count -eq 1) {
            $message = $engineIssue + "`r`n请等待官方更新完成，或检查 UPDATE.bat 的最终错误。"
        } elseif ($unavailableModels.Count -and $missing.Count -eq 1) {
            $message = "发现 $($unavailableModels.Count) 个模型配置，但它们引用的 GGUF 文件或专家包已缺失。`r`n" +
                "配置文件没有被删除。请恢复模型文件或使用官方 START-HERE.bat 重新安装模型，然后重新打开启动器。"
        } else {
            $message = "启动器没有位于一个已安装完成的 Strata 目录中。`r`n`r`n" +
                "请把整个 launcher 文件夹放到 Strata 根目录下，使两者成为：`r`n" +
                "  <Strata>\START-HERE.bat`r`n" +
                "  <Strata>\launcher\Strata-Launcher.bat`r`n`r`n" +
                "当前识别的 Strata 根目录：$root`r`n" +
                "缺少：`r`n  - " + ($missing -join "`r`n  - ") + "`r`n`r`n" +
                '请先用官方 START-HERE.bat 完成 Strata 和模型安装，再打开本启动器。'
        }
    }

    return [pscustomobject]@{
        IsReady = ($missing.Count -eq 0)
        LauncherDirectory = $launcher
        Root = $root
        DefaultDataDirectory = $defaultDataDirectory
        Python = Join-Path $root '.venv\Scripts\python.exe'
        Server = Join-Path $root 'serve\server.py'
        ModelConfigs = @($modelConfigs)
        UnavailableModels = @($unavailableModels)
        EngineIssue = $engineIssue
        EngineWarning = $engineWarning
        StrataVersion = $strataVersion
        EngineVersion = $(if ($engineStatus.InstalledVersion) { [string]$engineStatus.InstalledVersion } else { '未知' })
        DeepSeekEngineVersion = $(if ($deepSeekEngine.InstalledVersion) { [string]$deepSeekEngine.InstalledVersion } else { '' })
        DeepSeekEnginePath = [string]$deepSeekEngine.Path
        ModelCatalogStatus = $(if ($modelCatalog.Count) { 'current-setup' } else { 'fallback' })
        ModelCatalogSource = $catalogSource
        ModelCatalogCount = $modelCatalog.Count
        ModelCatalogError = $catalogError
        Missing = @($missing)
        Message = $message
    }
}

function Get-StrataSourceVersion {
    param([Parameter(Mandatory=$true)][string]$Root)

    if (-not (Test-Path -LiteralPath (Join-Path $Root '.git')) -or
            -not (Get-Command git -ErrorAction SilentlyContinue)) { return '未知' }
    try {
        $description = @(& git -C $Root describe --tags --always --match 'v[0-9]*' 2>$null)
        if ($LASTEXITCODE -eq 0 -and $description.Count -eq 1) {
            $version = ([string]$description[0]).Trim()
            if ($version -match '^v\d+\.\d+\.\d+(?:\.\d+)?(?:-\d+-g[0-9a-f]+)?$') { return $version }
        }
    } catch { }
    return '未知'
}

function Get-StrataEngineExecutablePaths {
    param([Parameter(Mandatory=$true)][string]$Root)

    # The Qwen engine sits in engine\; DeepSeek's package is unpacked into a versioned folder under engine-dsv41\.
    $paths = @((Join-Path $Root 'engine\strata.exe'))
    $direct = Join-Path $Root 'engine-dsv41\strata-dsv41.exe'
    if (Test-Path -LiteralPath $direct -PathType Leaf) { $paths += $direct }
    foreach ($dir in @(Get-ChildItem -LiteralPath (Join-Path $Root 'engine-dsv41') -Directory -ErrorAction SilentlyContinue)) {
        $exe = Join-Path $dir.FullName 'strata-dsv41.exe'
        if (Test-Path -LiteralPath $exe -PathType Leaf) { $paths += $exe }
    }
    return $paths
}
function Get-StrataDeepSeekEngineStatus {
    param([Parameter(Mandatory=$true)][string]$Root)

    $status = [pscustomobject]@{ InstalledVersion = $null; Path = ''; Directory = '' }
    $base = Join-Path $Root 'engine-dsv41'
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { return $status }
    $found = @()
    foreach ($sub in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue)) {
        $exe = Join-Path $sub.FullName 'strata-dsv41.exe'
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
        $version = $null
        $build = Join-Path $sub.FullName 'BUILD.json'
        if (Test-Path -LiteralPath $build -PathType Leaf) {
            try {
                $data = Get-Content -LiteralPath $build -Raw -Encoding UTF8 | ConvertFrom-Json
                if (([string]$data.version) -match '^\d+(?:\.\d+)+$') { $version = [version]([string]$data.version) }
            } catch { }
        }
        if (-not $version) {
            $match = [regex]::Match($sub.Name, '^(\d+(?:\.\d+)+)')
            if ($match.Success) { $version = [version]$match.Groups[1].Value }
        }
        $found += [pscustomobject]@{ Version = $version; Path = $exe; Directory = $sub.FullName }
    }
    if (-not $found.Count) { return $status }
    $best = $found | Sort-Object -Property @{ Expression = { if ($_.Version) { $_.Version } else { [version]'0.0' } } } -Descending | Select-Object -First 1
    $status.InstalledVersion = $best.Version
    $status.Path = $best.Path
    $status.Directory = $best.Directory
    return $status
}

function Get-StrataEngineVersionStatus {
    param([Parameter(Mandatory=$true)][string]$Root)

    $setupPath = Join-Path $Root 'setup.py'
    $status = [pscustomobject]@{
        Issue = ''
        Warning = ''
        MinimumVersion = $null
        SourceVersion = $null
        RequiredVersion = $null
        InstalledVersion = $null
        InstallSource = ''
    }
    if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
        return $status
    }
    try {
        $setupSource = Get-Content -LiteralPath $setupPath -Raw -Encoding UTF8
        $match = [regex]::Match($setupSource,'(?m)^MIN_ENGINE\s*=\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)')
        if (-not $match.Success) { return $status }
        $minimum = [version]::new([int]$match.Groups[1].Value,[int]$match.Groups[2].Value,[int]$match.Groups[3].Value)
        $status.MinimumVersion = $minimum
        $cmakePath = Join-Path $Root 'CMakeLists.txt'
        if (Test-Path -LiteralPath $cmakePath -PathType Leaf) {
            $cmakeSource = Get-Content -LiteralPath $cmakePath -Raw -Encoding UTF8
            $sourceMatch = [regex]::Match($cmakeSource,'(?m)^project\(strata\s+VERSION\s+(\d+(?:\.\d+)+)\b')
            if ($sourceMatch.Success) {
                $status.SourceVersion = [version]$sourceMatch.Groups[1].Value
            }
        }
        $buildPath = Join-Path $Root 'engine\BUILD.json'
        if (-not (Test-Path -LiteralPath $buildPath -PathType Leaf)) {
            $status.Issue = "引擎安装状态无法确认：缺少 $buildPath。"
            return $status
        }
        $build = Get-Content -LiteralPath $buildPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $status.InstalledVersion = [version]([string]$build.version)
        $status.InstallSource = [string]$build.source
        $required = $minimum
        if ($status.InstallSource -eq 'local' -and $status.SourceVersion -and $status.SourceVersion -gt $required) {
            $required = $status.SourceVersion
        }
        $status.RequiredVersion = $required
        if ($status.InstalledVersion -lt $required) {
            if ($status.InstallSource -eq 'local') {
                $status.Warning = "当前本地编译引擎 $($status.InstalledVersion) 低于当前源码构建目标 $required；请重新编译引擎。"
            } else {
                $status.Warning = "当前预编译引擎 $($status.InstalledVersion) 低于 Strata 安装所需 $required；请检查更新结果。"
            }
        }
    } catch {
        $status.Issue = '无法读取或比较 Strata 安装及引擎版本。'
    }
    return $status
}

function Get-StrataMissingModelFiles {
    param([Parameter(Mandatory=$true)]$Config, [Parameter(Mandatory=$true)][string]$ConfigPath)

    # setup.py leaves strata-*.json in place when the GGUF folder is removed.
    # Only check paths that identify model weights; an optional helper component
    # going missing must not silently remove an otherwise installed model.
    $base = [string[]]@($Config.args)
    $user = [string[]]@($Config.user_args)
    $configDirectory = Split-Path -Parent $ConfigPath
    $workingDirectory = if ($Config.cwd) {
        if ([IO.Path]::IsPathRooted([string]$Config.cwd)) { [string]$Config.cwd }
        else { Join-Path $configDirectory ([string]$Config.cwd) }
    } else { $configDirectory }
    foreach ($flag in @('--pack','--native','--native-dense-gguf','--gguf','--ple-gguf','--embd-gguf')) {
        $value = ''
        foreach ($argsList in @($base,$user)) {
            $index = [Array]::IndexOf([string[]]$argsList,$flag)
            if ($index -ge 0 -and $index + 1 -lt $argsList.Count) { $value = [string]$argsList[$index + 1] }
        }
        if (-not $value) { continue }
        try {
            $path = if ([IO.Path]::IsPathRooted($value)) { $value } else { Join-Path $workingDirectory $value }
            $path = [IO.Path]::GetFullPath($path)
            $kind = if ($flag -eq '--pack') { 'Container' } else { 'Leaf' }
            if (-not (Test-Path -LiteralPath $path -PathType $kind)) { Write-Output $path }
        } catch { Write-Output $value }
    }
}

function Get-StrataModelCatalog {
    param(
        [Parameter(Mandatory=$true)][string]$LauncherDirectory,
        [ref]$Source
    )

    $launcher = [IO.Path]::GetFullPath($LauncherDirectory)
    $root = Resolve-StrataLauncherRoot -LauncherDirectory $launcher
    $setup = Join-Path $root 'setup.py'
    $helper = Join-Path $launcher 'model_catalog.py'
    if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) { throw "找不到官方 setup.py：$setup" }
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { throw "找不到模型清单提取器：$helper" }
    $setupHash = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash
    $helperHash = (Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash
    $cache = Join-Path $launcher 'data\model-catalog-cache.json'

    if (Test-Path -LiteralPath $cache -PathType Leaf) {
        try {
            $saved = Get-Content -LiteralPath $cache -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($saved.schema -eq 1 -and
                [string]::Equals([string]$saved.root,$root,[StringComparison]::OrdinalIgnoreCase) -and
                $saved.setup_hash -eq $setupHash -and $saved.helper_hash -eq $helperHash -and
                @($saved.catalog).Count -gt 0) {
                $valid = @($saved.catalog | Where-Object { -not $_.model_name -or -not $_.label }).Count -eq 0
                if ($valid) {
                    if ($null -ne $Source) { $Source.Value = 'cache' }
                    foreach ($entry in $saved.catalog) { Write-Output $entry }
                    return
                }
            }
        } catch { }
    }

    $catalog = @(Read-StrataModelCatalogFromSetup -LauncherDirectory $launcher)
    if (-not $catalog.Count) { throw '官方 setup 未返回支持模型清单。' }
    $payload = [ordered]@{
        schema = 1
        root = $root
        setup_hash = $setupHash
        helper_hash = $helperHash
        catalog = $catalog
    }
    $temporary = $cache + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $cache) -Force)
        [IO.File]::WriteAllText($temporary,($payload | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $cache -Force
    } catch {
        # Read-only launcher locations still get the live catalog for this run.
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    if ($null -ne $Source) { $Source.Value = 'extracted' }
    foreach ($entry in $catalog) { Write-Output $entry }
}

function Read-StrataModelCatalogFromSetup {
    param([Parameter(Mandatory=$true)][string]$LauncherDirectory)

    $launcher = [IO.Path]::GetFullPath($LauncherDirectory)
    $root = Resolve-StrataLauncherRoot -LauncherDirectory $launcher
    $python = Join-Path $root '.venv\Scripts\python.exe'
    $helper = Join-Path $launcher 'model_catalog.py'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "找不到官方 Python：$python" }
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { throw "找不到模型清单提取器：$helper" }

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $python
    $psi.Arguments = '"' + $helper + '"'
    $psi.WorkingDirectory = $root
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { throw '无法启动模型清单提取器。' }
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            $process.Kill()
            throw '读取官方模型清单超时。'
        }
        $output = $outputTask.Result
        $errorOutput = $errorTask.Result
        if ($process.ExitCode -ne 0) { throw "读取官方模型清单失败：$errorOutput" }
        $catalog = $output | ConvertFrom-Json
        foreach ($entry in $catalog) { Write-Output $entry }
    } finally {
        $process.Dispose()
    }
}

function Get-StrataMonitorUrl {
    param(
        [Parameter(Mandatory=$true)][ValidateRange(1024,65535)][int]$Port,
        $Health
    )

    if ($null -eq $Health -or $Health.service -ne 'strata') { return $null }
    return "http://127.0.0.1:$Port/#monitor"
}

function Get-StrataModelLabel {
    param([string]$ModelName, [string]$Arch, [object[]]$Catalog=@())

    $name = $ModelName.Trim()
    foreach ($entry in $Catalog) {
        if ($entry.model_name -ieq $name -and (-not $entry.arch -or $entry.arch -ieq $Arch) -and $entry.label) {
            return [string]$entry.label
        }
    }
    if ($Arch -eq 'deepseek41') { return 'DeepSeek-V4.1-Flash' }
    if ($Arch -eq 'qwen35moe') {
        $prefix = 'qwen3.6-35b-a3b-'
        if ($name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $quant = $name.Substring($prefix.Length).ToUpperInvariant()
            if (@('UD-Q4_K_XL','UD-Q6_K_XL','Q8_0') -contains $quant) {
                return "Qwen3.6-35B-A3B (Unsloth MTP) $quant"
            }
        }
        return $ModelName
    }

    $families = @(
        @{ Prefix='qwen3.8-flash-next-unsloth-'; Label='Qwen3.8-Flash-Next (Unsloth)'; Models=@('UD-IQ4_XS','UD-Q4_K_XL','UD-Q5_K_XL','UD-Q6_K_XL','Q8_0') },
        @{ Prefix='qwen3.8-flash-next-coder-'; Label='Qwen3.8-Flash-Next Coder (ISTA-DASLab GSQ-RCO)'; Models=@('IQ1_M') },
        @{ Prefix='qwen3.8-flash-next-'; Label='Qwen3.8-Flash-Next (ISTA-DASLab GSQ-RCO)'; Models=@('Q2_0','IQ2_XS','IQ3_XXS','IQ3_S') },
        @{ Prefix='swift-1.5-'; Label='Swift 1.5 (UkisAI GSQ-RCO)'; Models=@('IQ2_XS','IQ3_XXS','IQ3_S') }
    )
    if ($name.StartsWith('qwen3.8-flash-next-nvfp4-', [StringComparison]::OrdinalIgnoreCase)) {
        $quant = $name.Substring('qwen3.8-flash-next-nvfp4-'.Length).ToUpperInvariant()
        if ($quant -eq 'NVFP4') { return 'Qwen3.8-Flash-Next (sergqwer GPTQ) NVFP4' }
        if ($quant -eq 'NVFP4-NVIDIA') { return 'Qwen3.8-Flash-Next (NVIDIA; sergqwer conversion) NVFP4' }
        return $ModelName
    }
    foreach ($family in $families) {
        if (-not $name.StartsWith($family.Prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $quant = $name.Substring($family.Prefix.Length).ToUpperInvariant()
        if ($family.Models -contains $quant) { return "$($family.Label) $quant" }
        break
    }
    return $ModelName
}

function Get-StrataNewestReleaseTag {
    param([string]$ReleaseTag, [string[]]$Tags, [scriptblock]$IsDescendant)
    if ($ReleaseTag -notmatch '^v(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?$') { return $null }
    $series = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
    $base = [version]$ReleaseTag.Substring(1)
    $patchPattern = '^v' + [regex]::Escape($series) + '\.\d+$'
    $best = $null
    foreach ($tag in @($Tags)) {
        if ($tag -notmatch $patchPattern) { continue }
        $version = [version]$tag.Substring(1)
        if ($version -le $base) { continue }
        if ($IsDescendant -and -not (& $IsDescendant $tag)) { continue }
        if (-not $best -or $version -gt $best.Version) {
            $best = [pscustomobject]@{ Tag = $tag; Version = $version }
        }
    }
    return $best
}
function Resolve-StrataModelLabelCollisions {
    param([object[]]$ModelConfigs)

    foreach ($group in @($ModelConfigs | Group-Object -Property Label | Where-Object { $_.Count -gt 1 })) {
        foreach ($config in $group.Group) {
            $stem = [IO.Path]::GetFileNameWithoutExtension([string]$config.Path)
            $config.Label = "$($config.Label) [$stem]"
        }
    }
}

function Resolve-StrataLauncherRoot {
    param([Parameter(Mandatory=$true)][string]$LauncherDirectory)

    $launcher = [IO.Path]::GetFullPath($LauncherDirectory)
    $candidate = Split-Path -Parent $launcher
    if (Test-Path -LiteralPath (Join-Path $candidate 'START-HERE.bat') -PathType Leaf) {
        return $candidate
    }
    $sibling = Join-Path $candidate 'Strata'
    if (Test-Path -LiteralPath (Join-Path $sibling 'START-HERE.bat') -PathType Leaf) {
        return $sibling
    }
    return $candidate
}
function Repair-StrataConfigEnginePath {
    param(
        [Parameter(Mandatory=$true)]$Config,
        [Parameter(Mandatory=$true)][string]$Root,
        [string]$NewEngineExe = ''
    )

    # A model config names its engine by absolute path, and the DeepSeek engine upgrade installs a new versioned
    # package folder and then deletes the old one: a config written before that names a file which no longer exists,
    # and the start dies inside CreateProcess (WinError 2). Re-point it — only when the named engine is missing (a
    # working config is never touched), only the DeepSeek engine (engine-dsv41), and only to an installed engine.
    $exe = [string]$Config.exe
    if (-not $exe -or (Test-Path -LiteralPath $exe)) { return $Config }
    if ($exe -notmatch '[\\/]engine-dsv41[\\/]') { return $Config }
    $replacement = $NewEngineExe
    if (-not $replacement) { $replacement = [string](Get-StrataDeepSeekEngineStatus -Root $Root).Path }
    if (-not $replacement -or -not (Test-Path -LiteralPath $replacement -PathType Leaf)) { return $Config }
    $oldFolder = Split-Path -Parent $exe
    $newFolder = Split-Path -Parent $replacement
    $Config.exe = $replacement
    if ($Config.PSObject.Properties['lib_dirs'] -and $Config.lib_dirs) {
        $dirs = @()
        foreach ($dir in @($Config.lib_dirs)) {
            $dirs += $(if ([string]::Equals([string]$dir, $oldFolder, [StringComparison]::OrdinalIgnoreCase)) { $newFolder } else { [string]$dir })
        }
        $Config.lib_dirs = $dirs
    }
    return $Config
}

function Repair-StrataEngineConfigFiles {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [string]$NewEngineExe = ''
    )

    # The same repair on disk, before the server reads a run config: only the engine's folder path is replaced, the
    # rest of the file stays byte for byte (the JSON writer would reformat the whole config).
    $newExe = $NewEngineExe
    if (-not $newExe) { $newExe = [string](Get-StrataDeepSeekEngineStatus -Root $Root).Path }
    if (-not $newExe -or -not (Test-Path -LiteralPath $newExe -PathType Leaf)) { return @() }
    $newFolder = Split-Path -Parent $newExe
    $fixed = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Filter 'strata-*.json' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if ($file.Name -like '*.shared-settings.json') { continue }
        $raw = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
        if ($raw -notmatch 'engine-dsv41') { continue }
        $config = $null
        try { $config = $raw | ConvertFrom-Json } catch { continue }
        if (-not $config -or -not $config.exe) { continue }
        $exe = [string]$config.exe
        if (Test-Path -LiteralPath $exe) { continue }
        if ($exe -notmatch '[\\/]engine-dsv41[\\/]') { continue }
        $oldFolder = Split-Path -Parent $exe
        if (-not $oldFolder -or $oldFolder -eq $newFolder) { continue }
        $updated = $raw.Replace($oldFolder.Replace('\', '\\'), $newFolder.Replace('\', '\\'))
        $updated = $updated.Replace(($oldFolder -replace '\\', '/'), ($newFolder -replace '\\', '/'))
        if ($updated -eq $raw) { continue }
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        [IO.File]::WriteAllText($file.FullName, $updated, (New-Object Text.UTF8Encoding($hasBom)))
        $fixed += [pscustomobject]@{ Config = $file.Name; From = $oldFolder; To = $newFolder }
    }
    return $fixed
}
