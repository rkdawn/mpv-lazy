@echo off
setlocal

chcp 936 >nul

rem ============================================
rem  mpv-lazy 一键格式关联（强占模式）
rem  双击即用 mpv 打开常见影音格式
rem  已被其他播放器占用的格式会强占并备份原设置
rem  取消/还原请运行 mpv-unassoc.bat
rem ============================================

where pwsh >nul 2>&1
if %errorlevel% == 0 (
	pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0mpv-assoc.ps1"
) else (
	powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mpv-assoc.ps1"
)

pause
endlocal
