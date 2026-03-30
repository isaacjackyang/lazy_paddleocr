@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\merge_txt_by_serial.ps1" %*
endlocal
