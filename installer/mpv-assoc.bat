@echo off
setlocal EnableDelayedExpansion

chcp 936 >nul

rem ============================================
rem  mpv-lazy 一键格式关联（当前用户，免管理员）
rem  关联后双击视频/音频即用 mpv 打开
rem  已被其他播放器占用的格式会跳过并提示
rem ============================================

for %%i in ("%~dp0..") do set "ROOT=%%~fi"
set "MPV_EXE=%ROOT%\mpv.exe"
set "MPV_ICON=%~dp0mpv-icon.ico"

if not exist "%MPV_EXE%" (
	echo ========================================
	echo 未找到 mpv.exe，应确保本文件位于 mpv-lazy\installer 目录内
	echo ========================================
	pause
	exit /b 1
)

set "EXTS=mkv mp4 avi flv wmv mov mpg mpeg mpe m2ts ts mts m2t vob rmvb rm webm m4v 3gp 3g2 f4v ogm ogv divx m2v mp3 flac ape wav m4a aac ogg opus wma cue"

set /a OK=0
set /a SKIP=0
set "SKIPLIST="

for %%e in (%EXTS%) do (
	set "DOIT=1"
	rem 检查用户是否已在系统设置里显式指定过默认程序
	reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.%%e\UserChoice" /v ProgId >nul 2>&1
	if !errorlevel! == 0 (
		set "CUR="
		for /f "tokens=2,*" %%a in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.%%e\UserChoice" /v ProgId 2^>nul ^| findstr /C:"REG_SZ"') do set "CUR=%%b"
		echo !CUR! | findstr /B /C:"mpv-lazy." >nul
		if !errorlevel! neq 0 (
			set "DOIT=0"
			set /a SKIP+=1
			set "SKIPLIST=!SKIPLIST! .%%e"
		)
	)
	if !DOIT! == 1 (
		reg add "HKCU\Software\Classes\.%%e" /ve /d "mpv-lazy.%%e" /f >nul
		reg add "HKCU\Software\Classes\mpv-lazy.%%e" /ve /d "%%e 文件" /f >nul
		reg add "HKCU\Software\Classes\mpv-lazy.%%e\DefaultIcon" /ve /d "%MPV_ICON%,0" /f >nul
		reg add "HKCU\Software\Classes\mpv-lazy.%%e\shell\open\command" /ve /d "\"%MPV_EXE%\" \"%%1\"" /f >nul
		set /a OK+=1
	)
)

rem 通知系统刷新关联缓存
powershell -NoProfile -Command "Add-Type -MemberDefinition '[DllImport(\"shell32.dll\")] public static extern void SHChangeNotify(int wEventId, int uFlags, System.IntPtr dwItem1, System.IntPtr dwItem2);' -Name Sh -Namespace W; [W.Sh]::SHChangeNotify(0x8000000, 0, [System.IntPtr]::Zero, [System.IntPtr]::Zero)" >nul 2>&1

echo ========================================
echo 格式关联完成：已关联 !OK! 个格式
if !SKIP! gtr 0 (
	echo 以下 !SKIP! 个格式已被其他播放器设为默认，未改动：
	echo !SKIPLIST!
	echo 如需改用 mpv 打开，请：右键文件 - 打开方式 - 选择其他应用 - mpv
)
echo.
echo 注意：关联指向当前路径 %MPV_EXE%
echo 若移动 mpv-lazy 文件夹，重新运行本文件即可
echo ========================================

pause
endlocal
