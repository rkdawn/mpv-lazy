#Requires -Version 5.1
<#
  mpv-lazy 一键格式关联（强占模式，当前用户，免管理员）
  - 已被其他播放器设为默认的格式：解除 UserChoice 权限保护并删除，强占关联
  - 原有关联先备份到 HKCU\Software\mpv-lazy\AssocBackup，可用 mpv-unassoc.bat 还原
  - 由 mpv-assoc.bat 调用，勿直接运行
#>
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936) } catch {}

$root   = Split-Path -Parent $PSScriptRoot
$mpvExe = Join-Path $root 'mpv.exe'
$icon   = Join-Path $PSScriptRoot 'mpv-icon.ico'

if (-not (Test-Path $mpvExe)) {
    Write-Host '========================================' -ForegroundColor Red
    Write-Host '未找到 mpv.exe，应确保本工具位于 mpv-lazy\installer 目录内' -ForegroundColor Red
    Write-Host '========================================' -ForegroundColor Red
    exit 1
}

$exts = 'mkv mp4 avi flv wmv mov mpg mpeg mpe m2ts ts mts m2t vob rmvb rm webm m4v 3gp 3g2 f4v ogm ogv divx m2v mp3 flac ape wav m4a aac ogg opus wma cue' -split ' '
$backupRoot = 'HKCU:\Software\mpv-lazy\AssocBackup'

function Get-DefaultValue([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    try { return (Get-ItemProperty -Path $path -Name '(default)' -ErrorAction Stop).'(default)' } catch { return $null }
}

function Remove-UserChoice([string]$ext) {
    $sub = "Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.$ext\UserChoice"
    $r = @{ Existed = $false; ProgId = $null; Removed = $true }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sub, $false)
    if ($null -eq $key) { return $r }
    $r.Existed = $true
    try { $r.ProgId = $key.GetValue('ProgId') } catch {}
    $key.Close()
    if ($r.ProgId -like 'mpv-lazy.*') { return $r }   # 本来就是我们的，无需删
    try {
        # 所有者对 ACL 有隐式 WRITE_DAC：以 ChangePermissions 打开，移除「拒绝删除/写入」保护
        # （PS 注册表提供程序的 Set-Acl 不申请 ChangePermissions 权限，必须用 .NET API）
        $wkey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sub,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::ChangePermissions)
        $acl = $wkey.GetAccessControl()
        $denyRules = @($acl.GetAccessRules($true, $false, [System.Security.Principal.NTAccount]) |
            Where-Object { $_.AccessControlType -eq 'Deny' })
        foreach ($rule in $denyRules) { [void]$acl.RemoveAccessRuleSpecific($rule) }
        if ($denyRules.Count -gt 0) { $wkey.SetAccessControl($acl) }
        $wkey.Close()
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($sub)
    } catch {
        $r.Removed = $false
    }
    return $r
}

$ok = 0; $forced = 0; $backed = 0; $failed = @()
foreach ($e in $exts) {
    $dotKey  = "HKCU:\Software\Classes\.$e"
    $progKey = "HKCU:\Software\Classes\mpv-lazy.$e"

    $oldDefault = Get-DefaultValue $dotKey
    $uc = Remove-UserChoice $e
    if (-not $uc.Removed) { $failed += ".$e"; continue }

    # 首次关联时备份原状态（重复运行不覆盖备份）
    $bKey = Join-Path $backupRoot $e
    if (-not (Test-Path $bKey)) {
        New-Item -Path $bKey -Force | Out-Null
        if ($oldDefault) { Set-ItemProperty -Path $bKey -Name 'OldDefault' -Value $oldDefault; $backed++ }
        if ($uc.ProgId)  { Set-ItemProperty -Path $bKey -Name 'OldUserChoice' -Value $uc.ProgId; $backed++ }
    }
    if ($uc.Existed -and $uc.ProgId -and $uc.ProgId -notlike 'mpv-lazy.*') { $forced++ }

    New-Item -Path $dotKey -Force | Out-Null
    New-Item -Path "$progKey\shell\open\command" -Force | Out-Null
    New-Item -Path "$progKey\DefaultIcon" -Force | Out-Null
    Set-ItemProperty -Path $dotKey  -Name '(default)' -Value "mpv-lazy.$e"
    Set-ItemProperty -Path $progKey -Name '(default)' -Value "$e 文件"
    Set-ItemProperty -Path "$progKey\DefaultIcon" -Name '(default)' -Value "$icon,0"
    Set-ItemProperty -Path "$progKey\shell\open\command" -Name '(default)' -Value "`"$mpvExe`" `"%1`""
    $ok++
}

# 通知系统刷新关联缓存
try {
    Add-Type -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int w, int f, System.IntPtr p1, System.IntPtr p2);' -Name Sh -Namespace W
    [W.Sh]::SHChangeNotify(0x8000000, 0, [System.IntPtr]::Zero, [System.IntPtr]::Zero)
} catch {}

Write-Host '========================================' -ForegroundColor Green
Write-Host "格式关联完成：已关联 $ok 个格式（其中强占 $forced 个）" -ForegroundColor Green
if ($backed -gt 0) {
    Write-Host '原默认程序已备份，运行 mpv-unassoc.bat 可还原' -ForegroundColor Yellow
}
if ($forced -gt 0) {
    Write-Host '系统可能弹出「默认应用已重置」通知，属正常现象' -ForegroundColor Yellow
}
if ($failed.Count -gt 0) {
    Write-Host "以下 $($failed.Count) 个格式强占失败（权限不足）：$($failed -join ' ')" -ForegroundColor Red
}
Write-Host ''
Write-Host "关联指向：$mpvExe"
Write-Host '若移动 mpv-lazy 文件夹，重新运行本工具即可'
Write-Host '========================================' -ForegroundColor Green
