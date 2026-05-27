param(
    [string]$OutputDir = ".\wheel",
    [switch]$IncludeCpuFallback = $false
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Write-Step($Message) {
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
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
    Write-Progress -Id 1 -Activity $Activity -Status $Status -PercentComplete $percent
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

function Get-VenvPython {
    param([string]$ProjectRoot)

    $venvPython = Join-Path $ProjectRoot ".venv\Scripts\python.exe"
    if (-not (Test-Path $venvPython)) {
        throw "Cannot build wheelhouse because venv Python was not found: $venvPython"
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

function Resolve-OutputDirectory {
    param(
        [string]$ProjectRoot,
        [string]$OutputDir
    )

    $resolved = $OutputDir
    if (-not [System.IO.Path]::IsPathRooted($resolved)) {
        $resolved = Join-Path $ProjectRoot $resolved
    }

    $resolved = [System.IO.Path]::GetFullPath($resolved)
    $projectRootFull = [System.IO.Path]::GetFullPath($ProjectRoot)
    if ($resolved -eq $projectRootFull) {
        throw "Refusing to use the project root itself as the wheel output directory."
    }

    return $resolved
}

function Export-Wheelhouse {
    param(
        [string]$ProjectRoot,
        [string]$OutputDirectory,
        [switch]$IncludeCpuFallback
    )

    $venvPython = Get-VenvPython -ProjectRoot $ProjectRoot

    Write-Step "Prepare output"
    if (Test-Path $OutputDirectory) {
        Write-Host "Removing existing output folder: $OutputDirectory" -ForegroundColor Yellow
        Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

    Write-Step "Detect Python version"
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

    Set-Content -Path (Join-Path $OutputDirectory "python-version.txt") -Value $pythonVersion -Encoding ASCII

    Write-Step "Collect installed packages"
    Write-SubProgress -Activity "Export wheelhouse" -Status "Collecting installed package list" -Current 1 -Total 3
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

    $lockPath = Join-Path $OutputDirectory "requirements-lock.txt"
    $packages | Set-Content -Path $lockPath -Encoding UTF8

    $paddlePackages = @($packages | Where-Object { $_ -match '^paddlepaddle(-gpu)?==' })
    $generalPackages = @($packages | Where-Object { $_ -notmatch '^paddlepaddle(-gpu)?==' })
    $gpuPackage = $packages | Where-Object { $_ -match '^paddlepaddle-gpu==' } | Select-Object -First 1
    $wheelhouseMode = if ($gpuPackage) {
        if ($IncludeCpuFallback) { "gpu-with-cpu-fallback" } else { "gpu-only" }
    } else {
        "cpu-only"
    }
    Set-Content -Path (Join-Path $OutputDirectory "wheelhouse-mode.txt") -Value $wheelhouseMode -Encoding ASCII

    Write-Step "Download wheel files"
    Write-Host "Exporting wheelhouse with $venvPython" -ForegroundColor Yellow
    Write-Host "Output directory: $OutputDirectory" -ForegroundColor Green
    Write-Host "Python version : $pythonVersion" -ForegroundColor Green
    Write-Host "Wheelhouse mode: $wheelhouseMode" -ForegroundColor Green

    Write-SubProgress -Activity "Export wheelhouse" -Status "Downloading general wheel files" -Current 2 -Total 3
    if ($generalPackages.Count -gt 0) {
        $generalDownload = Invoke-NativeProcess `
            -FilePath $venvPython `
            -Arguments (@("-m", "pip", "download", "--disable-pip-version-check", "--only-binary=:all:", "--dest", $OutputDirectory) + $generalPackages) `
            -EchoOutput
        if ($generalDownload.ExitCode -ne 0) {
            throw "Failed to export wheel files. Some non-Paddle packages may not have downloadable wheel files for this environment."
        }
    }

    if ($paddlePackages.Count -gt 0) {
        $gpuIndexTag = Get-PaddleGpuIndexTag -PythonExe $venvPython
        Write-Host "Paddle GPU index: $gpuIndexTag" -ForegroundColor Green

        foreach ($package in $paddlePackages) {
            if ($package -match '^paddlepaddle-gpu==') {
                $gpuDownload = Invoke-NativeProcess `
                    -FilePath $venvPython `
                    -Arguments @("-m", "pip", "download", "--disable-pip-version-check", "--only-binary=:all:", "--no-deps", "--dest", $OutputDirectory, "-i", "https://www.paddlepaddle.org.cn/packages/stable/$gpuIndexTag/", $package) `
                    -EchoOutput
                if ($gpuDownload.ExitCode -ne 0) {
                    throw "Failed to export $package from the official Paddle GPU index ($gpuIndexTag)."
                }
                continue
            }

            $cpuDownload = Invoke-NativeProcess `
                -FilePath $venvPython `
                -Arguments @("-m", "pip", "download", "--disable-pip-version-check", "--only-binary=:all:", "--no-deps", "--dest", $OutputDirectory, "-i", "https://www.paddlepaddle.org.cn/packages/stable/cpu/", $package) `
                -EchoOutput
            if ($cpuDownload.ExitCode -ne 0) {
                throw "Failed to export $package from the official Paddle CPU index."
            }
        }
    }

    if ($gpuPackage -and $IncludeCpuFallback) {
        Write-SubProgress -Activity "Export wheelhouse" -Status "Downloading CPU Paddle fallback wheel" -Current 3 -Total 3
        $fallbackDownload = Invoke-NativeProcess `
            -FilePath $venvPython `
            -Arguments @("-m", "pip", "download", "--disable-pip-version-check", "--only-binary=:all:", "--no-deps", "--dest", $OutputDirectory, "-i", "https://www.paddlepaddle.org.cn/packages/stable/cpu/", "paddlepaddle==3.3.0") `
            -EchoOutput
        if ($fallbackDownload.ExitCode -ne 0) {
            Write-Host "Warning: failed to download CPU Paddle fallback wheel." -ForegroundColor Yellow
            $global:LASTEXITCODE = 0
        }
    } else {
        Write-SubProgress -Activity "Export wheelhouse" -Status "Wheelhouse export complete" -Current 3 -Total 3
    }

    $wheelFiles = @(Get-ChildItem -LiteralPath $OutputDirectory -Filter *.whl -File -ErrorAction SilentlyContinue)
    $wheelCount = $wheelFiles.Count
    $wheelBytes = ($wheelFiles | Measure-Object -Property Length -Sum).Sum

    Write-Progress -Id 1 -Activity "Export wheelhouse" -Completed
    Write-Step "Done"
    Write-Host "Wheelhouse created successfully." -ForegroundColor Green
    Write-Host "Output directory : $OutputDirectory" -ForegroundColor Green
    Write-Host "Python version   : $pythonVersion" -ForegroundColor Green
    Write-Host "Wheelhouse mode  : $wheelhouseMode" -ForegroundColor Green
    Write-Host "Wheel files      : $wheelCount" -ForegroundColor Green
    Write-Host ("Total size       : {0:N2} GB" -f ($wheelBytes / 1GB)) -ForegroundColor Green
}

try {
    Write-Step "Resolve project root"
    $ProjectRoot = Get-ProjectRoot
    Set-Location $ProjectRoot
    Write-Host $ProjectRoot

    $ResolvedOutputDir = Resolve-OutputDirectory -ProjectRoot $ProjectRoot -OutputDir $OutputDir
    Export-Wheelhouse -ProjectRoot $ProjectRoot -OutputDirectory $ResolvedOutputDir -IncludeCpuFallback:$IncludeCpuFallback
}
catch {
    Write-Progress -Id 1 -Activity "Export wheelhouse" -Completed
    Write-Host ""
    Write-Host "WHEELHOUSE BUILD FAILED" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    if ($_.ScriptStackTrace) {
        Write-Host ""
        Write-Host "Script stack trace:" -ForegroundColor Yellow
        Write-Host $_.ScriptStackTrace
    }

    exit 1
}
