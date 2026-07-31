@echo off
title Refresh and publish Relevant Posts
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "scripts\refresh-signal-desk.ps1" -Budget -MaxXaiSpendUsd 1.00 -MaxXaiRequests 8 -Publish
if errorlevel 1 (
  echo.
  echo The public dashboard was not changed. Review the message above.
  pause
  exit /b 1
)
echo.
echo The latest edition is now on the shared GitHub link.
pause
