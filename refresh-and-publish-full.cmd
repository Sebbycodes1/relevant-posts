@echo off
title Full refresh and publish Relevant Posts
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "scripts\refresh-signal-desk.ps1" -Publish
if errorlevel 1 (
  echo.
  echo The public dashboard was not changed. Review the message above.
  pause
  exit /b 1
)
echo.
echo The full edition is now on the shared GitHub link.
pause
