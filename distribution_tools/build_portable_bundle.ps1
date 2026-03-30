param(
    [string]$OutputDir = ".\dist",
    [string]$BundleName = "PaddleOCR",
    [switch]$IncludeModelCache = $false,
    [switch]$IncludeWheelhouse = $false,
    [switch]$IncludeTests = $false,
    [switch]$IncludeScreenshots = $false,
    [switch]$KeepStaging = $false
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Write-Step($msg) {
    Write-Host ""
    Write-Host "=== $msg ===" -ForegroundColor Cyan
}

function Start-BundlePhase {
    param(
        [string]$Name,
        [ref]$PhaseCounter,
        [int]$PhaseTotal
    )

    $PhaseCounter.Value++
    $completedPhases = $PhaseCounter.Value - 1
    $percent = if ($PhaseTotal -le 0) { 0 } else { [int](($completedPhases / [double]$PhaseTotal) * 100) }

    Write-Step $Name
    Write-Progress -Id 1 -Activity "Building portable bundle" -Status "Step $($PhaseCounter.Value)/${PhaseTotal}: $Name" -PercentComplete $percent -CurrentOperation $Name
}

function Finish-BundlePhase {
    param(
        [string]$Name,
        [int]$PhaseIndex,
        [int]$PhaseTotal
    )

    Write-Progress -Id 2 -Activity $Name -Completed
    $percent = if ($PhaseTotal -le 0) { 100 } else { [int](($PhaseIndex / [double]$PhaseTotal) * 100) }
    Write-Progress -Id 1 -Activity "Building portable bundle" -Status "Completed: $Name" -PercentComplete $percent -CurrentOperation $Name
}

function Write-SubProgress {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$Current,
        [int]$Total
    )

    $safeTotal = if ($Total -le 0) { 1 } else { $Total }
    $percent = [int](($Current / [double]$safeTotal) * 100)
    Write-Progress -Id 2 -ParentId 1 -Activity $Activity -Status $Status -PercentComplete $percent
}

function Test-WorkspaceRoot {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return $false
    }

    $runnerScript = Join-Path $Path "tools\run_ocr_launcher.py"
    $registerScript = Join-Path $Path "register_shared_ocr_home.ps1"
    return (Test-Path $runnerScript) -and (Test-Path $registerScript)
}

function Get-ProjectRoot {
    $candidates = @()

    if ($PSScriptRoot -and (Test-Path $PSScriptRoot)) {
        $candidates += $PSScriptRoot
    }

    $current = (Get-Location).Path
    if ($current -and (Test-Path $current) -and ($candidates -notcontains $current)) {
        $candidates += $current
    }

    foreach ($candidate in $candidates) {
        if (Test-WorkspaceRoot -Path $candidate) {
            return $candidate
        }

        $parent = Split-Path -Parent $candidate
        if ($parent -and ($parent -ne $candidate) -and (Test-WorkspaceRoot -Path $parent)) {
            return $parent
        }
    }

    if ($candidates.Count -gt 0) {
        return $candidates[0]
    }

    throw "Unable to resolve project root."
}

function Get-VenvPython {
    param([string]$ProjectRoot)

    $venvPython = Join-Path $ProjectRoot ".venv\Scripts\python.exe"
    if (-not (Test-Path $venvPython)) {
        throw "Cannot build bundled wheelhouse because venv Python was not found: $venvPython"
    }

    return $venvPython
}

