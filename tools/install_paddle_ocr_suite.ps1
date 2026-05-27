param(
    [ValidateSet("cpu", "gpu")]
    [string]$Mode = "gpu",

    [ValidateSet("cu118", "cu126", "cu129", "cu130")]
    [string]$Cuda = "cu118",

    [string]$VenvDir = ".venv",

    [switch]$StrictVenvPythonMatch = $false,

    [switch]$RequireGpu = $false,

    [int]$PipInstallTimeoutSeconds = 600
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}
$env:PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK = "True"
$env:PYTHONNOUSERSITE = "1"
$script:BundledWheelhouse = $null
$script:BundledWheelhousePythonVersion = $null
$script:InstallerScriptPath = $PSCommandPath
$script:ProjectRootForManual = $null
$script:SystemPythonForManual = $null
$script:PreferredPythonVersionForManual = $null
$script:RequireGpu = [bool]$RequireGpu
$script:InstallStageStatus = [ordered]@{
    python = $false
    venv = $false
    packaging = $false
    paddle = $false
    ocr = $false
    structure = $false
    verify = $false
}

if ($RequireGpu -and $Mode -ne "gpu") {
    throw "-RequireGpu requires -Mode gpu."
}

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
    Write-Progress -Id 1 -Activity "Installing OCR environment" -Status "Step $($PhaseCounter.Value)/${PhaseTotal}: $Name" -PercentComplete $percent -CurrentOperation $Name
}

function Finish-InstallPhase {
    param(
        [string]$Name,
        [int]$PhaseIndex,
        [int]$PhaseTotal
    )

    Write-Progress -Id 2 -Activity $Name -Completed
    $percent = if ($PhaseTotal -le 0) { 100 } else { [int](($PhaseIndex / [double]$PhaseTotal) * 100) }
    Write-Progress -Id 1 -Activity "Installing OCR environment" -Status "Completed: $Name" -PercentComplete $percent -CurrentOperation $Name
}

function Write-InstallSubProgress {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete = 0
    )

    Write-Progress -Id 2 -ParentId 1 -Activity $Activity -Status $Status -PercentComplete $PercentComplete
}

function Quote-PSLiteral {
    param([string]$Value)

    if ($null -eq $Value) {
        return "''"
    }

    return "'" + $Value.Replace("'", "''") + "'"
}

function Wrap-ManualCommand {
    param([string]$InnerCommand)

    return "& { `$env:PYTHONNOUSERSITE='1'; `$env:PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK='True'; $InnerCommand }"
}

function Get-ManualProjectRoot {
    if ($env:PADDLE_OCR_ORIGINAL_ROOT) {
        return $env:PADDLE_OCR_ORIGINAL_ROOT
    }

    if ($script:ProjectRootForManual) {
        return $script:ProjectRootForManual
    }

    return (Get-Location).Path
}

function Get-ManualVenvPath {
    return (Join-Path (Get-ManualProjectRoot) $VenvDir)
}

function Get-ManualVenvPython {
    return (Join-Path (Get-ManualVenvPath) "Scripts\python.exe")
}

function Get-ManualWheelhouseRoot {
    foreach ($folderName in @("wheel", "bundled_wheels")) {
        $wheelhouseRoot = Join-Path (Get-ManualProjectRoot) $folderName
        if (Test-Path $wheelhouseRoot) {
            return $wheelhouseRoot
        }
    }

    return $null
}

function Get-SharedLauncherConfigDir {
    if ($env:LOCALAPPDATA) {
        return (Join-Path $env:LOCALAPPDATA "PaddleOCRLauncher")
    }

    return (Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "PaddleOCRLauncher")
}

function Get-SharedLauncherConfigPath {
    return (Join-Path (Get-SharedLauncherConfigDir) "shared_install_root.txt")
}

function Register-SharedLauncherEnvironment {
    param([string]$InstallRoot)

    $env:PADDLE_OCR_HOME = $InstallRoot
    [Environment]::SetEnvironmentVariable("PADDLE_OCR_HOME", $InstallRoot, "User")

    $registryPath = "HKCU:\Software\PaddleOCRLauncher"
    New-Item -Path $registryPath -Force | Out-Null
    Set-ItemProperty -Path $registryPath -Name "InstallRoot" -Value $InstallRoot
}

function Register-SharedLauncherRoot {
    param([string]$ProjectRoot)

    $resolvedRoot = (Resolve-Path $ProjectRoot).Path
    $configDir = Get-SharedLauncherConfigDir
    $configPath = Get-SharedLauncherConfigPath
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    Set-Content -Path $configPath -Value $resolvedRoot -Encoding ASCII
    Register-SharedLauncherEnvironment -InstallRoot $resolvedRoot
    return $configPath
}

function New-PipManualCommand {
    param(
        [string]$PythonExe,
        [string[]]$Packages,
        [switch]$Upgrade,
        [switch]$ForceReinstall,
        [string]$IndexUrl = ""
    )

    $parts = @(
        "&", (Quote-PSLiteral $PythonExe),
        "-m", "pip", "install",
        "--disable-pip-version-check",
        "--progress-bar", "off",
        "--timeout", "60",
        "--retries", "1"
    )

    if ($Upgrade) {
        $parts += "--upgrade"
    }

    if ($ForceReinstall) {
        $parts += "--force-reinstall"
    }

    $wheelhouseRoot = Get-ManualWheelhouseRoot
    if ($wheelhouseRoot) {
        $parts += @("--no-index", "--find-links", (Quote-PSLiteral $wheelhouseRoot))
    } elseif (-not [string]::IsNullOrWhiteSpace($IndexUrl)) {
        $parts += @("-i", (Quote-PSLiteral $IndexUrl))
    }

    foreach ($package in $Packages) {
        $parts += (Quote-PSLiteral $package)
    }

    return (Wrap-ManualCommand -InnerCommand ($parts -join " "))
}

function Add-ManualRecoveryItem {
    param(
        [System.Collections.Generic.List[object]]$Items,
        [string]$Title,
        [string]$Command
    )

    [void]$Items.Add([pscustomobject]@{
        Title = $Title
        Command = $Command
    })
}

function Get-ManualRecoveryItems {
    param([switch]$StructureOnly)

    $items = New-Object 'System.Collections.Generic.List[object]'
    $projectRoot = Get-ManualProjectRoot
    $venvPath = Get-ManualVenvPath
    $venvPython = Get-ManualVenvPython
    $preferredPythonVersion = if ($script:PreferredPythonVersionForManual) { $script:PreferredPythonVersionForManual } else { "3.13" }
    $systemPython = $script:SystemPythonForManual

    if (-not $systemPython) {
        $systemPython = "<supported-python.exe>"
    }

    Add-ManualRecoveryItem -Items $items -Title "Open the project folder" -Command ("Set-Location " + (Quote-PSLiteral $projectRoot))

    if ($StructureOnly) {
        Add-ManualRecoveryItem -Items $items -Title "Install PP-StructureV3 dependencies" -Command (New-PipManualCommand -PythonExe $venvPython -Packages @("paddlex[ocr]==3.4.2"))
        Add-ManualRecoveryItem -Items $items -Title "Verify PP-StructureV3" -Command (Wrap-ManualCommand -InnerCommand ("& " + (Quote-PSLiteral $venvPython) + " -c " + (Quote-PSLiteral 'import paddle; from paddleocr import PPStructureV3; PPStructureV3(); print("PPSTRUCTUREV3_READY=OK")')))
        return $items
    }

    if (-not $script:InstallStageStatus.python) {
        Add-ManualRecoveryItem -Items $items -Title "Install a supported Python version" -Command ("winget install -e --id Python.Python.$preferredPythonVersion --accept-source-agreements --accept-package-agreements")
    }

    if (-not $script:InstallStageStatus.venv) {
        Add-ManualRecoveryItem -Items $items -Title "Create the virtual environment" -Command (Wrap-ManualCommand -InnerCommand ("& " + (Quote-PSLiteral $systemPython) + " -m venv " + (Quote-PSLiteral $venvPath)))
    }

    if (-not $script:InstallStageStatus.packaging) {
        Add-ManualRecoveryItem -Items $items -Title "Upgrade pip / setuptools / wheel" -Command (New-PipManualCommand -PythonExe $venvPython -Packages @("pip", "setuptools", "wheel") -Upgrade)
    }

    if (-not $script:InstallStageStatus.paddle) {
        if ($Mode -eq "gpu") {
            Add-ManualRecoveryItem -Items $items -Title "Install PaddlePaddle GPU" -Command (New-PipManualCommand -PythonExe $venvPython -Packages @("paddlepaddle-gpu==3.2.2") -ForceReinstall:$false -IndexUrl "https://www.paddlepaddle.org.cn/packages/stable/$Cuda/")
            if (-not $script:RequireGpu) {
                Add-ManualRecoveryItem -Items $items -Title "If GPU still fails, install PaddlePaddle CPU fallback" -Command (New-PipManualCommand -PythonExe $venvPython -Packages @("paddlepaddle==3.3.0") -IndexUrl "https://www.paddlepaddle.org.cn/packages/stable/cpu/")
            }
        } else {
            Add-ManualRecoveryItem -Items $items -Title "Install PaddlePaddle CPU" -Command (New-PipManualCommand -PythonExe $venvPython -Packages @("paddlepaddle==3.3.0") -IndexUrl "https://www.paddlepaddle.org.cn/packages/stable/cpu/")
        }
    }

    if (-not $script:InstallStageStatus.ocr) {
        Add-ManualRecoveryItem -Items $items -Title "Install PaddleOCR / Pillow / PyMuPDF" -Command (New-PipManualCommand -PythonExe $venvPython -Packages @("paddleocr", "pillow", "pymupdf") -Upgrade)
    }

    if (-not $script:InstallStageStatus.structure) {
        Add-ManualRecoveryItem -Items $items -Title "Install PP-StructureV3 dependencies" -Command (New-PipManualCommand -PythonExe $venvPython -Packages @("paddlex[ocr]==3.4.2"))
    }

    if (-not $script:InstallStageStatus.verify) {
        if ($script:RequireGpu) {
            $verifyCommand = 'import fitz, paddle, paddleocr; paddle.device.set_device("gpu"); from paddleocr import PaddleOCR, PPStructureV3; PaddleOCR(device="gpu", use_doc_orientation_classify=False, use_doc_unwarping=False, use_textline_orientation=False, text_rec_score_thresh=0.0); PPStructureV3(device="gpu"); paddle.utils.run_check(); print("INSTALL_VERIFY_OK")'
        } else {
            $verifyCommand = 'import fitz, paddle, paddleocr; from paddleocr import PaddleOCR, PPStructureV3; PaddleOCR(use_doc_orientation_classify=False, use_doc_unwarping=False, use_textline_orientation=False, text_rec_score_thresh=0.0); PPStructureV3(); paddle.utils.run_check(); print("INSTALL_VERIFY_OK")'
        }
        Add-ManualRecoveryItem -Items $items -Title "Verify the installed environment" -Command (Wrap-ManualCommand -InnerCommand ("& " + (Quote-PSLiteral $venvPython) + " -c " + (Quote-PSLiteral $verifyCommand)))
    }

    return $items
}

