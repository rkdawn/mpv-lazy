<#
.SYNOPSIS
    mpv-lazy-ng 完整懒人包打包脚本
.DESCRIPTION
    从 mpv 官方 Releases 获取最新主程序，与本仓库的配置体系、
    补丁工具、更新器组装成解压即用的完整懒人包。

    产出：dist/mpv-lazy-ng-<日期>-mpv<版本>/ 与同名 .7z

    用法：
      build-package.bat                交互式打包
      build-package.ps1 -Y             跳过确认
      build-package.ps1 -Tag v0.41.0   指定 mpv 版本（默认最新）
      build-package.ps1 -Skip7z        只产出目录，不压缩
#>
param(
    [switch]$Y,                        # 自动确认
    [string]$Tag = '',                 # 指定 mpv 版本 tag（如 v0.41.0），默认最新
    [switch]$Skip7z                    # 不打包 7z
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ━━━ 路径定位（脚本位于 <repo>/build/） ━━
$repoDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$rootName = 'mpv-lazy-ng'
$dlDir = Join-Path $repoDir 'updater\_download'

function Write-Info { param($m) Write-Host "  $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "  $m" -ForegroundColor Green }
function Write-Warn2{ param($m) Write-Host "  $m" -ForegroundColor Yellow }
function Write-Err  { param($m) Write-Host "  $m" -ForegroundColor Red }

function Get-FileSha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [IO.File]::OpenRead($Path)
        $hash = $sha.ComputeHash($fs)
        $fs.Close()
        return ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally { $sha.Dispose() }
}

function Find-SevenZip {
    $paths = @(
        'D:\Program Files\7-Zip\7z.exe',
        'C:\Program Files\7-Zip\7z.exe',
        'C:\Program Files (x86)\7-Zip\7z.exe'
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $p } }
    return $null
}

# ━━━ 获取 mpv 官方构建（优先复用缓存） ━━
function Get-MpvBinaries {
    param([string]$DesiredTag)   # 为空则取最新

    $headers = @{ 'User-Agent' = 'mpv-lazy-ng-builder' }
    try {
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/mpv-player/mpv/releases/latest' -Headers $headers -TimeoutSec 30
    } catch {
        Write-Err "GitHub API 请求失败：$($_.Exception.Message)"; exit 1
    }
    $tag = if ($DesiredTag) { $DesiredTag } else { $rel.tag_name }

    $assetName = "mpv-$tag-x86_64-w64-mingw32.zip"
    $asset = $rel.assets | Where-Object { $_.name -eq $assetName }
    if (-not $asset -and -not $DesiredTag) { Write-Err "资产未找到：$assetName"; exit 1 }
    if (-not $asset) {
        # 指定了历史版本时按固定 URL 下载
        $url = "https://github.com/mpv-player/mpv/releases/download/$tag/$assetName"
        $sha256 = $null
    } else {
        $url = $asset.browser_download_url
        $sha256 = $null
        if ($asset.digest -match 'sha256:([0-9a-f]+)') { $sha256 = $Matches[1] }
    }

    New-Item -ItemType Directory -Path $dlDir -Force | Out-Null
    $zipPath = Join-Path $dlDir $assetName

    # 缓存有效则复用
    if ((Test-Path $zipPath) -and $sha256 -and (Get-FileSha256 $zipPath) -eq $sha256) {
        Write-Ok "复用已缓存的 $assetName"
    } else {
        Write-Info "下载 mpv 官方构建 $tag ..."
        try { Invoke-WebRequest -Uri $url -OutFile $zipPath -TimeoutSec 600 }
        catch { Write-Err "下载失败：$($_.Exception.Message)"; exit 1 }
        if ($sha256) {
            if ((Get-FileSha256 $zipPath) -ne $sha256) { Write-Err "SHA256 校验失败"; exit 1 }
            Write-Ok "SHA256 校验通过"
        }
    }

    # 解压（双层 zip）
    $sevenZip = Find-SevenZip
    $stage = Join-Path $dlDir "_build_stage_$tag"
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    if ($sevenZip) { & $sevenZip x $zipPath -o"$stage" -y | Out-Null }
    else           { Expand-Archive $zipPath -DestinationPath $stage -Force }

    $innerZip = Get-ChildItem $stage -Filter '*.zip' | Select-Object -First 1
    $binDir = $stage
    if ($innerZip) {
        $innerDir = Join-Path $stage '_inner'
        New-Item -ItemType Directory -Path $innerDir -Force | Out-Null
        if ($sevenZip) { & $sevenZip x $innerZip.FullName -o"$innerDir" -y | Out-Null }
        else           { Expand-Archive $innerZip.FullName -DestinationPath $innerDir -Force }
        $binDir = $innerDir
    }
    return @{ Tag = $tag; BinDir = $binDir; Stage = $stage }
}

