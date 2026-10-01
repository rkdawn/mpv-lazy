<#
.SYNOPSIS
    MPV 自定义补丁脚本（模块化）
.DESCRIPTION
    菜单式选择功能模块，进入后选择应用或恢复。
    添加新功能时，只需在下面添加 PatchList 条目即可。
.NOTES
    将脚本放到 mpv-lazy-ng 根目录或 tools/ 子目录下均可，双击 mpv-lazy-patch.bat 运行
#>

# ━━━ 自动检索配置目录 ━━
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$candidates = @(
    (Join-Path $scriptDir "portable_config"),                                  # 本目录（懒人包根目录布局）
    (Join-Path (Split-Path -Parent $scriptDir) "portable_config")              # 父目录（仓库 tools/ 布局）
)
$CfgDir = $null
foreach ($p in $candidates) {
    if (Test-Path (Join-Path $p "mpv.conf")) {
        $CfgDir = $p
        break
    }
}
if (-not $CfgDir) {
    Write-Host "[错误] 未找到 mpv.conf，请将此脚本放到 mpv-lazy-ng 根目录或 tools/ 目录下" -ForegroundColor Red
    Write-Host "目录结构应为：mpv-lazy-ng/tools/mpv-lazy-patch.ps1" -ForegroundColor Yellow
    Write-Host "                 mpv-lazy-ng/portable_config/mpv.conf" -ForegroundColor Yellow
    Read-Host "按回车退出"
    exit 1
}

$ErrorActionPreference = "Stop"
$enc = New-Object System.Text.UTF8Encoding $false

# 辅助函数：写文件保持 LF 行尾（mpv-lazy原版用LF，WriteAllLines默认写CRLF会破坏行尾一致性）
function Write-LfFile {
    param([string]$Path, [string[]]$Lines, [System.Text.Encoding]$Encoding)
    $content = $Lines -join "`n"
    # 去除多余尾部空行，再统一加一个LF（与原版保持一致）
    $content = $content.TrimEnd("`n", "`r") + "`n"
    [IO.File]::WriteAllText($Path, $content, $Encoding)
}