function Write-ManualRecoveryChecklist {
    param(
        [string]$Reason = "",
        [switch]$StructureOnly
    )

    $items = Get-ManualRecoveryItems -StructureOnly:$StructureOnly
    if ($items.Count -eq 0) {
        return
    }

    $projectRoot = Get-ManualProjectRoot
    $outputPath = Join-Path $projectRoot "tools\install_manual_recovery.ps1"
    $fileLines = @(
        "# PaddleOCR manual recovery commands",
        "# Generated by install_paddle_ocr_suite.ps1",
        ""
    )

    for ($index = 0; $index -lt $items.Count; $index++) {
        $number = $index + 1
        $fileLines += "# $number. $($items[$index].Title)"
        $fileLines += $items[$index].Command
        $fileLines += ""
    }

    try {
        Set-Content -Path $outputPath -Value $fileLines -Encoding UTF8
    }
    catch {}

    Write-Step "Manual recovery checklist"
    if ($Reason) {
        Write-Host $Reason -ForegroundColor Yellow
    }

    for ($index = 0; $index -lt $items.Count; $index++) {
        $number = $index + 1
        Write-Host "$number. $($items[$index].Title)" -ForegroundColor Yellow
        Write-Host $items[$index].Command
        Write-Host ""
    }

    $wheelhouseRoot = Get-ManualWheelhouseRoot
    if ($wheelhouseRoot) {
        Write-Host "If a local wheel command says a package was not found, rerun the same command after removing --no-index --find-links $wheelhouseRoot ." -ForegroundColor Yellow
        Write-Host ""
    }

    Write-Host "A copy of these commands was written to: $outputPath" -ForegroundColor Green
}