# ━━━ 主流程 ━━
Write-Host ""
Write-Host " ━━ mpv-lazy-ng 完整懒人包构建 ━━" -ForegroundColor Cyan
Write-Host ""

# 前置检查：仓库文件齐备
foreach ($d in @('portable_config', 'tools', 'updater', 'installer')) {
    if (-not (Test-Path (Join-Path $repoDir $d))) {
        Write-Err "缺少目录 $d，请在仓库根目录运行"; exit 1
    }
}

$mpv = Get-MpvBinaries $Tag
Write-Ok "mpv 版本：$($mpv.Tag)"

# 组装目录
$dateTag = Get-Date -Format 'yyyyMMdd'
$pkgName = "$rootName-$dateTag-mpv$($mpv.Tag)"
$distDir = Join-Path $repoDir 'dist'
$pkgDir  = Join-Path $distDir $pkgName
$outDir  = Join-Path $pkgDir $rootName
if (Test-Path $pkgDir) { Remove-Item $pkgDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

Write-Info "组装中 ..."

# 1. mpv 二进制
foreach ($f in (Get-ChildItem $mpv.BinDir -File)) {
    if ($f.Name -match '^(mpv\.exe|mpv\.com|.*\.dll)$') {
        Copy-Item $f.FullName (Join-Path $outDir $f.Name)
    }
}

# 2. 配置体系
Copy-Item (Join-Path $repoDir 'portable_config') (Join-Path $outDir 'portable_config') -Recurse

# 3. 补丁工具（放包根目录，双击即用）
Copy-Item (Join-Path $repoDir 'tools\mpv-lazy-patch.bat')  $outDir
Copy-Item (Join-Path $repoDir 'tools\mpv-lazy-patch.ps1')  $outDir

# 4. 更新器
New-Item -ItemType Directory -Path (Join-Path $outDir 'updater') -Force | Out-Null
Copy-Item (Join-Path $repoDir 'updater\update-mpv.bat') (Join-Path $outDir 'updater')
Copy-Item (Join-Path $repoDir 'updater\update-mpv.ps1') (Join-Path $outDir 'updater')

# 5. installer 与根文件
Copy-Item (Join-Path $repoDir 'installer') (Join-Path $outDir 'installer') -Recurse
foreach ($f in @('umpv.conf', 'LICENSE.MD', 'LICENSE.txt', 'portable.vs', 'README.md')) {
    $src = Join-Path $repoDir $f
    if (Test-Path $src) { Copy-Item $src $outDir }
}

# 清理暂存
Remove-Item $mpv.Stage -Recurse -Force -ErrorAction SilentlyContinue

# 版本信息
@{
    mpv       = $mpv.Tag
    package   = $pkgName
    buildDate = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
} | ConvertTo-Json | Out-File (Join-Path $outDir 'VERSION.json') -Encoding utf8 -NoNewline

# 统计
$nFiles = (Get-ChildItem $outDir -Recurse -File).Count
$sizeMB = [math]::Round((Get-ChildItem $outDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB, 1)
Write-Ok "组装完成：$nFiles 个文件，$sizeMB MB"
Write-Info "输出目录：$pkgDir"

# 压缩 7z
if (-not $Skip7z) {
    $sevenZip = Find-SevenZip
    if ($sevenZip) {
        $archive = Join-Path $distDir "$pkgName.7z"
        Write-Info "压缩 7z ..."
        & $sevenZip a -t7z -mx=7 "$archive" "$outDir" | Out-Null
        if (Test-Path $archive) {
            $archMB = [math]::Round((Get-Item $archive).Length / 1MB, 1)
            Write-Ok "压缩包：$archive （$archMB MB）"
        } else { Write-Warn2 "压缩失败，目录版仍可用" }
    } else {
        Write-Warn2 "未找到 7-Zip，跳过压缩（目录版可直接使用）"
    }
}

Write-Host ""
Write-Ok "构建完成 ✔"
Write-Info "使用方法：解压到任意目录 → 双击 mpv.exe 播放"
Write-Info "右键菜单：运行 installer\mpv-register.bat"
Write-Info "应用定制：双击 mpv-lazy-patch.bat"
Write-Info "保持更新：双击 updater\update-mpv.bat"
