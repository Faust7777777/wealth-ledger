@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Finwealth.ps1" %*
exit /b %errorlevel%