function Pause-And-Exit {
    param([int]$Code = 0)
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit $Code
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

function Throw-IfFailed {
    param([string]$Message)
    if ($LASTEXITCODE -ne 0) {
        throw $Message
    }
}

function Invoke-NativeProcess {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [switch]$EchoOutput,
        [int]$TimeoutSeconds = 0,
        [string]$TimeoutMessage = "Process timed out."
    )

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()

    try {
        $startProcessArgs = @{
            FilePath = $FilePath
            ArgumentList = $ArgumentList
            PassThru = $true
            NoNewWindow = $true
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError = $stderrPath
        }
        if ($TimeoutSeconds -le 0) {
            $startProcessArgs.Wait = $true
        }

        $process = Start-Process @startProcessArgs

        $timedOut = $false
        if ($TimeoutSeconds -gt 0) {
            $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
            if ($timedOut) {
                try {
                    $process.Kill()
                }
                catch {}
                try {
                    $process.WaitForExit()
                }
                catch {}
            }
        } else {
            $process.WaitForExit()
        }

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

        if ($timedOut) {
            $global:LASTEXITCODE = 124
            throw $TimeoutMessage
        }

        $global:LASTEXITCODE = $exitCode
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

function Invoke-ProcessWithTimeout {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [int]$TimeoutSeconds,
        [string]$TimeoutMessage,
        [switch]$EchoOutput
    )

    $result = Invoke-NativeProcess `
        -FilePath $FilePath `
        -ArgumentList $ArgumentList `
        -TimeoutSeconds $TimeoutSeconds `
        -TimeoutMessage $TimeoutMessage `
        -EchoOutput:$EchoOutput

    $global:LASTEXITCODE = $result.ExitCode
    return $result
}

function Invoke-InteractiveNativeProcess {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList
    )

    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $ArgumentList `
        -Wait `
        -NoNewWindow `
        -PassThru

    $exitCode = if ($null -eq $process.ExitCode) { 0 } else { [int]$process.ExitCode }
    $global:LASTEXITCODE = $exitCode
    return [pscustomobject]@{
        ExitCode = $exitCode
    }
}

function Invoke-PipInstall {
    param(
        [string]$PythonExe,
        [string[]]$Packages,
        [string]$IndexUrl = "",
        [switch]$Upgrade,
        [switch]$ForceReinstall,
        [int]$TimeoutSeconds = 600
    )

    $baseArgs = @(
        "-m", "pip", "install",
        "--disable-pip-version-check",
        "--progress-bar", "off",
        "--timeout", "60",
        "--retries", "1"
    )

    if ($Upgrade) {
        $baseArgs += @("--upgrade")
    }

    if ($ForceReinstall) {
        $baseArgs += @("--force-reinstall")
    }

    $packageSummary = ($Packages | Select-Object -First 3) -join ", "
    if ($Packages.Count -gt 3) {
        $packageSummary += ", ..."
    }

    $onlineArgs = @($baseArgs + $Packages)

    if (-not [string]::IsNullOrWhiteSpace($IndexUrl)) {
        $onlineArgs += @("-i", $IndexUrl)
    }

    if ($script:BundledWheelhouse -and (Test-Path $script:BundledWheelhouse)) {
        $localArgs = @($baseArgs + @("--no-index", "--find-links", $script:BundledWheelhouse) + $Packages)
        Write-Host "Trying bundled wheelhouse first..." -ForegroundColor Yellow
        Write-InstallSubProgress -Activity "Install Python packages" -Status "Trying bundled wheelhouse: $packageSummary" -PercentComplete 20
        try {
            $null = Invoke-ProcessWithTimeout `
                -FilePath $PythonExe `
                -ArgumentList $localArgs `
                -TimeoutSeconds $TimeoutSeconds `
                -TimeoutMessage "Bundled wheelhouse install timed out after $TimeoutSeconds seconds." `
                -EchoOutput
            $global:LASTEXITCODE = 0
        }
        catch {
            Write-Host "Bundled wheelhouse install timed out. Falling back to online package sources..." -ForegroundColor Yellow
            $global:LASTEXITCODE = 1
        }

        if ($LASTEXITCODE -eq 0) {
            Write-InstallSubProgress -Activity "Install Python packages" -Status "Installed from bundled wheelhouse: $packageSummary" -PercentComplete 100
            Write-Host "Installed from bundled wheelhouse." -ForegroundColor Green
            return
        }

        Write-Host "Bundled wheelhouse does not fully satisfy this install request. Falling back to online package sources..." -ForegroundColor Yellow
    }

    $sourceLabel = if ([string]::IsNullOrWhiteSpace($IndexUrl)) { "online package sources" } else { $IndexUrl }
    Write-InstallSubProgress -Activity "Install Python packages" -Status "Installing from $sourceLabel : $packageSummary" -PercentComplete 65
    $null = Invoke-ProcessWithTimeout `
        -FilePath $PythonExe `
        -ArgumentList $onlineArgs `
        -TimeoutSeconds $TimeoutSeconds `
        -TimeoutMessage "pip install timed out after $TimeoutSeconds seconds." `
        -EchoOutput
    $global:LASTEXITCODE = 0
    Write-InstallSubProgress -Activity "Install Python packages" -Status "Installed: $packageSummary" -PercentComplete 100
}

function Test-ProjectPathNeedsShortening {
    param(
        [string]$ProjectRoot,
        [string]$VenvPathName
    )

    $probePath = Join-Path $ProjectRoot "$VenvPathName\Lib\site-packages\modelscope\msdatasets\dataset_cls\custom_datasets\image_quality_assessment_degradation\image_quality_assessment_degradation_dataset.py"
    return ($probePath.Length -ge 240)
}

function Get-AvailableSubstDrive {
    foreach ($letter in @("P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z")) {
        $driveRoot = "${letter}:\"
        if (-not (Test-Path $driveRoot)) {
            return "${letter}:"
        }
    }

    return $null
}

function Get-ScriptRelativePathFromProjectRoot {
    param(
        [string]$ProjectRoot,
        [string]$ScriptPath
    )

    $resolvedProjectRoot = (Resolve-Path $ProjectRoot).Path.TrimEnd('\')
    $resolvedScriptPath = (Resolve-Path $ScriptPath).Path

    if ($resolvedScriptPath.StartsWith($resolvedProjectRoot + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $resolvedScriptPath.Substring($resolvedProjectRoot.Length + 1)
    }

    return (Split-Path $resolvedScriptPath -Leaf)
}

function Invoke-InstallerFromShortDrive {
    param([string]$ProjectRoot)

    $substDrive = Get-AvailableSubstDrive
    if (-not $substDrive) {
        throw "Project path is too long, but no free drive letter is available for temporary shortening."
    }

    $substCreateResult = Invoke-NativeProcess -FilePath "subst.exe" -ArgumentList @($substDrive, $ProjectRoot)
    if ($substCreateResult.ExitCode -ne 0) {
        throw "Failed to create a temporary drive mapping for a shorter install path."
    }

    $relativeInstallerPath = Get-ScriptRelativePathFromProjectRoot -ProjectRoot $ProjectRoot -ScriptPath $script:InstallerScriptPath
    $mappedScript = Join-Path "$substDrive\" $relativeInstallerPath
    $argumentList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $mappedScript,
        "-Mode", $Mode,
        "-Cuda", $Cuda,
        "-VenvDir", $VenvDir,
        "-PipInstallTimeoutSeconds", $PipInstallTimeoutSeconds
    )

    if ($StrictVenvPythonMatch) {
        $argumentList += "-StrictVenvPythonMatch"
    }

    $previousOriginalRoot = $env:PADDLE_OCR_ORIGINAL_ROOT
    $originalRoot = if ($previousOriginalRoot) { $previousOriginalRoot } else { $ProjectRoot }

    try {
        $env:PADDLE_OCR_SHORT_PATH_ACTIVE = "1"
        $env:PADDLE_OCR_ORIGINAL_ROOT = $originalRoot
        $rerunResult = Invoke-NativeProcess -FilePath "powershell.exe" -ArgumentList $argumentList -EchoOutput
        $exitCode = $rerunResult.ExitCode
    }
    finally {
        Remove-Item Env:PADDLE_OCR_SHORT_PATH_ACTIVE -ErrorAction SilentlyContinue
        if ($previousOriginalRoot) {
            $env:PADDLE_OCR_ORIGINAL_ROOT = $previousOriginalRoot
        } else {
            Remove-Item Env:PADDLE_OCR_ORIGINAL_ROOT -ErrorAction SilentlyContinue
        }
        try {
            Invoke-NativeProcess -FilePath "subst.exe" -ArgumentList @($substDrive, "/d") | Out-Null
        }
        catch {}
    }

    exit $exitCode
}

function Ensure-ShortProjectPath {
    param(
        [string]$ProjectRoot,
        [string]$VenvPathName
    )

    if ($env:PADDLE_OCR_SHORT_PATH_ACTIVE -eq "1") {
        return
    }

    if (-not (Test-ProjectPathNeedsShortening -ProjectRoot $ProjectRoot -VenvPathName $VenvPathName)) {
        return
    }

    Write-Step "Shorten working path"
    Write-Host "Project path is long enough to trigger Windows path-length install failures." -ForegroundColor Yellow
    Write-Host "Temporarily remapping the project to a shorter drive letter for installation..." -ForegroundColor Yellow
    Invoke-InstallerFromShortDrive -ProjectRoot $ProjectRoot
}

function Import-BundledModelCache {
    param([string]$ProjectRoot)

    $bundledCacheRoot = Join-Path $ProjectRoot "bundled_model_cache\official_models"
    if (-not (Test-Path $bundledCacheRoot)) {
        return
    }

    $targetCacheRoot = Join-Path $env:USERPROFILE ".paddlex\official_models"
    New-Item -ItemType Directory -Path $targetCacheRoot -Force | Out-Null

    Write-Step "Import bundled model cache"
    Write-Host "Source: $bundledCacheRoot" -ForegroundColor Yellow
    Write-Host "Target: $targetCacheRoot" -ForegroundColor Yellow

    foreach ($item in (Get-ChildItem -Path $bundledCacheRoot -Force)) {
        $destination = Join-Path $targetCacheRoot $item.Name
        if (Test-Path $destination) {
            Write-Host "Skip existing cache item: $($item.Name)" -ForegroundColor Green
            continue
        }

        Write-Host "Import cache item: $($item.Name)" -ForegroundColor Yellow
        Copy-Item -Path $item.FullName -Destination $destination -Recurse -Force
    }
}

function Initialize-BundledWheelhouse {
    param([string]$ProjectRoot)

    $wheelhouseRoot = $null
    foreach ($folderName in @("wheel", "bundled_wheels")) {
        $candidate = Join-Path $ProjectRoot $folderName
        if (Test-Path $candidate) {
            $wheelhouseRoot = $candidate
            break
        }
    }

    if (-not $wheelhouseRoot) {
        return
    }

    $wheelFiles = @(Get-ChildItem -Path $wheelhouseRoot -Filter *.whl -File -ErrorAction SilentlyContinue)
    if ($wheelFiles.Count -eq 0) {
        Write-Host "$(Split-Path $wheelhouseRoot -Leaf) was found, but no .whl files are present. Ignoring local wheelhouse." -ForegroundColor Yellow
        return
    }

    $versionFile = Join-Path $wheelhouseRoot "python-version.txt"
    if (Test-Path $versionFile) {
        $script:BundledWheelhousePythonVersion = (Get-Content -Path $versionFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
    }

    $script:BundledWheelhouse = $wheelhouseRoot

    Write-Step "Detect bundled wheelhouse"
    Write-Host "Local wheels: $wheelhouseRoot" -ForegroundColor Green
    if ($script:BundledWheelhousePythonVersion) {
        Write-Host "Preferred Python version for bundled wheels: $script:BundledWheelhousePythonVersion" -ForegroundColor Yellow
    }
}

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-PythonExeSupported {
    param([string]$PythonExe)

    if (-not (Test-Path $PythonExe)) {
        return $false
    }

    $tempPy = Join-Path $env:TEMP "check_python_supported.py"
@'
import platform
import struct
import sys

major = sys.version_info.major
minor = sys.version_info.minor
bits = struct.calcsize("P") * 8
machine = platform.machine().lower()

ok = (
    bits == 64 and
    major == 3 and
    9 <= minor <= 13 and
    machine in ("amd64", "x86_64")
)

print("PYTHON_OK=" + ("1" if ok else "0"))
print("PYTHON_VERSION={0}.{1}".format(major, minor))
print("PYTHON_BITS={0}".format(bits))
print("PYTHON_MACHINE={0}".format(machine))
raise SystemExit(0 if ok else 1)
'@ | Set-Content -Path $tempPy -Encoding ASCII

    try {
        $result = Invoke-NativeProcess -FilePath $PythonExe -ArgumentList @($tempPy)
        return ($result.ExitCode -eq 0)
    }
    catch {
        return $false
    }
    finally {
        if (Test-Path $tempPy) {
            Remove-Item $tempPy -Force -ErrorAction SilentlyContinue
        }
    }
}


function Get-PythonMajorMinor {
    param([string]$PythonExe)

    if (-not (Test-Path $PythonExe)) {
        return $null
    }

    $tempPy = Join-Path $env:TEMP ("get_python_major_minor_{0}.py" -f ([guid]::NewGuid().ToString("N")))
    try {
@'
import sys
print("{0}.{1}".format(sys.version_info.major, sys.version_info.minor))
'@ | Set-Content -Path $tempPy -Encoding ASCII

        $result = Invoke-NativeProcess -FilePath $PythonExe -ArgumentList @($tempPy)
        if ($result.ExitCode -ne 0) {
            return $null
        }

        $verLine = $result.StdOut | Where-Object { $_ } | Select-Object -Last 1
        $ver = if ($verLine) { $verLine.Trim() } else { "" }
        if ($ver) {
            return $ver
        }
    }
    catch {}
    finally {
        if (Test-Path $tempPy) {
            Remove-Item $tempPy -Force -ErrorAction SilentlyContinue
        }
    }
    return $null
}

function Get-PyLauncherCandidates {
    $candidates = New-Object System.Collections.Generic.List[string]

    if (-not (Test-CommandExists "py")) {
        return $candidates
    }

    try {
        $result = Invoke-NativeProcess -FilePath "py" -ArgumentList @("-0p")
        if ($result.ExitCode -ne 0) {
            return $candidates
        }
        $lines = $result.StdOut
    }
    catch {
        return $candidates
    }

    foreach ($line in $lines) {
        if ($line -match '([A-Za-z]:\\.*python\.exe)\s*$') {
            [void]$candidates.Add($Matches[1])
        }
    }

    return $candidates
}

function Find-SupportedPython {
    param([string]$PreferredVersion = "")

    $candidates = New-Object System.Collections.Generic.List[string]
    $allowedVersions = @("3.13", "3.12", "3.11", "3.10", "3.9")
    $supportedCandidates = New-Object System.Collections.Generic.List[object]
    $fallbackCandidates = New-Object System.Collections.Generic.List[object]

    try {
        $projectRoot = Get-ProjectRoot
        $venvPython = Join-Path $projectRoot "$VenvDir\Scripts\python.exe"
        $venvBasePython = Get-VenvConfigValue -VenvPython $venvPython -Key "executable"
        if ($venvBasePython) {
            [void]$candidates.Add($venvBasePython)
        }
    }
    catch {}

    foreach ($path in (Get-PyLauncherCandidates)) {
        if ($path) { [void]$candidates.Add($path) }
    }

    if (Test-CommandExists "python") {
        $tempPy = Join-Path $env:TEMP ("get_default_python_path_{0}.py" -f ([guid]::NewGuid().ToString("N")))
        try {
@'
import sys
print(sys.executable)
'@ | Set-Content -Path $tempPy -Encoding ASCII

            $result = Invoke-NativeProcess -FilePath "python" -ArgumentList @($tempPy)
            $pathLine = if ($result.ExitCode -eq 0) { $result.StdOut | Where-Object { $_ } | Select-Object -Last 1 } else { $null }
            $path = if ($pathLine) { $pathLine.Trim() } else { "" }
            if ($path) { [void]$candidates.Add($path) }
        }
        catch {}
        finally {
            if (Test-Path $tempPy) {
                Remove-Item $tempPy -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $common = @(
        "$env:LocalAppData\Programs\Python\Python313\python.exe",
        "$env:LocalAppData\Programs\Python\Python312\python.exe",
        "$env:LocalAppData\Programs\Python\Python311\python.exe",
        "$env:LocalAppData\Programs\Python\Python310\python.exe",
        "$env:LocalAppData\Programs\Python\Python39\python.exe",
        "$env:ProgramFiles\Python313\python.exe",
        "$env:ProgramFiles\Python312\python.exe",
        "$env:ProgramFiles\Python311\python.exe",
        "$env:ProgramFiles\Python310\python.exe",
        "$env:ProgramFiles\Python39\python.exe"
    )
    foreach ($p in $common) {
        if (Test-Path $p) { [void]$candidates.Add($p) }
    }

    # Broader fallback scan for fresh winget installs not yet visible to current PATH/py launcher.
    foreach ($root in @("$env:LocalAppData\Programs\Python", "$env:ProgramFiles")) {
        if (Test-Path $root) {
            Get-ChildItem -Path $root -Filter python.exe -Recurse -File -ErrorAction SilentlyContinue |
                ForEach-Object { [void]$candidates.Add($_.FullName) }
        }
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        $candidateVersion = Get-PythonMajorMinor -PythonExe $candidate
        if (-not $candidateVersion -or ($allowedVersions -notcontains $candidateVersion)) {
            continue
        }

        $candidateInfo = [pscustomobject]@{
            Path = $candidate
            Version = $candidateVersion
        }

        if (Test-PythonExeSupported -PythonExe $candidate) {
            [void]$supportedCandidates.Add($candidateInfo)
            continue
        }

        if (Test-Path $candidate) {
            [void]$fallbackCandidates.Add($candidateInfo)
        }
    }

    if ($supportedCandidates.Count -eq 0 -and $fallbackCandidates.Count -gt 0) {
        Write-Host "Python support probing returned non-zero results. Falling back to version-based interpreter selection." -ForegroundColor Yellow
        foreach ($candidateInfo in $fallbackCandidates) {
            [void]$supportedCandidates.Add([pscustomobject]@{
                Path = $candidateInfo.Path
                Version = $candidateInfo.Version
            })
        }
    }

    if ($supportedCandidates.Count -eq 0) {
        return $null
    }

    $orderedCandidates = $supportedCandidates | Sort-Object { [array]::IndexOf($allowedVersions, $_.Version) }

    if ($PreferredVersion) {
        $preferredCandidate = $orderedCandidates | Where-Object { $_.Version -eq $PreferredVersion } | Select-Object -First 1
        if ($preferredCandidate) {
            return $preferredCandidate.Path
        }
    }

    return ($orderedCandidates | Select-Object -First 1).Path
}

function Install-PythonViaWinget {
    param([string]$PreferredVersion = "3.13")

    $majorMinor = if ($PreferredVersion -match '^\d+\.\d+$') { $PreferredVersion } else { "3.13" }
    $packageId = "Python.Python.$majorMinor"

    Write-Host "No supported Python found. Installing Python $majorMinor via winget..." -ForegroundColor Yellow

    if (-not (Test-CommandExists "winget")) {
        throw "winget not found. Cannot auto-install Python. Install App Installer / winget first."
    }

    $wingetResult = Invoke-NativeProcess `
        -FilePath "winget" `
        -ArgumentList @("install", "-e", "--id", $packageId, "--accept-source-agreements", "--accept-package-agreements") `
        -EchoOutput
    if ($wingetResult.ExitCode -ne 0) {
        throw "winget failed to install Python $majorMinor."
    }

    Start-Sleep -Seconds 5
}

function Warn-IfBundledWheelhousePythonMismatch {
    param([string]$PythonExe)

    if (-not $script:BundledWheelhouse -or -not $script:BundledWheelhousePythonVersion) {
        return
    }

    $detectedVersion = Get-PythonMajorMinor -PythonExe $PythonExe
    if (-not $detectedVersion) {
        return
    }

    if ($detectedVersion -ne $script:BundledWheelhousePythonVersion) {
        Write-Host "Bundled wheels were built for Python $script:BundledWheelhousePythonVersion, but the current interpreter is $detectedVersion." -ForegroundColor Yellow
        Write-Host "Local wheel installs may be skipped by pip and fall back to online downloads." -ForegroundColor Yellow
    }
}

function Get-PreferredPythonVersion {
    if ($script:BundledWheelhousePythonVersion) {
        return $script:BundledWheelhousePythonVersion
    }

    return $null
}

function Recreate-Venv {
    param(
        [string]$PythonExe,
        [string]$VenvPath
    )

    $tempVenvPath = "{0}.rebuild_{1}" -f $VenvPath, ([guid]::NewGuid().ToString("N"))
    $backupVenvPath = "{0}.backup_{1}" -f $VenvPath, ([guid]::NewGuid().ToString("N"))

    try {
        $venvResult = Invoke-NativeProcess -FilePath $PythonExe -ArgumentList @("-m", "venv", $tempVenvPath) -EchoOutput
        if ($venvResult.ExitCode -ne 0) {
            throw "Failed to create virtual environment."
        }

        if (Test-Path $VenvPath) {
            Write-Host "Replacing incompatible virtual environment: $VenvPath" -ForegroundColor Yellow
            Move-Item -Path $VenvPath -Destination $backupVenvPath -Force
        }

        Move-Item -Path $tempVenvPath -Destination $VenvPath -Force

        if (Test-Path $backupVenvPath) {
            Remove-Item $backupVenvPath -Recurse -Force
        }
    }
    catch {
        if ((-not (Test-Path $VenvPath)) -and (Test-Path $backupVenvPath)) {
            Move-Item -Path $backupVenvPath -Destination $VenvPath -Force
        }
        throw
    }
    finally {
        if (Test-Path $tempVenvPath) {
            Remove-Item $tempVenvPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-PackagingToolsReady {
    param([string]$PythonExe)

    $tempPy = Join-Path $env:TEMP "check_packaging_tools_ready.py"
@'
try:
    import packaging
    import pip
    import setuptools
    import wheel
    print("PACKAGING_TOOLS_READY=OK")
    raise SystemExit(0)
except Exception as e:
    print("PACKAGING_TOOLS_READY_FAILED={0}".format(repr(e)))
    raise SystemExit(1)
'@ | Set-Content -Path $tempPy -Encoding ASCII

    try {
        $result = Invoke-NativeProcess -FilePath $PythonExe -ArgumentList @($tempPy)
        return ($result.ExitCode -eq 0)
    }
    finally {
        if (Test-Path $tempPy) {
            Remove-Item $tempPy -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-VenvConfigValue {
    param(
        [string]$VenvPython,
        [string]$Key
    )

    $venvScriptsDir = Split-Path $VenvPython -Parent
    if (-not $venvScriptsDir) {
        return $null
    }

    $venvRoot = Split-Path $venvScriptsDir -Parent
    if (-not $venvRoot) {
        return $null
    }

    $cfgPath = Join-Path $venvRoot "pyvenv.cfg"
    if (-not (Test-Path $cfgPath)) {
        return $null
    }

    foreach ($line in (Get-Content $cfgPath -ErrorAction SilentlyContinue)) {
        if ($line -match ("^\s*" + [regex]::Escape($Key) + "\s*=\s*(.+?)\s*$")) {
            return $Matches[1].Trim()
        }
    }

    return $null
}

function Test-VenvBaseInterpreterReusable {
    param([string]$VenvPython)

    $venvHome = Get-VenvConfigValue -VenvPython $VenvPython -Key "home"
    if ($venvHome -and -not (Test-Path $venvHome)) {
        Write-Host "Venv reuse check failed: pyvenv.cfg home does not exist on this machine: $venvHome" -ForegroundColor Yellow
        return $false
    }

    $venvExecutable = Get-VenvConfigValue -VenvPython $VenvPython -Key "executable"
    if ($venvExecutable -and -not (Test-Path $venvExecutable)) {
        Write-Host "Venv reuse check failed: pyvenv.cfg executable does not exist on this machine: $venvExecutable" -ForegroundColor Yellow
        return $false
    }

    return $true
}

function Test-VenvReusable {
    param(
        [string]$VenvPython,
        [string]$SystemPythonExe,
        [switch]$StrictMatch
    )

    if (-not (Test-Path $VenvPython)) {
        return $false
    }

    $allowedVersions = @("3.13", "3.12", "3.11", "3.10", "3.9")
    $venvVer = $null
    $venvVersionRaw = Get-VenvConfigValue -VenvPython $VenvPython -Key "version"
    if ($venvVersionRaw -and ($venvVersionRaw -match '^(\d+\.\d+)')) {
        $venvVer = $Matches[1]
    }
    if (-not $venvVer) {
        $venvVer = Get-PythonMajorMinor -PythonExe $VenvPython
    }
    if (-not $venvVer -or ($allowedVersions -notcontains $venvVer)) {
        return $false
    }

    if (-not (Test-VenvBaseInterpreterReusable -VenvPython $VenvPython)) {
        return $false
    }

    if ($StrictMatch) {
        $systemVer = Get-PythonMajorMinor -PythonExe $SystemPythonExe

        if (-not $systemVer -or -not $venvVer) {
            return $false
        }

        if ($systemVer -ne $venvVer) {
            Write-Host "Strict venv reuse check failed: system Python version $systemVer != venv Python version $venvVer" -ForegroundColor Yellow
            return $false
        }
    }

    return $true
}

function Upgrade-PackagingTools {
    param([string]$PythonExe)

    Invoke-PipInstall -PythonExe $PythonExe -Packages @("pip", "setuptools", "wheel") -Upgrade -TimeoutSeconds $PipInstallTimeoutSeconds
    if ($LASTEXITCODE -ne 0 -and (Test-PackagingToolsReady -PythonExe $PythonExe)) {
        Write-Host "Packaging tools are ready after post-install verification." -ForegroundColor Green
        $global:LASTEXITCODE = 0
    }
    Throw-IfFailed "Failed to upgrade pip/setuptools/wheel."
}

function Test-PaddleReusable {
    param(
        [string]$PythonExe,
        [string]$DesiredMode
    )

    $tempPy = Join-Path $env:TEMP "check_paddle_reusable.py"
    if ($DesiredMode -eq "gpu") {
@'
import sys
try:
    import paddle
    print("PADDLE_VERSION={0}".format(paddle.__version__))
    if not paddle.is_compiled_with_cuda():
        print("PADDLE_GPU_OK=0")
        raise SystemExit(1)
    paddle.device.set_device("gpu")
    tensor = paddle.ones([1], dtype="float32") + 1
    print("PADDLE_RUNTIME_DEVICE={0}".format(paddle.device.get_device()))
    print("PADDLE_GPU_OK=1")
    raise SystemExit(0)
except Exception as e:
    print("PADDLE_CHECK_ERROR={0}".format(repr(e)))
    raise SystemExit(1)
'@ | Set-Content -Path $tempPy -Encoding ASCII
    } else {
@'
import sys
try:
    import paddle
    print("PADDLE_VERSION={0}".format(paddle.__version__))
    raise SystemExit(0)
except Exception as e:
    print("PADDLE_CHECK_ERROR={0}".format(repr(e)))
    raise SystemExit(1)
'@ | Set-Content -Path $tempPy -Encoding ASCII
    }

    try {
        $result = Invoke-NativeProcess -FilePath $PythonExe -ArgumentList @($tempPy)
        return ($result.ExitCode -eq 0)
    }
    finally {
        if (Test-Path $tempPy) {
            Remove-Item $tempPy -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-OCRDependenciesReusable {
    param([string]$PythonExe)

    $tempPy = Join-Path $env:TEMP "check_ocr_deps_reusable.py"
@'
import sys
try:
    import paddleocr
    import fitz
    print("PADDLEOCR_VERSION={0}".format(getattr(paddleocr, "__version__", "unknown")))
    print("PYMUPDF_VERSION={0}".format(getattr(fitz, "VersionBind", "unknown")))
    raise SystemExit(0)
except Exception as e:
    print("OCR_DEPS_CHECK_ERROR={0}".format(repr(e)))
    raise SystemExit(1)
'@ | Set-Content -Path $tempPy -Encoding ASCII

    try {
        $result = Invoke-NativeProcess -FilePath $PythonExe -ArgumentList @($tempPy)
        return ($result.ExitCode -eq 0)
    }
    finally {
        if (Test-Path $tempPy) {
            Remove-Item $tempPy -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-OCRRuntimeReusable {
    param([string]$PythonExe)

    $tempPy = Join-Path $env:TEMP "check_ppocr_runtime_ready.py"
    if ($script:RequireGpu) {
@'
import paddle
try:
    paddle.device.set_device("gpu")
    from paddleocr import PaddleOCR
    PaddleOCR(
        device="gpu",
        use_doc_orientation_classify=False,
        use_doc_unwarping=False,
        use_textline_orientation=False,
        text_rec_score_thresh=0.0,
    )
    print("PADDLE_RUNTIME_DEVICE={0}".format(paddle.device.get_device()))
    print("PPOCRV5_READY=OK")
    raise SystemExit(0)
except Exception as e:
    print("PPOCRV5_READY_FAILED={0}".format(repr(e)))
    raise SystemExit(1)
'@ | Set-Content -Path $tempPy -Encoding ASCII
    } else {
@'
try:
    from paddleocr import PaddleOCR
    PaddleOCR(
        use_doc_orientation_classify=False,
        use_doc_unwarping=False,
        use_textline_orientation=False,
        text_rec_score_thresh=0.0,
    )
    print("PPOCRV5_READY=OK")
    raise SystemExit(0)
except Exception as e:
    print("PPOCRV5_READY_FAILED={0}".format(repr(e)))
    raise SystemExit(1)
'@ | Set-Content -Path $tempPy -Encoding ASCII
    }

    try {
        $result = Invoke-NativeProcess -FilePath $PythonExe -ArgumentList @($tempPy)
        return ($result.ExitCode -eq 0)
    }
    catch {
        return $false
    }
    finally {
        if (Test-Path $tempPy) {
            Remove-Item $tempPy -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-PaddlexReusable {
    param([string]$PythonExe)

    $tempPy = Join-Path $env:TEMP "check_paddlex_ready.py"
@'
try:
    import paddlex
    print("PADDLEX_READY=OK")
    raise SystemExit(0)
except Exception as e:
    print("PADDLEX_READY_FAILED={0}".format(repr(e)))
    raise SystemExit(1)
'@ | Set-Content -Path $tempPy -Encoding ASCII

    try {
        $result = Invoke-NativeProcess -FilePath $PythonExe -ArgumentList @($tempPy)
        return ($result.ExitCode -eq 0)
    }
    finally {
        if (Test-Path $tempPy) {
            Remove-Item $tempPy -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-StructureDependenciesReusable {
    param([string]$PythonExe)

    $tempPy = Join-Path $env:TEMP "check_structure_ready.py"
    if ($script:RequireGpu) {
@'
import paddle
from paddleocr import PPStructureV3
print("PADDLE_VERSION={0}".format(paddle.__version__))
paddle.device.set_device("gpu")
PPStructureV3(device="gpu")
print("PADDLE_RUNTIME_DEVICE={0}".format(paddle.device.get_device()))
print("PPSTRUCTUREV3_OK")
'@ | Set-Content -Path $tempPy -Encoding ASCII
    } else {
@'
import paddle
from paddleocr import PPStructureV3
print("PADDLE_VERSION={0}".format(paddle.__version__))
PPStructureV3()
print("PPSTRUCTUREV3_OK")
'@ | Set-Content -Path $tempPy -Encoding ASCII
    }

    try {
        $result = Invoke-NativeProcess -FilePath $PythonExe -ArgumentList @($tempPy)
        return ($result.ExitCode -eq 0)
    }
    catch {
        return $false
    }
    finally {
        if (Test-Path $tempPy) {
            Remove-Item $tempPy -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-StructureDependencies {
    param([string]$PythonExe)

    Invoke-PipInstall -PythonExe $PythonExe -Packages @("paddlex[ocr]==3.4.2") -TimeoutSeconds $PipInstallTimeoutSeconds
    if ($LASTEXITCODE -ne 0 -and (Test-PaddlexReusable -PythonExe $PythonExe)) {
        Write-Host "PaddleX is ready after post-install verification." -ForegroundColor Green
        $global:LASTEXITCODE = 0
    }
    Throw-IfFailed "Failed to install PP-StructureV3 dependencies (paddlex[ocr]==3.4.2)."
}

function Ensure-StructureDependenciesInstalled {
    param(
        [string]$PythonExe,
        [string]$DesiredMode,
        [string]$CudaVersion
    )

    if (Test-StructureDependenciesReusable -PythonExe $PythonExe) {
        Write-Host "Reusable PP-StructureV3 dependencies detected. Skipping reinstall." -ForegroundColor Green
        return $DesiredMode
    }

    Write-Host "Reusable PP-StructureV3 dependencies not found. Installing..." -ForegroundColor Yellow
    Install-StructureDependencies -PythonExe $PythonExe

    if (-not (Test-StructureDependenciesReusable -PythonExe $PythonExe)) {
        Write-Host "PP-StructureV3 validation still failed. Reinstalling PaddlePaddle and retrying..." -ForegroundColor Yellow
        $RepairedMode = Repair-PaddleInstalled -PythonExe $PythonExe -DesiredMode $DesiredMode -CudaVersion $CudaVersion
        Write-Host "PaddlePaddle repair mode: $RepairedMode" -ForegroundColor Green
        $DesiredMode = $RepairedMode

        if (-not (Test-OCRDependenciesReusable -PythonExe $PythonExe)) {
            Write-Host "OCR dependencies no longer validate after PaddlePaddle repair. Revalidating OCR stack..." -ForegroundColor Yellow
            Ensure-OCRDependenciesInstalled -PythonExe $PythonExe
        }

        Install-StructureDependencies -PythonExe $PythonExe
        if (-not (Test-StructureDependenciesReusable -PythonExe $PythonExe)) {
            throw "PP-StructureV3 dependency install failed validation even after PaddlePaddle repair."
        }
    }

    Write-Host "PP-StructureV3 dependencies are ready." -ForegroundColor Green
    return $DesiredMode
}

function Install-PaddleCPU {
    param(
        [string]$PythonExe,
        [switch]$ForceReinstall
    )

    Write-Host "Trying official Paddle CPU index first..." -ForegroundColor Yellow
    try {
        Invoke-PipInstall `
            -PythonExe $PythonExe `
            -Packages @("paddlepaddle==3.3.0") `
            -IndexUrl "https://www.paddlepaddle.org.cn/packages/stable/cpu/" `
            -ForceReinstall:$ForceReinstall `
            -TimeoutSeconds $PipInstallTimeoutSeconds
        if ($LASTEXITCODE -ne 0 -and (Test-PaddleReusable -PythonExe $PythonExe -DesiredMode "cpu")) {
            Write-Host "CPU PaddlePaddle is ready after post-install verification." -ForegroundColor Green
            $global:LASTEXITCODE = 0
        }
    }
    catch {
        Write-Host "Official CPU index timed out or failed unexpectedly. Falling back to PyPI..." -ForegroundColor Yellow
        $global:LASTEXITCODE = 1
    }

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Installed paddlepaddle from official CPU index." -ForegroundColor Green
        return
    }

    Write-Host "Official CPU index failed. Falling back to PyPI..." -ForegroundColor Yellow
    Invoke-PipInstall `
        -PythonExe $PythonExe `
        -Packages @("paddlepaddle") `
        -ForceReinstall:$ForceReinstall `
        -TimeoutSeconds $PipInstallTimeoutSeconds
    if ($LASTEXITCODE -ne 0 -and (Test-PaddleReusable -PythonExe $PythonExe -DesiredMode "cpu")) {
        Write-Host "CPU PaddlePaddle is ready after post-install verification." -ForegroundColor Green
        $global:LASTEXITCODE = 0
    }
    Throw-IfFailed "Failed to install paddlepaddle from both official CPU index and PyPI."

    Write-Host "Installed paddlepaddle from PyPI." -ForegroundColor Green
}

function Install-PaddleGPU {
    param(
        [string]$PythonExe,
        [string]$CudaVersion,
        [switch]$ForceReinstall
    )

    Write-Host "Installing paddlepaddle-gpu from official GPU index: $CudaVersion" -ForegroundColor Yellow
    if ($script:RequireGpu) {
        Write-Host "GPU-only mode is enabled. If GPU install or validation fails, the installer will stop instead of falling back to CPU." -ForegroundColor Yellow
    } else {
        Write-Host "If the GPU wheel download stalls for over $PipInstallTimeoutSeconds seconds, the installer will fall back to CPU." -ForegroundColor Yellow
    }
    Invoke-PipInstall `
        -PythonExe $PythonExe `
        -Packages @("paddlepaddle-gpu==3.2.2") `
        -IndexUrl "https://www.paddlepaddle.org.cn/packages/stable/$CudaVersion/" `
        -ForceReinstall:$ForceReinstall `
        -TimeoutSeconds $PipInstallTimeoutSeconds
    if ($LASTEXITCODE -ne 0 -and (Test-PaddleReusable -PythonExe $PythonExe -DesiredMode "gpu")) {
        Write-Host "GPU PaddlePaddle is ready after post-install verification." -ForegroundColor Green
        $global:LASTEXITCODE = 0
    }
    Throw-IfFailed "Failed to install paddlepaddle-gpu from official GPU index."
}

function Repair-PaddleInstalled {
    param(
        [string]$PythonExe,
        [string]$DesiredMode,
        [string]$CudaVersion
    )

    Write-Host "PaddlePaddle appears inconsistent. Forcing reinstall..." -ForegroundColor Yellow

    if ($DesiredMode -eq "gpu") {
        try {
            Install-PaddleGPU -PythonExe $PythonExe -CudaVersion $CudaVersion -ForceReinstall
            if (Test-PaddleReusable -PythonExe $PythonExe -DesiredMode "gpu") {
                Write-Host "GPU PaddlePaddle repaired successfully." -ForegroundColor Green
                return "gpu"
            }
            throw "GPU PaddlePaddle force reinstall completed but GPU validation still failed."
        }
        catch {
            if ($script:RequireGpu) {
                throw "Forced GPU PaddlePaddle repair failed and -RequireGpu was specified. CPU fallback is disabled."
            }
            Write-Host "Forced GPU PaddlePaddle repair failed. Falling back to forced CPU reinstall..." -ForegroundColor Yellow
            Install-PaddleCPU -PythonExe $PythonExe -ForceReinstall
            if (Test-PaddleReusable -PythonExe $PythonExe -DesiredMode "cpu") {
                Write-Host "CPU PaddlePaddle repaired successfully." -ForegroundColor Green
                return "cpu"
            }
            throw "Forced CPU PaddlePaddle repair also failed."
        }
    }

    Install-PaddleCPU -PythonExe $PythonExe -ForceReinstall
    if (Test-PaddleReusable -PythonExe $PythonExe -DesiredMode "cpu") {
        Write-Host "CPU PaddlePaddle repaired successfully." -ForegroundColor Green
        return "cpu"
    }
    throw "Forced CPU PaddlePaddle repair failed."
}

function Ensure-PaddleInstalled {
    param(
        [string]$PythonExe,
        [string]$DesiredMode,
        [string]$CudaVersion
    )

    if (Test-PaddleReusable -PythonExe $PythonExe -DesiredMode $DesiredMode) {
        Write-Host "Reusable PaddlePaddle installation detected. Skipping reinstall." -ForegroundColor Green
        return $DesiredMode
    }

    if ($DesiredMode -eq "gpu") {
        Write-Host "Reusable GPU PaddlePaddle not found. Installing GPU build..." -ForegroundColor Yellow
        try {
            Install-PaddleGPU -PythonExe $PythonExe -CudaVersion $CudaVersion
            if (Test-PaddleReusable -PythonExe $PythonExe -DesiredMode "gpu") {
                Write-Host "GPU PaddlePaddle is ready." -ForegroundColor Green
                return "gpu"
            }
            throw "GPU PaddlePaddle install completed but GPU check still failed."
        }
        catch {
            if ($script:RequireGpu) {
                throw "GPU install/check failed and -RequireGpu was specified. CPU fallback is disabled."
            }
            Write-Host "GPU install/check failed. Falling back to CPU..." -ForegroundColor Yellow
            Install-PaddleCPU -PythonExe $PythonExe
            if (Test-PaddleReusable -PythonExe $PythonExe -DesiredMode "cpu") {
                Write-Host "CPU PaddlePaddle is ready." -ForegroundColor Green
                return "cpu"
            }
            throw "CPU PaddlePaddle fallback also failed."
        }
    }

    Write-Host "Reusable CPU PaddlePaddle not found. Installing CPU build..." -ForegroundColor Yellow
    Install-PaddleCPU -PythonExe $PythonExe
    if (Test-PaddleReusable -PythonExe $PythonExe -DesiredMode "cpu") {
        Write-Host "CPU PaddlePaddle is ready." -ForegroundColor Green
        return "cpu"
    }
    throw "CPU PaddlePaddle install failed validation."
}

function Install-OCRDependencies {
    param([string]$PythonExe)

    Invoke-PipInstall -PythonExe $PythonExe -Packages @("paddleocr", "pillow", "pymupdf") -Upgrade -TimeoutSeconds $PipInstallTimeoutSeconds
    if ($LASTEXITCODE -ne 0 -and (Test-OCRDependenciesReusable -PythonExe $PythonExe)) {
        Write-Host "OCR dependencies are ready after post-install verification." -ForegroundColor Green
        $global:LASTEXITCODE = 0
    }
    Throw-IfFailed "Failed to install paddleocr / pillow / pymupdf."
}

function Ensure-OCRDependenciesInstalled {
    param([string]$PythonExe)

    if (Test-OCRDependenciesReusable -PythonExe $PythonExe) {
        if (Test-OCRRuntimeReusable -PythonExe $PythonExe) {
            Write-Host "Reusable PaddleOCR / PyMuPDF installation detected. Skipping reinstall." -ForegroundColor Green
            Write-Host "PP-OCRv5 runtime/models are ready." -ForegroundColor Green
            return
        }

        Write-Host "PaddleOCR imports are available, but PP-OCRv5 runtime/model validation failed." -ForegroundColor Yellow
    } else {
        Write-Host "Reusable OCR dependencies not found. Installing..." -ForegroundColor Yellow
        Install-OCRDependencies -PythonExe $PythonExe

        if (-not (Test-OCRDependenciesReusable -PythonExe $PythonExe)) {
            throw "OCR dependency install failed validation."
        }
    }

    if (-not (Test-OCRRuntimeReusable -PythonExe $PythonExe)) {
        throw "PP-OCRv5 runtime/model validation failed. Check network access or clear the broken model cache and retry."
    }

    Write-Host "OCR dependencies and PP-OCRv5 runtime are ready." -ForegroundColor Green
}

function Verify-Installation {
    param(
        [string]$PythonExe,
        [bool]$CheckStructure = $true
    )

    $tempPy = Join-Path $env:TEMP "verify_paddle_install.py"
    if ($CheckStructure) {
        if ($script:RequireGpu) {
@'
import platform
import struct
import sys
import fitz
import paddle
import paddleocr
from paddleocr import PaddleOCR, PPStructureV3

print("Python:", sys.version.replace("\n", " "))
print("Bits:", struct.calcsize("P") * 8)
print("Machine:", platform.machine())
print("Paddle:", paddle.__version__)
print("Paddle compiled with CUDA:", paddle.is_compiled_with_cuda())
print("PaddleOCR:", getattr(paddleocr, "__version__", "unknown"))
print("PyMuPDF:", getattr(fitz, "VersionBind", "unknown"))

if not paddle.is_compiled_with_cuda():
    raise RuntimeError("The installed PaddlePaddle build is not CUDA-enabled.")

try:
    paddle.device.set_device("gpu")
    print("Paddle runtime device:", paddle.device.get_device())
except Exception as e:
    print("PADDLE_GPU_DEVICE_FAILED=", repr(e))
    raise

try:
    PaddleOCR(
        device="gpu",
        use_doc_orientation_classify=False,
        use_doc_unwarping=False,
        use_textline_orientation=False,
        text_rec_score_thresh=0.0,
    )
    print("PPOCRV5_READY=OK")
except Exception as e:
    print("PPOCRV5_READY_FAILED=", repr(e))
    raise

try:
    PPStructureV3(device="gpu")
    print("PPSTRUCTUREV3_READY=OK")
except Exception as e:
    print("PPSTRUCTUREV3_READY_FAILED=", repr(e))
    raise

try:
    paddle.utils.run_check()
    print("RUN_CHECK=OK")
except Exception as e:
    print("RUN_CHECK_FAILED=", repr(e))
    raise
'@ | Set-Content -Path $tempPy -Encoding ASCII
        } else {
@'
import platform
import struct
import sys
import fitz
import paddle
import paddleocr
from paddleocr import PaddleOCR, PPStructureV3

print("Python:", sys.version.replace("\n", " "))
print("Bits:", struct.calcsize("P") * 8)
print("Machine:", platform.machine())
print("Paddle:", paddle.__version__)
print("Paddle compiled with CUDA:", paddle.is_compiled_with_cuda())
print("PaddleOCR:", getattr(paddleocr, "__version__", "unknown"))
print("PyMuPDF:", getattr(fitz, "VersionBind", "unknown"))

try:
    PaddleOCR(
        use_doc_orientation_classify=False,
        use_doc_unwarping=False,
        use_textline_orientation=False,
        text_rec_score_thresh=0.0,
    )
    print("PPOCRV5_READY=OK")
except Exception as e:
    print("PPOCRV5_READY_FAILED=", repr(e))
    raise

try:
    PPStructureV3()
    print("PPSTRUCTUREV3_READY=OK")
except Exception as e:
    print("PPSTRUCTUREV3_READY_FAILED=", repr(e))
    raise

try:
    paddle.utils.run_check()
    print("RUN_CHECK=OK")
except Exception as e:
    print("RUN_CHECK_FAILED=", repr(e))
    raise
'@ | Set-Content -Path $tempPy -Encoding ASCII
        }
    } else {
        if ($script:RequireGpu) {
@'
import platform
import struct
import sys
import fitz
import paddle
import paddleocr
from paddleocr import PaddleOCR

print("Python:", sys.version.replace("\n", " "))
print("Bits:", struct.calcsize("P") * 8)
print("Machine:", platform.machine())
print("Paddle:", paddle.__version__)
print("Paddle compiled with CUDA:", paddle.is_compiled_with_cuda())
print("PaddleOCR:", getattr(paddleocr, "__version__", "unknown"))
print("PyMuPDF:", getattr(fitz, "VersionBind", "unknown"))

if not paddle.is_compiled_with_cuda():
    raise RuntimeError("The installed PaddlePaddle build is not CUDA-enabled.")

try:
    paddle.device.set_device("gpu")
    print("Paddle runtime device:", paddle.device.get_device())
except Exception as e:
    print("PADDLE_GPU_DEVICE_FAILED=", repr(e))
    raise

try:
    PaddleOCR(
        device="gpu",
        use_doc_orientation_classify=False,
        use_doc_unwarping=False,
        use_textline_orientation=False,
        text_rec_score_thresh=0.0,
    )
    print("PPOCRV5_READY=OK")
except Exception as e:
    print("PPOCRV5_READY_FAILED=", repr(e))
    raise

try:
    paddle.utils.run_check()
    print("RUN_CHECK=OK")
except Exception as e:
    print("RUN_CHECK_FAILED=", repr(e))
    raise
'@ | Set-Content -Path $tempPy -Encoding ASCII
        } else {
@'
import platform
import struct
import sys
import fitz
import paddle
import paddleocr
from paddleocr import PaddleOCR

print("Python:", sys.version.replace("\n", " "))
print("Bits:", struct.calcsize("P") * 8)
print("Machine:", platform.machine())
print("Paddle:", paddle.__version__)
print("Paddle compiled with CUDA:", paddle.is_compiled_with_cuda())
print("PaddleOCR:", getattr(paddleocr, "__version__", "unknown"))
print("PyMuPDF:", getattr(fitz, "VersionBind", "unknown"))

try:
    PaddleOCR(
        use_doc_orientation_classify=False,
        use_doc_unwarping=False,
        use_textline_orientation=False,
        text_rec_score_thresh=0.0,
    )
    print("PPOCRV5_READY=OK")
except Exception as e:
    print("PPOCRV5_READY_FAILED=", repr(e))
    raise

try:
    paddle.utils.run_check()
    print("RUN_CHECK=OK")
except Exception as e:
    print("RUN_CHECK_FAILED=", repr(e))
    raise
'@ | Set-Content -Path $tempPy -Encoding ASCII
        }
    }

    try {
        $result = Invoke-NativeProcess -FilePath $PythonExe -ArgumentList @($tempPy) -EchoOutput
        if ($result.ExitCode -ne 0) {
            throw "Installation verification failed."
        }
    }
    finally {
        if (Test-Path $tempPy) {
            Remove-Item $tempPy -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-InstalledComponentSummary {
    param(
        [string]$PythonExe,
        [string]$FinalMode
    )

    $tempPy = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), ".py")
    try {
        Set-Content -Path $tempPy -Encoding ASCII -Value @"
import importlib.metadata as md
import json
import sys

packages = {}
for name in ("paddlepaddle", "paddlepaddle-gpu", "paddleocr", "paddlex", "PyMuPDF"):
    try:
        packages[name] = md.version(name)
    except Exception:
        packages[name] = ""

summary = {
    "python": sys.version.split()[0],
    "paddle": packages.get("paddlepaddle-gpu") or packages.get("paddlepaddle") or "",
    "paddleocr": packages.get("paddleocr") or "",
    "paddlex": packages.get("paddlex") or "",
    "pymupdf": packages.get("PyMuPDF") or "",
    "mode": "$FinalMode"
}
print(json.dumps(summary, ensure_ascii=True))
"@

        $result = Invoke-NativeProcess -FilePath $PythonExe -ArgumentList @($tempPy)
        if ($result.ExitCode -ne 0) {
            throw "Failed to collect the installed package summary."
        }

        $jsonLine = $result.StdOut | Where-Object { $_ } | Select-Object -Last 1
        if (-not $jsonLine) {
            throw "Failed to collect the installed package summary."
        }

        return $jsonLine | ConvertFrom-Json
    }
    finally {
        if (Test-Path $tempPy) {
            Remove-Item $tempPy -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    $ProjectRoot = Get-ProjectRoot
    $script:ProjectRootForManual = if ($env:PADDLE_OCR_ORIGINAL_ROOT) { $env:PADDLE_OCR_ORIGINAL_ROOT } else { $ProjectRoot }
    Ensure-ShortProjectPath -ProjectRoot $ProjectRoot -VenvPathName $VenvDir
    Set-Location $ProjectRoot

    $LogDir = Join-Path $ProjectRoot "log"
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    $LogPath = Join-Path $LogDir "install_paddle_ocr_suite.log"
    Start-Transcript -Path $LogPath -Force | Out-Null

    $phaseNames = @(
        "Prepare workspace",
        "Detect supported Python",
        "Check virtual environment",
        "Upgrade pip tools",
        "Install PaddlePaddle",
        "Install PaddleOCR and dependencies",
        "Install PP-StructureV3 dependencies",
        "Verify installation"
    )
    $phaseTotal = $phaseNames.Count
    $phaseCounter = 0

    Start-InstallPhase -Name "Prepare workspace" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    Write-Host $ProjectRoot

    Write-InstallSubProgress -Activity "Prepare workspace" -Status "Configure Paddle environment" -PercentComplete 15
    Write-Host "PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=$env:PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK" -ForegroundColor Green
    if ($script:RequireGpu) {
        Write-Host "GPU-only install mode: enabled (CPU fallback disabled)" -ForegroundColor Yellow
    }

    Write-InstallSubProgress -Activity "Prepare workspace" -Status "Import bundled model cache" -PercentComplete 45
    Import-BundledModelCache -ProjectRoot $ProjectRoot
    Write-InstallSubProgress -Activity "Prepare workspace" -Status "Detect bundled wheelhouse" -PercentComplete 75
    Initialize-BundledWheelhouse -ProjectRoot $ProjectRoot
    Finish-InstallPhase -Name "Prepare workspace" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    $VenvPython = Join-Path $ProjectRoot "$VenvDir\Scripts\python.exe"
    $ExistingVenvBasePython = $null
    if (Test-Path $VenvPython) {
        $ExistingVenvBasePython = Get-VenvConfigValue -VenvPython $VenvPython -Key "executable"
        if ((-not $ExistingVenvBasePython) -or (-not (Test-Path $ExistingVenvBasePython))) {
            $ExistingVenvHome = Get-VenvConfigValue -VenvPython $VenvPython -Key "home"
            if ($ExistingVenvHome) {
                $ExistingVenvCandidate = Join-Path $ExistingVenvHome "python.exe"
                if (Test-Path $ExistingVenvCandidate) {
                    $ExistingVenvBasePython = $ExistingVenvCandidate
                }
            }
        }
    }

    Start-InstallPhase -Name "Detect supported Python" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    $PreferredPythonVersion = Get-PreferredPythonVersion
    $script:PreferredPythonVersionForManual = if ($PreferredPythonVersion) { $PreferredPythonVersion } else { "3.13" }
    $PythonExe = $null
    if ($ExistingVenvBasePython -and (Test-Path $ExistingVenvBasePython)) {
        $PythonExe = $ExistingVenvBasePython
        Write-Host "Detected reusable venv base Python: $PythonExe" -ForegroundColor Green
    }

    if (-not $PythonExe) {
        $PythonExe = Find-SupportedPython -PreferredVersion $PreferredPythonVersion
    }
    $DetectedPythonVersion = if ($PythonExe) { Get-PythonMajorMinor -PythonExe $PythonExe } else { $null }

    if ($PreferredPythonVersion -and $PythonExe -and $DetectedPythonVersion -and $DetectedPythonVersion -ne $PreferredPythonVersion) {
        Write-Host "Bundled wheels prefer Python $PreferredPythonVersion. Trying to install that version via winget before continuing..." -ForegroundColor Yellow
        try {
            Install-PythonViaWinget -PreferredVersion $PreferredPythonVersion
            $PreferredPythonExe = Find-SupportedPython -PreferredVersion $PreferredPythonVersion
            if ($PreferredPythonExe) {
                $PythonExe = $PreferredPythonExe
            }
        }
        catch {
            Write-Host "Automatic install of Python $PreferredPythonVersion failed. Continuing with detected Python $DetectedPythonVersion." -ForegroundColor Yellow
        }
    }

    if (-not $PythonExe) {
        Install-PythonViaWinget -PreferredVersion $PreferredPythonVersion
        $PythonExe = Find-SupportedPython -PreferredVersion $PreferredPythonVersion
    }

    if (-not $PythonExe) {
        throw "No supported Python found after auto-install. Please install 64-bit Python 3.13 manually."
    }

    Write-Host "Detected system Python: $PythonExe" -ForegroundColor Green
    $script:SystemPythonForManual = $PythonExe
    $script:InstallStageStatus.python = $true
    Warn-IfBundledWheelhousePythonMismatch -PythonExe $PythonExe
    Finish-InstallPhase -Name "Detect supported Python" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    $VenvPython = Join-Path $ProjectRoot "$VenvDir\Scripts\python.exe"

    Start-InstallPhase -Name "Check virtual environment" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    if (Test-VenvReusable -VenvPython $VenvPython -SystemPythonExe $PythonExe -StrictMatch:$StrictVenvPythonMatch) {
        Write-Host "Reusable virtual environment detected. Skipping rebuild." -ForegroundColor Green
    } else {
        Recreate-Venv -PythonExe $PythonExe -VenvPath (Join-Path $ProjectRoot $VenvDir)
    }

    $VenvPython = Join-Path $ProjectRoot "$VenvDir\Scripts\python.exe"
    if (-not (Test-Path $VenvPython)) {
        throw "Virtual environment Python not found: $VenvPython"
    }

    Write-Host "Using venv Python: $VenvPython" -ForegroundColor Green
    $script:InstallStageStatus.venv = $true
    Finish-InstallPhase -Name "Check virtual environment" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-InstallPhase -Name "Upgrade pip tools" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    Upgrade-PackagingTools -PythonExe $VenvPython
    $script:InstallStageStatus.packaging = $true
    Finish-InstallPhase -Name "Upgrade pip tools" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-InstallPhase -Name "Install PaddlePaddle" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    $FinalMode = Ensure-PaddleInstalled -PythonExe $VenvPython -DesiredMode $Mode -CudaVersion $Cuda
    $script:InstallStageStatus.paddle = $true
    Write-Host "Final Paddle mode: $FinalMode" -ForegroundColor Green
    Finish-InstallPhase -Name "Install PaddlePaddle" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-InstallPhase -Name "Install PaddleOCR and dependencies" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    Ensure-OCRDependenciesInstalled -PythonExe $VenvPython
    $script:InstallStageStatus.ocr = $true
    Finish-InstallPhase -Name "Install PaddleOCR and dependencies" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-InstallPhase -Name "Install PP-StructureV3 dependencies" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    $FinalMode = Ensure-StructureDependenciesInstalled -PythonExe $VenvPython -DesiredMode $FinalMode -CudaVersion $Cuda
    $script:InstallStageStatus.structure = $true
    Finish-InstallPhase -Name "Install PP-StructureV3 dependencies" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-InstallPhase -Name "Verify installation" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    Verify-Installation -PythonExe $VenvPython -CheckStructure:$true
    $script:InstallStageStatus.verify = $true
    Finish-InstallPhase -Name "Verify installation" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    $InstalledSummary = $null
    try {
        $InstalledSummary = Get-InstalledComponentSummary -PythonExe $VenvPython -FinalMode $FinalMode
    }
    catch {
        Write-Host "Installed package summary could not be collected automatically." -ForegroundColor Yellow
        Write-Host $_.Exception.Message -ForegroundColor Yellow
    }

    Write-Host "Installation completed successfully." -ForegroundColor Green
    $SharedLauncherConfigPath = Register-SharedLauncherRoot -ProjectRoot $ProjectRoot
    Write-Host "Shared OCR home registered: $ProjectRoot" -ForegroundColor Green
    Write-Host "Shared OCR home file: $SharedLauncherConfigPath" -ForegroundColor Green
    Write-Host "Log file: $LogPath" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Installed components:" -ForegroundColor Cyan
    Write-Host "Python          : $(if ($InstalledSummary) { $InstalledSummary.python } else { '(not detected)' })" -ForegroundColor Green
    Write-Host "Virtual env     : $VenvPython" -ForegroundColor Green
    Write-Host "GPU required    : $(if ($script:RequireGpu) { 'YES' } else { 'NO' })" -ForegroundColor Green
    Write-Host "Paddle mode     : $(if ($InstalledSummary) { $InstalledSummary.mode } else { $FinalMode })" -ForegroundColor Green
    Write-Host "PaddlePaddle    : $(if ($InstalledSummary -and $InstalledSummary.paddle) { $InstalledSummary.paddle } else { '(not detected)' })" -ForegroundColor Green
    Write-Host "PaddleOCR       : $(if ($InstalledSummary -and $InstalledSummary.paddleocr) { $InstalledSummary.paddleocr } else { '(not detected)' })" -ForegroundColor Green
    Write-Host "PaddleX         : $(if ($InstalledSummary -and $InstalledSummary.paddlex) { $InstalledSummary.paddlex } else { '(not detected)' })" -ForegroundColor Green
    Write-Host "PyMuPDF         : $(if ($InstalledSummary -and $InstalledSummary.pymupdf) { $InstalledSummary.pymupdf } else { '(not detected)' })" -ForegroundColor Green
    Write-Host "PP-OCRv5        : READY" -ForegroundColor Green
    Write-Host "PP-StructureV3  : READY" -ForegroundColor Green

    try { Stop-Transcript | Out-Null } catch {}

    Write-Progress -Id 1 -Activity "Installing OCR environment" -Status "Completed" -PercentComplete 100 -CurrentOperation $ProjectRoot
    Write-Progress -Id 2 -Activity "Installing OCR environment" -Completed
    Write-Step "Done"
    Pause-And-Exit 0
}
catch {
    Write-Progress -Id 2 -Activity "Installing OCR environment" -Completed
    Write-Progress -Id 1 -Activity "Installing OCR environment" -Completed
    Write-Host ""
    Write-Host "INSTALL FAILED" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    if ($_.ScriptStackTrace) {
        Write-Host ""
        Write-Host "Script stack trace:" -ForegroundColor Yellow
        Write-Host $_.ScriptStackTrace
    }

    Write-ManualRecoveryChecklist -Reason $_.Exception.Message

    try { Stop-Transcript | Out-Null } catch {}

    Write-Host ""
    Write-Host "Check log file: $LogPath" -ForegroundColor Yellow
    Pause-And-Exit 1
}
