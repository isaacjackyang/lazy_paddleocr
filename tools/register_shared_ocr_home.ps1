$ErrorActionPreference = "Stop"

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

    $launcherScript = Join-Path $Path "tools\start_ocr_launcher.ps1"
    $runnerScript = Join-Path $Path "tools\run_ocr_launcher.py"
    $registerScript = Join-Path $Path "tools\register_shared_ocr_home.ps1"

    return (Test-Path $launcherScript) -and (Test-Path $runnerScript) -and (Test-Path $registerScript)
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

try {
    $projectRoot = Get-ProjectRoot
    $pythonExe = Join-Path $projectRoot ".venv\Scripts\python.exe"
    $launcherScript = Join-Path $projectRoot "tools\start_ocr_launcher.ps1"
    $runnerScript = Join-Path $projectRoot "tools\run_ocr_launcher.py"

    if (-not (Test-Path $pythonExe)) {
        throw "Shared OCR Python was not found: $pythonExe"
    }

    if (-not (Test-Path $launcherScript)) {
        throw "Shared OCR launcher was not found: $launcherScript"
    }

    if (-not (Test-Path $runnerScript)) {
        throw "Shared OCR runner was not found: $runnerScript"
    }

    $configPath = Register-SharedLauncherRoot -ProjectRoot $projectRoot
    Write-Host ""
    Write-Host "Shared OCR home registered." -ForegroundColor Green
    Write-Host "Home   : $projectRoot"
    Write-Host "Config : $configPath"
    Write-Host "Env    : PADDLE_OCR_HOME (User)"
    Write-Host ""
    Write-Host "You can now copy 'ocr_here.bat' next to your documents." -ForegroundColor Yellow
    Write-Host "Use '-NoRecursive' when you only want the current folder." -ForegroundColor Yellow
    Pause-And-Exit 0
}
catch {
    Write-Host ""
    Write-Host "REGISTER FAILED" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Pause-And-Exit 1
}
