@echo off
title Balanced refresh and publish Relevant Posts
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "scripts\refresh-signal-desk.ps1" -Balanced -MaxXaiSpendUsd 4.00 -MaxXaiRequests 16 -Publish
if errorlevel 1 (
  echo.
  echo The public dashboard was not changed. Review the message above.
  pause
  exit /b 1
)
echo.
echo The balanced edition is now on the shared GitHub link.
pause
