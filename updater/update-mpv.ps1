<#
.SYNOPSIS
    mpv-lazy-ng 主程序更新器（跟随 mpv 官方）
.DESCRIPTION
    从 mpv-player/mpv 官方 GitHub Releases 检查并下载最新版主程序，
    自动替换 mpv.exe / mpv.com / 依赖 dll，配置文件不受影响。

    用法：
      update-mpv.bat                    交互式检查并更新
      update-mpv.ps1 -Check             仅检查新版本，不下载
      update-mpv.ps1 -Y                 跳过确认自动更新
      update-mpv.ps1 -Component ytdlp   更新 yt-dlp.exe
      update-mpv.ps1 -Arch msvc         使用 MSVC 构建（默认 mingw）
#>
param(
    [switch]$Check,                     # 仅检查
    [switch]$Y,                         # 自动确认
    [ValidateSet('mingw', 'msvc')]
    [string]$Arch = 'mingw',            # 官方提供两种 Windows x64 构建
    [ValidateSet('mpv', 'ytdlp')]
    [string]$Component = 'mpv'          # 更新组件
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ━━━ 定位项目根目录（脚本位于 <root>/updater/） ━━
$rootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dlDir   = Join-Path $rootDir 'updater\_download'
$verFile = Join-Path $rootDir 'VERSION.json'

function Write-Info  { param($m) Write-Host "  $m" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "  $m" -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host "  $m" -ForegroundColor Yellow }
function Write-Err   { param($m) Write-Host "  $m" -ForegroundColor Red }

# ━━━ 读取已安装版本 ━━
function Get-InstalledMpvVersion {
    $mpvCom = Join-Path $rootDir 'mpv.com'
    $mpvExe = Join-Path $rootDir 'mpv.exe'
    foreach ($bin in @($mpvCom, $mpvExe)) {
        if (Test-Path $bin) {
            try {
                $line = (& $bin --version 2>$null | Select-Object -First 1)
                if ($line -match 'mpv\s+(v?[\d\.\-a-z]+)') { return $Matches[1] }
            } catch {}
        }
    }
    return $null
}

function Read-VersionJson {
    if (Test-Path $verFile) {
        try { return Get-Content $verFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    return $null
}

function Write-VersionJson {
    param([hashtable]$data)
    $data['updatedAt'] = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $data | ConvertTo-Json | Out-File $verFile -Encoding utf8 -NoNewline
}

# ━━━ GitHub API（限流时自动降级：302 重定向解析，不消耗 API 配额） ━━
function Get-LatestTagViaRedirect {
    param([string]$Repo)
    # https://github.com/<repo>/releases/latest 会 302 到 .../tag/<tag>
    $req = [Net.HttpWebRequest]::Create("https://github.com/$Repo/releases/latest")
    $req.AllowAutoRedirect = $false
    $req.UserAgent = 'mpv-lazy-ng-updater'
    $req.Timeout = 30000
    try {
        $resp = $req.GetResponse()
        $loc = $resp.Headers['Location']
        $resp.Close()
        if ($loc -match '/tag/(.+)$') { return $Matches[1] }
    } catch {}
    return $null
}

function Get-LatestRelease {
    param([string]$Repo)
    $headers = @{ 'User-Agent' = 'mpv-lazy-ng-updater' }
    try {
        return Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers -TimeoutSec 30
    } catch {
        Write-Warn2 "GitHub API 不可用（$($_.Exception.Message)），降级为重定向解析 ..."
        $tag = Get-LatestTagViaRedirect $Repo
        if (-not $tag) {
            Write-Err "无法获取最新版本号，请检查网络后重试"
            exit 1
        }
        # 构造最小 release 对象（无 digest，跳过 sha256 校验）
        return [PSCustomObject]@{
            tag_name      = $tag
            published_at  = 'unknown'
            assets        = @()
        }
    }
}

function Get-AssetUrl {
    # 优先 API 资产对象；否则构造固定下载 URL
    param($Release, [string]$AssetName, [string]$Repo)
    $a = $Release.assets | Where-Object { $_.name -eq $AssetName }
    if ($a) { return @{ Url = $a.browser_download_url; Sha256 = if ($a.digest -match 'sha256:([0-9a-f]+)') { $Matches[1] } else { $null } } }
    return @{ Url = "https://github.com/$Repo/releases/download/$($Release.tag_name)/$AssetName"; Sha256 = $null }
}

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

# ━━━ 下载文件（带 sha256 校验） ━━
function Download-Asset {
    param([string]$Url, [string]$OutFile, [string]$ExpectedSha256)
    if (Test-Path $OutFile) {
        Write-Info "已存在下载缓存，校验中 ..."
        if (-not $ExpectedSha256 -or (Get-FileSha256 $OutFile) -eq $ExpectedSha256) {
            Write-Ok "缓存有效，跳过下载"
            return $true
        }
        Write-Warn2 "缓存损坏，重新下载"
        Remove-Item $OutFile -Force
    }
    Write-Info "下载 $Url"
    Write-Info "（约需 1-3 分钟，取决于网速）"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -TimeoutSec 600
    } catch {
        Write-Err "下载失败：$($_.Exception.Message)"
        return $false
    }
    if ($ExpectedSha256) {
        $actual = Get-FileSha256 $OutFile
        if ($actual -ne $ExpectedSha256) {
            Write-Err "SHA256 校验失败！"
            Write-Err "  期望：$ExpectedSha256"
            Write-Err "  实际：$actual"
            Remove-Item $OutFile -Force
            return $false
        }
        Write-Ok "SHA256 校验通过"
    }
    return $true
}

# ━━━ 找本机 7-Zip ━━
function Find-SevenZip {
    $paths = @(
        'D:\Program Files\7-Zip\7z.exe',
        'C:\Program Files\7-Zip\7z.exe',
        'C:\Program Files (x86)\7-Zip\7z.exe'
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $p } }
    return $null
}

# ══════════════════════════════════════════
#  组件 1：mpv 主程序
# ══════════════════════════════════════════
if ($Component -eq 'mpv') {

    Write-Host ""
    Write-Host " ━━ mpv-lazy-ng · mpv 主程序更新（官方源） ━━" -ForegroundColor Cyan
    Write-Host ""

    $installed = Get-InstalledMpvVersion
    if ($installed) { Write-Info "当前版本：$installed" }
    else            { Write-Warn2 "当前版本：未检测到 mpv.exe（将全新安装）" }

    $rel = Get-LatestRelease 'mpv-player/mpv'
    $tag = $rel.tag_name
    $pubDate = '未知'
    try { $pubDate = ([datetime]$rel.published_at).ToString('yyyy-MM-dd') } catch {}
    Write-Info "官方最新：$tag   （发布于 $pubDate）"

    # 构造资产名（官方格式：mpv-v0.41.0-x86_64-w64-mingw32.zip）
    $archSuffix = if ($Arch -eq 'msvc') { 'x86_64-pc-windows-msvc' } else { 'x86_64-w64-mingw32' }
    $assetName  = "mpv-$tag-$archSuffix.zip"
    $dl = Get-AssetUrl $rel $assetName 'mpv-player/mpv'
    if (-not $dl.Url) {
        Write-Err "资产未找到：$assetName"
        Write-Warn2 "该版本可能未提供此架构构建，可尝试 -Arch msvc / -Arch mingw"
        exit 1
    }

    # 已是最新？（简单比较：已安装版本字符串包含 tag 去掉 v 的版本号）
    $verNum = $tag -replace '^v', ''
    if ($installed -and $installed -match [regex]::Escape($verNum)) {
        Write-Ok "已是最新版本，无需更新"
        exit 0
    }
    if ($Check) { Write-Warn2 "有新版本 $tag，使用 update-mpv.bat 执行更新"; exit 0 }

    if (-not $Y) {
        $confirm = Read-Host "  是否下载并更新到 $tag ？(Y/n)"
        if ($confirm -and $confirm -ne 'Y' -and $confirm -ne 'y') { Write-Info "已取消"; exit 0 }
    }

    # 下载
    New-Item -ItemType Directory -Path $dlDir -Force | Out-Null
    $zipPath = Join-Path $dlDir $assetName
    if (-not (Download-Asset $dl.Url $zipPath $dl.Sha256)) { exit 1 }

    # 解压（官方 zip 是双层：外层包含 mpv-git-<date>-<hash>-x86_64.zip）
    $sevenZip = Find-SevenZip
    $stageDir = Join-Path $dlDir '_stage'
    if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force }
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

    Write-Info "解压 ..."
    if ($sevenZip) {
        & $sevenZip x $zipPath -o"$stageDir" -y | Out-Null
    } else {
        Expand-Archive -Path $zipPath -DestinationPath $stageDir -Force
    }

    # 找内层 zip
    $innerZip = Get-ChildItem $stageDir -Filter '*.zip' | Select-Object -First 1
    $binDir = $stageDir
    if ($innerZip) {
        Write-Info "解压内层包（官方双层打包） ..."
        $innerDir = Join-Path $stageDir '_inner'
        New-Item -ItemType Directory -Path $innerDir -Force | Out-Null
        if ($sevenZip) { & $sevenZip x $innerZip.FullName -o"$innerDir" -y | Out-Null }
        else           { Expand-Archive -Path $innerZip.FullName -DestinationPath $innerDir -Force }
        $binDir = $innerDir
    }

    # 替换二进制：mpv.exe / mpv.com / *.dll → 根目录
    Write-Info "替换主程序与依赖库 ..."
    $replaced = 0
    foreach ($f in (Get-ChildItem $binDir -File)) {
        if ($f.Name -match '^(mpv\.exe|mpv\.com|.*\.dll)$') {
            Copy-Item $f.FullName (Join-Path $rootDir $f.Name) -Force
            $replaced++
        }
    }
    Write-Ok "已替换 $replaced 个文件（mpv.exe + mpv.com + 依赖 dll）"

    # 验证
    $newVer = Get-InstalledMpvVersion
    if ($newVer) { Write-Ok "更新完成，当前版本：$newVer" }

    # 记录版本
    $vj = @{}
    $old = Read-VersionJson
    if ($old) { $vj['ytdlp'] = $old.ytdlp }
    $vj['mpv'] = $tag
    Write-VersionJson $vj

    # 清理暂存
    Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Ok "mpv 已更新至 $tag"
    Write-Info "配置（portable_config）与补丁不受影响"
}

