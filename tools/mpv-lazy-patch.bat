@echo off
cd /d "%~dp0"
where pwsh >nul 2>nul
if %errorlevel%==0 (
  pwsh -ExecutionPolicy Bypass -NoProfile -File "%~dp0mpv-lazy-patch.ps1"
) else (
  powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0mpv-lazy-patch.ps1"
)
