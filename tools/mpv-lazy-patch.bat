@echo off
cd /d "%~dp0"
pwsh -ExecutionPolicy Bypass -NoProfile -File "%~dp0mpv-lazy-patch.ps1"
