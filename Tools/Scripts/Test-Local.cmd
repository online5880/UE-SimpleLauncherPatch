@echo off
where pwsh.exe >nul 2>nul || (
  echo PowerShell 7 ^(pwsh.exe^) is required.
  pause
  exit /b 1
)
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-Local.ps1"
if errorlevel 1 pause
