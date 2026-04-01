param(
    [string]$ImageTag = "paddleocr-launcher:cpu",
    [string]$DockerfilePath = ".\Dockerfile",
    [string]$DockerDataDir = ".\.docker_data",
    [int]$DockerReadyTimeoutSeconds = 300,
    [switch]$ForceRebuild = $false,
    [switch]$AutoStart = $true,
    [switch]$NoAutoStart = $false
)

if ($NoAutoStart) {
    $AutoStart = $false
}

$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"

function Write-Step($Message) {
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
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
    Write-Progress -Id 1 -Activity "Installing Docker OCR environment" -Status "Step $($PhaseCounter.Value)/${PhaseTotal}: $Name" -PercentComplete $percent -CurrentOperation $Name
}

function Finish-InstallPhase {
    param(
        [string]$Name,
        [int]$PhaseIndex,
        [int]$PhaseTotal
    )

    Write-Progress -Id 2 -Activity $Name -Completed
    $percent = if ($PhaseTotal -le 0) { 100 } else { [int](($PhaseIndex / [double]$PhaseTotal) * 100) }
    Write-Progress -Id 1 -Activity "Installing Docker OCR environment" -Status "Completed: $Name" -PercentComplete $percent -CurrentOperation $Name
}

function Write-InstallSubProgress {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete = 0
    )

    Write-Progress -Id 2 -ParentId 1 -Activity $Activity -Status $Status -PercentComplete $PercentComplete
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

