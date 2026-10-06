# Changelog

## 1.1.7 — 2026-10-06

- 移除每分钟及登录修复触发器，改为从关闭状态启动 Nanoleaf 时按需检查；退出后不自动重启。
- 增加 wscript 无控制台启动入口，创建 PowerShell 时隐藏窗口，修复定时检查闪窗。
- 提供桌面/开始菜单 HA 启动快捷方式；HA 登录启动使用同一入口，保留 `--hidden` 托盘启动，手动启动正常打开窗口。
- 修复任务仅检查/修补文件，不再停止或重启应用；更新器正在运行或文件不稳定时推迟启动。
- 卸载时移除 HA 快捷方式，并恢复本插件持有的官方登录启动项。

## 1.1.6 — 2026-10-06

- 复用现有修复任务，增加每分钟无限重复检查，支持官方自动更新后恢复已兼容版本。
- 增加文件变化缓存、更新器检测和两次稳定观察；未变化时不启动 Node 检查或 Nanoleaf，不反复写日志。
- 自动更新修复后仅在应用原本运行时隐藏重启，正常托盘退出后保持关闭。
- 未知版本保留官方文件，并缓存不兼容结果直到文件或插件版本变化。
- 状态脚本显示自动恢复状态和日志，并使用可靠退出码执行器。

## 1.1.5 — 2026-10-06

- 根据 Desktop 3.0.1 的本机诊断增加独立的入口、退出和清理精确兼容规则，保留 3.0.0 与旧插件升级支持；未知版本继续拒绝修改。
- 使用共享 .NET 进程执行器等待 Electron GUI 可执行文件并读取可靠退出码，修复安装/恢复/修复/还原时空退出码的问题。
- 安装器在修改配置前先检查兼容性；为新官方版本单独备份，备份版本与哈希检查在还原写入前执行。
- 扩展合成 ASAR 测试：双版本往返、清理函数绑定、幂等安装、旧插件升级、官方更新迁移、无效标记及备份保护。
- 添加 Windows PowerShell 5.1 GUI 进程测试。真实 3.0.1 界面、USB 与退出验证待设备安装完成。

## 1.1.4 — 2026-10-03

- Published a generic installer with automatic Pegboard USB and Windows IPv4 discovery.
- Moved device IDs, names and network addresses from source code into local runtime configuration.
- Added dynamic one- or two-device rendering in the embedded HA window.
- Preserved the `/device/j`, `/device/k` and `/device/all` compatibility endpoints.
- Added repository privacy checks and a synthetic ASAR patch round-trip test.
- Retained compatibility with both array-based and legacy final-cleanup callbacks.

## 1.1.3

- Ran colour-calibration and LTPDU client-manager cleanup before main-process self-termination.
- Fixed residual Nanoleaf processes after all other cleanup had completed.

## 1.1.0–1.1.2

- Replaced external forced-exit tasks with bounded cleanup inside the Nanoleaf main process.
- Added bridge shutdown and renderer cleanup ordering.

## 1.0.0–1.0.6

- Added the embedded Home Assistant bridge, UI, update preparation and repair workflow.
- Iterated on legacy exit cleanup before the internal cleanup design was completed.
