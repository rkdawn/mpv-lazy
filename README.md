# mpv-lazy-ng · 跟随 mpv 官方的懒人包

基于 [hooke007/mpv_PlayKit](https://github.com/hooke007/mpv_PlayKit)（mpv-lazy）的配置体系复刻，
**主程序改为跟随 [mpv-player/mpv](https://github.com/mpv-player/mpv) 官方 Releases 更新**，
并整合自研的模块化补丁工具，形成可持续维护的新懒人包项目。

> 解压即用 · 配置中文注释齐全 · 一键更新主程序 · 一键重建完整包

---

## 与原 mpv-lazy 的差异

| 项目 | mpv-lazy（原） | mpv-lazy-ng（本项目） |
|---|---|---|
| mpv 主程序 | hooke007 打包的第三方构建，随其发布节奏 | **mpv 官方 CI 构建**（x86_64 mingw），双击即更新到最新 |
| 更新方式 | 等待整包重新发布 | `updater\update-mpv.bat` 一键跟随官方 |
| 配置体系 | hooke007 中文注释配置 | 同源继承（portable_config 同步自 lite 分支） |
| 定制补丁 | 无 | `mpv-lazy-patch.bat` 8 个模块，应用/恢复可逆 |
| VapourSynth / Python | 整包内置（约 80 MB） | 不内置；yt-dlp 可选一键更新 |
| 重建发布 | 人工打包 | `build\build-package.bat` 一键构建完整包 |

mpv 官方构建说明：release 二进制为 CI 构建，未包含全部功能（如无编码输出），对日常播放无影响。

## 目录结构

```
mpv-lazy-ng/
├── portable_config/          # 配置体系（mpv.conf / uosc / 着色器 / 字体 …）
├── tools/                    # 模块化补丁工具（打包时复制到包根目录）
│   ├── mpv-lazy-patch.bat        双击运行
│   ├── mpv-lazy-patch.ps1        8 个补丁模块，应用/恢复双向可逆
│   └── 1.0-legacy/               早期版本存档
├── updater/                  # 更新器
│   ├── update-mpv.bat            双击 → 检查并更新 mpv 官方最新版
│   └── update-mpv.ps1            -Check 仅检查 / -Y 自动确认 / -Component ytdlp
├── build/                    # 打包脚本
│   ├── build-package.bat         双击 → 构建完整懒人包到 dist/
│   └── build-package.ps1         -Tag v0.41.0 指定版本 / -Skip7z 仅目录
├── installer/                # 右键菜单注册等（源自 mpv-lazy）
├── umpv.conf                 # umpv 配置
├── portable.vs               # VapourSynth 便携标记（如需 vs 功能）
├── LICENSE.MD / LICENSE.txt  # 许可证
└── README.md                 # 本文件
```

## 快速开始（懒人包使用侧）

1. 解压完整包到任意目录（路径不含特殊字符为宜）
2. 双击 `mpv.exe` 直接播放，或将视频拖入
3. 可选注册右键菜单：运行 `installer\mpv-register.bat`
4. 应用个人定制：双击 `mpv-lazy-patch.bat`，选择模块应用
5. 保持最新：双击 `updater\update-mpv.bat`

### 补丁工具模块（mpv-lazy-patch）

| # | 模块 | 效果 |
|---|---|---|
| 1 | 无边框播放窗口 | `border=no` |
| 2 | 窗口默认65%尺寸 | `autofit=65%` |
| 3 | 播放列表显示文件名 | `osd-playlist-entry=filename` |
| 4 | 同目录自动连播 | `autocreate-playlist=same` + `directory-mode=lazy` |
| 5 | 单击暂停·双击全屏 | smart-click.lua + input_uosc.conf 联动 |
| 6 | 音量跟随系统 | 隐藏音量条、锁定 volume=100、禁用音量快捷键 |
| 7 | 片头片尾书签跳过 | bookmark-skip.lua + Ctrl+←/→/B/X + uosc 菜单 |

每个模块均支持「应用 / 恢复」，恢复即回到 mpv-lazy 原版行为；新增功能只需在 `$PatchList` 中追加条目。

### 更新器用法

```powershell
# 交互式更新 mpv 主程序
updater\update-mpv.bat

# 仅检查是否有新版本
pwsh updater\update-mpv.ps1 -Check

# 自动确认更新
pwsh updater\update-mpv.ps1 -Y

# 更新 yt-dlp（可选组件，用于在线视频）
pwsh updater\update-mpv.ps1 -Component ytdlp

# 使用 MSVC 构建而非 mingw
pwsh updater\update-mpv.ps1 -Arch msvc
```

更新只替换 `mpv.exe` / `mpv.com` / 依赖 dll，**配置与补丁不受影响**。
下载带 SHA256 校验，来源为 GitHub Releases 官方资产。

## 构建完整懒人包（项目维护侧）

```powershell
# 双击或运行：产出 dist/mpv-lazy-ng-<日期>-mpv<版本>/
build\build-package.bat

# 指定 mpv 版本、跳过压缩
pwsh build\build-package.ps1 -Tag v0.41.0 -Skip7z
```

构建流程：拉取 mpv 官方构建（复用本地缓存）→ 组装 portable_config / tools / updater / installer → 写入 VERSION.json → 压缩 7z。

## 同步上游

- **配置更新**（hooke007 上游）：
  ```bash
  git remote add playkit https://github.com/hooke007/mpv_PlayKit.git
  git fetch playkit lite && git merge playkit/lite --allow-unrelated-histories
  # 或仅同步 portable_config 后手动解决冲突
  ```
- **主程序更新**：无需改仓库，`updater` 直接跟随官方。

## 致谢与许可

- [mpv-player/mpv](https://github.com/mpv-player/mpv) — GPLv2+（主程序官方构建）
- [hooke007/mpv_PlayKit](https://github.com/hooke007/mpv_PlayKit) — 配置体系与整合方案
- 各脚本（uosc、input_plus 等）著作权归属其原作者，见 `LICENSE.MD`

本项目仅做整合与自动化，遵循上游许可证分发。