# ━━━ 补丁模块定义 ━━
$PatchList = @(
    # ──── 1. 无边框窗口 ────
    @{
        Name    = "无边框播放窗口"
        Desc    = "border=no"
        Apply   = {
            param($dir, $enc)
            $mpvConf = Join-Path $dir "mpv.conf"
            if (-not (Test-Path $mpvConf)) { return "[跳过] mpv.conf 不存在" }
            $content = [IO.File]::ReadAllText($mpvConf, $enc)
            if ($content -match 'border\s*=\s*no') { return '  - border=no 已存在' }
            $content = $content -replace '( keep-open = yes)', " border = no # 无边框`n`$1"
            [IO.File]::WriteAllText($mpvConf, $content, $enc)
            return '  + 已添加 border=no'
        }
        Restore = {
            param($dir, $enc)
            $mpvConf = Join-Path $dir "mpv.conf"
            if (-not (Test-Path $mpvConf)) { return "[跳过] mpv.conf 不存在" }
            $lines = [IO.File]::ReadAllLines($mpvConf, $enc)
            $newLines = [System.Collections.ArrayList]::new()
            $removed = 0
            foreach ($line in $lines) {
                if ($line -match '^\s*border\s*=\s*no') { $removed++; continue }
                [void]$newLines.Add($line)
            }
            if ($removed -gt 0) {
                Write-LfFile $mpvConf $newLines.ToArray() $enc
                return "  - 已移除 border=no"
            }
            return '  - 无需恢复'
        }
    },

    # ──── 2. 窗口默认65% ────
    @{
        Name    = "窗口默认65%尺寸"
        Desc    = "autofit=65%"
        Apply   = {
            param($dir, $enc)
            $mpvConf = Join-Path $dir "mpv.conf"
            if (-not (Test-Path $mpvConf)) { return "[跳过] mpv.conf 不存在" }
            $content = [IO.File]::ReadAllText($mpvConf, $enc)
            if ($content -match 'autofit\s*=\s*65%') { return '  - autofit=65% 已存在' }
            # 插入到 border=no 后面，或 keep-open 前面
            if ($content -match 'border\s*=\s*no') {
                $content = $content -replace '(border\s*=\s*no[^\r\n]*)', "`$1`n autofit = 65% # 窗口默认占65%"
            } else {
                $content = $content -replace '( keep-open = yes)', " autofit = 65% # 窗口默认占65%`n`$1"
            }
            [IO.File]::WriteAllText($mpvConf, $content, $enc)
            return '  + 已添加 autofit=65%'
        }
        Restore = {
            param($dir, $enc)
            $mpvConf = Join-Path $dir "mpv.conf"
            if (-not (Test-Path $mpvConf)) { return "[跳过] mpv.conf 不存在" }
            $lines = [IO.File]::ReadAllLines($mpvConf, $enc)
            $newLines = [System.Collections.ArrayList]::new()
            $removed = 0
            foreach ($line in $lines) {
                if ($line -match '^\s*autofit\s*=\s*65%') { $removed++; continue }
                [void]$newLines.Add($line)
            }
            if ($removed -gt 0) {
                Write-LfFile $mpvConf $newLines.ToArray() $enc
                return "  - 已移除 autofit=65%"
            }
            return '  - 无需恢复'
        }
    },

    # ──── 3. 播放列表显示文件名 ────
    @{
        Name    = "播放列表显示文件名"
        Desc    = "osd-playlist-entry=filename"
        Apply   = {
            param($dir, $enc)
            $mpvConf = Join-Path $dir "mpv.conf"
            if (-not (Test-Path $mpvConf)) { return "[跳过] mpv.conf 不存在" }
            $content = [IO.File]::ReadAllText($mpvConf, $enc)
            if ($content -match 'osd-playlist-entry\s*=\s*filename') { return '  - osd-playlist-entry=filename 已存在' }
            if ($content -match 'autofit\s*=\s*65%') {
                $content = $content -replace '(autofit\s*=\s*65%[^\r\n]*)', "`$1`n osd-playlist-entry = filename # 播放列表显示文件名"
            } else {
                $content += "`nosd-playlist-entry = filename # 播放列表显示文件名"
            }
            [IO.File]::WriteAllText($mpvConf, $content, $enc)
            return '  + 已添加 osd-playlist-entry=filename'
        }
        Restore = {
            param($dir, $enc)
            $mpvConf = Join-Path $dir "mpv.conf"
            if (-not (Test-Path $mpvConf)) { return "[跳过] mpv.conf 不存在" }
            $lines = [IO.File]::ReadAllLines($mpvConf, $enc)
            $newLines = [System.Collections.ArrayList]::new()
            $removed = 0
            foreach ($line in $lines) {
                if ($line -match '^\s*osd-playlist-entry\s*=\s*filename') { $removed++; continue }
                [void]$newLines.Add($line)
            }
            if ($removed -gt 0) {
                Write-LfFile $mpvConf $newLines.ToArray() $enc
                return "  - 已移除 osd-playlist-entry=filename"
            }
            return '  - 无需恢复'
        }
    },

    # ──── 4. 自动连播 ────
    @{
        Name    = "同目录自动连播"
        Desc    = "autocreate-playlist=same + directory-mode=lazy"
        Apply   = {
            param($dir, $enc)
            $mpvConf = Join-Path $dir "mpv.conf"
            if (-not (Test-Path $mpvConf)) { return "[跳过] mpv.conf 不存在" }
            $content = [IO.File]::ReadAllText($mpvConf, $enc)
            $msgs = @()

            # autocreate-playlist=same
            # 先检查是否存在未注释的有效行
            $hasUncommented = $false
            $lines = $content -split "`r?`n"
            foreach ($ln in $lines) {
                if ($ln -match '^\s*autocreate-playlist\s*=\s*same' -and $ln -notmatch '^\s*#') {
                    $hasUncommented = $true; break
                }
            }
            if ($hasUncommented) {
                $msgs += '  - autocreate-playlist=same 已存在'
            } else {
                if ($content -match '#autocreate-playlist\s*=\s*same') {
                    $content = $content -replace '#autocreate-playlist\s*=\s*same', 'autocreate-playlist = same  # 同目录视频自动加入播放列表'
                } else {
                    $content += "`nautocreate-playlist = same  # 同目录视频自动加入播放列表"
                }
                $msgs += '  + 已添加 autocreate-playlist=same'
            }

            # directory-mode: ignore → lazy（原版默认ignore，连播需要lazy）
            if ($content -match 'directory-mode\s*=\s*laz') {
                $msgs += '  - directory-mode=lazy 已存在'
            } elseif ($content -match 'directory-mode\s*=\s*ignore') {
                $content = $content -replace 'directory-mode\s*=\s*ignore', 'directory-mode = lazy  # 不递归扫描子目录'
                $msgs += '  + directory-mode=ignore → lazy'
            }

            [IO.File]::WriteAllText($mpvConf, $content, $enc)
            return $msgs -join "`r`n"
        }
        Restore = {
            param($dir, $enc)
            $mpvConf = Join-Path $dir "mpv.conf"
            if (-not (Test-Path $mpvConf)) { return "[跳过] mpv.conf 不存在" }
            $lines = [IO.File]::ReadAllLines($mpvConf, $enc)
            $newLines = [System.Collections.ArrayList]::new()
            $removed = 0
            $mod = $false
            foreach ($line in $lines) {
                if ($line -match '^\s*autocreate-playlist\s*=\s*same') {
                    # 替换为原版注释行，而非直接删除
                    [void]$newLines.Add('#autocreate-playlist = same')
                    $removed++
                    continue
                }
                if ($line -match 'directory-mode\s*=\s*laz') {
                    [void]$newLines.Add(' directory-mode = ignore')
                    $mod = $true; continue
                }
                [void]$newLines.Add($line)
            }
            if ($removed -gt 0 -or $mod) {
                Write-LfFile $mpvConf $newLines.ToArray() $enc
                return '  - 已恢复（移除 autocreate-playlist + directory-mode→ignore）'
            }
            return '  - 无需恢复'
        }
    },

    @{
        Name    = "单击暂停·双击全屏"
        Desc    = "smart-click.lua + input_uosc.conf 两处修改"
        Apply   = {
            param($dir, $enc)
            $inputConf = Join-Path $dir "input_uosc.conf"
            $luaPath   = Join-Path $dir "scripts\smart-click.lua"
            $msgs = @()

            # input_uosc.conf
            if (Test-Path $inputConf) {
                $lines = [IO.File]::ReadAllLines($inputConf, $enc)
                $mod = $false
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match '^\s*MBTN_LEFT\s+ignore\s*$') {
                        $lines[$i] = " MBTN_LEFT         script-message smart-click                       # 单击暂停/双击全屏"
                        $mod = $true
                    }
                    elseif ($lines[$i] -match 'MBTN_LEFT\s+script-message\s+smart-click') {
                        # 已修改，跳过
                    }
                    if ($lines[$i] -match '^\s*MBTN_LEFT_DBL\s+cycle fullscreen') {
                        $lines[$i] = " MBTN_LEFT_DBL     ignore                                                # 由smart-click接管"
                        $mod = $true
                    }
                    elseif ($lines[$i] -match 'MBTN_LEFT_DBL\s+ignore\s+# 由smart-click接管') {
                        # 已修改，跳过
                    }
                }
                if ($mod) {
                    Write-LfFile $inputConf $lines $enc
                    $msgs += "  + input_uosc.conf 已修改"
                } else {
                    $msgs += "  - input_uosc.conf 无需修改"
                }
            } else {
                $msgs += "  [跳过] input_uosc.conf 不存在"
            }

            # smart-click.lua
            $luaContent = @'
-- smart-click.lua
-- 单击暂停 + 双击全屏，互不冲突
-- 无边框模式下顶部标题栏区域忽略点击

local msg = require('mp.msg')

local DOUBLE_CLICK_TIME = 200  -- 毫秒
local TITLE_BAR_PX = 40       -- 顶部排除区域（像素）

local last_click_time = 0
local pending_timer = nil

local function in_title_bar()
    local fs = mp.get_property_bool('fullscreen', false)
    local max = mp.get_property_bool('window-maximized', false)
    if fs or max then return false end
    local mouse = mp.get_property_native('mouse-pos')
    if not mouse or not mouse.y then return false end
    return mouse.y < TITLE_BAR_PX
end

local function do_single()
    if in_title_bar() then return end
    mp.command('cycle pause')
end

local function on_click()
    local now = mp.get_time() * 1000
    if now - last_click_time < DOUBLE_CLICK_TIME and last_click_time > 0 then
        last_click_time = 0
        if pending_timer then pending_timer:kill(); pending_timer = nil end
        mp.command('cycle fullscreen')
    else
        last_click_time = now
        if pending_timer then pending_timer:kill() end
        pending_timer = mp.add_timeout(DOUBLE_CLICK_TIME / 1000, do_single)
    end
end

mp.register_script_message('smart-click', on_click)
msg.info('smart-click loaded')
'@
            if (-not (Test-Path (Split-Path $luaPath))) {
                New-Item -ItemType Directory -Path (Split-Path $luaPath) | Out-Null
            }
            [IO.File]::WriteAllText($luaPath, $luaContent, $enc)
            $msgs += "  + scripts\smart-click.lua 已写入"

            return $msgs -join "`r`n"
        }
        Restore = {
            param($dir, $enc)
            $inputConf = Join-Path $dir "input_uosc.conf"
            $luaPath   = Join-Path $dir "scripts\smart-click.lua"
            $msgs = @()

            # input_uosc.conf 还原
            if (Test-Path $inputConf) {
                $lines = [IO.File]::ReadAllLines($inputConf, $enc)
                $mod = $false
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match 'MBTN_LEFT\s+script-message\s+smart-click') {
                        $lines[$i] = " MBTN_LEFT         ignore"
                        $mod = $true
                    }
                    if ($lines[$i] -match 'MBTN_LEFT_DBL\s+ignore\s+# 由smart-click接管') {
                        $lines[$i] = " MBTN_LEFT_DBL     cycle fullscreen                                      # 全屏/窗口"
                        $mod = $true
                    }
                }
                if ($mod) {
                    Write-LfFile $inputConf $lines $enc
                    $msgs += "  - input_uosc.conf 已还原"
                } else {
                    $msgs += "  - input_uosc.conf 无需还原"
                }
            } else {
                $msgs += "  [跳过] input_uosc.conf 不存在"
            }

            # smart-click.lua 删除
            if (Test-Path $luaPath) {
                Remove-Item $luaPath -Force
                $msgs += "  - scripts\smart-click.lua 已删除"
            } else {
                $msgs += "  - smart-click.lua 不存在，无需删除"
            }

            return $msgs -join "`r`n"
        }
    },
    @{
        Name    = "音量跟随系统"
        Desc    = "隐藏音量条 + 锁定volume=100 + 停止追踪音量 + 禁用音量快捷键"
        Apply   = {
            param($dir, $enc)
            $msgs = @()

            # --- 1. script-opts.conf: 隐藏音量条 + 停止追踪音量 ---
            $soFile = Join-Path $dir "script-opts.conf"
            if (Test-Path $soFile) {
                $lines = [IO.File]::ReadAllLines($soFile, $enc)
                $mod = $false
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    # 添加 uosc-volume=no
                    if ($lines[$i] -match 'uosc-volume\s*=\s*no') {
                        # 已有
                    }
                    # 停止追踪 volume/mute（改为追踪空列表）
                    if ($lines[$i] -match 'save_global_props-props\s*=\s*volume,mute') {
                        $lines[$i] = ' script-opts-append = save_global_props-props=              # 停止追踪音量（跟随系统）'
                        $mod = $true
                    }
                }
                # 添加 uosc-volume=no（如果不存在）
                $hasVolNo = $false
                foreach ($line in $lines) {
                    if ($line -match 'uosc-volume\s*=\s*no') { $hasVolNo = $true; break }
                }
                if (-not $hasVolNo) {
                    $lastUoscIdx = -1
                    for ($i = 0; $i -lt $lines.Count; $i++) {
                        if ($lines[$i] -match 'uosc-') { $lastUoscIdx = $i }
                    }
                    $newLines = [System.Collections.ArrayList]::new()
                    for ($i = 0; $i -lt $lines.Count; $i++) {
                        [void]$newLines.Add($lines[$i])
                        if ($i -eq $lastUoscIdx) {
                            [void]$newLines.Add(' script-opts-append = uosc-volume=no                         # 隐藏音量条')
                        }
                    }
                    $lines = $newLines.ToArray()
                    $mod = $true
                }
                if ($mod) {
                    Write-LfFile $soFile $lines $enc
                    $msgs += '  + script-opts.conf 已修改'
                } else {
                    $msgs += '  - script-opts.conf 无需修改'
                }
            } else {
                $msgs += '  [跳过] script-opts.conf 不存在'
            }

            # --- 2. mpv.conf: volume-max 改为 100 ---
            $mpvConf = Join-Path $dir "mpv.conf"
            if (Test-Path $mpvConf) {
                $lines = [IO.File]::ReadAllLines($mpvConf, $enc)
                $newLines = [System.Collections.ArrayList]::new()
                $found = $false
                $mod = $false
                foreach ($line in $lines) {
                    if ($line -match 'volume-max') {
                        if (-not $found) {
                            # 第一处：改为100
                            $found = $true
                            if ($line -match 'volume-max\s*=\s*100') {
                                # 已经是100，保留
                            } else {
                                $line = ' volume-max = 100  # 锁定上限，跟随系统音量'
                                $mod = $true
                            }
                        } else {
                            # 重复行，删除
                            $mod = $true
                            continue
                        }
                    }
                    [void]$newLines.Add($line)
                }
                if ($mod) {
                    Write-LfFile $mpvConf $newLines.ToArray() $enc
                    $msgs += '  + mpv.conf: volume-max 改为 100（去重）'
                } else {
                    $msgs += '  - mpv.conf: volume-max 无需修改'
                }
            } else {
                $msgs += '  [跳过] mpv.conf 不存在'
            }

            # --- 3. saved-props.json: 清空音量追踪 ---
            $savedProps = Join-Path $dir "saved-props.json"
            # 无论文件是否存在都写入 {}（原版不存在，补丁需要创建）
            [IO.File]::WriteAllText($savedProps, '{}', $enc)
            $msgs += '  + saved-props.json 已清空'

            # --- 4. input_uosc.conf: 注释掉音量快捷键 ---
            $inputConf = Join-Path $dir "input_uosc.conf"
            if (Test-Path $inputConf) {
                $lines = [IO.File]::ReadAllLines($inputConf, $enc)
                $mod = $false
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    # 匹配 "-  no-osd add volume" 或 "=  no-osd add volume"
                    if ($lines[$i] -match '^(\s*[-=]\s+)no-osd\s+add\s+volume' -and $lines[$i] -notmatch '^#') {
                        $lines[$i] = '#' + $lines[$i] + '  # 禁用音量调节（跟随系统）'
                        $mod = $true
                    }
                }
                if ($mod) {
                    Write-LfFile $inputConf $lines $enc
                    $msgs += '  + input_uosc.conf: 音量快捷键已禁用'
                } else {
                    $msgs += '  - input_uosc.conf: 音量快捷键无需修改'
                }
            } else {
                $msgs += '  [跳过] input_uosc.conf 不存在'
            }

            return $msgs -join "`r`n"
        }
        Restore = {
            param($dir, $enc)
            $msgs = @()

            # --- 1. script-opts.conf: 还原 ---
            $soFile = Join-Path $dir "script-opts.conf"
            if (Test-Path $soFile) {
                $lines = [IO.File]::ReadAllLines($soFile, $enc)
                $newLines = [System.Collections.ArrayList]::new()
                $removed = 0
                $mod = $false
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    # 移除 uosc-volume=no
                    if ($lines[$i] -match 'uosc-volume\s*=\s*no') {
                        $removed++
                        continue
                    }
                    # 还原 save_global_props-props
                    if ($lines[$i] -match 'save_global_props-props\s*=\s*#.*停止追踪') {
                        $lines[$i] = ' script-opts-append = save_global_props-props=volume,mute'
                        $mod = $true
                    }
                    [void]$newLines.Add($lines[$i])
                }
                if ($removed -gt 0 -or $mod) {
                    Write-LfFile $soFile $newLines.ToArray() $enc
                    $msgs += "  - script-opts.conf 已还原（移除$removed行+还原追踪）"
                } else {
                    $msgs += '  - script-opts.conf 无需还原'
                }
            } else {
                $msgs += '  [跳过] script-opts.conf 不存在'
            }

            # --- 2. mpv.conf: volume-max 还原为 130 ---
            $mpvConf = Join-Path $dir "mpv.conf"
            if (Test-Path $mpvConf) {
                $lines = [IO.File]::ReadAllLines($mpvConf, $enc)
                $newLines = [System.Collections.ArrayList]::new()
                $found = $false
                $mod = $false
                foreach ($line in $lines) {
                    if ($line -match 'volume-max') {
                        if (-not $found) {
                            $found = $true
                            if ($line -match 'volume-max\s*=\s*100') {
                                $line = ' volume-max = 130'
                                $mod = $true
                            }
                        } else {
                            # 重复行删除
                            $mod = $true
                            continue
                        }
                    }
                    [void]$newLines.Add($line)
                }
                if ($mod) {
                    Write-LfFile $mpvConf $newLines.ToArray() $enc
                    $msgs += '  - mpv.conf: volume-max 还原为 130（去重）'
                } else {
                    $msgs += '  - mpv.conf: volume-max 无需还原'
                }
            } else {
                $msgs += '  [跳过] mpv.conf 不存在'
            }

            # --- 3. saved-props.json: 删除（原版不存在此文件） ---
            $savedProps = Join-Path $dir "saved-props.json"
            if (Test-Path $savedProps) {
                Remove-Item $savedProps -Force
                $msgs += '  - saved-props.json 已删除（原版不存在）'
            }

            # --- 4. input_uosc.conf: 取消注释音量快捷键 ---
            $inputConf = Join-Path $dir "input_uosc.conf"
            if (Test-Path $inputConf) {
                $lines = [IO.File]::ReadAllLines($inputConf, $enc)
                $mod = $false
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match '^#(\s*[-=]\s+no-osd\s+add\s+volume.*?)\s*# 禁用音量调节（跟随系统）') {
                        # 去掉行首 # 和行尾 # 禁用音量调节（跟随系统），恢复原行
                        $lines[$i] = $Matches[1]
                        $mod = $true
                    }
                }
                if ($mod) {
                    Write-LfFile $inputConf $lines $enc
                    $msgs += '  - input_uosc.conf: 音量快捷键已还原'
                } else {
                    $msgs += '  - input_uosc.conf: 无需还原'
                }
            } else {
                $msgs += '  [跳过] input_uosc.conf 不存在'
            }

            return $msgs -join "`r`n"
        }
    },
    @{
        Name    = "片头片尾书签跳过"
        Desc    = "bookmark-skip.lua + Ctrl+←/→/B/X 键绑定 + uosc #! 菜单"
        Apply   = {
            param($dir, $enc)
            $luaPath   = Join-Path $dir "scripts\bookmark-skip.lua"
            $inputConf = Join-Path $dir "input_uosc.conf"
            $msgs = @()

            # bookmark-skip.lua（内嵌，不依赖外部文件）
            $luaContent = @'
-- bookmark-skip.lua
-- 片头/片尾/区间跳过，同目录视频共享书签
-- Ctrl+← 片头 / Ctrl+→ 片尾 / Ctrl+B 区间 / Ctrl+X 清除

local msg = require('mp.msg')
local utils = require('mp.utils')

local SKIP_THRESHOLD = 0.5
local DATA_FILE = "~~/script-data/bookmark_skip.json"
local OSD_DURATION = 3

local bookmarks = {}
local pending_start = nil
local pending_timer = nil
local menu_open = false

-- ========== 工具 ==========

local function get_data_path()
    return mp.command_native({"expand-path", DATA_FILE})
end

local function dir_hash(path)
    if not path or path == "" then return nil end
    local dir = utils.split_path(path)
    if not dir or dir == "" then return nil end
    local h = 0
    for i = 1, #dir do
        h = (h * 31 + string.byte(dir, i)) % 1000000007
    end
    return tostring(h)
end

local function get_dir_name(path)
    if not path or path == "" then return "未知" end
    local dir = utils.split_path(path)
    if not dir then return "未知" end
    dir = dir:gsub("[/\\]$", "")
    return dir:match("[^/\\]+$") or "未知"
end

local function format_time(sec)
    if not sec or sec < 0 then return "0:00" end
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = math.floor(sec % 60)
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

local function format_dur(sec)
    if not sec or sec <= 0 then return "0s" end
    sec = math.floor(sec + 0.5)
    if sec < 60 then return string.format("%ds", sec) end
    local m = math.floor(sec / 60)
    local s = sec % 60
    if s == 0 then return string.format("%dm", m) end
    return string.format("%dm%02ds", m, s)
end

local function load_bookmarks()
    local path = get_data_path()
    local f = io.open(path, "r")
    if not f then bookmarks = {}; return end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then bookmarks = {}; return end
    local ok, data = pcall(utils.parse_json, content)
    if not ok or type(data) ~= "table" then bookmarks = {}; return end
    bookmarks = data
end

local function save_bookmarks()
    local path = get_data_path()
    local dir = utils.split_path(path)
    os.execute('mkdir "' .. dir:gsub('/', '\\') .. '" 2>nul')
    local f = io.open(path, "w")
    if f then f:write(utils.format_json(bookmarks)); f:close() end
end

local function get_current_hash()
    local path = mp.get_property("path")
    if not path then return nil end
    return dir_hash(path)
end

-- 清理目录已不存在的书签
local function cleanup_orphaned()
    local changed = false
    for h, data in pairs(bookmarks) do
        local dir = data.path
        if dir and not os.rename(dir, dir) then
            bookmarks[h] = nil
            changed = true
        end
    end
    if changed then save_bookmarks() end
end

local function get_current_items()
    local h = get_current_hash()
    if not h or not bookmarks[h] then return {} end
    return bookmarks[h].items or {}
end

local function sort_items(items)
    table.sort(items, function(a, b) return a["start"] < b["start"] end)
end

-- ========== pending 定时刷新 ==========

local function stop_pending_timer()
    if pending_timer then pending_timer:kill(); pending_timer = nil end
end

local function update_pending_osd()
    if not pending_start then stop_pending_timer(); return end
    local pos = mp.get_property_number("time-pos") or 0
    local s, e_ = pending_start, pos
    if s > e_ then s, e_ = e_, s end
    mp.osd_message(
        string.format("标记区间  %s → %s (%s)\nCtrl+B 完成 / Ctrl+X 取消",
            format_time(s), format_time(e_), format_dur(e_ - s)), 1.5)
end

-- ========== 标记 ==========

local function add_bookmark(label, start_, end_)
    local path = mp.get_property("path")
    if not path then mp.osd_message("无文件播放中", OSD_DURATION); return end
    local h = dir_hash(path)
    if not h then return end
    if not bookmarks[h] then
        bookmarks[h] = { name = get_dir_name(path), path = utils.split_path(path):gsub("[/\\]$", ""), items = {} }
    end
    if label == "片头" or label == "片尾" then
        local items = bookmarks[h].items
        for i = #items, 1, -1 do
            if items[i].label == label then table.remove(items, i) end
        end
    end
    table.insert(bookmarks[h].items, { label = label, ["start"] = start_, ["end"] = end_ })
    sort_items(bookmarks[h].items)
    save_bookmarks()
end

function mark_opening()
    local pos = mp.get_property_number("time-pos")
    if not pos or pos <= 0 then mp.osd_message("位置无效", OSD_DURATION); return end
    add_bookmark("片头", 0, pos)
    show_status()
    refresh_menu()
end

function mark_ending()
    local pos = mp.get_property_number("time-pos")
    local dur = mp.get_property_number("duration")
    if not pos then mp.osd_message("位置无效", OSD_DURATION); return end
    add_bookmark("片尾", pos, dur or (pos + 1))
    show_status()
    refresh_menu()
end

function mark_custom()
    if pending_start then
        local pos = mp.get_property_number("time-pos")
        if not pos then mp.osd_message("位置无效", OSD_DURATION); return end
        local s, e_ = pending_start, pos
        if s > e_ then s, e_ = e_, s end
        pending_start = nil
        stop_pending_timer()
        add_bookmark("区间", s, e_)
        show_status()
        refresh_menu()
    else
        local pos = mp.get_property_number("time-pos")
        if not pos then mp.osd_message("位置无效", OSD_DURATION); return end
        pending_start = pos
        update_pending_osd()
        pending_timer = mp.add_periodic_timer(0.5, update_pending_osd)
    end
end

-- ========== 显示 ==========

function show_status()
    local items = get_current_items()
    if #items == 0 then
        mp.osd_message("无跳过区间", OSD_DURATION)
        return
    end
    local lines = {}
    for i, bk in ipairs(items) do
        lines[#lines + 1] = string.format("%s %s→%s (%s)",
            bk.label, format_time(bk["start"]), format_time(bk["end"]),
            format_dur(bk["end"] - bk["start"]))
    end
    mp.osd_message(table.concat(lines, "\n"), OSD_DURATION)
end

-- ========== 删除 ==========

function delete_index(idx)
    local h = get_current_hash()
    if not h or not bookmarks[h] then return end
    local items = bookmarks[h].items
    if not items or idx < 1 or idx > #items then return end
    local removed = table.remove(items, idx)
    if #items == 0 then bookmarks[h] = nil end
    save_bookmarks()
    mp.osd_message(string.format("已删除 %s %s→%s", removed.label, format_time(removed["start"]), format_time(removed["end"])), OSD_DURATION)
    refresh_menu()
end

function clear_current()
    if pending_start then
        pending_start = nil
        stop_pending_timer()
        mp.osd_message("已取消标记", OSD_DURATION)
        return
    end
    local h = get_current_hash()
    if not h or not bookmarks[h] then mp.osd_message("无书签", OSD_DURATION); return end
    local n = #(bookmarks[h].items or {})
    bookmarks[h] = nil
    save_bookmarks()
    mp.osd_message(string.format("已清除 %d 条", n), OSD_DURATION)
    refresh_menu()
end

-- ========== 自动跳过 ==========

local function check_skip()
    local pos = mp.get_property_number("time-pos")
    if not pos then return end
    local items = get_current_items()
    for _, bk in ipairs(items) do
        if pos >= bk["start"] and pos < bk["end"] then
            mp.commandv("set", "time-pos", tostring(bk["end"]))
            mp.osd_message(string.format("跳过%s %s→%s", bk.label, format_time(bk["start"]), format_time(bk["end"])), OSD_DURATION)
            return
        end
    end
end

-- ========== uosc 菜单 ==========

local function build_menu_items()
    local items = get_current_items()
    local menu_items = {}

    menu_items[#menu_items + 1] = {
        title = "标记片头", hint = "Ctrl+←",
        value = "script-message bookmark-skip-opening",
        keep_open = true
    }
    menu_items[#menu_items + 1] = {
        title = "标记片尾", hint = "Ctrl+→",
        value = "script-message bookmark-skip-ending",
        keep_open = true
    }
    menu_items[#menu_items + 1] = {
        title = "标记区间", hint = "Ctrl+B",
        value = "script-message bookmark-skip-custom",
        keep_open = true
    }

    if #items > 0 then
        menu_items[#menu_items + 1] = { title = "", separator = true }
        for i, bk in ipairs(items) do
            menu_items[#menu_items + 1] = {
                title = string.format("%s  %s → %s", bk.label, format_time(bk["start"]), format_time(bk["end"])),
                hint = format_dur(bk["end"] - bk["start"]) .. "  点此删除",
                value = string.format("script-message bookmark-skip-delete %d", i)
            }
        end
        menu_items[#menu_items + 1] = { title = "", separator = true }
        menu_items[#menu_items + 1] = {
            title = "清除本目录", hint = "Ctrl+X",
            value = "script-message bookmark-skip-clear"
        }
    end

    return menu_items
end

local function build_menu_data()
    return {
        type = "bookmark-skip-menu",
        title = "跳过片头/尾",
        items = build_menu_items()
    }
end

local function open_menu()
    menu_open = true
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(build_menu_data()))
end

function refresh_menu()
    if not menu_open then return end
    mp.commandv("script-message-to", "uosc", "update-menu", utils.format_json(build_menu_data()))
end

-- 菜单关闭时清除标记
mp.register_script_message("menu-closed", function(type)
    if type == "bookmark-skip-menu" then menu_open = false end
end)

-- ========== 事件 ==========

mp.register_event("file-loaded", function()
    if #get_current_items() > 0 then show_status() end
end)

mp.add_periodic_timer(SKIP_THRESHOLD, check_skip)

-- ========== 快捷键 ==========

mp.add_key_binding("ctrl+left",  "bookmark-mark-op",  mark_opening)
mp.add_key_binding("ctrl+right", "bookmark-mark-ed",  mark_ending)
mp.add_key_binding("ctrl+b",     "bookmark-toggle",   mark_custom)
mp.add_key_binding("ctrl+x",     "bookmark-clear",    clear_current)

-- ========== Script-message ==========

mp.register_script_message("bookmark-skip-opening", mark_opening)
mp.register_script_message("bookmark-skip-ending",  mark_ending)
mp.register_script_message("bookmark-skip-custom",  mark_custom)
mp.register_script_message("bookmark-skip-clear",   clear_current)
mp.register_script_message("bookmark-skip-menu",    open_menu)
mp.register_script_message("bookmark-skip-delete",  function(idx_str)
    local idx = tonumber(idx_str)
    if idx then delete_index(idx) end
end)

-- ========== 初始化 ==========

load_bookmarks()
cleanup_orphaned()
msg.info("bookmark-skip loaded")

'@
            if (-not (Test-Path (Split-Path $luaPath))) {
                New-Item -ItemType Directory -Path (Split-Path $luaPath) | Out-Null
            }
            [IO.File]::WriteAllText($luaPath, $luaContent, $enc)
            $msgs += "  + scripts\bookmark-skip.lua 已写入"

            # input_uosc.conf: 键绑定 + #! 菜单项
            if (Test-Path $inputConf) {
                $content = [IO.File]::ReadAllText($inputConf, $enc)
                $added = @()

                # 键绑定
                if ($content -notmatch 'bookmark-mark-op') {
                    $content += "
 Ctrl+LEFT         script-binding bookmark-mark-op                 # 标记片头"
                    $added += "Ctrl+LEFT"
                }
                if ($content -notmatch 'bookmark-mark-ed') {
                    $content += "
 Ctrl+RIGHT        script-binding bookmark-mark-ed                 # 标记片尾"
                    $added += "Ctrl+RIGHT"
                }
                if ($content -notmatch 'bookmark-toggle') {
                    $content += "
 Ctrl+B            script-binding bookmark-toggle                  # 标记区间"
                    $added += "Ctrl+B"
                }
                if ($content -notmatch 'bookmark-clear') {
                    $content += "
 Ctrl+X            script-binding bookmark-clear                   # 清除书签"
                    $added += "Ctrl+X"
                }

                # #! 菜单项（uosc 右键菜单）— 插入到 AB循环点后面
                if ($content -notmatch 'bookmark-skip-menu') {
                    $lines = $content -split "`r?`n"
                    $insertIdx = -1
                    for ($i = 0; $i -lt $lines.Count; $i++) {
                        if ($lines[$i] -match 'ab-loop.*AB循环') { $insertIdx = $i + 1; break }
                    }
                    if ($insertIdx -ge 0) {
                        $newLines = [System.Collections.ArrayList]::new($lines)
                        $newLines.Insert($insertIdx, "#                  script-message bookmark-skip-menu              #! 播放 > 跳过片头/尾")
                        $content = $newLines -join "`n"
                    } else {
                        $content += "`n#                  script-message bookmark-skip-menu              #! 播放 > 跳过片头/尾"
                    }
                    $added += "菜单项"
                }

                if ($added.Count -gt 0) {
                    [IO.File]::WriteAllText($inputConf, $content, $enc)
                    $msgs += "  + input_uosc.conf: 已添加 $($added -join ', ')"
                } else {
                    $msgs += "  - input_uosc.conf: 已存在"
                }
            }

            return $msgs -join "`r`n"
        }
        Restore = {
            param($dir, $enc)
            $msgs = @()

            $luaPath = Join-Path $dir "scripts\bookmark-skip.lua"
            if (Test-Path $luaPath) {
                Remove-Item $luaPath -Force
                $msgs += "  - scripts\bookmark-skip.lua 已删除"
            }

            # 清理书签数据
            $dataFile = Join-Path $dir "script-data\bookmark_skip.json"
            if (Test-Path $dataFile) {
                Remove-Item $dataFile -Force
                $msgs += "  - script-data\bookmark_skip.json 已删除"
            }
            $oldDataFile = Join-Path $dir "watch_later\bookmark_skip.json"
            if (Test-Path $oldDataFile) {
                Remove-Item $oldDataFile -Force
                $msgs += "  - watch_later\bookmark_skip.json (旧版) 已删除"
            }

            # input_uosc.conf: 移除键绑定 + #! 菜单项
            $inputConf = Join-Path $dir "input_uosc.conf"
            if (Test-Path $inputConf) {
                $lines = [IO.File]::ReadAllLines($inputConf, $enc)
                $newLines = [System.Collections.ArrayList]::new()
                $removed = 0
                foreach ($line in $lines) {
                    if ($line -match 'bookmark-') { $removed++; continue }
                    [void]$newLines.Add($line)
                }
                if ($removed -gt 0) {
                    Write-LfFile $inputConf $newLines.ToArray() $enc
                    $msgs += "  - input_uosc.conf: 已移除 $removed 行书签相关"
                }
            }

            return $msgs -join "`r`n"
        }
    }
)

