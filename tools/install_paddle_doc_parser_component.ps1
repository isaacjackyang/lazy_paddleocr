param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("ppstructurev3", "paddleocr-vl-1.5", "paddleocr-vl")]
    [string]$Target,

    [ValidateSet("cpu", "gpu")]
    [string]$Mode = "gpu",

    [ValidateSet("cu118", "cu126", "cu129", "cu130")]
    [string]$Cuda = "cu129",

    [string]$VenvDir = ".venv",

    [int]$PipInstallTimeoutSeconds = 600
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"
$env:PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK = "True"
$env:PYTHONNOUSERSITE = "1"

function Write-Step($msg) {
    Write-Host ""
    Write-Host "=== $msg ===" -ForegroundColor Cyan
}

function Start-InstallPhase {
    param(
        [string]$Name,
        [ref]$PhaseCounter,
        [int]$PhaseTotal
    )

    $PhaseCounter.Value++
    $completedPhases = $PhaseCounter.Value - 1
    $percent = if ($PhaseTotal -le 0) { 0 } else { [int](($completedPhases / [double]$PhaseTotal) * 100) }

    Write-Step $Name
    Write-Progress -Id 1 -Activity "Installing PaddleOCR component" -Status "Step $($PhaseCounter.Value)/${PhaseTotal}: $Name" -PercentComplete $percent -CurrentOperation $Name
}

function Finish-InstallPhase {
    param(
        [string]$Name,
        [int]$PhaseIndex,
        [int]$PhaseTotal
    )

    $percent = if ($PhaseTotal -le 0) { 100 } else { [int](($PhaseIndex / [double]$PhaseTotal) * 100) }
    Write-Progress -Id 1 -Activity "Installing PaddleOCR component" -Status "Completed: $Name" -PercentComplete $percent -CurrentOperation $Name
}

function Pause-And-Exit {
    param([int]$Code = 0)
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit $Code
}

function Get-TargetLabel {
    switch ($Target) {
        "ppstructurev3" { return "PP-StructureV3" }
        "paddleocr-vl-1.5" { return "PaddleOCR-VL-1.5" }
        "paddleocr-vl" { return "PaddleOCR-VL" }
        default { return $Target }
    }
}

function Test-WorkspaceRoot {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return $false
    }

    $runnerScript = Join-Path $Path "tools\run_ocr_launcher.py"
    $registerScript = Join-Path $Path "tools\register_shared_ocr_home.ps1"
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

function Test-PythonCandidate {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $probe = 'import sys, struct; print(sys.executable); print(f"{sys.version_info.major}.{sys.version_info.minor}"); print(struct.calcsize("P") * 8)'
    $result = Invoke-NativeProcess -FilePath $FilePath -Arguments ($Arguments + @("-c", $probe))
    if ($result.ExitCode -ne 0 -or $result.StdOut.Count -lt 3) {
        return $null
    }

    $bits = 0
    [void][int]::TryParse($result.StdOut[2].Trim(), [ref]$bits)
    $version = $result.StdOut[1].Trim()
    if ($bits -ne 64) {
        return $null
    }
    if ($version -notin @("3.13", "3.12", "3.11", "3.10", "3.9")) {
        return $null
    }

    return [pscustomobject]@{
        FilePath   = $FilePath
        Arguments  = $Arguments
        Executable = $result.StdOut[0].Trim()
        Version    = $version
    }
}

function Find-SupportedPython {
    $pyCmd = Get-Command py -ErrorAction SilentlyContinue
    if ($pyCmd) {
        foreach ($version in @("3.13", "3.12", "3.11", "3.10", "3.9")) {
            $candidate = Test-PythonCandidate -FilePath $pyCmd.Source -Arguments @("-$version")
            if ($candidate) {
                return $candidate
            }
        }
    }

    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCmd) {
        $candidate = Test-PythonCandidate -FilePath $pythonCmd.Source -Arguments @()
        if ($candidate) {
            return $candidate
        }
    }

    throw "No supported 64-bit Python (3.9-3.13) was found. Install Python first, then rerun this script."
}

