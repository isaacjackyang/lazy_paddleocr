@echo off
setlocal

set "INSTALL_ROOT="
set "CONFIG_FILE="
set "LAUNCHER_SCRIPT="
set "TARGET_ROOT=%~dp0"

if defined PADDLE_OCR_HOME set "INSTALL_ROOT=%PADDLE_OCR_HOME%"
if not defined INSTALL_ROOT call :read_user_env_install_root
if not defined INSTALL_ROOT call :read_registry_install_root
if not defined INSTALL_ROOT call :resolve_config_file
if not defined INSTALL_ROOT if defined CONFIG_FILE call :read_install_root "%CONFIG_FILE%"
if "%TARGET_ROOT:~-1%"=="\" set "TARGET_ROOT=%TARGET_ROOT:~0,-1%"

if not defined INSTALL_ROOT goto :missing_config
call :resolve_launcher_script
if not defined LAUNCHER_SCRIPT goto :stale_config

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LAUNCHER_SCRIPT%" -Root "%TARGET_ROOT%" -NoRecursive %*
set "EXIT_CODE=%ERRORLEVEL%"
exit /b %EXIT_CODE%

:missing_config
echo Shared OCR home is not registered yet.
echo Run register_shared_ocr_home.cmd once from your main PaddleOCR folder.
echo Or set PADDLE_OCR_HOME before running this launcher.
pause
exit /b 1

:stale_config
echo Shared OCR home points to an invalid folder:
echo %INSTALL_ROOT%
echo Run register_shared_ocr_home.cmd again from your main PaddleOCR folder.
pause
exit /b 1

:read_user_env_install_root
for /f "tokens=2,*" %%I in ('reg query "HKCU\Environment" /v PADDLE_OCR_HOME 2^>nul ^| find /i "PADDLE_OCR_HOME"') do (
    if not defined INSTALL_ROOT set "INSTALL_ROOT=%%J"
)
exit /b 0

:read_registry_install_root
for /f "tokens=2,*" %%I in ('reg query "HKCU\Software\PaddleOCRLauncher" /v InstallRoot 2^>nul ^| find /i "InstallRoot"') do (
    if not defined INSTALL_ROOT set "INSTALL_ROOT=%%J"
)
exit /b 0

:resolve_config_file
if defined LOCALAPPDATA call :set_config_candidate "%LOCALAPPDATA%\PaddleOCRLauncher\shared_install_root.txt"
if not defined CONFIG_FILE if defined USERPROFILE call :set_config_candidate "%USERPROFILE%\AppData\Local\PaddleOCRLauncher\shared_install_root.txt"
if not defined CONFIG_FILE for /f "usebackq delims=" %%I in (`powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('LocalApplicationData')" 2^>nul`) do call :set_config_candidate "%%I\PaddleOCRLauncher\shared_install_root.txt"
exit /b 0

:set_config_candidate
if not defined CONFIG_FILE if exist "%~1" set "CONFIG_FILE=%~1"
exit /b 0

:read_install_root
for /f "usebackq delims=" %%I in ("%~1") do (
    if not defined INSTALL_ROOT set "INSTALL_ROOT=%%I"
)
exit /b 0

:resolve_launcher_script
if not defined LAUNCHER_SCRIPT if exist "%INSTALL_ROOT%\tools\start_ocr_launcher.ps1" set "LAUNCHER_SCRIPT=%INSTALL_ROOT%\tools\start_ocr_launcher.ps1"
if not defined LAUNCHER_SCRIPT if exist "%INSTALL_ROOT%\start_ocr_launcher.ps1" set "LAUNCHER_SCRIPT=%INSTALL_ROOT%\start_ocr_launcher.ps1"
exit /b 0