function Invoke-NativeProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [switch]$EchoOutput
    )

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()

    try {
        $process = Start-Process `
            -FilePath $FilePath `
            -ArgumentList $Arguments `
            -Wait `
            -NoNewWindow `
            -PassThru `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath

        $exitCode = if ($null -eq $process.ExitCode) { 0 } else { [int]$process.ExitCode }
        $stdoutLines = if (Test-Path $stdoutPath) { @(Get-Content -Path $stdoutPath) } else { @() }
        $stderrLines = if (Test-Path $stderrPath) { @(Get-Content -Path $stderrPath) } else { @() }

        if ($EchoOutput) {
            foreach ($line in $stdoutLines) {
                Write-Host $line
            }
            foreach ($line in $stderrLines) {
                Write-Host $line -ForegroundColor Yellow
            }
        }

        return [pscustomobject]@{
            ExitCode = $exitCode
            StdOut   = $stdoutLines
            StdErr   = $stderrLines
        }
    }
    finally {
        Remove-Item $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-PaddleGpuIndexTag {
    param([string]$PythonExe)

    $tempPy = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), ".py")
    try {
        Set-Content -Path $tempPy -Encoding ASCII -Value @"
import paddle
print((paddle.version.cuda() or '').strip())
"@

        $result = Invoke-NativeProcess -FilePath $PythonExe -Arguments @($tempPy)
        if ($result.ExitCode -ne 0) {
            return "cu118"
        }

        $cudaVersionLine = $result.StdOut | Where-Object { $_ } | Select-Object -Last 1
        $cudaVersion = if ($cudaVersionLine) { $cudaVersionLine.Trim() } else { "" }
    }
    finally {
        Remove-Item $tempPy -Force -ErrorAction SilentlyContinue
    }

    if (-not $cudaVersion) {
        return "cu118"
    }

    $normalized = $cudaVersion -replace '[^0-9.]', ''
    switch ($normalized) {
        "11.8" { return "cu118" }
        "12.6" { return "cu126" }
        "12.9" { return "cu129" }
        "13.0" { return "cu130" }
        default {
            $compact = $normalized -replace '\.', ''
            if ($compact) {
                return "cu$compact"
            }
            return "cu118"
        }
    }
}

function Copy-PortableFile {
    param(
        [string]$ProjectRoot,
        [string]$StagingRoot,
        [string]$RelativePath
    )

    $source = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path $source)) {
        return
    }

    $destination = Join-Path $StagingRoot $RelativePath
    $destinationDir = Split-Path $destination -Parent
    if ($destinationDir) {
        New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
    }

    Copy-Item -Path $source -Destination $destination -Force
}

function Copy-PortableDirectory {
    param(
        [string]$ProjectRoot,
        [string]$StagingRoot,
        [string]$RelativePath,
        [string]$Activity = "Copy directory"
    )

    $source = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path $source)) {
        return
    }

    $destination = Join-Path $StagingRoot $RelativePath
    New-Item -ItemType Directory -Path $destination -Force | Out-Null

    $files = @(Get-ChildItem -Path $source -File -Recurse -Force)
    if ($files.Count -eq 0) {
        Write-SubProgress -Activity $Activity -Status "No files to copy" -Current 1 -Total 1
        return
    }

    $index = 0
    foreach ($file in $files) {
        $index++
        $relativeFilePath = $file.FullName.Substring($source.Length).TrimStart('\', '/')
        $destinationPath = Join-Path $destination $relativeFilePath
        $destinationDir = Split-Path $destinationPath -Parent
        if ($destinationDir) {
            New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
        }

        Copy-Item -Path $file.FullName -Destination $destinationPath -Force
        Write-SubProgress -Activity $Activity -Status $relativeFilePath -Current $index -Total $files.Count
    }
}

function Copy-BundledModelCache {
    param(
        [string]$ProjectRoot,
        [string]$StagingRoot
    )

    $sourceCache = Join-Path $env:USERPROFILE ".paddlex\official_models"
    if (-not (Test-Path $sourceCache)) {
        Write-Host "Model cache not found at $sourceCache . Building lite bundle instead." -ForegroundColor Yellow
        return $false
    }

    $destinationCache = Join-Path $StagingRoot "bundled_model_cache\official_models"
    New-Item -ItemType Directory -Path $destinationCache -Force | Out-Null

    Write-Host "Copying cached models from $sourceCache" -ForegroundColor Yellow
    $cacheItems = @(Get-ChildItem -Path $sourceCache -Force)
    if ($cacheItems.Count -eq 0) {
        Write-SubProgress -Activity "Copy bundled model cache" -Status "No cached models found" -Current 1 -Total 1
        return $false
    }

    $index = 0
    foreach ($item in $cacheItems) {
        $index++
        $destinationPath = Join-Path $destinationCache $item.Name
        if ($item.PSIsContainer) {
            Copy-PortableDirectory -ProjectRoot $sourceCache -StagingRoot $destinationCache -RelativePath $item.Name -Activity "Copy bundled model cache"
        } else {
            Copy-Item -Path $item.FullName -Destination $destinationPath -Force
            Write-SubProgress -Activity "Copy bundled model cache" -Status $item.Name -Current $index -Total $cacheItems.Count
        }
    }
    return $true
}

