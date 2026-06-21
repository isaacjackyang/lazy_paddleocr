[CmdletBinding()]
param(
    [string]$PythonExe = "",
    [string]$ScriptPath = ""
)

$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ToolsDir

if ([string]::IsNullOrWhiteSpace($PythonExe)) {
    $PythonExe = Join-Path $RepoRoot ".venv\Scripts\python.exe"
}

if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $ScriptPath = Join-Path $ToolsDir "run_ocr_gui.py"
}

if (-not (Test-Path -LiteralPath $PythonExe)) {
    throw "Python executable not found: $PythonExe. Run install_paddle_all.bat first."
}

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "GUI script not found: $ScriptPath"
}

Set-Location -LiteralPath $RepoRoot
& $PythonExe $ScriptPath
