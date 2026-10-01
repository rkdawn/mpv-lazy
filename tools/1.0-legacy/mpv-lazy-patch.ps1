<#
.SYNOPSIS
    MPV 自定义补丁脚本（模块化）
.DESCRIPTION
    菜单式选择功能模块，进入后选择应用或恢复。
    添加新功能时，只需在下面添加 PatchList 条目即可。
.NOTES
    将脚本放到 mpv-lazy 根目录下，双击 mpv-lazy-patch.bat 运行
#>

# ━━━ 自动检索配置目录 ━━
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$candidates = @(
    (Join-Path $scriptDir "portable_config")
)
$CfgDir = $null
foreach ($p in $candidates) {
    if (Test-Path (Join-Path $p "mpv.conf")) {
        $CfgDir = $p
        break
    }
}
if (-not $CfgDir) {
    Write-Host "[错误] 未找到 mpv.conf，请将此脚本放到 mpv-lazy 根目录下" -ForegroundColor Red
    Write-Host "目录结构应为：mpv-lazy/mpv-lazy-patch.ps1" -ForegroundColor Yellow
    Write-Host "                 mpv-lazy/portable_config/mpv.conf" -ForegroundColor Yellow
    Read-Host "按回车退出"
    exit 1
}

$ErrorActionPreference = "Stop"
$enc = New-Object System.Text.UTF8Encoding $false

