$ErrorActionPreference = "Stop"

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

$ProjectRoot = Get-ProjectRoot
$OutputRoot = Join-Path $ProjectRoot "output"
$PaddleCPUVersion = "3.3.0"
$PaddleGPUVersion = "3.2.2"
$PaddleOCRVersion = "3.7.0"
$PaddleXVersion = "3.7.0"
$GpuCudaChannel = "cu118"  # Change to "cu126" if your GPU environment needs it.

Set-Location $ProjectRoot
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        $commandText = @($FilePath) + $Arguments
        throw "Command failed: $($commandText -join ' ')"
    }
}

function Test-PythonVersion {
    param([string]$Version)

    try {
        & py "-$Version" -c "import sys; print(sys.version)" *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Get-PythonVersion {
    foreach ($version in @("3.10", "3.11", "3.12", "3.9", "3.8")) {
        if (Test-PythonVersion $version) {
            return $version
        }
    }

    throw "Could not find Python 3.8 to 3.12. Install Python first and make sure the py launcher is available."
}

function Test-GpuRuntime {
    $nvidiaSmi = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
    if (-not $nvidiaSmi) {
        return $false
    }

    try {
        & $nvidiaSmi.Source *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Install-PaddleEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PythonVersion,

        [Parameter(Mandatory = $true)]
        [string]$EnvName,

        [Parameter(Mandatory = $true)]
        [string]$PaddlePackage,

        [Parameter(Mandatory = $true)]
        [string]$PaddleVersion,

        [Parameter(Mandatory = $true)]
        [string]$PackageIndexUrl,

        [Parameter(Mandatory = $true)]
        [string]$Device,

        [Parameter(Mandatory = $true)]
        [string]$OutputName,

        [switch]$SkipPipelineTests
    )

    $envPath = Join-Path $ProjectRoot $EnvName
    $pythonExe = Join-Path $envPath "Scripts\python.exe"
    $paddlexExe = Join-Path $envPath "Scripts\paddlex.exe"
    $paddleocrExe = Join-Path $envPath "Scripts\paddleocr.exe"
    $outputBase = Join-Path $OutputRoot $OutputName
    $ocrOutput = Join-Path $outputBase "ocr"
    $structureOutput = Join-Path $outputBase "pp_structure_v3"

    if (-not (Test-Path $pythonExe)) {
        Write-Host "[$OutputName] Creating virtual environment: $EnvName" -ForegroundColor Cyan
        Invoke-NativeCommand py "-$PythonVersion" "-m" "venv" $envPath
    } else {
        Write-Host "[$OutputName] Reusing existing virtual environment: $EnvName" -ForegroundColor Yellow
    }

    Write-Host "[$OutputName] Upgrading pip, setuptools, and wheel..." -ForegroundColor Cyan
    Invoke-NativeCommand $pythonExe "-m" "pip" "install" "--upgrade" "pip" "setuptools" "wheel"

    Write-Host "[$OutputName] Installing $PaddlePackage $PaddleVersion ..." -ForegroundColor Cyan
    Invoke-NativeCommand $pythonExe "-m" "pip" "install" "$PaddlePackage==$PaddleVersion" "-i" $PackageIndexUrl

    Write-Host "[$OutputName] Installing PaddleOCR 3.7.0, PaddleX OCR dependencies, and ONNX Runtime..." -ForegroundColor Cyan
    Invoke-NativeCommand $pythonExe "-m" "pip" "install" "--upgrade" "paddleocr==$PaddleOCRVersion" "paddlex[ocr]==$PaddleXVersion" "onnxruntime" "pillow" "pymupdf"

    if (-not (Test-Path $paddlexExe)) {
        throw "paddlex.exe was not found after installation: $paddlexExe"
    }

    if (-not (Test-Path $paddleocrExe)) {
        throw "paddleocr.exe was not found after installation: $paddleocrExe"
    }

    Write-Host "[$OutputName] Version check" -ForegroundColor Cyan
    Invoke-NativeCommand $pythonExe "-c" 'import paddle; print("paddle =", paddle.__version__)'
    Invoke-NativeCommand $pythonExe "-c" 'import paddleocr, onnxruntime; print("paddleocr =", getattr(paddleocr, "__version__", "unknown")); print("onnxruntime =", onnxruntime.__version__)'
    Invoke-NativeCommand $pythonExe "-m" "pip" "show" "paddlex"

    if ($SkipPipelineTests) {
        Write-Warning "[$OutputName] GPU runtime was not detected. Installation finished, but GPU pipeline tests were skipped."
        return
    }

    New-Item -ItemType Directory -Force -Path $ocrOutput | Out-Null
    New-Item -ItemType Directory -Force -Path $structureOutput | Out-Null

    Write-Host "[$OutputName] Testing PP-OCRv6 via the OCR pipeline..." -ForegroundColor Cyan
    $ocrArgs = @(
        "ocr",
        "-i", "https://paddle-model-ecology.bj.bcebos.com/paddlex/imgs/demo_image/general_ocr_002.png",
        "--text_detection_model_name", "PP-OCRv6_medium_det",
        "--text_recognition_model_name", "PP-OCRv6_medium_rec",
        "--engine", "paddle_static",
        "--use_doc_orientation_classify", "False",
        "--use_doc_unwarping", "False",
        "--use_textline_orientation", "False",
        "--save_path", $ocrOutput,
        "--device", $Device
    )
    Invoke-NativeCommand $paddleocrExe @ocrArgs

    Write-Host "[$OutputName] Testing PP-StructureV3..." -ForegroundColor Cyan
    $structureArgs = @(
        "--pipeline", "PP-StructureV3",
        "--input", "https://paddle-model-ecology.bj.bcebos.com/paddlex/imgs/demo_image/pp_structure_v3_demo.png",
        "--engine", "paddle_static",
        "--use_doc_orientation_classify", "False",
        "--use_doc_unwarping", "False",
        "--use_textline_orientation", "False",
        "--save_path", $structureOutput,
        "--device", $Device
    )
    Invoke-NativeCommand $paddlexExe @structureArgs
}

$pythonVersion = Get-PythonVersion
$gpuRuntimeAvailable = Test-GpuRuntime

Write-Host "Using Python $pythonVersion" -ForegroundColor Green
Write-Host "Project root: $ProjectRoot" -ForegroundColor Green
Write-Host "GPU runtime detected: $gpuRuntimeAvailable" -ForegroundColor Green

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

Install-PaddleEnvironment `
    -PythonVersion $pythonVersion `
    -EnvName ".venv-cpu" `
    -PaddlePackage "paddlepaddle" `
    -PaddleVersion $PaddleCPUVersion `
    -PackageIndexUrl "https://www.paddlepaddle.org.cn/packages/stable/cpu/" `
    -Device "cpu" `
    -OutputName "cpu"

Install-PaddleEnvironment `
    -PythonVersion $pythonVersion `
    -EnvName ".venv-gpu" `
    -PaddlePackage "paddlepaddle-gpu" `
    -PaddleVersion $PaddleGPUVersion `
    -PackageIndexUrl "https://www.paddlepaddle.org.cn/packages/stable/$GpuCudaChannel/" `
    -Device "gpu:0" `
    -OutputName "gpu" `
    -SkipPipelineTests:(-not $gpuRuntimeAvailable)

Write-Host "" 
Write-Host "Install completed." -ForegroundColor Green
Write-Host "CPU environment: .venv-cpu" -ForegroundColor Green
Write-Host "GPU environment: .venv-gpu (CUDA channel: $GpuCudaChannel)" -ForegroundColor Green
Write-Host "CPU OCR output: .\output\cpu\ocr" -ForegroundColor Green
Write-Host "CPU PP-StructureV3 output: .\output\cpu\pp_structure_v3" -ForegroundColor Green
Write-Host "GPU OCR output: .\output\gpu\ocr" -ForegroundColor Green
Write-Host "GPU PP-StructureV3 output: .\output\gpu\pp_structure_v3" -ForegroundColor Green
