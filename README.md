# Nanoleaf HA Embedded Plugin

一个面向 Windows 的非官方 Nanoleaf Desktop 扩展：把 USB 连接的 Pegboard Desk Dock 接入 Home Assistant，并在 Nanoleaf 主窗口中加入中文 HA 管理界面。

> [!IMPORTANT]
> 本项目与 Nanoleaf 官方无隶属或授权关系。它不会分发 Nanoleaf Desktop、`app.asar` 或其他官方二进制文件；使用前必须自行合法安装官方桌面端。

## 功能

- 安装时自动识别最多两块 `VID_37FA&PID_8201` Pegboard；
- 在 Nanoleaf 主窗口左下角加入 **HA** 按钮；
- 通过 Nanoleaf 内部 Electron IPC 读取状态并控制开关，不使用 9222 调试端口；
- 提供 `/device/j`、`/device/k`、`/device/all` 三个兼容 REST 端点；
- 自动生成 Home Assistant REST 开关和中文 `light` 模板实体；
- 使用随机 256 位 Bearer 密钥，并把 Windows 防火墙入站范围限制为指定 HAOS IP；
- 支持 `--hidden` 登录启动、官方更新前还原、更新后重新安装补丁；
- 从托盘退出时先执行 Nanoleaf 连接清理，再由当前主进程完成有界退出，不依赖外部强制清理任务。

## 兼容范围

当前版本：**1.1.6**

| 项目 | 范围 |
| --- | --- |
| 操作系统 | Windows 10/11 x64 |
| Nanoleaf Desktop | 3.0.0；3.0.1 的精确兼容标记已依据本机诊断适配，两版本通过合成 ASAR 测试 |
| 设备 | Pegboard Desk Dock，USB `VID_37FA&PID_8201` |
| 设备数量 | 1–2 块 |
| Home Assistant | 使用 `configuration.yaml` 的 REST 与 Template 集成 |

Nanoleaf Desktop 没有公开插件接口。官方更新可能改变内部代码；补丁找不到精确兼容标记时会停止，不会尝试模糊修改未知版本。

1.1.5 已在 Desktop 3.0.1 上完成真实 Windows 设备的界面、两块灯板控制与托盘退出验证。1.1.6 增加自动更新恢复，完整官方更新过程仍需设备实测。

## 安装

1. 从 Releases 下载并解压 ZIP。
2. 确保 Pegboard 已连接，Nanoleaf Desktop 能正常控制它。
3. 在解压目录打开普通 PowerShell，执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1 -HaIp 192.168.1.50
```

把示例地址替换为你的 HAOS IPv4。安装器会请求一次管理员权限，并自动检测 Windows 局域网 IP 与 Pegboard 序列号。

如果自动检测不合适，可以显式指定：

```powershell
.\install.ps1 `
  -HaIp 192.168.1.50 `
  -PcIp 192.168.1.20 `
  -DeviceJId DEVICE_SERIAL_A `
  -DeviceKId DEVICE_SERIAL_B `
  -DeviceJName "左侧灯板" `
  -DeviceKName "右侧灯板"
```

只使用一块灯板时省略 `-DeviceKId`。重新运行安装器会保留已有 Bearer 密钥，避免现有 HA 配置失效。

安装完成后：

1. 打开 Nanoleaf 主窗口左下角的 **HA**；
2. 确认设备状态正常；
3. 点击 **复制 HA YAML**；
4. 粘贴到 HAOS 的 `configuration.yaml`；
5. 在 Home Assistant 中检查配置后重启。

生成的实体包括每块灯板和“全部灯板”的 REST 开关，以及对应的中文灯光实体。

## 本地配置与接口

运行时配置位于 `C:\ProgramData\NHA\config.json`，由安装器在本机生成，不属于仓库内容。设备槽位与端点对应如下：

| 槽位 | 端点 | 说明 |
| --- | --- | --- |
| J | `/device/j` | 第一块或名称匹配 J 的设备 |
| K | `/device/k` | 第二块或名称匹配 K 的设备 |
| All | `/device/all` | 同时控制全部已配置设备 |

请求必须包含：

```http
Authorization: Bearer <本机生成的密钥>
```

读取状态使用 `GET`，控制电源使用：

```json
{"on": true}
```

## 官方更新

### 已升级到 Desktop 3.0.1，但 HA 按钮消失

旧插件 1.1.4 的三个兼容标记不匹配 3.0.1。下载插件 1.1.6，解压后在该目录执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1
```

安装器会从已安装配置复用 HAOS/Windows IP、设备 ID、名称和 Bearer 密钥。已有 HA YAML 无需因这次兼容修复而重新生成。3.0.1 会单独备份；还原时会校验备份版本和哈希，不会把 3.0.0 备份复制到 3.0.1。

### 下一次官方更新

Nanoleaf 的自动更新可以保持开启。插件 1.1.6 复用已有的 `Nanoleaf HA Plugin Repair` 任务，在登录后和每分钟检查官方文件变化：

- 等待更新器结束、文件稳定至少 30 秒后，恢复已经支持的精确版本；通常在更新结束后约 1–2 分钟恢复。
- 文件未变化时使用缓存，不重复启动检查进程或应用。
- 需要重启正在运行的 Nanoleaf 时，仅重启一次并使用 `--hidden`。
- 用户已经退出 Nanoleaf 时，补丁可恢复到文件中，但应用保持关闭。
- 新版本不在兼容表中，或标记已变化时，保留官方文件并写入 `repair.log`；安装新的兼容插件后自动重新检查。

因此，正常自动更新无需手动点“准备官方更新”。自动恢复期间 HA 接口会暂时不可用。

若要人工控制更新时机，仍可使用原来的手动流程：

1. 在 HA 窗口点击 **准备官方更新**；
2. 完成 Nanoleaf 官方更新；
3. 以管理员身份运行：

```powershell
C:\ProgramData\NHA\resume-after-update.ps1
```

若新版本不兼容，恢复脚本会停止并保留官方文件。请提交 Issue 并附上 Nanoleaf Desktop 版本及去除隐私信息后的错误文本；不要上传 `app.asar`、密钥或设备序列号。

## 诊断与卸载

查看状态：

```powershell
C:\ProgramData\NHA\status.ps1
```

卸载并恢复安装时备份的官方文件：

```powershell
C:\ProgramData\NHA\uninstall.ps1
```

配置与备份会保留在 `C:\ProgramData\NHA`，便于恢复。确认不再需要后可自行删除该目录。

## 安全与隐私

- 仓库和 Release 不包含用户 IP、设备序列号、Bearer 密钥、日志或官方备份；
- Bearer 密钥仅在安装电脑本地生成；
- 网关监听端口默认为 `17654`，Windows 防火墙只允许安装时指定的 HAOS IP；
- 插件仍属于修改本地桌面应用的非官方方案，请先阅读 [SECURITY.md](SECURITY.md)；
- 报告问题前请从日志中删除 IP、序列号、用户名和密钥。

## 开发

测试不需要 Nanoleaf 官方文件：仓库使用最小合成 ASAR 验证补丁的检查、写入、完整性更新与还原流程。

```bash
npm test
```

提交代码前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。版本记录见 [CHANGELOG.md](CHANGELOG.md)。

## 许可证

本仓库自行编写的代码采用 [MIT License](LICENSE)。该许可证不适用于 Nanoleaf 的软件、商标或其他第三方材料。
