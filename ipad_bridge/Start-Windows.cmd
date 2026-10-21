@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-windows.ps1"
set "launcher_result=%errorlevel%"
if not "%launcher_result%"=="0" pause
exit /b %launcher_result%