function Ensure-VenvPython {
    param([string]$ProjectRoot)

    $venvPath = Join-Path $ProjectRoot $VenvDir
    $venvPython = Join-Path $venvPath "Scripts\python.exe"
    if (Test-Path $venvPython) {
        Write-Host "Using existing virtual environment: $venvPython" -ForegroundColor Green
        return $venvPython
    }

    $systemPython = Find-SupportedPython
    Write-Host "Creating virtual environment with Python $($systemPython.Version)..." -ForegroundColor Yellow

    $createArgs = @()
    if ($systemPython.Arguments) {
        $createArgs += $systemPython.Arguments
    }
    $createArgs += @("-m", "venv", $venvPath)
    $createResult = Invoke-NativeProcess -FilePath $systemPython.FilePath -Arguments $createArgs -EchoOutput
    if ($createResult.ExitCode -ne 0 -or -not (Test-Path $venvPython)) {
        throw "Failed to create virtual environment: $venvPath"
    }

    return $venvPython
}

function Invoke-PipInstall {
    param(
        [string]$PythonExe,
        [string[]]$Packages,
        [switch]$Upgrade,
        [string]$IndexUrl = ""
    )

    $args = @(
        "-m", "pip", "install",
        "--disable-pip-version-check",
        "--progress-bar", "off",
        "--timeout", "60",
        "--retries", "1"
    )
    if ($Upgrade) {
        $args += "--upgrade"
    }
    if (-not [string]::IsNullOrWhiteSpace($IndexUrl)) {
        $args += @("-i", $IndexUrl)
    }
    $args += $Packages

    $result = Invoke-NativeProcess -FilePath $PythonExe -Arguments $args -EchoOutput
    if ($result.ExitCode -ne 0) {
        throw "pip install failed: $($Packages -join ', ')"
    }
}

function Install-PaddleCPU {
    param([string]$PythonExe)

    Write-Host "Installing PaddlePaddle CPU..." -ForegroundColor Yellow
    Invoke-PipInstall -PythonExe $PythonExe -Packages @("paddlepaddle==3.3.0") -IndexUrl "https://www.paddlepaddle.org.cn/packages/stable/cpu/"
}

function Install-PaddleGPU {
    param(
        [string]$PythonExe,
        [string]$CudaVersion
    )

    Write-Host "Installing PaddlePaddle GPU from index: $CudaVersion" -ForegroundColor Yellow
    Invoke-PipInstall -PythonExe $PythonExe -Packages @("paddlepaddle-gpu==3.3.1") -IndexUrl "https://www.paddlepaddle.org.cn/packages/stable/$CudaVersion/"
}

function Test-PythonPackageVersion {
    param(
        [string]$PythonExe,
        [string]$PackageName,
        [string]$ExpectedVersion
    )

    $result = Invoke-NativeProcess -FilePath $PythonExe -Arguments @("-m", "pip", "show", $PackageName)
    if ($result.ExitCode -ne 0) {
        return $false
    }

    foreach ($line in $result.StdOut) {
        if ($line -like "Version:*") {
            return $line.Substring("Version:".Length).Trim() -eq $ExpectedVersion
        }
    }

    return $false
}

function Ensure-PaddleInstalled {
    param([string]$PythonExe)

    if ($Mode -eq "gpu") {
        if (Test-PythonPackageVersion -PythonExe $PythonExe -PackageName "paddlepaddle-gpu" -ExpectedVersion "3.3.1") {
            Write-Host "Reusable GPU PaddlePaddle installation detected. Skipping reinstall." -ForegroundColor Green
            return "gpu"
        }

        try {
            Install-PaddleGPU -PythonExe $PythonExe -CudaVersion $Cuda
            return "gpu"
        }
        catch {
            Write-Host "GPU installation failed. Falling back to CPU..." -ForegroundColor Yellow
            Install-PaddleCPU -PythonExe $PythonExe
            return "cpu"
        }
    }

    if (Test-PythonPackageVersion -PythonExe $PythonExe -PackageName "paddlepaddle" -ExpectedVersion "3.3.0") {
        Write-Host "Reusable CPU PaddlePaddle installation detected. Skipping reinstall." -ForegroundColor Green
        return "cpu"
    }

    Install-PaddleCPU -PythonExe $PythonExe
    return "cpu"
}

function Install-ComponentDependencies {
    param([string]$PythonExe)

    Write-Host "Installing PaddleOCR doc-parser dependencies..." -ForegroundColor Yellow
    Invoke-PipInstall -PythonExe $PythonExe -Packages @("paddleocr[doc-parser]", "pillow", "pymupdf") -Upgrade
}

function Invoke-PythonSnippet {
    param(
        [string]$PythonExe,
        [string]$Code,
        [string]$FailureMessage
    )

    $tempPy = Join-Path $env:TEMP ("verify_" + [guid]::NewGuid().ToString("N") + ".py")
    Set-Content -Path $tempPy -Value $Code -Encoding UTF8
    try {
        $result = Invoke-NativeProcess -FilePath $PythonExe -Arguments @($tempPy) -EchoOutput
        if ($result.ExitCode -ne 0) {
            throw $FailureMessage
        }
    }
    finally {
        Remove-Item $tempPy -Force -ErrorAction SilentlyContinue
    }
}

