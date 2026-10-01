<#
.SYNOPSIS
    mpv-lazy-ng 主程序更新器（跟随 mpv 官方 master 每日构建）
.DESCRIPTION
    从 shinchiro/mpv-winbuild-cmake Releases 检查并下载最新 mpv 构建
    （该构建随 mpv 官方 master 每日更新，且启用 vapoursynth —— 补帧/AI 滤镜必需；
      mpv 官方 Releases 的 CI 构建不含 vapoursynth，故不采用），
    自动替换 mpv.exe / mpv.com / d3dcompiler_43.dll，配置文件不受影响。

    用法：
      update-mpv.bat                    交互式检查并更新
      update-mpv.ps1 -Check             仅检查新版本，不下载
      update-mpv.ps1 -Y                 跳过确认自动更新
      update-mpv.ps1 -Component ytdlp   更新 yt-dlp.exe
#>
param(
    [switch]$Check,                     # 仅检查
    [switch]$Y,                         # 自动确认
    [ValidateSet('x86_64', 'x86_64-v3')]
    [string]$Arch = 'x86_64',           # shinchiro 构建变体
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

# ━━━ 从 expanded_assets 页面解析资产名（shinchiro 资产名含 git hash，需页面抓取） ━━
function Get-ShinchiroAssetName {
    param([string]$Tag)
    $page = Invoke-WebRequest -Uri "https://github.com/shinchiro/mpv-winbuild-cmake/releases/expanded_assets/$Tag" -UseBasicParsing -TimeoutSec 30
    $pattern = [regex]::Escape($Tag)
    if ($Arch -eq 'x86_64-v3') {
        $m = [regex]::Match($page.Content, "/shinchiro/mpv-winbuild-cmake/releases/download/$pattern/(mpv-x86_64-v3-\d{8}-git-[0-9a-f]+\.7z)")
    } else {
        $m = [regex]::Match($page.Content, "/shinchiro/mpv-winbuild-cmake/releases/download/$pattern/(mpv-x86_64-\d{8}-git-[0-9a-f]+\.7z)")
    }
    if ($m.Success) { return $m.Groups[1].Value }
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
    Write-Host " ━━ mpv-lazy-ng · mpv 主程序更新（shinchiro 每日构建 · 含 vapoursynth） ━━" -ForegroundColor Cyan
    Write-Host ""

    $installed = Get-InstalledMpvVersion
    if ($installed) { Write-Info "当前版本：$installed" }
    else            { Write-Warn2 "当前版本：未检测到 mpv.exe（将全新安装）" }

    $repo = 'shinchiro/mpv-winbuild-cmake'
    $rel = Get-LatestRelease $repo
    $tag = $rel.tag_name
    $pubDate = '未知'
    try { $pubDate = ([datetime]$rel.published_at).ToString('yyyy-MM-dd') } catch {}
    Write-Info "最新构建：$tag   （发布于 $pubDate）"

    # 资产名（API 资产列表优先；降级时从 expanded_assets 页面抓取）
    $assetName = $null
    $dl = $null
    if ($rel.assets.Count -gt 0) {
        $archPat = if ($Arch -eq 'x86_64-v3') { 'mpv-x86_64-v3-\d{8}-git-[0-9a-f]+\.7z' } else { 'mpv-x86_64-\d{8}-git-[0-9a-f]+\.7z' }
        $a = $rel.assets | Where-Object { $_.name -match "^$archPat`$" } | Select-Object -First 1
        if ($a) {
            $assetName = $a.name
            $dl = @{ Url = $a.browser_download_url; Sha256 = $null }   # shinchiro 无官方 sha256
        }
    }
    if (-not $assetName) {
        $assetName = Get-ShinchiroAssetName $tag
        if (-not $assetName) { Write-Err "未找到 $tag 的 mpv 资产（$Arch）"; exit 1 }
        $dl = @{ Url = "https://github.com/$repo/releases/download/$tag/$assetName"; Sha256 = $null }
    }

    # 已是最新？（版本字符串里的短哈希是资产名长哈希的前缀：
    #   mpv --version 显示 9 位如 g3186d369f，资产名含 10 位如 3186d369f9，故用前缀比较而非包含）
    $gitHash = $null
    if ($assetName -match '-git-([0-9a-f]+)\.7z$') { $gitHash = $Matches[1].ToLower() }
    $isCurrent = $false
    if ($installed -and $gitHash) {
        if ($installed -match '-g([0-9a-f]+)\s*$' -or $installed -match '-g([0-9a-f]+)$') {
            $isCurrent = $gitHash.StartsWith($Matches[1].ToLower())
        } elseif ($installed -match [regex]::Escape($gitHash)) {
            $isCurrent = $true
        }
    }
    if ($isCurrent) {
        Write-Ok "已是最新构建（$gitHash），无需更新"
        exit 0
    }
    if ($Check) { Write-Warn2 "有新构建 $assetName，使用 update-mpv.bat 执行更新"; exit 0 }

    if (-not $Y) {
        $confirm = Read-Host "  是否下载并更新到 $assetName ？(Y/n)"
        if ($confirm -and $confirm -ne 'Y' -and $confirm -ne 'y') { Write-Info "已取消"; exit 0 }
    }

    # 下载
    New-Item -ItemType Directory -Path $dlDir -Force | Out-Null
    $zipPath = Join-Path $dlDir $assetName
    if (-not (Download-Asset $dl.Url $zipPath $dl.Sha256)) { exit 1 }

    # 解压（shinchiro 单层 7z）
    $sevenZip = Find-SevenZip
    if (-not $sevenZip) { Write-Err "解压需要 7-Zip"; exit 1 }
    $stageDir = Join-Path $dlDir '_stage'
    if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force }
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

    Write-Info "解压 ..."
    & $sevenZip x $zipPath -o"$stageDir" -y | Out-Null

    # 替换二进制：mpv.exe / mpv.com / d3dcompiler_43.dll（静态构建，无其他依赖 dll）
    Write-Info "替换主程序 ..."
    $replaced = 0
    foreach ($f in (Get-ChildItem $stageDir -File)) {
        if ($f.Name -match '^(mpv\.exe|mpv\.com|d3dcompiler[^\.]*\.dll)$') {
            Copy-Item $f.FullName (Join-Path $rootDir $f.Name) -Force
            $replaced++
        }
    }
    Write-Ok "已替换 $replaced 个文件（mpv.exe + mpv.com + d3dcompiler_43.dll）"

    # 验证
    $newVer = Get-InstalledMpvVersion
    if ($newVer) { Write-Ok "更新完成，当前版本：$newVer" }

    # 记录版本
    $vj = @{}
    $old = Read-VersionJson
    if ($old) { $vj['ytdlp'] = $old.ytdlp }
    $vj['mpv'] = $assetName -replace '\.7z$', ''
    Write-VersionJson $vj

    # 清理暂存
    Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Ok "mpv 已更新至 $assetName"
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
    if ($Check) { Write-Warn2 "有新版本 $tag，使用 update-mpv.bat 执行更新（或 update-mpv.bat ytdlp）"; exit 0 }

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
