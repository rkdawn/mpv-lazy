@echo off
cd /d "%~dp0"
where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-mpv.ps1" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-mpv.ps1" %*
)
echo.
pause
