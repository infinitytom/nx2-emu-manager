<img src="assets/icon-256.png" width="96" align="right" alt="icon">

# NX2 Emu Manager · Eden / Eglantine 多版本管理器

Eden 系模拟器（Eden、Eglantine / PokeDinner 分支，以及 yuzu / citron / sudachi / suyu 等同源分支）的 **多版本管理、调试和联机工具**。
分支多、更新快，不同游戏要配不同版本？用它挑版本、启动、对比开关、管理存档和着色器，再开个联机房间。

- 零依赖：Windows 自带的 PowerShell 5.1 + WPF，深色界面，双击即用
- 单文件：`EmuManager.ps1`，所有数据存放在旁边的 `data\` 目录
- 不包含也不下载任何模拟器、keys、固件或游戏

## 功能

### 版本与游戏识别
- 扫描磁盘找出所有模拟器目录，读取 `VERSION.txt` / `BUILD-INFO.txt` / 压缩包文件名中的 **分支和 commit**
- 识别数据目录：版本目录里有 `user\` = 独立数据；否则使用 `%APPDATA%\eden`（共享），会自动跟随目录链接（junction / 符号链接）找到真实位置，默认位置没有数据时会在各盘查找 `X:\eden`、`X:\eden\eden`；也可以手动「更改数据目录」（单个版本或所有共享版本）
- 识别游戏：解包目录（从 `exefs\main.npdm` 读取 TitleID）以及 nsp / xci / nup（Eglantine 2.5+ 整合包，直接读文件头里的 TitleID 和所含更新版本）；`updates\<版本号>` 自动识别为更新
- **游戏封面**：扫描后在后台按 TitleID 从任天堂官网（欧洲站，含 Switch 2 游戏）自动下载方形官方封面并补全官方名称；查不到时可按名字搜索、从缩略图里挑选，或自己选择图片 / 从剪贴板粘贴。也会使用游戏目录里的 `cover`/`icon` 图片和模拟器游戏列表缓存的图标
- **导入 zip**：新构建解压到独立目录，多个版本并存，可一键设为独立数据
- **隔离数据**：把共享 `%APPDATA%` 的版本转为独立 `user\` 目录（自动复制 keys / 固件 / 存档）

### 启动与调试
- 选择启动目标（基础 / 更新 / 任意文件）、GUI 或命令行前端、全屏
- **环境变量开关**：每次启动单独注入 `EDEN_NX2_*` 等变量，优先级高于 `nx2_switches.txt`，按「版本 × 游戏」记住
- **开关浏览与对比**：直接从 exe 中扫描出该版本支持的全部开关，并与另一个版本对比差异
- 命令行前端崩溃后保留控制台窗口
- 退出后自动记录：时长、退出码（如 `0xC0000005 访问冲突`）、本次日志副本，并弹窗标记结果
- **兼容性矩阵**：每个「版本 × 游戏」的状态（完美 / 可玩 / 卡顿 / 画面错误 / 崩溃…）和备注，版本列表用色条直接显示
- 运行记录可一键「载入此配置」复现
- **环境变量预设**：把常用开关组合存成预设，在任何版本 / 游戏上一键套用

### 存档 / 着色器 / 配置
- 列出所选版本 × 游戏的存档、着色器缓存、Mods、SDMC、游戏专属配置、日志、keys、固件、NX2 开关文件
- 打开、打包备份（zip）、清空（先自动备份）、从备份还原、复制到另一个版本（存档会自动适配用户 ID）

### 模拟器设置
- 在管理器里直接修改所选版本的 **全局设置** 或 **单个游戏的专属设置**（覆盖全局）
- 常用项（图形 API、分辨率、过滤、抗锯齿、垂直同步、异步着色器、ASTC、主机模式、内存布局、CPU 精度、自动 Stub、日志过滤…）用开关 / 选项按钮修改，可单项「恢复默认 / 跟随全局」
- 设置项定义在 `profiles.json` 的 `settings` 里，可自行增加；也可直接编辑原始配置文件；保存前自动备份为 `.emumgr.bak`

### 联机房间
- 使用版本自带的房间服务器（`eden-room.exe` 等）开房：房间名、端口、人数、密码、首选游戏 / TitleID，可选公开到大厅
- 实时显示房间日志，一键放行防火墙 UDP 端口，复制局域网地址
- 加入房间：把昵称 / 地址 / 端口写入所选版本的「多人游戏 → 直接连接」默认值，并可直接启动游戏

### 扩展（不用改脚本）
右上角「扩展」集中打开以下配置，改完按 F5 生效：

| 文件 | 作用 |
|---|---|
| `data\profiles.json` | **模拟器档案**：exe / 命令行 / 房间服务器文件名、便携目录名、`%APPDATA%` 目录名、启动参数模板（如 `{fullscreen} -g "{target}"`）、开关前缀正则、存档 / 着色器 / Mods 等路径模板、联机配置写入位置。内置 Eden 家族和 Ryujinx 家族，新分支改了 exe 名或目录结构只需改这里 |
| `data\titles.json` | TitleID → 游戏名称 |
| `data\tools.json` | 启动页「工具」按钮：命令 + 参数模板，可注入环境变量（例：带开关的命令行、RenderDoc） |
| `data\hooks\pre-launch\*.ps1` | 启动前运行，可修改本次的环境变量 / 启动参数，返回 `$false` 取消启动 |
| `data\hooks\post-exit\*.ps1` | 退出后运行，拿到退出码、时长、日志副本（例：崩溃时自动打包日志） |
| `data\covers\<TitleID>.png` | 自定义封面 |

模板占位符：`{data}` `{emuDir}` `{exe}` `{gui}` `{cli}` `{tid}` `{tidl}`（小写）`{target}` `{gameDir}` `{gameName}` `{emuName}` `{appdata}` `{localappdata}` `{manager}` `{managerData}`

## 使用

1. 下载或 clone 本仓库，放到任意位置（推荐与模拟器同一个盘，例如 `F:\EmuManager`）
2. 双击 `EmuManager.bat`
   - 启动器会先做语法检查，启动失败时弹窗显示原因并写入 `startup-error.log`
   - 也可以用 `EmuManager-debug.bat`，保留控制台输出
3. 首次启动默认扫描脚本所在磁盘的根目录；可在右上角「扫描目录」里修改
4. 「扩展 → 桌面快捷方式」可在桌面创建带图标、不弹控制台的快捷方式

> 系统要求：Windows 10 / 11（自带 PowerShell 5.1 和 .NET Framework 4.x）。

## 数据目录

| 路径 | 内容 |
|---|---|
| `data\config.json` | 扫描目录设置 |
| `data\db.json` | 别名、兼容性记录、启动配置、运行历史、房间设置 |
| `data\runs\` | 每次运行的日志副本 |
| `data\backups\` | 备份 zip（`游戏\类型\版本_时间.zip`） |
| `data\room\` | 房间服务器日志与封禁列表 |
| `data\profiles.json` `titles.json` `tools.json` `hooks\` `covers\` | 扩展配置（见上） |

## 说明

- 同时运行两个共享同一数据目录的版本会互相覆盖存档 / 着色器，管理器会提醒；对比测试建议先「隔离数据」
- 加入房间写入的是 `qt-config.ini` 的 `[Multiplayer]` 段（原文件备份为 `.emumgr.bak`），写入前请先关闭该版本
- 外网联机需要路由器转发 UDP 端口，或使用 ZeroTier / Tailscale 等组网工具

## License

MIT