# ━━━ 补丁模块定义 ━━
$PatchList = @(
    @{
        Name    = "无边框窗口 + 65%默认大小"
        Desc    = "border=no + autofit=65%"
        Apply   = {
            param($dir, $enc)
            $mpvConf = Join-Path $dir "mpv.conf"
            if (-not (Test-Path $mpvConf)) { return "[跳过] mpv.conf 不存在" }
            $content = [IO.File]::ReadAllText($mpvConf, $enc)
            if ($content -match 'border\s*=\s*no') {
                return "  - border=no 已存在，跳过"
            }
            $content = $content -replace '( keep-open = yes)', " border = no # 无边框`r`nautofit = 65% # 窗口默认占65%`r`n`$1"
            [IO.File]::WriteAllText($mpvConf, $content, $enc)
            return "  + 已添加 border=no 和 autofit=65%"
        }
        Restore = {
            param($dir, $enc)
            $mpvConf = Join-Path $dir "mpv.conf"
            if (-not (Test-Path $mpvConf)) { return "[跳过] mpv.conf 不存在" }
            $lines = [IO.File]::ReadAllLines($mpvConf, $enc)
            $newLines = [System.Collections.ArrayList]::new()
            $removed = 0
            foreach ($line in $lines) {
                if ($line -match '^\s*border\s*=\s*no' -or $line -match '^\s*autofit\s*=\s*65%') {
                    $removed++
                    continue
                }
                [void]$newLines.Add($line)
            }
            if ($removed -gt 0) {
                [IO.File]::WriteAllLines($mpvConf, $newLines.ToArray(), $enc)
                return "  - 已移除 border=no 和 autofit=65%（$removed 行）"
            }
            return "  - 无需恢复，未找到相关行"
        }
    },
    @{
        Name    = "单击暂停 / 双击全屏"
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
                    [IO.File]::WriteAllLines($inputConf, $lines, $enc)
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
                    [IO.File]::WriteAllLines($inputConf, $lines, $enc)
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
        Name    = "禁用音量控制 + 跟随系统"
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
                    [IO.File]::WriteAllLines($soFile, $lines, $enc)
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
                $content = [IO.File]::ReadAllText($mpvConf, $enc)
                if ($content -match 'volume-max\s*=\s*130') {
                    $content = $content -replace 'volume-max\s*=\s*130', 'volume-max = 100  # 锁定上限，跟随系统音量'
                    [IO.File]::WriteAllText($mpvConf, $content, $enc)
                    $msgs += '  + mpv.conf: volume-max 改为 100'
                } else {
                    $msgs += '  - mpv.conf: volume-max 无需修改'
                }
            } else {
                $msgs += '  [跳过] mpv.conf 不存在'
            }

            # --- 3. saved-props.json: 清空音量追踪 ---
            $savedProps = Join-Path $dir "saved-props.json"
            if (Test-Path $savedProps) {
                [IO.File]::WriteAllText($savedProps, '{}', $enc)
                $msgs += '  + saved-props.json 已清空'
            }

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
                    [IO.File]::WriteAllLines($inputConf, $lines, $enc)
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
                    if ($lines[$i] -match 'save_global_props-props\s*=\s*# 停止追踪音量') {
                        $lines[$i] = ' script-opts-append = save_global_props-props=volume,mute'
                        $mod = $true
                    }
                    [void]$newLines.Add($lines[$i])
                }
                if ($removed -gt 0 -or $mod) {
                    [IO.File]::WriteAllLines($soFile, $newLines.ToArray(), $enc)
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
                $content = [IO.File]::ReadAllText($mpvConf, $enc)
                if ($content -match 'volume-max\s*=\s*100') {
                    $content = $content -replace 'volume-max\s*=\s*100.*', 'volume-max = 130'
                    [IO.File]::WriteAllText($mpvConf, $content, $enc)
                    $msgs += '  - mpv.conf: volume-max 还原为 130'
                } else {
                    $msgs += '  - mpv.conf: volume-max 无需还原'
                }
            } else {
                $msgs += '  [跳过] mpv.conf 不存在'
            }

            # --- 3. saved-props.json: 还原默认值 ---
            $savedProps = Join-Path $dir "saved-props.json"
            if (Test-Path $savedProps) {
                [IO.File]::WriteAllText($savedProps, '{"volume":100,"mute":false}', $enc)
                $msgs += '  - saved-props.json 已还原'
            }

            # --- 4. input_uosc.conf: 取消注释音量快捷键 ---
            $inputConf = Join-Path $dir "input_uosc.conf"
            if (Test-Path $inputConf) {
                $lines = [IO.File]::ReadAllLines($inputConf, $enc)
                $mod = $false
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match '^#(\s*[-=]\s+no-osd\s+add\s+volume.*)# 禁用音量调节') {
                        $lines[$i] = $Matches[1]
                        $mod = $true
                    }
                }
                if ($mod) {
                    [IO.File]::WriteAllLines($inputConf, $lines, $enc)
                    $msgs += '  - input_uosc.conf: 音量快捷键已还原'
                } else {
                    $msgs += '  - input_uosc.conf: 无需还原'
                }
            } else {
                $msgs += '  [跳过] input_uosc.conf 不存在'
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
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  MPV 自定义补丁" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  配置目录：$CfgDir" -ForegroundColor DarkGray
    Write-Host ""
    for ($i = 0; $i -lt $PatchList.Count; $i++) {
        Write-Host ("  {0,2}. {1}" -f ($i+1), $PatchList[$i].Name) -ForegroundColor White
    }
    Write-Host "   Q.  退出" -ForegroundColor DarkGray
    Write-Host ""

    $key = (Read-Host "选择功能编号")
    if ($null -ne $key) { $key = $key.Trim() } else { $key = "" }

    if ($key -eq "q" -or $key -eq "Q") {
        Write-Host "再见！" -ForegroundColor DarkGray
        break
    }
    if ($key -notmatch '^\d+$') { continue }
    $idx = [int]$key - 1
    if ($idx -lt 0 -or $idx -ge $PatchList.Count) { continue }

    $patch = $PatchList[$idx]

    # 子菜单：应用 / 恢复
    while ($true) {
        Write-Host ""
        Write-Host "--- $($patch.Name) ---" -ForegroundColor Yellow
        Write-Host "  $($patch.Desc)" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  1.  应用" -ForegroundColor Green
        Write-Host "  2.  恢复" -ForegroundColor Red
        Write-Host "  0.  返回" -ForegroundColor DarkGray
        Write-Host ""
        $sub = (Read-Host "选择操作")
        if ($null -ne $sub) { $sub = $sub.Trim() } else { $sub = "" }

        if ($sub -eq "1") {
            Invoke-PatchAction $patch "apply"
            break
        }
        elseif ($sub -eq "2") {
            Invoke-PatchAction $patch "restore"
            break
        }
        elseif ($sub -eq "0" -or $sub -eq "") {
            break
        }
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