# ══════════════════════════════════════════
#  组件 2：yt-dlp
# ══════════════════════════════════════════
elseif ($Component -eq 'ytdlp') {

    Write-Host ""
    Write-Host " ━━ mpv-lazy-ng · yt-dlp 更新（官方源） ━━" -ForegroundColor Cyan
    Write-Host ""

    $ytPath = Join-Path $rootDir 'yt-dlp.exe'
    $installed = $null
    if (Test-Path $ytPath) {
        try { $installed = (& $ytPath --version 2>$null | Select-Object -First 1) } catch {}
    }
    if ($installed) { Write-Info "当前版本：$installed" }
    else            { Write-Warn2 "当前版本：未安装" }

    $rel = Get-LatestRelease 'yt-dlp/yt-dlp'
    $tag = $rel.tag_name
    $pubDate = '未知'
    try { $pubDate = ([datetime]$rel.published_at).ToString('yyyy-MM-dd') } catch {}
    Write-Info "官方最新：$tag   （发布于 $pubDate）"

    if ($installed -and $installed -eq ($tag -replace '^v', '')) {
        Write-Ok "已是最新版本"; exit 0
    }

    $dl = Get-AssetUrl $rel 'yt-dlp.exe' 'yt-dlp/yt-dlp'
    if (-not $dl.Url) { Write-Err "未找到 yt-dlp.exe 资产"; exit 1 }

    New-Item -ItemType Directory -Path $dlDir -Force | Out-Null
    $tmp = Join-Path $dlDir 'yt-dlp.exe'
    if (-not (Download-Asset $dl.Url $tmp $dl.Sha256)) { exit 1 }

    Copy-Item $tmp $ytPath -Force
    Write-Ok "已更新：$(& $ytPath --version 2>$null | Select-Object -First 1)"

    $vj = @{}
    $old = Read-VersionJson
    if ($old) { $vj['mpv'] = $old.mpv }
    $vj['ytdlp'] = $tag
    Write-VersionJson $vj
}