function Export-BundledWheelhouse {
    param(
        [string]$ProjectRoot,
        [string]$StagingRoot
    )

    $venvPython = Get-VenvPython -ProjectRoot $ProjectRoot
    $wheelhouseRoot = Join-Path $StagingRoot "bundled_wheels"
    New-Item -ItemType Directory -Path $wheelhouseRoot -Force | Out-Null

    Write-Host "Exporting bundled wheels with $venvPython" -ForegroundColor Yellow
    $pythonVersionScript = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), ".py")
    try {
        Set-Content -Path $pythonVersionScript -Encoding ASCII -Value @"
import sys
print("{0}.{1}".format(sys.version_info.major, sys.version_info.minor))
"@

        $pythonVersionResult = Invoke-NativeProcess -FilePath $venvPython -Arguments @($pythonVersionScript)
        if ($pythonVersionResult.ExitCode -ne 0) {
            throw "Failed to detect the Python version used by the current virtual environment."
        }

        $pythonVersionLine = $pythonVersionResult.StdOut | Where-Object { $_ } | Select-Object -Last 1
        $pythonVersion = if ($pythonVersionLine) { $pythonVersionLine.Trim() } else { "" }
    }
    finally {
        Remove-Item $pythonVersionScript -Force -ErrorAction SilentlyContinue
    }

    if (-not $pythonVersion) {
        throw "Failed to detect the Python version used by the current virtual environment."
    }

    Set-Content -Path (Join-Path $wheelhouseRoot "python-version.txt") -Value $pythonVersion -Encoding ASCII

    Write-SubProgress -Activity "Export bundled wheelhouse" -Status "Collecting installed package list" -Current 1 -Total 3
    $freezeResult = Invoke-NativeProcess -FilePath $venvPython -Arguments @("-m", "pip", "freeze", "--all")
    if ($freezeResult.ExitCode -ne 0) {
        throw "Failed to collect installed packages from the current virtual environment."
    }

    $packages = @($freezeResult.StdOut) |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -notmatch '^\-e\s+' -and $_ -match '==' }

    if ($packages.Count -eq 0) {
        throw "No pinned packages were found in the current virtual environment."
    }

    $lockPath = Join-Path $wheelhouseRoot "requirements-lock.txt"
    $packages | Set-Content -Path $lockPath -Encoding UTF8

    $paddlePackages = @($packages | Where-Object { $_ -match '^paddlepaddle(-gpu)?==' })
    $generalPackages = @($packages | Where-Object { $_ -notmatch '^paddlepaddle(-gpu)?==' })

    Write-SubProgress -Activity "Export bundled wheelhouse" -Status "Downloading general wheel files" -Current 2 -Total 3
    if ($generalPackages.Count -gt 0) {
        $generalDownload = Invoke-NativeProcess `
            -FilePath $venvPython `
            -Arguments (@("-m", "pip", "download", "--disable-pip-version-check", "--only-binary=:all:", "--dest", $wheelhouseRoot) + $generalPackages) `
            -EchoOutput
        if ($generalDownload.ExitCode -ne 0) {
            throw "Failed to export bundled wheels. Some non-Paddle packages may not have downloadable wheel files for this environment."
        }
    }

    if ($paddlePackages.Count -gt 0) {
        $gpuIndexTag = Get-PaddleGpuIndexTag -PythonExe $venvPython
        foreach ($package in $paddlePackages) {
            if ($package -match '^paddlepaddle-gpu==') {
                $gpuDownload = Invoke-NativeProcess `
                    -FilePath $venvPython `
                    -Arguments @("-m", "pip", "download", "--disable-pip-version-check", "--only-binary=:all:", "--no-deps", "--dest", $wheelhouseRoot, "-i", "https://www.paddlepaddle.org.cn/packages/stable/$gpuIndexTag/", $package) `
                    -EchoOutput
                if ($gpuDownload.ExitCode -ne 0) {
                    throw "Failed to export $package from the official Paddle GPU index ($gpuIndexTag)."
                }
                continue
            }

            $cpuDownload = Invoke-NativeProcess `
                -FilePath $venvPython `
                -Arguments @("-m", "pip", "download", "--disable-pip-version-check", "--only-binary=:all:", "--no-deps", "--dest", $wheelhouseRoot, "-i", "https://www.paddlepaddle.org.cn/packages/stable/cpu/", $package) `
                -EchoOutput
            if ($cpuDownload.ExitCode -ne 0) {
                throw "Failed to export $package from the official Paddle CPU index."
            }
        }
    }

    $gpuPackage = $packages | Where-Object { $_ -match '^paddlepaddle-gpu==' } | Select-Object -First 1
    if ($gpuPackage) {
        Write-SubProgress -Activity "Export bundled wheelhouse" -Status "Downloading CPU Paddle fallback wheel" -Current 3 -Total 3
        $fallbackDownload = Invoke-NativeProcess `
            -FilePath $venvPython `
            -Arguments @("-m", "pip", "download", "--disable-pip-version-check", "--only-binary=:all:", "--no-deps", "--dest", $wheelhouseRoot, "-i", "https://www.paddlepaddle.org.cn/packages/stable/cpu/", "paddlepaddle==3.3.0") `
            -EchoOutput
        if ($fallbackDownload.ExitCode -ne 0) {
            Write-Host "Warning: failed to download CPU Paddle fallback wheel. The portable bundle may still need internet if GPU fallback is required." -ForegroundColor Yellow
            $global:LASTEXITCODE = 0
        }
    } else {
        Write-SubProgress -Activity "Export bundled wheelhouse" -Status "Wheelhouse export complete" -Current 3 -Total 3
    }

    return $true
}

