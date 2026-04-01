[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$PythonExe = ".\.venv\Scripts\python.exe",
    [string]$LauncherScript = ".\tools\run_ocr_launcher.py",
    [string]$Root = "",
    [switch]$NoRecursive,
    [ValidateSet("Auto", "CPU", "GPU")]
    [string]$Device = "Auto",
    [int]$PdfDpi = 200,
    [switch]$KeepPdfImages,
    [string]$PdfImageDirname = "_pdf_pages",
    [string]$ImageExts = ".jpg,.jpeg,.png,.bmp,.tif,.tiff,.webp",
    [string]$PdfExts = ".pdf",
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs = @()
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

    $quotedArguments = @()
    foreach ($argument in $Arguments) {
        if ($null -eq $argument) {
            $quotedArguments += '""'
            continue
        }

        if ($argument -match '[\s"]') {
            $quotedArguments += '"' + ($argument -replace '"', '\"') + '"'
        }
        else {
            $quotedArguments += $argument
        }
    }

    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $quotedArguments `
        -Wait `
        -NoNewWindow `
        -PassThru

    $exitCode = if ($null -eq $process.ExitCode) { 0 } else { [int]$process.ExitCode }
    return [pscustomobject]@{
        ExitCode = $exitCode
    }
}

function Resolve-ScanRoot {
    param(
        [string]$ProjectRoot,
        [string]$ExplicitRoot,
        [string[]]$RemainingArguments
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitRoot)) {
        return (Resolve-Path $ExplicitRoot).Path
    }

    if (-not $RemainingArguments -or $RemainingArguments.Count -eq 0) {
        return ""
    }

    $rawCandidates = @()
    $joined = ($RemainingArguments -join " ").Trim()
    if ($joined) {
        $rawCandidates += $joined
    }
    foreach ($item in $RemainingArguments) {
        if (-not [string]::IsNullOrWhiteSpace($item) -and ($rawCandidates -notcontains $item)) {
            $rawCandidates += $item
        }
    }

    foreach ($candidate in $rawCandidates) {
        $resolved = $null

        if (Test-Path -LiteralPath $candidate) {
            $resolved = (Resolve-Path -LiteralPath $candidate).Path
        }
        elseif (Test-Path -LiteralPath (Join-Path $ProjectRoot $candidate)) {
            $resolved = (Resolve-Path -LiteralPath (Join-Path $ProjectRoot $candidate)).Path
        }

        if (-not $resolved) {
            continue
        }

        $item = Get-Item -LiteralPath $resolved
        if ($item.PSIsContainer) {
            return $item.FullName
        }

        return $item.DirectoryName
    }

    Write-Host "Ignoring extra launcher arguments: $($RemainingArguments -join ' ')" -ForegroundColor Yellow
    return ""
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
    $ResolvedRoot = Resolve-ScanRoot -ProjectRoot $ProjectRoot -ExplicitRoot $Root -RemainingArguments $RemainingArgs
    $SharedLauncherConfigPath = Register-SharedLauncherRoot -ProjectRoot $ProjectRoot
    Write-Host "Shared OCR Home   : $ProjectRoot"
    Write-Host "Shared Home File  : $SharedLauncherConfigPath"
    Finish-LauncherPhase -Name "Check launcher files" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-LauncherPhase -Name "Show settings" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    Write-Host "Python            : $ResolvedPythonExe"
    Write-Host "Launcher          : $ResolvedLauncherScript"
    Write-Host "Scan Root         : $(if ($ResolvedRoot) { $ResolvedRoot } else { $ProjectRoot })"
    Write-Host "Recursive         : $RecursiveEnabled"
    Write-Host "Device            : $Device"
    Write-Host "PDF DPI           : $PdfDpi"
    Write-Host "Keep PDF Images   : $KeepPdfImages"
    Write-Host "PDF Image Dirname : $PdfImageDirname"
    Write-Host "Image Exts        : $ImageExts"
    Write-Host "PDF Exts          : $PdfExts"
    Finish-LauncherPhase -Name "Show settings" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    $ArgsList = @()

    if (-not [string]::IsNullOrWhiteSpace($ResolvedRoot)) {
        $ArgsList += "--root"
        $ArgsList += $ResolvedRoot
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
    Write-Host "You will be asked to choose file types, mode, confidence threshold, TXT output layout, and output format." -ForegroundColor Yellow
    Write-Host "Interactive prompts will appear below." -ForegroundColor Yellow
    Write-Host ""
    Write-Progress -Id 1 -Activity "Starting OCR launcher" -Completed

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
