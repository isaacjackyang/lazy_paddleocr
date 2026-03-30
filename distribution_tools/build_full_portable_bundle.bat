@echo off
setlocal
set SCRIPT_DIR=%~dp0
powershell.exe -ExecutionPolicy Bypass -File "%SCRIPT_DIR%build_portable_bundle.ps1" -IncludeModelCache -IncludeWheelhouse
set ERR=%ERRORLEVEL%
if not "%ERR%"=="0" (
  echo.
  echo Full portable bundle build failed with exit code %ERR%.
  pause
  exit /b %ERR%
)
