@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" -Production -OpenBrowser
if errorlevel 1 (
  echo.
  echo DealSphere could not start. See .tools\web-error.log and .tools\postgres-error.log.
  pause
)
