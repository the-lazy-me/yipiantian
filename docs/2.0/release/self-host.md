> 与 2026-11-15 main 分支（含 cba4597 之后的修复与载荷上限切片）对应的实现状态，未验收

# 自托管世界服务端（开发试玩版）

本文面向自己运行 `world_server.gd` 的运营者。以下所有行为以当前仓库实现为准；命令只在 macOS 上实测，Windows 命令按同一入口给出，未在 Windows 实机执行。

## 1. 适用边界

- 服务端是项目脚本 `Game/world/world_server.gd`，用 Godot 4.7.2 编辑器二进制以 `--headless` 运行，不需要场景、GPU 或音频。
- 当前没有独立服务器包，也没有 systemd / launchd / Windows 服务封装、日志轮转、崩溃自动重启或端口占用处理。
- 只支持 WSS + 自签证书；没有域名证书、NAT 穿透、地址发布或中心目录。
- 实测网络范围只有本机与同一局域网；跨网段、公网和防火墙组合未验证。
- 一个数据目录同一时间只能有一个服务端实例。

## 2. 数据目录

`--data-dir` 必须是绝对路径，且路径本身和所有上级目录都不能是符号链接（macOS 上不要用 `/tmp`，它指向 `/private/tmp`）。

首次启动会创建目录并生成材料。运行后会按功能逐步出现：

| 文件 | 内容 |
|---|---|
| `farm.json` | 世界农场主档（v27） |
| `farm.backup.json` | 上一代已提交农场 |
| `farm.pending.json` 等 | 提交中途的临时文件；正常退出后通常不存在 |
| `nature.json` / `nature.backup.json` | 天气种子与灾害开关（v2） |
| `social.json` / `social.backup.json` | 邻里、留言、授权（v2），使用社交功能后出现 |
| `territory.json` / `territory.backup.json` | 地籍（v1），使用占地功能后出现 |
| `world.key` | RSA 2048 私钥，**绝不可外传** |
| `world-id.txt` | 本目录的世界名，首次成功启动写入 |
| `server.crt` | 自签证书（CN=localhost，有效期 2014-01-01 至 2034-01-01） |
| `invite.bin` | 32 字节邀请密钥，**绝不可外传** |
| `server-status.json` | 运行状态，供健康检查 |
| `authority.lock/owner` | 单实例锁，运行期间存在 |
| `stop` / `read-only` | 运营控制文件，按需创建 |

## 3. 启动

macOS（实测）：

```sh
GODOT="/Applications/Godot.app/Contents/MacOS/Godot"   # 改成你的 Godot 可执行文件路径
"$GODOT" --headless --path Game --script res://world/world_server.gd -- \
  --data-dir=/srv/farm/world --port=7777 --world=world-alpha \
  --join-url=wss://192.168.1.20:7777
```

Windows（未实测）：

```powershell
$Godot = "C:\Godot\Godot_v4.7.2-stable_win64.exe"
& $Godot --headless --path Game --script res://world/world_server.gd -- `
  --data-dir=D:\farm\world --port=7777 --world=world-alpha `
  --join-url=wss://192.168.1.20:7777
```

从仓库根目录运行；`--path Game` 指向项目。`--join-url` 必须填朋友实际能访问的地址（本机局域网 IPv4 和端口），服务端只会绑定 `0.0.0.0`，不知道自己的对外地址。

冒烟启动（到点自动保存退出）：

```sh
"$GODOT" --headless --path Game --script res://world/world_server.gd -- \
  --data-dir=/srv/farm/world --port=7777 --run-seconds=5 --join-url=wss://192.168.1.20:7777
```

## 4. 参数

除 `--data-dir` 外都有默认值。

| 参数 | 默认 | 说明 |
|---|---|---|
| `--data-dir` | 无，必需 | 世界目录，必须是绝对路径；相对路径会拒绝 |
| `--port` | `7777` | WSS 监听端口，绑定 `0.0.0.0`；非数字或不在 `1..65535` 报 `invalid_option` 并退出 2（不会被夹到边界） |
| `--world` | `world` | 世界 ID，写入加入码并在加入时校验 |
| `--generation` | `1` | 运行代次，写入状态；超出 `1..1073741824` 报 `invalid_option` 并退出 2 |
| `--run-seconds` | `0` | `0` 表示常驻；大于 0 时到点保存并退出 |
| `--now-utc` | 系统时间 | 世界的初始 UTC 秒 |
| `--key-file` / `--cert-file` / `--invite-file` | 数据目录内 | 可指向外部材料；仍建议与数据目录一起备份 |
| `--join-url` | 空 | 仅在该次运行**新生成邀请**时用于打印 `join_code` |
| `--server-name` | `localhost` | 加入码中的服务器名，默认即可 |

注意：

