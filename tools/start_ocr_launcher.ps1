param(
    [string]$PythonExe = ".\.venv\Scripts\python.exe",
    [string]$LauncherScript = ".\run_ocr_launcher.py",
    [string]$Root = "",
    [switch]$NoRecursive,
    [ValidateSet("Auto", "CPU", "GPU")]
    [string]$Device = "Auto",
    [int]$PdfDpi = 200,
    [switch]$KeepPdfImages,
    [string]$PdfImageDirname = "_pdf_pages",
    [string]$ImageExts = ".jpg,.jpeg,.png,.bmp,.tif,.tiff,.webp",
    [string]$PdfExts = ".pdf"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"

function Write-Step($msg) {
    Write-Host ""
    Write-Host "=== $msg ===" -ForegroundColor Cyan
}

function Start-LauncherPhase {
    param(
        [string]$Name,
        [ref]$PhaseCounter,
        [int]$PhaseTotal
    )

    $PhaseCounter.Value++
    $completedPhases = $PhaseCounter.Value - 1
    $percent = if ($PhaseTotal -le 0) { 0 } else { [int](($completedPhases / [double]$PhaseTotal) * 100) }

    Write-Step $Name
    Write-Progress -Id 1 -Activity "Starting OCR launcher" -Status "Step $($PhaseCounter.Value)/${PhaseTotal}: $Name" -PercentComplete $percent -CurrentOperation $Name
}

function Finish-LauncherPhase {
    param(
        [string]$Name,
        [int]$PhaseIndex,
        [int]$PhaseTotal
    )

    $percent = if ($PhaseTotal -le 0) { 100 } else { [int](($PhaseIndex / [double]$PhaseTotal) * 100) }
    Write-Progress -Id 1 -Activity "Starting OCR launcher" -Status "Completed: $Name" -PercentComplete $percent -CurrentOperation $Name
}

function Pause-And-Exit {
    param([int]$Code = 0)
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit $Code
}

function Get-ProjectRoot {
    if ($PSScriptRoot -and (Test-Path $PSScriptRoot)) {
        return $PSScriptRoot
    }

    $current = (Get-Location).Path
    if ($current -and (Test-Path $current)) {
        return $current
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

function Invoke-InteractiveNativeProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $Arguments `
        -Wait `
        -NoNewWindow `
        -PassThru

    $exitCode = if ($null -eq $process.ExitCode) { 0 } else { [int]$process.ExitCode }
    return [pscustomobject]@{
        ExitCode = $exitCode
    }
}

try {
    $phaseTotal = 4
    $phaseCounter = 0

    Start-LauncherPhase -Name "Resolve project root" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    $ProjectRoot = Get-ProjectRoot
    Set-Location $ProjectRoot
    Write-Host $ProjectRoot
    Finish-LauncherPhase -Name "Resolve project root" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    $ResolvedPythonExe = $PythonExe
    if (-not [System.IO.Path]::IsPathRooted($ResolvedPythonExe)) {
        $ResolvedPythonExe = Join-Path $ProjectRoot $ResolvedPythonExe
    }

    $ResolvedLauncherScript = $LauncherScript
    if (-not [System.IO.Path]::IsPathRooted($ResolvedLauncherScript)) {
        $ResolvedLauncherScript = Join-Path $ProjectRoot $ResolvedLauncherScript
    }

    Start-LauncherPhase -Name "Check launcher files" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    if (-not (Test-Path $ResolvedPythonExe)) {
        throw "Python executable not found: $ResolvedPythonExe"
    }

    if (-not (Test-Path $ResolvedLauncherScript)) {
        throw "Launcher script not found: $ResolvedLauncherScript"
    }

    $RecursiveEnabled = -not $NoRecursive
    Finish-LauncherPhase -Name "Check launcher files" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-LauncherPhase -Name "Show settings" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    Write-Host "Python            : $ResolvedPythonExe"
    Write-Host "Launcher          : $ResolvedLauncherScript"
    Write-Host "Recursive         : $RecursiveEnabled"
    Write-Host "Device            : $Device"
    Write-Host "PDF DPI           : $PdfDpi"
    Write-Host "Keep PDF Images   : $KeepPdfImages"
    Write-Host "PDF Image Dirname : $PdfImageDirname"
    Write-Host "Image Exts        : $ImageExts"
    Write-Host "PDF Exts          : $PdfExts"
    Finish-LauncherPhase -Name "Show settings" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    $ArgsList = @()

    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        $ArgsList += "--root"
        $ArgsList += $Root
    }

    if ($RecursiveEnabled) {
        $ArgsList += "--recursive"
    }

    $ArgsList += "--device"
    $ArgsList += $Device.ToLowerInvariant()

    $ArgsList += "--pdf-dpi"
    $ArgsList += "$PdfDpi"

    if ($KeepPdfImages) {
        $ArgsList += "--keep-pdf-images"
    }

    $ArgsList += "--pdf-image-dirname"
    $ArgsList += $PdfImageDirname

    $ArgsList += "--image-exts"
    $ArgsList += $ImageExts

    $ArgsList += "--pdf-exts"
    $ArgsList += $PdfExts

    Start-LauncherPhase -Name "Start OCR Launcher" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    Write-Host "Default behavior scans subfolders recursively." -ForegroundColor Yellow
    Write-Host "Use -NoRecursive if you only want the current folder." -ForegroundColor Yellow
    Write-Host "You will be asked to choose file types, mode, confidence threshold, and output format." -ForegroundColor Yellow
    Write-Host ""

    $launcherResult = Invoke-InteractiveNativeProcess `
        -FilePath $ResolvedPythonExe `
        -Arguments (@($ResolvedLauncherScript) + $ArgsList)

    if ($launcherResult.ExitCode -ne 0) {
        throw "Launcher execution failed. Exit Code = $($launcherResult.ExitCode)"
    }

    Finish-LauncherPhase -Name "Start OCR Launcher" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal
    Write-Progress -Id 1 -Activity "Starting OCR launcher" -Status "Completed" -PercentComplete 100 -CurrentOperation $ResolvedLauncherScript
    Write-Step "Done"
    Write-Host "OCR launcher finished successfully." -ForegroundColor Green
    Write-Progress -Id 1 -Activity "Starting OCR launcher" -Completed
    Pause-And-Exit 0
}
catch {
    Write-Progress -Id 1 -Activity "Starting OCR launcher" -Completed
    Write-Host ""
    Write-Host "LAUNCHER FAILED" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    if ($_.ScriptStackTrace) {
        Write-Host ""
        Write-Host "Script stack trace:" -ForegroundColor Yellow
        Write-Host $_.ScriptStackTrace
    }

    Pause-And-Exit 1
}
