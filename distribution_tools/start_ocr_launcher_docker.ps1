param(
    [string]$ImageTag = "paddleocr-launcher:cpu",
    [string]$DockerDataDir = ".\.docker_data",
    [string]$Root = "",
    [switch]$NoRecursive,
    [int]$PdfDpi = 200,
    [switch]$KeepPdfImages,
    [string]$PdfImageDirname = "_pdf_pages",
    [string]$ImageExts = ".jpg,.jpeg,.png,.bmp,.tif,.tiff,.webp",
    [string]$PdfExts = ".pdf"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"

function Write-Step($Message) {
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
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
    Write-Progress -Id 1 -Activity "Starting Docker OCR launcher" -Status "Step $($PhaseCounter.Value)/${PhaseTotal}: $Name" -PercentComplete $percent -CurrentOperation $Name
}

function Finish-LauncherPhase {
    param(
        [string]$Name,
        [int]$PhaseIndex,
        [int]$PhaseTotal
    )

    $percent = if ($PhaseTotal -le 0) { 100 } else { [int](($PhaseIndex / [double]$PhaseTotal) * 100) }
    Write-Progress -Id 1 -Activity "Starting Docker OCR launcher" -Status "Completed: $Name" -PercentComplete $percent -CurrentOperation $Name
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

function Resolve-PathOrProjectChild {
    param(
        [string]$ProjectRoot,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($Value)) {
        return $Value
    }

    return (Join-Path $ProjectRoot $Value)
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

function Get-DockerCliPath {
    $command = Get-Command docker.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Source -and (Test-Path $command.Source)) {
        return $command.Source
    }

    $candidates = @(
        "C:\Program Files\Docker\Docker\resources\bin\docker.exe",
        (Join-Path $env:ProgramFiles "Docker\Docker\resources\bin\docker.exe")
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    return $null
}

function Wait-ForDockerReady {
    param([string]$DockerCli)

    $result = Invoke-NativeProcess -FilePath $DockerCli -Arguments @("version", "--format", "{{.Server.Version}}")
    if ($result.ExitCode -ne 0) {
        throw "Docker engine is not ready. Start Docker Desktop first, or run distribution_tools\install_paddle_ocr_docker.ps1."
    }

    $version = ($result.StdOut | Select-Object -Last 1).Trim()
    if (-not $version) {
        throw "Docker engine responded unexpectedly."
    }

    return $version
}

function Assert-LinuxContainerMode {
    param([string]$DockerCli)

    $result = Invoke-NativeProcess -FilePath $DockerCli -Arguments @("info", "--format", "{{.OSType}}")
    if ($result.ExitCode -ne 0) {
        throw "Unable to query Docker container mode."
    }

    $osType = ($result.StdOut | Select-Object -Last 1).Trim().ToLowerInvariant()
    if ($osType -ne "linux") {
        throw "Docker is not in Linux container mode. Switch Docker Desktop to Linux containers and rerun this script."
    }
}

function Test-DockerImageExists {
    param(
        [string]$DockerCli,
        [string]$Tag
    )

    $result = Invoke-NativeProcess -FilePath $DockerCli -Arguments @("image", "inspect", $Tag)
    return ($result.ExitCode -eq 0)
}

function Ensure-DockerDataDirectories {
    param([string]$DockerDataRoot)

    New-Item -ItemType Directory -Path $DockerDataRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $DockerDataRoot "paddlex\official_models") -Force | Out-Null
}

function Get-RelativeChildPath {
    param(
        [string]$ParentPath,
        [string]$ChildPath
    )

    $parentFull = [System.IO.Path]::GetFullPath($ParentPath)
    $childFull = [System.IO.Path]::GetFullPath($ChildPath)

    if (-not $parentFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $parentFull += [System.IO.Path]::DirectorySeparatorChar
    }

    if ($childFull.StartsWith($parentFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $childFull.Substring($parentFull.Length)
    }

    return $null
}

try {
    $phaseTotal = 4
    $phaseCounter = 0

    Start-LauncherPhase -Name "Resolve project root" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    $projectRoot = Get-ProjectRoot
    Set-Location $projectRoot
    $resolvedDockerDataDir = Resolve-PathOrProjectChild -ProjectRoot $projectRoot -Value $DockerDataDir
    Ensure-DockerDataDirectories -DockerDataRoot $resolvedDockerDataDir
    Finish-LauncherPhase -Name "Resolve project root" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-LauncherPhase -Name "Check Docker runtime" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    $dockerCli = Get-DockerCliPath
    if (-not $dockerCli) {
        throw "docker.exe was not found. Run distribution_tools\install_paddle_ocr_docker.ps1 first."
    }

    $dockerVersion = Wait-ForDockerReady -DockerCli $dockerCli
    Assert-LinuxContainerMode -DockerCli $dockerCli

    if (-not (Test-DockerImageExists -DockerCli $dockerCli -Tag $ImageTag)) {
        throw "Docker image not found: $ImageTag. Run distribution_tools\install_paddle_ocr_docker.ps1 first."
    }

    $recursiveEnabled = -not $NoRecursive
    Finish-LauncherPhase -Name "Check Docker runtime" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-LauncherPhase -Name "Show settings" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    Write-Host "Docker CLI         : $dockerCli"
    Write-Host "Docker server      : $dockerVersion"
    Write-Host "Image tag          : $ImageTag"
    Write-Host "Project root       : $projectRoot"
    Write-Host "Docker data dir    : $resolvedDockerDataDir"
    Write-Host "Recursive          : $recursiveEnabled"
    Write-Host "PDF DPI            : $PdfDpi"
    Write-Host "Keep PDF Images    : $KeepPdfImages"
    Write-Host "PDF Image Dirname  : $PdfImageDirname"
    Write-Host "Image Exts         : $ImageExts"
    Write-Host "PDF Exts           : $PdfExts"
    Finish-LauncherPhase -Name "Show settings" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    $containerRoot = $null
    $extraMountArgs = @()
    $resolvedRoot = Resolve-PathOrProjectChild -ProjectRoot $projectRoot -Value $Root
    if ($resolvedRoot) {
        $relativeChild = Get-RelativeChildPath -ParentPath $projectRoot -ChildPath $resolvedRoot
        if ($null -ne $relativeChild) {
            $containerRoot = "/workspace/" + ($relativeChild -replace "\\", "/")
        } else {
            $extraMountArgs += @("-v", "${resolvedRoot}:/scan_root")
            $containerRoot = "/scan_root"
        }
    }

    $argsList = @()
    if ($containerRoot) {
        $argsList += "--root"
        $argsList += $containerRoot
    }

    if ($recursiveEnabled) {
        $argsList += "--recursive"
    }

    $argsList += "--pdf-dpi"
    $argsList += "$PdfDpi"

    if ($KeepPdfImages) {
        $argsList += "--keep-pdf-images"
    }

    $argsList += "--pdf-image-dirname"
    $argsList += $PdfImageDirname
    $argsList += "--image-exts"
    $argsList += $ImageExts
    $argsList += "--pdf-exts"
    $argsList += $PdfExts

    Start-LauncherPhase -Name "Start Docker OCR Launcher" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    Write-Host "Default behavior scans subfolders recursively." -ForegroundColor Yellow
    Write-Host "Use -NoRecursive if you only want the current folder." -ForegroundColor Yellow
    Write-Host "You will be asked to choose file types, mode, confidence threshold, and output format." -ForegroundColor Yellow
    Write-Host ""

    $dockerRunArgs = @(
        "run",
        "--rm",
        "-it",
        "-e", "PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=True",
        "-e", "PADDLE_PDX_ENABLE_MKLDNN_BYDEFAULT=False",
        "-e", "PYTHONUNBUFFERED=1",
        "-v", "${projectRoot}:/workspace",
        "-v", "${resolvedDockerDataDir}\paddlex:/root/.paddlex",
        "-w", "/workspace"
) + $extraMountArgs + @(
    $ImageTag,
    "python",
    "tools/run_ocr_launcher.py"
) + $argsList

    $launcherResult = Invoke-InteractiveNativeProcess -FilePath $dockerCli -Arguments $dockerRunArgs
    if ($launcherResult.ExitCode -ne 0) {
        throw "Docker launcher execution failed. Exit Code = $($launcherResult.ExitCode)"
    }

    Finish-LauncherPhase -Name "Start Docker OCR Launcher" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal
    Write-Progress -Id 1 -Activity "Starting Docker OCR launcher" -Status "Completed" -PercentComplete 100 -CurrentOperation $ImageTag
    Write-Step "Done"
    Write-Host "Docker OCR launcher finished successfully." -ForegroundColor Green
    Write-Progress -Id 1 -Activity "Starting Docker OCR launcher" -Completed
    Pause-And-Exit 0
}
catch {
    Write-Progress -Id 1 -Activity "Starting Docker OCR launcher" -Completed
    Write-Host ""
    Write-Host "DOCKER LAUNCHER FAILED" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    if ($_.ScriptStackTrace) {
        Write-Host ""
        Write-Host "Script stack trace:" -ForegroundColor Yellow
        Write-Host $_.ScriptStackTrace
    }

    Pause-And-Exit 1
}