function Get-DockerDesktopExePath {
    $candidates = @(
        "C:\Program Files\Docker\Docker\Docker Desktop.exe",
        (Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe")
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    return $null
}

function Ensure-WingetAvailable {
    $command = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "winget was not found. Please install Docker Desktop manually, then rerun this script."
    }

    return $command.Source
}

function Ensure-DockerDesktopInstalled {
    $dockerCli = Get-DockerCliPath
    if ($dockerCli) {
        Write-Host "Docker CLI is already installed." -ForegroundColor Green
        return $dockerCli
    }

    $wingetExe = Ensure-WingetAvailable
    Write-Host "Installing Docker Desktop with winget..." -ForegroundColor Yellow

    $result = Invoke-NativeProcess `
        -FilePath $wingetExe `
        -Arguments @(
            "install",
            "-e",
            "--id", "Docker.DockerDesktop",
            "--accept-source-agreements",
            "--accept-package-agreements"
        ) `
        -EchoOutput

    if ($result.ExitCode -ne 0) {
        throw "Docker Desktop installation failed."
    }

    $dockerCli = Get-DockerCliPath
    if (-not $dockerCli) {
        throw "Docker Desktop was installed, but docker.exe was not found yet. Close this window and rerun the script."
    }

    return $dockerCli
}

function Start-DockerDesktopIfNeeded {
    $desktopExe = Get-DockerDesktopExePath
    if (-not $desktopExe) {
        Write-Host "Docker Desktop executable not found. Assuming the Docker engine is managed elsewhere." -ForegroundColor Yellow
        return
    }

    $existing = Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Docker Desktop is already running." -ForegroundColor Green
        return
    }

    Write-Host "Starting Docker Desktop..." -ForegroundColor Yellow
    Start-Process -FilePath $desktopExe | Out-Null
}

function Wait-ForDockerReady {
    param(
        [string]$DockerCli,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $attempt = 0

    while ((Get-Date) -lt $deadline) {
        $attempt++
        $percent = [Math]::Min(99, [int](($attempt * 5 / [double][Math]::Max($TimeoutSeconds, 1)) * 100))
        Write-InstallSubProgress -Activity "Wait for Docker engine" -Status "Checking Docker daemon" -PercentComplete $percent

        $result = Invoke-NativeProcess -FilePath $DockerCli -Arguments @("version", "--format", "{{.Server.Version}}")
        if ($result.ExitCode -eq 0) {
            $version = ($result.StdOut | Select-Object -Last 1).Trim()
            if ($version) {
                return $version
            }
        }

        Start-Sleep -Seconds 5
    }

    throw "Docker engine is not ready. Start Docker Desktop, wait for it to finish initializing, then rerun this script."
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

function Ensure-DockerDataDirectories {
    param([string]$DockerDataRoot)

    New-Item -ItemType Directory -Path $DockerDataRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $DockerDataRoot "paddlex\official_models") -Force | Out-Null
}

function Test-DockerImageExists {
    param(
        [string]$DockerCli,
        [string]$Tag
    )

    $result = Invoke-NativeProcess -FilePath $DockerCli -Arguments @("image", "inspect", $Tag)
    return ($result.ExitCode -eq 0)
}

function Build-DockerImage {
    param(
        [string]$DockerCli,
        [string]$ProjectRoot,
        [string]$ResolvedDockerfilePath,
        [string]$Tag
    )

    $result = Invoke-NativeProcess `
        -FilePath $DockerCli `
        -Arguments @("build", "--pull", "-t", $Tag, "-f", $ResolvedDockerfilePath, $ProjectRoot) `
        -EchoOutput

    if ($result.ExitCode -ne 0) {
        throw "Docker image build failed."
    }
}

try {
    $phaseNames = @(
        "Resolve project root",
        "Install Docker Desktop if needed",
        "Start Docker and wait for engine",
        "Prepare Docker data folders",
        "Build Docker image"
    )
    if ($AutoStart) {
        $phaseNames += "Start Docker OCR launcher"
    }
    $phaseTotal = $phaseNames.Count
    $phaseCounter = 0

    Start-InstallPhase -Name "Resolve project root" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    $projectRoot = Get-ProjectRoot
    Set-Location $projectRoot

    $resolvedDockerfilePath = Resolve-PathOrProjectChild -ProjectRoot $projectRoot -Value $DockerfilePath
    if (-not $resolvedDockerfilePath -or -not (Test-Path $resolvedDockerfilePath)) {
        throw "Dockerfile not found: $resolvedDockerfilePath"
    }

    $resolvedDockerDataDir = Resolve-PathOrProjectChild -ProjectRoot $projectRoot -Value $DockerDataDir
    Finish-InstallPhase -Name "Resolve project root" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-InstallPhase -Name "Install Docker Desktop if needed" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    $dockerCli = Ensure-DockerDesktopInstalled
    Finish-InstallPhase -Name "Install Docker Desktop if needed" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-InstallPhase -Name "Start Docker and wait for engine" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    Start-DockerDesktopIfNeeded
    $dockerVersion = Wait-ForDockerReady -DockerCli $dockerCli -TimeoutSeconds $DockerReadyTimeoutSeconds
    Assert-LinuxContainerMode -DockerCli $dockerCli
    Write-Host "Docker server version: $dockerVersion" -ForegroundColor Green
    Finish-InstallPhase -Name "Start Docker and wait for engine" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-InstallPhase -Name "Prepare Docker data folders" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    Ensure-DockerDataDirectories -DockerDataRoot $resolvedDockerDataDir
    Write-Host "Docker data directory: $resolvedDockerDataDir" -ForegroundColor Green
    Finish-InstallPhase -Name "Prepare Docker data folders" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    Start-InstallPhase -Name "Build Docker image" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
    if ((-not $ForceRebuild) -and (Test-DockerImageExists -DockerCli $dockerCli -Tag $ImageTag)) {
        Write-Host "Docker image already exists. Skipping rebuild: $ImageTag" -ForegroundColor Green
    } else {
        Build-DockerImage -DockerCli $dockerCli -ProjectRoot $projectRoot -ResolvedDockerfilePath $resolvedDockerfilePath -Tag $ImageTag
    }
    Finish-InstallPhase -Name "Build Docker image" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal

    if ($AutoStart) {
        Start-InstallPhase -Name "Start Docker OCR launcher" -PhaseCounter ([ref]$phaseCounter) -PhaseTotal $phaseTotal
        $startScript = Join-Path $projectRoot "start_ocr_launcher_docker.ps1"
        if (-not (Test-Path $startScript)) {
            throw "Docker launcher script not found: $startScript"
        }

        $startResult = Invoke-InteractiveNativeProcess `
            -FilePath "powershell.exe" `
            -Arguments @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", $startScript,
                "-ImageTag", $ImageTag,
                "-DockerDataDir", $resolvedDockerDataDir
            )

        if ($startResult.ExitCode -ne 0) {
            throw "Docker OCR launcher failed. Exit Code = $($startResult.ExitCode)"
        }

        Finish-InstallPhase -Name "Start Docker OCR launcher" -PhaseIndex $phaseCounter -PhaseTotal $phaseTotal
    }

    Write-Progress -Id 1 -Activity "Installing Docker OCR environment" -Status "Completed" -PercentComplete 100 -CurrentOperation $ImageTag
    Write-Step "Done"
    Write-Host "Docker OCR environment is ready." -ForegroundColor Green
    Write-Host "Image tag         : $ImageTag" -ForegroundColor Green
    Write-Host "Docker data dir   : $resolvedDockerDataDir" -ForegroundColor Green
    Write-Host "Docker server     : $dockerVersion" -ForegroundColor Green
    Write-Progress -Id 1 -Activity "Installing Docker OCR environment" -Completed
    Pause-And-Exit 0
}
catch {
    Write-Progress -Id 1 -Activity "Installing Docker OCR environment" -Completed
    Write-Host ""
    Write-Host "DOCKER INSTALL FAILED" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    if ($_.ScriptStackTrace) {
        Write-Host ""
        Write-Host "Script stack trace:" -ForegroundColor Yellow
        Write-Host $_.ScriptStackTrace
    }

    Pause-And-Exit 1
}
