@echo off
setlocal EnableDelayedExpansion

chcp 936 >nul

rem ============================================
rem  mpv-lazy 取消格式关联
rem  只移除由 mpv-assoc.bat 建立的关联
rem  不影响你在系统设置里手动指定的默认程序
rem ============================================

set "EXTS=mkv mp4 avi flv wmv mov mpg mpeg mpe m2ts ts mts m2t vob rmvb rm webm m4v 3gp 3g2 f4v ogm ogv divx m2v mp3 flac ape wav m4a aac ogg opus wma cue"

set /a DEL=0
set /a SKIP=0

for %%e in (%EXTS%) do (
	set "CUR="
	for /f "tokens=2,*" %%a in ('reg query "HKCU\Software\Classes\.%%e" /ve 2^>nul ^| findstr /C:"REG_SZ"') do set "CUR=%%b"
	if "!CUR!" == "mpv-lazy.%%e" (
		reg delete "HKCU\Software\Classes\.%%e" /ve /f >nul 2>&1
		set /a DEL+=1
	) else (
		set /a SKIP+=1
	)
	reg query "HKCU\Software\Classes\mpv-lazy.%%e" >nul 2>&1
	if !errorlevel! == 0 (
		reg delete "HKCU\Software\Classes\mpv-lazy.%%e" /f >nul 2>&1
	)
)

rem 通知系统刷新关联缓存
powershell -NoProfile -Command "Add-Type -MemberDefinition '[DllImport(\"shell32.dll\")] public static extern void SHChangeNotify(int wEventId, int uFlags, System.IntPtr dwItem1, System.IntPtr dwItem2);' -Name Sh -Namespace W; [W.Sh]::SHChangeNotify(0x8000000, 0, [System.IntPtr]::Zero, [System.IntPtr]::Zero)" >nul 2>&1

echo ========================================
echo 已取消 !DEL! 个格式的关联
echo （其余 !SKIP! 个未由本工具关联或已不存在，未改动）
echo ========================================

pause
endlocal