- `--world` 在首次成功启动后写入数据目录的 `world-id.txt`。之后用不同 `--world` 启动会以 `world_mismatch` 拒绝（加入码携带世界名，静默改名会让已发出的码全部失效）。确需改名时：停止服务端、删除 `world-id.txt`，再用新名字启动。
- `world-id.txt` 是运维记录，备份数据目录时一并保留；旧版本创建、还没有该文件的目录会在下一次成功启动时补写当前 `--world`。
- `--join-url` 不是“随时补印”：邀请已存在时重启不会再打印加入码。忘了码只能轮换邀请（见第 8 节）。
- 数据目录及其上级不能是符号链接。`--data-dir=/tmp/...` 会以 `world_open` / `load_unsafe_path` 失败。
- `--data-dir` 相对路径会被拒绝：stdout 报 `relative_data_dir` 并退出 2，且拒绝发生在任何写入之前——不会建目录，也不会写 `invite.bin`、`server.crt`、`world.key`。改用绝对路径。
- 参数越界一律拒绝而不是夹到边界，且校验在创建目录之前完成：被拒绝的启动不留下空目录。

## 5. 首次运行输出与材料

首次运行会在 stdout 打印一行 `WORLD_SERVER_READY`，其中包含：

- `cert_fingerprint`：证书 DER 的 SHA-256，共 32 段十六进制。
- `invite_created: true`、`invite_code`（`FARM1.` 开头）：邀请本身，不含地址和证书。
- 指定 `--join-url` 时还有 `join_code`（`FARMJ1.` 开头）：地址 + 证书 + 邀请，玩家游戏里粘贴的是这一串。
- `opened`：`created` 或 `loaded`；`engine`、`data_dir`、`port`、`world_id`、`run_generation`、`rules_version`、`protocol_version`。

之后的重启只打印运行信息，不再打印邀请或加入码。

必须立即保存 `join_code`。不要把 `WORLD_SERVER_READY` 原文发到公开渠道：其中含邀请密钥。

## 6. 状态文件与健康检查

`server-status.json` 在启动后写入，并在命令提交、只读切换和退出时更新。字段：

| 字段 | 含义 |
|---|---|
| `state` | `running` / `stopped` |
| `port` / `pid` | 监听端口与进程号 |
| `world_id` / `run_generation` | 世界与运行代次 |
| `opened` | `created` / `loaded` |
| `cert_fingerprint` | 证书指纹 |
| `saved` / `save` | 退出时的最终保存结果与类型：正常保存为 `saved`，只读退出为 `read_only_skipped`；运行中通常为 `false` / 空 |
| `read_only` | 是否处于只读 |
| `members` / `sequence` | 成员数、已提交命令序号 |
| `world_now_utc` / `elapsed_seconds` | 世界时间与本进程运行秒数 |

macOS 查看：

```sh
python3 -m json.tool /srv/farm/world/server-status.json
pgrep -fl world_server.gd
```

Windows 查看：

```powershell
Get-Content D:\farm\world\server-status.json -Raw | ConvertFrom-Json
Get-Process | Where-Object { $_.Path -like "*Godot*" } | Select-Object Id, ProcessName
```

状态文件不是原子替换写入的，读取方要容忍偶发的半截 JSON，稍后重试即可。

退出码：`0` 正常（含只读退出），`1` 退出保存失败，`2` 参数、目录、锁、监听或世界打开失败。

## 7. 加入流程与网络

1. 服务端启动，状态文件为 `running`。
2. 把首次输出中的 `join_code`（`FARMJ1.`）发给朋友。
3. 朋友打开同版本游戏，在加载页点“联机：加入朋友的农场，或开一间房”，填名字，粘贴加入码，点“加入”。
4. 双方必须能互相访问该 TCP 端口，且使用同一规则/协议版本（当前 27 / 1）。

防火墙放行（未实测）：

macOS：

```sh
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "/path/to/Godot.app/Contents/MacOS/Godot"
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp "/path/to/Godot.app/Contents/MacOS/Godot"
```

Windows（管理员 PowerShell）：

```powershell
New-NetFirewallRule -DisplayName "Farm World 7777" -Direction Inbound `
  -Protocol TCP -LocalPort 7777 -Action Allow
