> 与提交 cba4597 及其后修复对应的实现状态，未验收

# 问题反馈与日志收集

反馈问题时，先保留现场，再复制日志和存档。不要为了“清理”删除损坏文件、备份或 `*.unreadable.*`。

## 1. 日志位置

Godot 默认把运行日志写到用户数据目录下的 `logs/`，每次启动会把上一份 `godot.log` 轮换成带时间戳的文件。

| 系统 | 日志目录 |
|---|---|
| macOS | `~/Library/Application Support/Godot/app_userdata/我有一片田/logs/` |
| Windows | `%APPDATA%\Godot\app_userdata\我有一片田\logs\` |

也可以在启动时指定日志文件：

macOS：

```sh
"/path/to/我有一片田.app/Contents/MacOS/我有一片田" --log-file "$HOME/Desktop/farm.log"
```

Windows：

```powershell
& "C:\path\我有一片田\我有一片田.exe" --log-file "$env:USERPROFILE\Desktop\farm.log"
```

服务端日志在 stdout；重定向到文件：

macOS：

```sh
"$GODOT" --headless --path Game --script res://world/world_server.gd -- \
  --data-dir=/srv/farm/world --port=7777 > "$HOME/Desktop/server.log" 2>&1
```

Windows：

```powershell
& $Godot --headless --path Game --script res://world/world_server.gd -- `
  --data-dir=D:\farm\world --port=7777 *> "$env:USERPROFILE\Desktop\server.log"
```

系统级崩溃报告（如果存在）在 macOS 的 `~/Library/Logs/DiagnosticReports/`；Windows 可在“事件查看器 → Windows 日志 → 应用程序”中查找。它们不是游戏日志，只在真的崩溃时附上。

## 2. 关键日志行

日志是逐行文本，下面是排查时最有用的一行一类。

| 行 | 来源与含义 |
|---|---|
| `STARTUP_STAGE progress=<0-100> text=...` | 启动阶段；卡住时最后一行说明卡在哪 |
| `STARTUP_FAILED stage=<原因>` | 启动失败；前面通常有具体错误 |
| `STARTUP_COMPLETE` | 成功进入农场 |
| `STARTUP_BENCHMARK result=... recommendation=...` | 首次性能测试与推荐画质 |
| `FARM_LOAD stage=<loaded/missing/recovery_available/...> version=27 migrated=<bool> saved=<bool>` | 农场载入结果；`migrated` 当前只会是 `false` |
| `FARM_SAVE stage=complete version=27` | 一次农场保存完成 |
| `FARM_STORE stage=<原因> error=<数字>` | 存储层警告；常见于载入/保存失败 |
| `NATURE_LOAD stage=failed kind=<原因>` | 天气记录被拒绝；`kind` 说明是损坏、来自更新版本还是恢复可用 |
| `FARM_REMOTE world=<ID> role=<member/visitor> now=<秒>` | 已进入联机世界及角色 |
| `SETTINGS_STORE stage=<load/saved/...>` | 设置读取/保存 |
| `WORLD_TRANSFER stage=<export/prepare/import> result=<结果>` | 世界包导出/导入结果 |
| `WORLD_SERVER_READY {...}` | 服务端就绪；含端口、世界、指纹，首次运行还含邀请/加入码 |
| `WORLD_SERVER_STOP {...}` | 服务端正常退出；含 `save` 结果与退出时序号 |
| `WORLD_SERVER_ERROR {...}` | 服务端拒绝启动或运行失败；`reason` 为具体原因 |
| `WORLD_SERVER_ECONOMY_ERROR {...}` | 服务端经济结算失败；同一原因只打印一次 |

游戏内的提示文本也有诊断价值，例如“存档未能读取，可恢复上一份备份。”“天气记录来自更新的版本，请先更新游戏。”“保存未完成，最新进度仍在本次窗口中。”请把原文一起附上。

## 3. 最小复现信息

每次反馈至少提供：

- 游戏版本与提交号（“关于”页显示 Demo 版本；开发版附 `git rev-parse --short HEAD`）。
- 系统与架构（macOS/Windows、arm64/x86_64）、窗口模式、画质档位。
- 场景：单人、加入房间、自己开房、自托管服务端。
- 角色：成员或访客；房主是否使用编辑器构建。
- 操作步骤：从启动到问题出现，按顺序写；能稳定复现的写“每次”，偶发的写出现次数。
- 期望结果与实际结果，包括完整错误文案。
- 问题发生的时间点，以及是否在重启后仍出现。
- 相关日志行（整段复制，不要只截一半）。
- 存档问题：`farm-v27/` 的文件清单与 SHA-256；不要只发 `farm.json`。
- 服务端问题：启动命令（隐去秘密）、退出码、`server-status.json`、`WORLD_SERVER_*` 行。

macOS 记录存档哈希：

```sh
cd "$HOME/Library/Application Support/Godot/app_userdata/我有一片田"
find farm-v27 -type f -exec shasum -a 256 {} \; > /tmp/farm-sha256.txt
```

Windows：

```powershell
$Root = Join-Path $env:APPDATA "Godot\app_userdata\我有一片田\farm-v27"
Get-ChildItem $Root -Recurse -File | Get-FileHash -Algorithm SHA256 |
  Format-Table -AutoSize > "$env:USERPROFILE\Desktop\farm-sha256.txt"
```

如果游戏还能启动，先正常退出再复制；如果保存失败，先复制整个存档目录，再选择“重试保存”或“仍然退出（最新进度未保存）”，不要在复制前清理。

## 4. 绝对不要上传

- `invite.bin`、`world.key`：邀请密钥与 TLS 私钥。泄露后任何人都能以成员身份进入或冒充服务端。
- 加入码/邀请码整串：`FARMJ1.` 或 `FARM1.` 开头的字符串。它是凭证，不是普通诊断信息。
- 首次运行服务端的 `WORLD_SERVER_READY` 原文：含 `invite_code` / `join_code`。
- 命令行里的 `--join-code=...`、`--invite-file=...` 指向的秘密内容。
- `player/player.json`、`identity.json`：玩家 ID、设备 ID 等身份记录。除非问题必须依赖身份，否则不要发。
- `social.json`：含其他玩家的名字、留言和授权。这些是别人的数据；必须提供时先征得同意并删除无关内容。
- 相册 `farm-v27/album/` 与 `.local/recordings/`：可能包含现实环境、屏幕内容或他人信息。
- 任何包含真实姓名、邮箱、内网地址、绝对用户路径的日志。发送前把这些替换为 `<已隐去>`。

`server.crt` 是公开证书，`cert_fingerprint` 是公开指纹，通常可以保留；但连同私钥一起打包发送是禁止的。

## 5. 发送前自检

- [ ] 已删除或替换所有 `FARMJ1.` / `FARM1.` 字符串。
- [ ] 已确认压缩包里没有 `invite.bin`、`world.key`。
- [ ] 已确认没有 `player.json`、`identity.json`、`social.json`，或已获得同意并脱敏。
- [ ] 日志中的用户名、主目录、内网 IP 已替换。
- [ ] 已附上版本、系统、复现步骤、期望/实际和相关日志行。
- [ ] 存档问题附的是整个目录副本或哈希清单，不是被编辑过的单文件。
