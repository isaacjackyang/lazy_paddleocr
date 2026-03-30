param(
    [string]$OutputDir = ".\dist_exe",
    [string]$BundleName = "PaddleOCRLauncher",
    [switch]$IncludeModelCache = $false,
    [switch]$KeepBuildArtifacts = $false
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"
$env:PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK = "True"
$env:PYTHONNOUSERSITE = "1"

function Write-Step($Message) {
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Start-ExeBuildPhase {
    param(
        [string]$Name,
        [ref]$PhaseCounter,
        [int]$PhaseTotal
    )

    $PhaseCounter.Value++
    $completedPhases = $PhaseCounter.Value - 1
    $percent = if ($PhaseTotal -le 0) { 0 } else { [int](($completedPhases / [double]$PhaseTotal) * 100) }

    Write-Step $Name
    Write-Progress -Id 1 -Activity "Building one-folder exe" -Status "Step $($PhaseCounter.Value)/${PhaseTotal}: $Name" -PercentComplete $percent -CurrentOperation $Name
}

function Finish-ExeBuildPhase {
    param(
        [string]$Name,
        [int]$PhaseIndex,
        [int]$PhaseTotal
    )

    $percent = if ($PhaseTotal -le 0) { 100 } else { [int](($PhaseIndex / [double]$PhaseTotal) * 100) }
    Write-Progress -Id 1 -Activity "Building one-folder exe" -Status "Completed: $Name" -PercentComplete $percent -CurrentOperation $Name
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
        throw "Cannot build one-folder exe because venv Python was not found: $venvPython"
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

function Ensure-PyInstaller {
    param([string]$PythonExe)

    $showResult = Invoke-NativeProcess -FilePath $PythonExe -Arguments @("-m", "pip", "show", "pyinstaller")
    if ($showResult.ExitCode -eq 0) {
        Write-Host "PyInstaller is already installed." -ForegroundColor Green
        return
    }

    Write-Host "Installing PyInstaller into the project venv..." -ForegroundColor Yellow
    $installResult = Invoke-NativeProcess `
        -FilePath $PythonExe `
        -Arguments @("-m", "pip", "install", "--disable-pip-version-check", "--upgrade", "pyinstaller") `
        -EchoOutput
    if ($installResult.ExitCode -ne 0) {
        throw "Failed to install PyInstaller into the project virtual environment."
    }
}

function Get-PaddleRuntimeMode {
    param([string]$PythonExe)

    $tempPy = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), ".py")
    try {
        Set-Content -Path $tempPy -Encoding ASCII -Value @"
import paddle
print("gpu" if paddle.device.is_compiled_with_cuda() else "cpu")
"@

        $result = Invoke-NativeProcess -FilePath $PythonExe -Arguments @($tempPy)
        if ($result.ExitCode -ne 0) {
            return "unknown"
        }

        $modeLine = $result.StdOut | Select-Object -Last 1
        if (-not $modeLine) {
            return "unknown"
        }

        $mode = $modeLine.Trim()
        if (-not $mode) {
            return "unknown"
        }
        return $mode
    }
    finally {
        Remove-Item $tempPy -Force -ErrorAction SilentlyContinue
    }
}

function Write-QuickStart {
    param(
        [string]$Path,
        [string]$ExeName,
        [bool]$HasBundledModelCache,
        [string]$RuntimeMode
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
    $runtimeModeText = switch ($RuntimeMode.ToLowerInvariant()) {
        "gpu" { "GPU" }
        "cpu" { "CPU" }
        default { $RuntimeMode }
    }

    $template = & $decodeUtf8Base64 "T25lLWZvbGRlciBPQ1Ig5ZWf5YuV5YyFCj09PT09PT09PT09PT09PT09PT09PQoK5Z+36KGM5pa55byP77yaCi0gezB9CgrpgJnlgIvmiZPljIXlhaflrrnljIXlkKvvvJoKLSDlj6/nm7TmjqXln7fooYznmoQgb25lLWZvbGRlciBPQ1Ig5ZWf5YuV5ZmoIEVYRQotIOS+huiHquebruWJjSBgLnZlbnZgIOeahCBQYWRkbGUgLyBQYWRkbGVPQ1IgLyBQYWRkbGVYIOWft+ihjOeSsOWig+aqlOahiAoK5q2k5omT5YyF5om/5o6l55qE5Z+36KGM5qih5byP77yaCi0gezF9CgrmmK/lkKbljIXlkKvmqKHlnovlv6vlj5bvvJoKLSB7Mn0KCuazqOaEj+S6i+mghe+8mgotIOmgkOioreacg+aOg+aPjyBFWEUg5omA5Zyo55qE6LOH5paZ5aS+44CCCi0g5aaC5p6c6LOH5paZ5aS+5YWn5pyJIGBidW5kbGVkX21vZGVsX2NhY2hlYO+8jOWVn+WLleWZqOacg+iHquWLleaKiue8uuWwkeeahOaooeWei+WMr+WFpe+8mgogICVVU0VSUFJPRklMRSVcLnBhZGRsZXhcb2ZmaWNpYWxfbW9kZWxzCi0g5aaC5p6c6YCZ5YCLIEVYRSDmmK/lvp4gR1BVIOeSsOWig+aJk+WMhe+8jOebruaomembu+iFpuS7jemcgOWFt+WCmeebuOWuueeahCBHUFUgLyBDVURBIC8gY3VETk4g55Kw5aKD44CCCi0g5aaC5p6c5L2g5biM5pyb55u45a655oCn5pu06auY77yM5bu66K2w5pS555SoIENQVSDnkrDlooPph43mlrDmiZPljIXjgIIK"
    $content = $template -f $ExeName, $runtimeModeText, $modelCacheText

    Set-Content -Path $Path -Value $content -Encoding UTF8
}

try {
    $projectRoot = Get-ProjectRoot
    Set-Location $projectRoot

    $phaseNames = @(
        "Prepare output",
        "Ensure PyInstaller",
        "Build one-folder exe",
        "Add supporting files"
    )
    if (-not $KeepBuildArtifacts) {
        $phaseNames += "Clean build cache"
    }
    $phaseTotal = $phaseNames.Count
    $phaseCounter = 0

    $resolvedOutputDir = $OutputDir
    if (-not [System.IO.Path]::IsPathRooted($resolvedOutputDir)) {
        $resolvedOutputDir = Join-Path $projectRoot $resolvedOutputDir
    }

    $venvPython = Get-VenvPython -ProjectRoot $projectRoot
    $runtimeMode = Get-PaddleRuntimeMode -PythonExe $venvPython

    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $variant = if ($IncludeModelCache) { "with_models" } else { "lite" }
    $bundleFolderName = "{0}_{1}_{2}" -f $BundleName, $stamp, $variant
    $bundlePath = Join-Path $resolvedOutputDir $bundleFolderName
    $workPath = Join-Path $projectRoot ".pyinstaller_build\$bundleFolderName"
    $specPath = Join-Path $projectRoot "distribution_tools\ocr_launcher_onefolder.spec"

    Start-ExeBuildPhase -Name "Prepare output" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    New-Item -ItemType Directory -Path $resolvedOutputDir -Force | Out-Null

    if (Test-Path $bundlePath) {
        Remove-Item $bundlePath -Recurse -Force
    }
    if (Test-Path $workPath) {
        Remove-Item $workPath -Recurse -Force
    }
    Finish-ExeBuildPhase -Name "Prepare output" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-ExeBuildPhase -Name "Ensure PyInstaller" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    Ensure-PyInstaller -PythonExe $venvPython
    Finish-ExeBuildPhase -Name "Ensure PyInstaller" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-ExeBuildPhase -Name "Build one-folder exe" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    $env:PADDLE_OCR_PROJECT_ROOT = $projectRoot
    $env:PADDLE_OCR_BUNDLE_NAME = $bundleFolderName
    $env:PADDLE_OCR_INCLUDE_MODEL_CACHE = if ($IncludeModelCache) { "1" } else { "0" }

    $buildResult = Invoke-NativeProcess `
        -FilePath $venvPython `
        -Arguments @("-m", "PyInstaller", "--noconfirm", "--clean", "--distpath", $resolvedOutputDir, "--workpath", $workPath, $specPath) `
        -EchoOutput
    if ($buildResult.ExitCode -ne 0) {
        throw "PyInstaller build failed."
    }

    if (-not (Test-Path $bundlePath)) {
        throw "Expected one-folder bundle was not created: $bundlePath"
    }
    Finish-ExeBuildPhase -Name "Build one-folder exe" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-ExeBuildPhase -Name "Add supporting files" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    Copy-Item -Path (Join-Path $projectRoot "README.md") -Destination (Join-Path $bundlePath "README.md") -Force
    $notePath = Join-Path $projectRoot "docs\不同版本適合用途對照.txt"
    if (Test-Path $notePath) {
        Copy-Item -Path $notePath -Destination (Join-Path $bundlePath "不同版本適合用途對照.txt") -Force
    }

    Write-QuickStart `
        -Path (Join-Path $bundlePath "ONEFOLDER_QUICK_START.txt") `
        -ExeName ("{0}.exe" -f $bundleFolderName) `
        -HasBundledModelCache:$IncludeModelCache `
        -RuntimeMode $runtimeMode
    Finish-ExeBuildPhase -Name "Add supporting files" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    if (-not $KeepBuildArtifacts -and (Test-Path $workPath)) {
        Start-ExeBuildPhase -Name "Clean build cache" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
        Remove-Item $workPath -Recurse -Force
        Finish-ExeBuildPhase -Name "Clean build cache" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal
    }

    Write-Progress -Id 1 -Activity "Building one-folder exe" -Status "Completed" -PercentComplete 100 -CurrentOperation $bundlePath
    Write-Step "Done"
    Write-Host "One-folder exe bundle created:" -ForegroundColor Green
    Write-Host $bundlePath -ForegroundColor Green
    Write-Host "Runtime mode: $runtimeMode" -ForegroundColor Yellow
    if ($IncludeModelCache) {
        Write-Host "Bundled model cache: included" -ForegroundColor Yellow
    } else {
        Write-Host "Bundled model cache: not included" -ForegroundColor Yellow
    }
    Write-Progress -Id 1 -Activity "Building one-folder exe" -Completed
}
catch {
    Write-Progress -Id 1 -Activity "Building one-folder exe" -Completed
    Write-Host ""
    Write-Host "ONE-FOLDER EXE BUILD FAILED" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
