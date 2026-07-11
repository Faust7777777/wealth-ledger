@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Finwealth.ps1" %*
exit /b %ERRORLEVEL%
