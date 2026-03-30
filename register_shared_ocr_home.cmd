@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\register_shared_ocr_home.ps1" %*
endlocal