function New-PortableQuickStart {
    param(
        [string]$Path,
        [bool]$HasBundledModelCache,
        [bool]$HasBundledWheelhouse,
        [string]$WheelhousePythonVersion
    )

    $decodeUtf8Base64 = {
        param([string]$Value)
        return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Value))
    }

    $modelCacheText = if ($HasBundledModelCache) {
        & $decodeUtf8Base64 "5pyJ5YyF5ZCr"
    } else {
        & $decodeUtf8Base64 "5pyq5YyF5ZCr"
    }
    $wheelhouseText = if ($HasBundledWheelhouse) {
        & $decodeUtf8Base64 "5pyJ5YyF5ZCr"
    } else {
        & $decodeUtf8Base64 "5pyq5YyF5ZCr"
    }

    $template = & $decodeUtf8Base64 "5pSc5bi25byPIE9DUiDmiZPljIXoqqrmmI4KPT09PT09PT09PT09PT09PT09PQoK6YCZ5YCL5pSc5bi25YyF5Y+v5Lul5a6J5YWo5Zyw6KSH6KO95Yiw5Y+m5LiA5Y+wIFdpbmRvd3Mg6Zu76IWm5L2/55So44CCCuWug+WIu+aEj+S4jeWMheWQqyBgLnZlbnZg44CCCgrnm67mqJnpm7vohabkuIrnmoTlv6vpgJ/plovlp4vvvJoKMS4g5YWI5oqK6YCZ5YCLIFpJUCDop6Plo5PliLDnn63kuJTlj6/lr6vlhaXnmoTos4fmlpnlpL7vvIzkvovlpoIgYEQ6XFBhZGRsZU9DUmAKMi4g5aaC5p6c5L2g5LmL5YmN5pu+5oqK6IiK55qEIGAudmVudmAg6KSH6KO95Yiw6YCZ5YCL6LOH5paZ5aS+77yM6KuL5YWI5Yiq6ZmkCjMuIOmbmeaTiiBgaW5zdGFsbF9hbmRfc3RhcnQuYmF0YAo0LiDnrYnlvoXlronoo53nqIvlvI/lnKjoqbLpm7vohabkuIrph43mlrDlu7rnq4vnkrDlooMKCumgkOioreWMheWQq++8mgotIOWVn+WLleiFs+acrAotIOWuieijleiFs+acrAotIFJFQURNRSDoiIfoqqrmmI7mlofku7YKCumgkOioreS4jeWMheWQq++8mgotIGAudmVudmAKLSDlronoo53oqJjpjITmqpQKLSDmuKzoqabmiKrlnJYKLSDnlKLnlJ/nmoQgT0NSIOi8uOWHuuaqlAoK5piv5ZCm5YyF5ZCr5qih5Z6L5b+r5Y+W77yaCnswfQoK5piv5ZCm5YyF5ZCrIHdoZWVsaG91c2XvvJoKezF9Cg=="
    $content = $template -f $modelCacheText, $wheelhouseText

    if ($HasBundledModelCache) {
        $content += & $decodeUtf8Base64 "CgrpgJnlgIvmiZPljIXlhaflkKsgYGJ1bmRsZWRfbW9kZWxfY2FjaGVcb2ZmaWNpYWxfbW9kZWxzYOOAggrlronoo53nqIvlvI/mnIPoh6rli5XmiornvLrlsJHnmoTmqKHlnovlv6vlj5bljK/lhaXvvJoKJVVTRVJQUk9GSUxFJVwucGFkZGxleFxvZmZpY2lhbF9tb2RlbHMK"
    } else {
        $content += & $decodeUtf8Base64 "CgrpgJnlgIvmiZPljIXmnKrljIXlkKvmqKHlnovlv6vlj5bjgIIK55uu5qiZ6Zu76IWm56ys5LiA5qyh5L2/55So5pmC77yM5Y+v6IO96ZyA6KaB6YCj57ay5LiL6LyJ5qih5Z6L44CCCg=="
    }

    if ($HasBundledWheelhouse) {
        $wheelhouseExtra = & $decodeUtf8Base64 "CgrpgJnlgIvmiZPljIXlhaflkKsgYGJ1bmRsZWRfd2hlZWxzYOOAggrlronoo53nqIvlvI/mnIPlhYjlmJfoqabkvb/nlKjmnKzmqZ8gd2hlZWzvvIzlho3ogIPmha7otbDntrLot6/kuIvovInjgIIK5bu66K2w55uu5qiZ6Zu76IWm5L2/55So55qEIFB5dGhvbiDniYjmnKzvvJp7MH0K"
        $content += $wheelhouseExtra -f $WheelhousePythonVersion
    } else {
        $content += & $decodeUtf8Base64 "CgrpgJnlgIvmiZPljIXmnKrljIXlkKvmnKzmqZ8gd2hlZWzjgIIK55uu5qiZ6Zu76IWm5LuN54S26ZyA6KaB5b6e57ay6Lev5LiL6LyJIFB5dGhvbiDlpZfku7bjgIIK"
    }

    Set-Content -Path $Path -Value $content -Encoding UTF8
}

