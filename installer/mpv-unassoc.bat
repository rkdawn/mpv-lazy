@echo off
setlocal

chcp 936 >nul

rem ============================================
rem  mpv-lazy 取消格式关联
rem  移除本工具建立的关联并还原原默认程序
rem ============================================

where pwsh >nul 2>&1
if %errorlevel% == 0 (
	pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0mpv-unassoc.ps1"
) else (
	powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mpv-unassoc.ps1"
)

pause
endlocal