# ━━━ 执行单个操作 ━━
function Invoke-PatchAction {
    param($patch, [string]$action)
    $label = if ($action -eq "restore") { "恢复" } else { "应用" }
    $func  = if ($action -eq "restore") { "Restore" } else { "Apply" }
    Write-Host ""
    Write-Host "--- [$label] $($patch.Name) ---" -ForegroundColor Cyan
    $result = & $patch.$func $CfgDir $enc
    if ($result) { $result -split "`r`n" | ForEach-Object { Write-Host $_ } }
    Write-Host "完成！" -ForegroundColor Green
    Write-Host ""
    Read-Host "按回车返回"
}

# ━━━ 主菜单 ━━
while ($true) {
    Clear-Host
    Write-Host " MPV 自定义补丁  " -ForegroundColor Cyan -BackgroundColor DarkGray
    Write-Host "  $CfgDir" -ForegroundColor DarkGray
    Write-Host ""
    for ($i = 0; $i -lt $PatchList.Count; $i++) {
        Write-Host ("  {0,2}. {1}" -f ($i+1), $PatchList[$i].Name)
    }
    Write-Host ""
    Write-Host "  A. 一键全部应用  R. 一键全部恢复  Q. 退出" -ForegroundColor DarkGray

    $key = (Read-Host " >")
    if ($null -ne $key) { $key = $key.Trim().ToUpper() } else { $key = "" }

    if ($key -eq "Q") {
        break
    }

    # 一键全部应用
    if ($key -eq "A") {
        Clear-Host
        Write-Host " 一键全部应用 " -ForegroundColor Black -BackgroundColor Green
        Write-Host ""
        for ($i = 0; $i -lt $PatchList.Count; $i++) {
            Write-Host "  [$($i+1)] $($PatchList[$i].Name)" -ForegroundColor Cyan
            $result = & $PatchList[$i].Apply $CfgDir $enc
            if ($result) { $result -split "`r`n" | ForEach-Object { Write-Host "    $_" } }
        }
        Write-Host ""
        Write-Host " 完成 " -ForegroundColor Black -BackgroundColor Green
        Read-Host " 回车返回"
        continue
    }

    # 一键全部恢复
    if ($key -eq "R") {
        Clear-Host
        Write-Host " ⚠ 恢复所有模块到原版？输入 Y 确认 " -ForegroundColor Black -BackgroundColor Yellow
        $confirm = (Read-Host " >")
        if ($confirm -ne "Y") { continue }
        Clear-Host
        Write-Host " 一键全部恢复 " -ForegroundColor Black -BackgroundColor Red
        Write-Host ""
        for ($i = $PatchList.Count - 1; $i -ge 0; $i--) {
            Write-Host "  [$($i+1)] $($PatchList[$i].Name)" -ForegroundColor Cyan
            $result = & $PatchList[$i].Restore $CfgDir $enc
            if ($result) { $result -split "`r`n" | ForEach-Object { Write-Host "    $_" } }
        }
        Write-Host ""
        Write-Host " 完成 " -ForegroundColor Black -BackgroundColor Green
        Read-Host " 回车返回"
        continue
    }

    if ($key -notmatch '^\d+$') { continue }
    $idx = [int]$key - 1
    if ($idx -lt 0 -or $idx -ge $PatchList.Count) { continue }

    $patch = $PatchList[$idx]

    # 子菜单
    Clear-Host
    Write-Host " $($patch.Name) " -ForegroundColor Black -BackgroundColor Cyan
    Write-Host "  $($patch.Desc)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  1. 应用  2. 恢复  0. 返回"
    $sub = (Read-Host " >")
    if ($null -ne $sub) { $sub = $sub.Trim() } else { $sub = "" }

    if ($sub -eq "1") {
        Clear-Host
        Write-Host " [应用] $($patch.Name) " -ForegroundColor Black -BackgroundColor Green
        $result = & $patch.Apply $CfgDir $enc
        if ($result) { $result -split "`r`n" | ForEach-Object { Write-Host "  $_" } }
        Write-Host ""
        Read-Host " 完成，回车返回"
    }
    elseif ($sub -eq "2") {
        Clear-Host
        Write-Host " [恢复] $($patch.Name) " -ForegroundColor Black -BackgroundColor Red
        $result = & $patch.Restore $CfgDir $enc
        if ($result) { $result -split "`r`n" | ForEach-Object { Write-Host "  $_" } }
        Write-Host ""
        Read-Host " 完成，回车返回"
    }
}

<#
  添加新功能模块方法：

  在 $PatchList 数组中添加一个新的哈希表：

  @{
      Name    = "功能名称"
      Desc    = "简短描述"
      Apply   = {
          param($dir, $enc)
          # 应用逻辑
          return "  + 已添加 xxx"
      }
      Restore = {
          param($dir, $enc)
          # 恢复逻辑
          return "  - 已还原 xxx"
      }
  }
#>