function Verify-TargetInstallation {
    param([string]$PythonExe)

    switch ($Target) {
        "ppstructurev3" {
            $code = @'
import os
os.environ["PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK"] = "True"
os.environ["CUDA_VISIBLE_DEVICES"] = ""
import paddle
paddle.device.set_device("cpu")
from paddleocr import PPStructureV3
PPStructureV3(device="cpu", use_doc_orientation_classify=False, use_doc_unwarping=False)
print("PPSTRUCTUREV3_READY=OK")
'@
            Invoke-PythonSnippet -PythonExe $PythonExe -Code $code -FailureMessage "Failed to verify PP-StructureV3."
            return
        }
        "paddleocr-vl-1.5" {
            $code = @'
import inspect
from paddleocr import PaddleOCRVL
sig = inspect.signature(PaddleOCRVL)
sig.bind_partial(pipeline_version="v1.5")
assert sig.parameters["pipeline_version"].default == "v1.5"
print("PADDLEOCR_VL_1_5_IMPORT_OK")
'@
            Invoke-PythonSnippet -PythonExe $PythonExe -Code $code -FailureMessage "Failed to verify PaddleOCR-VL-1.5 import."
            return
        }
        "paddleocr-vl" {
            $code = @'
import inspect
from paddleocr import PaddleOCRVL
sig = inspect.signature(PaddleOCRVL)
sig.bind_partial(pipeline_version="v1")
print("PADDLEOCR_VL_V1_IMPORT_OK")
'@
            Invoke-PythonSnippet -PythonExe $PythonExe -Code $code -FailureMessage "Failed to verify PaddleOCR-VL import."
            return
        }
    }
}

try {
    $targetLabel = Get-TargetLabel
    $phaseTotal = 6
    $phaseCounter = 0

    Start-InstallPhase -Name "Resolve project root" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    $projectRoot = Get-ProjectRoot
    Set-Location $projectRoot
    Write-Host $projectRoot
    Finish-InstallPhase -Name "Resolve project root" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-InstallPhase -Name "Prepare virtual environment" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    $venvPython = Ensure-VenvPython -ProjectRoot $projectRoot
    Write-Host "Target            : $targetLabel"
    Write-Host "Python            : $venvPython"
    Write-Host "Mode              : $Mode"
    Write-Host "CUDA              : $Cuda"
    Finish-InstallPhase -Name "Prepare virtual environment" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-InstallPhase -Name "Upgrade pip tools" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    Invoke-PipInstall -PythonExe $venvPython -Packages @("pip", "setuptools", "wheel") -Upgrade
    Finish-InstallPhase -Name "Upgrade pip tools" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-InstallPhase -Name "Install PaddlePaddle" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    $finalMode = Ensure-PaddleInstalled -PythonExe $venvPython
    Write-Host "Final Paddle mode : $finalMode" -ForegroundColor Green
    Finish-InstallPhase -Name "Install PaddlePaddle" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-InstallPhase -Name "Install component dependencies" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    Install-ComponentDependencies -PythonExe $venvPython
    Finish-InstallPhase -Name "Install component dependencies" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-InstallPhase -Name "Verify installation" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    Verify-TargetInstallation -PythonExe $venvPython
    Finish-InstallPhase -Name "Verify installation" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Write-Progress -Id 1 -Activity "Installing PaddleOCR component" -Completed
    Write-Step "Done"
    Write-Host "$targetLabel installation completed successfully." -ForegroundColor Green
    if ($Target -like "paddleocr-vl*") {
        Write-Host "Note: PaddleOCR-VL model weights are usually downloaded on the first real inference run." -ForegroundColor Yellow
        Write-Host "This script prepares the client-side doc-parser environment. If you later need a GenAI server backend (vLLM / SGLang), install that backend separately." -ForegroundColor Yellow
    }
    Pause-And-Exit 0
}
catch {
    Write-Progress -Id 1 -Activity "Installing PaddleOCR component" -Completed
    Write-Host ""
    Write-Host "INSTALL FAILED" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    if ($_.ScriptStackTrace) {
        Write-Host ""
        Write-Host "Script stack trace:" -ForegroundColor Yellow
        Write-Host $_.ScriptStackTrace
    }

    Pause-And-Exit 1
}
