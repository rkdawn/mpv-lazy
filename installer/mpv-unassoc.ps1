#Requires -Version 5.1
<#
  mpv-lazy 取消格式关联
  - 移除本工具建立的关联（mpv-lazy.* ProgID）
  - 有备份的格式还原到关联前的默认程序
  - 由 mpv-unassoc.bat 调用，勿直接运行
#>
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(936) } catch {}

$exts = 'mkv mp4 avi flv wmv mov mpg mpeg mpe m2ts ts mts m2t vob rmvb rm webm m4v 3gp 3g2 f4v ogm ogv divx m2v mp3 flac ape wav m4a aac ogg opus wma cue' -split ' '
$backupRoot = 'HKCU:\Software\mpv-lazy\AssocBackup'

function Get-DefaultValue([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    try { return (Get-ItemProperty -Path $path -Name '(default)' -ErrorAction Stop).'(default)' } catch { return $null }
}

$removed = 0; $restored = 0
foreach ($e in $exts) {
    $dotKey  = "HKCU:\Software\Classes\.$e"
    $progKey = "HKCU:\Software\Classes\mpv-lazy.$e"
    $bKey    = Join-Path $backupRoot $e

    $cur = Get-DefaultValue $dotKey
    if ($cur -eq "mpv-lazy.$e") {
        # 有备份先还原旧默认，没有就清空
        $old = $null
        if (Test-Path $bKey) {
            try { $old = (Get-ItemProperty -Path $bKey -Name 'OldDefault' -ErrorAction Stop).OldDefault } catch {}
        }
        if ($old) {
            Set-ItemProperty -Path $dotKey -Name '(default)' -Value $old
            $restored++
        } else {
            Remove-ItemProperty -Path $dotKey -Name '(default)' -Force -ErrorAction SilentlyContinue
        }
        $removed++
    }
    if (Test-Path $progKey) { Remove-Item -Path $progKey -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $bKey)    { Remove-Item -Path $bKey -Recurse -Force -ErrorAction SilentlyContinue }
}
if (Test-Path $backupRoot) { Remove-Item -Path $backupRoot -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path 'HKCU:\Software\mpv-lazy') {
    if ((Get-ChildItem 'HKCU:\Software\mpv-lazy' -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item 'HKCU:\Software\mpv-lazy' -Force -ErrorAction SilentlyContinue
    }
}

try {
    Add-Type -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int w, int f, System.IntPtr p1, System.IntPtr p2);' -Name Sh -Namespace W
    [W.Sh]::SHChangeNotify(0x8000000, 0, [System.IntPtr]::Zero, [System.IntPtr]::Zero)
} catch {}

Write-Host '========================================' -ForegroundColor Green
Write-Host "已取消 $removed 个格式的关联（其中 $restored 个已还原为原默认程序）" -ForegroundColor Green
Write-Host '个别格式如未自动还原，请右键文件 - 打开方式重新选择' -ForegroundColor Yellow
Write-Host '========================================' -ForegroundColor Green
