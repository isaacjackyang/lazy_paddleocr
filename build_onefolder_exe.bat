@echo off
setlocal
set SCRIPT_DIR=%~dp0
powershell.exe -ExecutionPolicy Bypass -File "%SCRIPT_DIR%build_onefolder_exe.ps1"
set ERR=%ERRORLEVEL%
if not "%ERR%"=="0" (
  echo.
  echo One-folder exe build failed with exit code %ERR%.
  pause
  exit /b %ERR%
)