```

游戏内“开房”使用的是 20000–45000 的随机端口，且只在编辑器构建可用；常驻服务端不受此限制，但同样没有端口转发或公网发布功能。

## 8. 邀请轮换与身份材料

- `invite.bin` 是 32 字节邀请密钥；`join_code` 里含它。任何拿到码的人都能以成员身份进入。
- 需要让旧码失效时：停止服务端，删除 `invite.bin`，带 `--join-url` 重启。新运行会把新邀请和新的 `join_code` 打印一次。
- 同时删除 `world.key` / `server.crt` 会生成新证书，旧码全部失效；当前没有证书轮换、吊销或迁移入口。
- 不要上传或提交 `invite.bin`、`world.key`；`server.crt` 是公开证书，但也没有上传必要。

## 9. 停止、只读与单实例

控制文件放在数据目录：

macOS：

```sh
touch /srv/farm/world/read-only   # 停止写入
touch /srv/farm/world/stop        # 正常退出
rm -f /srv/farm/world/read-only   # 恢复写入前必须先删除
```

Windows：

```powershell
New-Item -ItemType File -Path D:\farm\world\read-only -Force
New-Item -ItemType File -Path D:\farm\world\stop -Force
Remove-Item D:\farm\world\read-only
```

语义：

- `stop`：服务端在下一个 0.25 秒 tick 退出，退出前保存一次，打印 `WORLD_SERVER_STOP`，状态写 `state=stopped`。`stop` 文件保留，下次成功启动时才清除。
- `read-only`：运行中创建后，服务端拒绝写入（客户端看到“世界正在搬迁，暂时不能操作”），并跳过退出保存，`save` 为 `read_only_skipped`。当前实现中 `read-only` 是持久部署状态，**重启后仍然只读**，必须手动删除；启动失败也不会清除它。
- 单实例：启动时创建 `authority.lock`，每 5 秒刷新 `owner` 的修改时间；心跳超过 30 秒视为崩溃残留，可被下一次启动接管。第二个实例会以 `data_dir_locked` 退出 2。
- 进程被 `kill -9` 后，锁会在 30 秒内仍被视为有效；立即重启会得到 `data_dir_locked`，等待 30 秒再启动即可。不要在服务端仍在运行时删除 `authority.lock`。
- 每条命令提交本身是原子的，强杀不会留下半个农场；非只读的正常退出仍会额外保存一次。

## 10. 备份

推荐顺序（利用只读冻结，避免复制到一半状态变化）：

```sh
touch /srv/farm/world/read-only
# 轮询状态直到 read_only=true
touch /srv/farm/world/stop
# 等服务端退出，确认退出码 0、save=read_only_skipped
DEST="$HOME/farm-backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DEST"
rsync -a /srv/farm/world/ "$DEST/world/"
find "$DEST/world" -type f -exec shasum -a 256 {} \; > "$DEST/SHA256SUMS"
rm -f /srv/farm/world/read-only
```

Windows：

```powershell
New-Item -ItemType File -Path D:\farm\world\read-only -Force
# 轮询状态直到 read_only=true
New-Item -ItemType File -Path D:\farm\world\stop -Force
# 等待进程退出
$Dest = Join-Path $HOME ("farm-backups\" + (Get-Date -Format yyyyMMdd-HHmmss))
New-Item -ItemType Directory -Path $Dest -Force | Out-Null
Copy-Item -Recurse D:\farm\world (Join-Path $Dest "world")
Get-ChildItem (Join-Path $Dest "world") -File |
  Get-FileHash -Algorithm SHA256 | Format-List
Remove-Item D:\farm\world\read-only
```

备份内容要包含世界文档和身份材料（`world.key`、`server.crt`、`invite.bin`）；只备份 `farm.json` 不能恢复一个可加入的世界。恢复时先停服务端、保留原目录、整目录还原，再用同一代次程序启动。

## 11. 常见错误

| 输出 / 现象 | 含义与处理 |
|---|---|
| `missing_data_dir` | 没给 `--data-dir`；补绝对路径 |
| `relative_data_dir` | 路径不是绝对路径；改用绝对路径（拒绝前没有任何写入） |
| `data_dir_unwritable` | 目录无法创建；检查权限与磁盘 |
| `invalid_option` | 端口不在 `1..65535` 或非数字、代次不在 `1..1073741824`、`--run-seconds` 为负、`--now-utc` 为负或非数字 |
| `data_dir_locked` | 已有实例或 30 秒内的崩溃残留；等待或确认旧进程已退出 |
| `listen_failed` | 端口被占用或无权限；换端口 |
| `world_mismatch` | `--world` 与目录的 `world-id.txt` 不一致；用原名字启动，或删除该文件后有意改名 |
| `world_open` + `load_unsafe_path` | 路径含符号链接（常见 `/tmp`）；换真实路径 |
| `world_open` + `load_farm_recovery_available` 等 | 世界文档需要显式恢复；先备份整个目录，不要在服务端里强行覆盖 |
| `world_open` + `load_nature_*` / `load_territory_*` | 天气或地籍文档被拒绝；保留原文件并按恢复流程处理 |
| `generate_certificate` / `write_certificate` / `write_invite` | 材料生成或写入失败；检查目录权限 |
| `grant` | 默认邀请未能加入世界；检查 `invite.bin` 与邀请材料 |
| `WORLD_SERVER_ECONOMY_ERROR` | 经济结算失败；同一原因只打印一次，按 `reason` 排查 |

## 12. 尚未提供

- 独立服务器导出包、容器镜像、systemd/launchd/Windows 服务模板。
- 日志轮转、崩溃自动重启、端口占用自动切换。
- 公网/NAT 穿透、域名证书、地址发布、官方服务器目录。
- Linux 实机、Windows 实机服务端验证。
- 邀请有效期、一次性邀请、邀请撤销界面、细粒度权限管理界面。
- 服务端侧的存档导出/导入命令（游戏内“导出世界”只在本地单人模式可用）。
- 在线改端口、改世界 ID、改数据目录而不重启。