try {
    $ProjectRoot = Get-ProjectRoot
    Set-Location $ProjectRoot

    $phaseNames = @("Prepare output", "Copy portable project files", "Write bundle metadata", "Create ZIP archive")
    if ($IncludeTests) {
        $phaseNames += "Copy tests"
    }
    if ($IncludeScreenshots) {
        $phaseNames += "Copy Screenshots"
    }
    if ($IncludeModelCache) {
        $phaseNames += "Copy bundled model cache"
    }
    if ($IncludeWheelhouse) {
        $phaseNames += "Export bundled wheelhouse"
    }
    if (-not $KeepStaging) {
        $phaseNames += "Clean staging"
    }

    $phaseTotal = $phaseNames.Count
    $phaseCounter = 0

    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $variantTags = @()
    if ($IncludeModelCache) {
        $variantTags += "mc"
    }
    if ($IncludeWheelhouse) {
        $variantTags += "wh"
    }
    $variant = if ($variantTags.Count -eq 0) { "lite" } else { $variantTags -join "_" }
    $bundleFolderName = "{0}_{1}_{2}" -f $BundleName, $stamp, $variant

    $ResolvedOutputDir = $OutputDir
    if (-not [System.IO.Path]::IsPathRooted($ResolvedOutputDir)) {
        $ResolvedOutputDir = Join-Path $ProjectRoot $ResolvedOutputDir
    }

    $StagingRoot = Join-Path $ResolvedOutputDir $bundleFolderName
    $ZipPath = Join-Path $ResolvedOutputDir ($bundleFolderName + ".zip")

    if (Test-Path $StagingRoot) {
        Remove-Item $StagingRoot -Recurse -Force
    }

    if (Test-Path $ZipPath) {
        Remove-Item $ZipPath -Force
    }

    Start-BundlePhase -Name "Prepare output" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    New-Item -ItemType Directory -Path $ResolvedOutputDir -Force | Out-Null
    New-Item -ItemType Directory -Path $StagingRoot -Force | Out-Null
    Finish-BundlePhase -Name "Prepare output" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-BundlePhase -Name "Copy portable project files" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    $coreFiles = @(
        "distribution_tools\build_portable_bundle.bat",
        "distribution_tools\build_full_portable_bundle.bat",
        "distribution_tools\build_portable_bundle.ps1",
        "install_and_start.bat",
        "merge_txt_by_serial.cmd",
        "ocr_here.bat",
        "ocr_here_no_recursive.bat",
        "register_shared_ocr_home.cmd",
        "tools\merge_txt_by_serial.ps1",
        "tools\register_shared_ocr_home.ps1",
        "tools\install_paddle_ocr_suite.ps1",
        "tools\install_paddleocr.ps1",
        "tools\run_ocr_launcher.py",
        "tools\start_ocr_launcher.bat",
        "tools\start_ocr_launcher.ps1",
        "README.md",
        "docs\不同版本適合用途對照.txt",
        "docs\問題與處理紀錄.md"
    )

    $coreFilesTotal = [Math]::Max($coreFiles.Count, 1)
    $coreFileIndex = 0
    foreach ($file in $coreFiles) {
        $coreFileIndex++
        Write-SubProgress -Activity "Copy portable project files" -Status $file -Current $coreFileIndex -Total $coreFilesTotal
        Copy-PortableFile -ProjectRoot $ProjectRoot -StagingRoot $StagingRoot -RelativePath $file
    }
    Finish-BundlePhase -Name "Copy portable project files" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    if ($IncludeTests) {
        Start-BundlePhase -Name "Copy tests" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
        Write-Host "Including tests folder." -ForegroundColor Yellow
        Copy-PortableDirectory -ProjectRoot $ProjectRoot -StagingRoot $StagingRoot -RelativePath "tests" -Activity "Copy tests"
        Finish-BundlePhase -Name "Copy tests" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal
    }

    if ($IncludeScreenshots) {
        Start-BundlePhase -Name "Copy Screenshots" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
        Write-Host "Including Screenshots folder." -ForegroundColor Yellow
        Copy-PortableDirectory -ProjectRoot $ProjectRoot -StagingRoot $StagingRoot -RelativePath "Screenshots" -Activity "Copy Screenshots"
        Finish-BundlePhase -Name "Copy Screenshots" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal
    }

    $HasBundledModelCache = $false
    $HasBundledWheelhouse = $false
    $WheelhousePythonVersion = ""
    if ($IncludeModelCache) {
        Start-BundlePhase -Name "Copy bundled model cache" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
        $HasBundledModelCache = Copy-BundledModelCache -ProjectRoot $ProjectRoot -StagingRoot $StagingRoot
        Finish-BundlePhase -Name "Copy bundled model cache" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal
    }

    if ($IncludeWheelhouse) {
        Start-BundlePhase -Name "Export bundled wheelhouse" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
        $HasBundledWheelhouse = Export-BundledWheelhouse -ProjectRoot $ProjectRoot -StagingRoot $StagingRoot
        if ($HasBundledWheelhouse) {
            $WheelhousePythonVersion = (Get-Content -Path (Join-Path $StagingRoot "bundled_wheels\python-version.txt") -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
        }
        Finish-BundlePhase -Name "Export bundled wheelhouse" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal
    }

    Start-BundlePhase -Name "Write bundle metadata" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    New-PortableQuickStart `
        -Path (Join-Path $StagingRoot "PORTABLE_QUICK_START.txt") `
        -HasBundledModelCache:$HasBundledModelCache `
        -HasBundledWheelhouse:$HasBundledWheelhouse `
        -WheelhousePythonVersion $WheelhousePythonVersion

    $bundleInfo = [ordered]@{
        bundle_name = $bundleFolderName
        created_at = (Get-Date).ToString("s")
        include_model_cache = [bool]$HasBundledModelCache
        include_wheelhouse = [bool]$HasBundledWheelhouse
        wheelhouse_python_version = $WheelhousePythonVersion
        include_tests = [bool]$IncludeTests
        include_screenshots = [bool]$IncludeScreenshots
        excluded = @(
            ".venv",
            "__pycache__",
            "install_paddle_ocr_suite.log",
            "generated OCR outputs",
            "temporary PDF render folders"
        )
    }
    $bundleInfo | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $StagingRoot "portable_bundle_manifest.json") -Encoding UTF8
    Finish-BundlePhase -Name "Write bundle metadata" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-BundlePhase -Name "Create ZIP archive" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    Write-SubProgress -Activity "Create ZIP archive" -Status "Compressing staged files" -Current 1 -Total 1
    Compress-Archive -Path $StagingRoot -DestinationPath $ZipPath -CompressionLevel Optimal
    Finish-BundlePhase -Name "Create ZIP archive" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    if (-not $KeepStaging) {
        Start-BundlePhase -Name "Clean staging" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
        Write-SubProgress -Activity "Clean staging" -Status "Removing temporary staging folder" -Current 1 -Total 1
        Remove-Item $StagingRoot -Recurse -Force
        Finish-BundlePhase -Name "Clean staging" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal
    }

    Write-Progress -Id 1 -Activity "Building portable bundle" -Status "Completed" -PercentComplete 100 -CurrentOperation $ZipPath
    Write-Progress -Id 2 -Activity "Building portable bundle" -Completed
    Write-Step "Done"
    Write-Host "Portable bundle created:" -ForegroundColor Green
    Write-Host $ZipPath -ForegroundColor Green
    if ($HasBundledModelCache) {
        Write-Host "Bundled model cache: included" -ForegroundColor Yellow
    } else {
        Write-Host "Bundled model cache: not included" -ForegroundColor Yellow
    }
    if ($HasBundledWheelhouse) {
        Write-Host "Bundled wheelhouse: included (Python $WheelhousePythonVersion)" -ForegroundColor Yellow
    } else {
        Write-Host "Bundled wheelhouse: not included" -ForegroundColor Yellow
    }
    Write-Progress -Id 2 -Activity "Building portable bundle" -Completed
    Write-Progress -Id 1 -Activity "Building portable bundle" -Completed
}
catch {
    Write-Progress -Id 2 -Activity "Building portable bundle" -Completed
    Write-Progress -Id 1 -Activity "Building portable bundle" -Completed
    Write-Host ""
    Write-Host "PORTABLE BUNDLE BUILD FAILED" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
