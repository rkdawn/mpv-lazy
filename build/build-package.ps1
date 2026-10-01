<#
.SYNOPSIS
    mpv-lazy-ng 完整懒人包打包脚本
.DESCRIPTION
    从 mpv 官方 Releases 获取最新主程序，与本仓库的配置体系、
    补丁工具、更新器组装成解压即用的完整懒人包。

    产出：dist/mpv-lazy-ng-<日期>-mpv<版本>/ 与同名 .7z

    用法：
      build-package.bat                交互式打包（默认已应用全部定制补丁，解压即用）
      build-package.ps1 -Y             跳过确认
      build-package.ps1 -NoPatches     不应用定制补丁（纯净 mpv-lazy 原版配置）
      build-package.ps1 -Tag v0.41.0   指定 mpv 版本（默认最新）
      build-package.ps1 -Skip7z        只产出目录，不压缩
      build-package.ps1 -NoVS          不打包 VapourSynth 补帧/AI 超分运行时（包体减小约 200MB）
      build-package.ps1 -VSSource 路径 指定原版 mpv-lazy exe/已解压目录（默认自动定位本地或联网下载）
#>
param(
    [switch]$Y,                        # 自动确认
    [string]$Tag = '',                 # 指定 mpv 版本 tag（如 v0.41.0），默认最新
    [switch]$Skip7z,                   # 不打包 7z
    [switch]$NoPatches,                # 不应用定制补丁
    [switch]$NoVS,                     # 不打包 VapourSynth 运行时
    [string]$VSSource = ''             # 原版 mpv-lazy 的 exe 或解压目录
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
    # CI/PATH 环境
    $cmd = Get-Command 7z -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# ━━━ 通过 302 重定向获取最新 tag（API 限流时的降级通道，不消耗配额） ━━
function Get-LatestTagViaRedirect {
    param([string]$Repo = 'shinchiro/mpv-winbuild-cmake')
    $req = [Net.HttpWebRequest]::Create("https://github.com/$Repo/releases/latest")
    $req.AllowAutoRedirect = $false
    $req.UserAgent = 'mpv-lazy-ng-builder'
    $req.Timeout = 30000
    try {
        $resp = $req.GetResponse()
        $loc = $resp.Headers['Location']
        $resp.Close()
        if ($loc -match '/tag/(.+)$') { return $Matches[1] }
    } catch {}
    return $null
}

# 别名（供降级路径调用）
function Get-LatestTagViaRedirectCustom { param([string]$Repo) Get-LatestTagViaRedirect -Repo $Repo }

# ━━━ 获取 mpv 构建（shinchiro 每日 master 构建 = mpv 官方 master 的跟随源，含 vapoursynth 滤镜；优先复用缓存） ━━
# 说明：mpv 官方 Releases 的 CI 构建未启用 vapoursynth（补帧/AI 滤镜不可用），
#       原版 mpv-lazy 亦使用本系构建。shinchiro releases：tag=日期，资产 mpv-x86_64-<日期>-git-<hash>.7z
function Get-ShinchiroAssetName {
    param([string]$Tag)
    $page = Invoke-WebRequest -Uri "https://github.com/shinchiro/mpv-winbuild-cmake/releases/expanded_assets/$Tag" -UseBasicParsing -TimeoutSec 30
    $m = [regex]::Match($page.Content, '/shinchiro/mpv-winbuild-cmake/releases/download/' + [regex]::Escape($Tag) + '/(mpv-x86_64-\d{8}-git-[0-9a-f]+\.7z)')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-MpvBinaries {
    param([string]$DesiredTag)   # 为空则取最新（shinchiro 日期 tag）

    $repo = 'shinchiro/mpv-winbuild-cmake'
    $headers = @{ 'User-Agent' = 'mpv-lazy-ng-builder' }
    $tag = $DesiredTag
    $assetName = $null
    $url = $null

    if (-not $tag) {
        try {
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers $headers -TimeoutSec 30
            $tag = $rel.tag_name
            $a = $rel.assets | Where-Object { $_.name -match '^mpv-x86_64-\d{8}-git-[0-9a-f]+\.7z$' } | Select-Object -First 1
            if (-not $a) { Write-Err "shinchiro release $tag 未找到 mpv-x86_64 资产"; exit 1 }
            $assetName = $a.name
            $url = $a.browser_download_url
        } catch {
            Write-Warn2 "GitHub API 不可用（$($_.Exception.Message)），降级为重定向解析 ..."
            $tag = Get-LatestTagViaRedirectCustom $repo
            if (-not $tag) { Write-Err "无法获取最新版本号，请检查网络后重试"; exit 1 }
        }
    }
    if (-not $assetName) {
        $assetName = Get-ShinchiroAssetName $tag
        if (-not $assetName) { Write-Err "未找到 $tag 的 mpv-x86_64 资产"; exit 1 }
    }

    New-Item -ItemType Directory -Path $dlDir -Force | Out-Null
    $zipPath = Join-Path $dlDir $assetName

    # 缓存有效则复用（shinchiro 无官方 sha256，按存在即复用）
    if (Test-Path $zipPath) {
        Write-Ok "复用已缓存的 $assetName"
    } else {
        if (-not $url) { $url = "https://github.com/$repo/releases/download/$tag/$assetName" }
        Write-Info "下载 mpv 构建 $assetName ..."
        try { Invoke-WebRequest -Uri $url -OutFile $zipPath -TimeoutSec 900 }
        catch { Write-Err "下载失败：$($_.Exception.Message)"; exit 1 }
    }

    # 解压（单层 7z：mpv.exe / mpv.com / d3dcompiler_43.dll / doc 等）
    $sevenZip = Find-SevenZip
    if (-not $sevenZip) { Write-Err "解压 7z 需要 7-Zip（未找到）"; exit 1 }
    $stage = Join-Path $dlDir "_build_stage_$tag"
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    & $sevenZip x $zipPath -o"$stage" -y | Out-Null

    # 构建标识（从资产名提取 git hash）
    $gitHash = $null
    if ($assetName -match '-git-([0-9a-f]+)\.7z$') { $gitHash = $Matches[1] }
    return @{ Tag = "$tag$(if ($gitHash) { "-git-$gitHash" })"; BinDir = $stage; Stage = $stage }
}

# ━━━ 定位/获取原版 mpv-lazy（VapourSynth 运行时的来源） ━━
# 优先级：-VSSource 参数 > 本地常见路径 glob > hooke007 官方 release 下载
function Get-LazySource {
    # 1) 显式参数
    $candidates = @()
    if ($VSSource) { $candidates += $VSSource }
    # 2) 本地已知下载位置
    $candidates += @(
        'E:\常用文件\下载\mpv-lazy-*.exe',
        "$env:USERPROFILE\Downloads\mpv-lazy-*.exe"
    )
    foreach ($c in $candidates) {
        $hit = Get-ChildItem $c -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
        if (Test-Path $c) { return $c }   # 目录形式
    }
    # 3) 联网下载 hooke007 最新完整版（302 重定向取 tag，再从 expanded_assets 找完整版 exe）
    Write-Warn2 "本地未找到原版 mpv-lazy，尝试从 hooke007 官方 release 下载 ..."
    try {
        $req = [Net.HttpWebRequest]::Create('https://github.com/hooke007/mpv_PlayKit/releases/latest')
        $req.AllowAutoRedirect = $false
        $req.UserAgent = 'mpv-lazy-ng-builder'
        $req.Timeout = 30000
        $resp = $req.GetResponse()
        $loc = $resp.Headers['Location']
        $resp.Close()
        if ($loc -notmatch '/tag/(.+)$') { return $null }
        $lazyTag = $Matches[1]
        $assetPage = Invoke-WebRequest -Uri "https://github.com/hooke007/mpv_PlayKit/releases/expanded_assets/$lazyTag" -UseBasicParsing -TimeoutSec 30
        # 完整版形如 mpv-lazy-<date>.exe（排除 -noVS.7z / 源码包）
        $m = [regex]::Match($assetPage.Content, '/hooke007/mpv_PlayKit/releases/download/[^\"]*?mpv-lazy-[^\"]*?\.exe')
        if (-not $m.Success) { Write-Warn2 "release 页未找到完整版 exe"; return $null }
        $url = 'https://github.com' + $m.Value
        New-Item -ItemType Directory -Path $dlDir -Force | Out-Null
        $exePath = Join-Path $dlDir "mpv-lazy-$lazyTag.exe"
        if (-not (Test-Path $exePath)) {
            Write-Info "下载原版 mpv-lazy $lazyTag（约 300MB，供提取 VS 运行时）..."
            Invoke-WebRequest -Uri $url -OutFile $exePath -TimeoutSec 1800
        } else {
            Write-Ok "复用已缓存的原版 mpv-lazy $lazyTag"
        }
        return $exePath
    } catch {
        Write-Warn2 "下载失败：$($_.Exception.Message)"
        return $null
    }
}

# ━━━ 从原版包提取 VapourSynth 运行时栈 + 周边工具 ━━
function Install-LazyExtras {
    param([string]$PkgRoot)   # 成品包根目录（mpv.exe 所在）

    $src = Get-LazySource
    if (-not $src) {
        Write-Warn2 "未获得原版 mpv-lazy 来源，本次构建不含 VS 运行时（补帧/AI 菜单不可用）"
        return $false
    }

    # 解压（SFX exe）或直接使用目录
    $extracted = $null
    if (Test-Path $src -PathType Leaf) {
        $sevenZip0 = Find-SevenZip
        if (-not $sevenZip0) { Write-Warn2 "无 7-Zip 可解压原版 exe，跳过 VS 运行时"; return $false }
        $extracted = Join-Path $dlDir "_lazy_extract"
        if (Test-Path $extracted) { Remove-Item $extracted -Recurse -Force }
        Write-Info "解压原版 mpv-lazy（提取 VS 运行时）..."
        & $sevenZip0 x $src -o"$extracted" -y | Out-Null
        $inner = Get-ChildItem $extracted -Directory | Select-Object -First 1
        if ($inner) { $extracted = $inner.FullName }
    } else {
        $extracted = $src
    }

    Write-Info "复制 VapourSynth 运行时与周边工具 ..."

    # 整目录：python site-packages / VS 插件（含 ONNX 模型）
    # 注：不打 Scripts/（pip 等 shim exe）—— 新版 mpv 会扫描 exe 目录 scripts/ 报
    #     "Can't load unknown script"；需要时可用包内 python.exe -m pip
    foreach ($d in @('Lib', 'vs-plugins', 'vs-coreplugins', 'vsgenstubs4')) {
        $s = Join-Path $extracted $d
        if (Test-Path $s) { Copy-Item $s (Join-Path $PkgRoot $d) -Recurse }
    }

    # 根文件白名单（绝不覆盖本仓库自己的 mpv.exe/mpv.com 等）
    $rootPatterns = @(
        '*.pyd',
        'python.exe', 'pythonw.exe', 'python3.dll', 'python3*.dll', 'python3*.zip',
        'python3*._pth', 'python.cat',
        'sqlite3.dll',
        'VSPipe.exe', 'VSScript.dll', 'VSScript*.dll', 'VSVFW.dll',
        'pfm-*-vapoursynth-win.exe', 'AVFS.exe',
        '7z.exe', '7z.dll',
        'yt-dlp.exe', 'umpv.exe', 'mpv_manual.pdf',
        'vsrepo.py', 'vsgenstubs.py',
        'msvcp140*.dll', 'vcruntime140*.dll', 'concrt140.dll', 'vccorlib140.dll',
        'libcrypto-*.dll', 'libssl-*.dll', 'libffi-*.dll'
    )
    foreach ($pat in $rootPatterns) {
        Get-ChildItem (Join-Path $extracted $pat) -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('mpv.exe', 'mpv.com') } |
            ForEach-Object { Copy-Item $_.FullName (Join-Path $PkgRoot $_.Name) -Force }
    }
    return $true
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
$pkgName = "$rootName-$dateTag-mpv$($mpv.Tag -replace '^v', '')"
$distDir = Join-Path $repoDir 'dist'
$pkgDir  = Join-Path $distDir $pkgName
$outDir  = Join-Path $pkgDir $rootName
if (Test-Path $pkgDir) { Remove-Item $pkgDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

Write-Info "组装中 ..."

# 1. mpv 二进制（shinchiro 静态构建：mpv.exe / mpv.com / d3dcompiler_43.dll）
foreach ($f in (Get-ChildItem $mpv.BinDir -File)) {
    if ($f.Name -match '^(mpv\.exe|mpv\.com|d3dcompiler[^\.]*\.dll)$') {
        Copy-Item $f.FullName (Join-Path $outDir $f.Name)
    }
}

# 2. 配置体系（剔除运行时生成的缓存/状态文件，保持包内干净）
Copy-Item (Join-Path $repoDir 'portable_config') (Join-Path $outDir 'portable_config') -Recurse
$cfgOut = Join-Path $outDir 'portable_config'
foreach ($junk in @(
    (Join-Path $cfgOut '_cache'),
    (Join-Path $cfgOut 'saved-props.json'),
    (Join-Path $cfgOut 'watch-later'),
    (Join-Path $cfgOut 'bookmark-skip.json')
)) {
    if (Test-Path $junk) { Remove-Item $junk -Recurse -Force }
}

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

# 5.2 VapourSynth 运行时栈（补帧/AI 超分）+ yt-dlp/umpv/手册（对齐原版懒人包）
$vsOk = $false
if (-not $NoVS) {
    $vsOk = Install-LazyExtras $outDir
    if ($vsOk) { Write-Ok "VapourSynth 运行时已打包（补帧/AI/yt-dlp 可用）" }
} else {
    Write-Warn2 "按参数跳过 VapourSynth 运行时（-NoVS）"
}

# 5.5 应用全部定制补丁（默认开启，解压即用成品；-NoPatches 跳过）
if (-not $NoPatches) {
    Write-Info "应用全部定制补丁（无边框/65%/连播/单击暂停/音量/书签跳过 ...）"
    $patchFile = Join-Path $repoDir 'tools\mpv-lazy-patch.ps1'
    $cfgDir = Join-Path $outDir 'portable_config'
    $benc = New-Object System.Text.UTF8Encoding $false
    $tokens = $null; $perr = $null
    $past = [System.Management.Automation.Language.Parser]::ParseFile($patchFile, [ref]$tokens, [ref]$perr)
    $passign = $past.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$PatchList' }, $true) | Select-Object -First 1
    $bPatchList = & ([ScriptBlock]::Create($passign.Right.Extent.Text))
    foreach ($fd in $past.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        . ([ScriptBlock]::Create($fd.Extent.Text))
    }
    foreach ($bp in $bPatchList) {
        $r = & $bp.Apply $cfgDir $benc
        if ($r) { $r -split "`r?`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
    }
    Write-Ok "全部 $($bPatchList.Count) 个补丁模块已预应用（可用包内 mpv-lazy-patch.bat 随时恢复单项）"
} else {
    Write-Warn2 "跳过定制补丁（纯净原版配置）"
}

# 清理暂存
Remove-Item $mpv.Stage -Recurse -Force -ErrorAction SilentlyContinue

# 版本信息
@{
    mpv       = $mpv.Tag
    package   = $pkgName
    patched   = (-not $NoPatches)
    vs        = [bool]$vsOk
    buildDate = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
} | ConvertTo-Json | Out-File (Join-Path $outDir 'VERSION.json') -Encoding utf8 -NoNewline

# 终检：剔除补丁应用阶段生成的运行时状态（对齐原版出厂状态：首次运行 mpv 后才生成）
foreach ($junk in @(
    (Join-Path $outDir 'portable_config\saved-props.json'),
    (Join-Path $outDir 'portable_config\_cache'),
    (Join-Path $outDir 'portable_config\bookmark-skip.json')
)) {
    if (Test-Path $junk) { Remove-Item $junk -Recurse -Force }
}

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
        # 先删旧包：7z a 会向已有压缩包追加更新，残留已删除文件的旧条目
        if (Test-Path $archive) { Remove-Item $archive -Force }
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
if ($NoPatches) {
    Write-Info "纯净包：解压到任意目录 → 双击 mpv.exe 播放 → 定制请双击 mpv-lazy-patch.bat"
} else {
    Write-Info "定制成品包：解压到任意目录 → 双击 mpv.exe 即是已配置好的播放器"
}
Write-Info "右键菜单：运行 installer\mpv-register.bat"
Write-Info "调整定制：双击 mpv-lazy-patch.bat（可恢复任意单项）"
Write-Info "保持更新：双击 updater\update-mpv.bat"
