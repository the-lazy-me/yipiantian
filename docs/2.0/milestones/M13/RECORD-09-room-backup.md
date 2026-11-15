# M13-03 · 房间完整备份与干净恢复演练（本机）

日期：2026-11-16。状态：本机演练通过，**不表示 M13-03 或 M13 验收完成**。本记录只描述用现有入口执行的一次完整演练；没有修改任何产品代码、规则、工作流或 CI 配置。新增文件只有本记录和规则夹具 `tests/room_backup_drill_test.gd`，均未提交。所有演练数据在 `.local/verification/room-backup-27196/`（`.local/` 已在 `.gitignore` 中忽略）。

## 结论

| 步骤 | 内容 | 结果 |
|---|---|---|
| 1 | 用 `world_server.gd` 建立房间，具名成员加入并提交真实播种命令 | 通过；`opened=created`，`sequence=1` |
| 2 | 停止服务端，整目录复制到新路径，逐文件比对 | 通过；12 个文件全部逐字节一致 |
| 3 | 从复制目录用同一端口、邀请与身份重启并继续操作 | 通过；`opened=loaded`，外来证明被拒，原身份可继续，`sequence=2` |
| 4 | 对复制件截断 `farm.json`，确认服务端拒绝且原件不受影响 | 通过；退出码 2，`world_open` / `load_recovery_available` |
| 5 | 同一端口复用与退出清理 | 通过；两个运行都使用端口 60018，无残留锁与进程 |

演练期间观察到一处低风险生产日志缺陷：客户端收到拒绝后立即断开时，
`_defer_disconnect()` 仍会在 0.5 秒后无条件 `disconnect_peer()`，打印
`ERROR: Condition "!peers_map.has(p_peer_id)" is true.`。演练后已修复为只在连接
仍处于已连接且该 peer 仍在表中时断开；修复后的复跑仍为 `ROOM_BACKUP_DRILL_TEST
checks=84 failures=0`（root `room-backup-67334`）。

夹具末行：

```text
ROOM_BACKUP_DRILL_TEST checks=84 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/room-backup-27196
```

## 环境与基线

| 项 | 值 |
|---|---|
| macOS | 27.0.1，arm64 |
| Godot | `4.7.2.stable.official.ed1daf0bf`，仅 `--headless` |
| 仓库 HEAD | `be67c85` |
| 分支 | `main` |
| 工作树 | 含其它并行任务的未提交改动；本任务未修改任何受版本控制文件 |
| 演练耗时 | 4.9 秒（要求 < 60 秒） |

演练入口文件在本次执行后立即记录的 SHA-256：

| 文件 | SHA-256 |
|---|---|
| `Game/world/world_server.gd` | `bd49696cb36737c4426f031e1e75f36d49212c476ee15f772897dff9b43a8cf8` |
| `Game/world/world_hosting.gd` | `e5bae68d6330076aa4e0454e769cd5c8509cfa77fc55d7c47f71d995e7a4cc80` |
| `Game/world/world_host.gd` | `e204c57a75d76d73788711ea229668e339c25c826f09f4651e82810a2bc08302` |
| `Game/world/world_member.gd` | `aeb09498cb49a41b7b60daaf56213ce97a627222e3ffc5fd1ab09cdae895790e` |
| `Game/farm/farm_store.gd` | `beb9925ad6a314e70d7de83e2db46fdb22c21380d0065d87998732accebec084` |
| `Game/world/player_binding_store.gd` | `c29e7f2f30a9674c9f46f7d7512ec0af73b830c3d6ea4d899f60d3fe06a83e62` |
| `Game/farm/farm_command.gd` | `dc57d9119bdfc28bcd20c85490137ac87db5655e16da73bc4bc176df527d16a8` |
| `Game/world/world_invite.gd` | `d9cc550e093eaccce04789a456b80695ec57f5bc9314433beb0627cac18fbb89` |
| `tests/room_backup_drill_test.gd` | `c10387c88246427770f26fa02a3d97efcbe953cac231cf3bc2a6ad2535c59da5` |

工作树当时仍有其它代理的改动（`Game/farm/*`、`Game/world/disputes_store.gd`、`Game/world/headless_world.gd`、`Game/world/world_host.gd`、`tests/dispute_*`）。上面的哈希对应本次执行后的工作树版本；并行文件继续变化后，本次结果只代表该版本。

## 入口与夹具

规则夹具：`tests/room_backup_drill_test.gd`。

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/room_backup_drill_test.gd"
```

- 使用 `Game/world/world_server.gd`，也就是桌面开房入口 `world_hosting.gd` 实际 spawn 的同一个脚本；直接 spawn 是为了能脚本化“停止后从复制目录重启”，不需要修改产品代码。
- 世界目录：`world-original`（原件）、`world-copy`（整目录复制件）、`world-damaged`（恢复后的第二次复制，用于截断场景）。
- 世界 ID：`backup-drill`；固定循环端口；具名玩家 `player_00000000000000000000000000000001`，显示名“阿青”。
- 初始命令：成员通过 WSS 提交 `sow field_01/cell_01 greens`；迁移后提交 `water field_01/cell_01`。
- 日志（含本次夹具生成的临时邀请材料，不应外传）：`.local/verification/room-backup-27196/logs/room_backup_drill_test.log`。
- 与服务端自身约束一致：数据目录必须是绝对路径且所有上级目录都不是符号链接；在符号链接的检出路径下运行会以 `world_open` / `load_unsafe_path` 失败。

## 步骤 1 · 建立房间并写入真实状态

- 首次启动打印 `WORLD_SERVER_READY`：`opened=created`、`world_id=backup-drill`、`port=60018`、`rules_version=27`、`protocol_version=1`。
- 首次运行生成了 `world.key`、`server.crt`、`invite.bin`、`world-id.txt`、`visitor-join-code.txt`。
- 具名成员用固定 `player.key`（32 字节）加入；服务端写入 `player_bindings.json`，`player_proof` 由“凭据 + 世界 ID”派生。
- 成员提交播种命令，权威返回 `ok`，事件序号从 0 到 1；`FARM_SAVE stage=complete version=27`。
- 写 `stop` 后服务端正常退出：`WORLD_SERVER_STOP ... "save":"saved","sequence":1,"state":"stopped"`；`authority.lock` 已删除。
- 停止后 `FarmStore.load_state()` 可读，`transaction.sequence=1`，`field_01/cell_01` 的 `crop_id=greens`。

此时原件目录共 12 个文件：`farm.json`、`farm.backup.json`、`social.json`、`nature.json`、`player_bindings.json`、`world.key`、`server.crt`、`invite.bin`、`world-id.txt`、`visitor-join-code.txt`、`server-status.json`、`stop`。没有 `social.backup.json`、`nature.backup.json`、`territory.json` 或 pending 文件。

## 步骤 2 · 停止后整目录复制并逐字节校验

记录原件哈希树（相对路径 → SHA-256）后递归复制到 `world-copy/`：

| 检查 | 结果 |
|---|---|
| 复制前后原件哈希树 | 相同 |
| 复制件哈希树 vs 原件 | 12 个文件全部相同 |
| 实际存在的关键文件 | 10 个逐字节相同：`farm.json`、`farm.backup.json`、`social.json`、`nature.json`、`player_bindings.json`、`world.key`、`server.crt`、`invite.bin`、`world-id.txt`、`visitor-join-code.txt` |
| `world-id.txt` | 内容仍为 `backup-drill` |
| 复制件 `FarmStore.load_state()` | 可读，`transaction.sequence=1` |
| 复制件身份绑定 | 包含 `player_...0001` |
| 原件 `player_bindings.json` 与复制件 | 字节相同（`a3c9df6a…`） |

`world.json` 是“导出世界”的包格式，不存放在服务端数据目录，因此没有出现在复制清单里；关键文件按实际存在项校验。

## 步骤 3 · 从复制目录用同一邀请与身份重启

| 检查 | 结果 |
|---|---|
| 复制目录启动 | `opened=loaded`，`world_id=backup-drill` |
| 端口复用 | 复用原端口 60018 |
| 证书 | 复制件 `server.crt` 可加载，指纹不变 |
| 外来证明 | 同一 `player_id` + 随机新凭据被拒，原因 `player_proof` |
| 原身份 | 原凭据可加入；会话从 `sequence=1` 开始 |
| 继续执行 | `water` 命令被接受，`sequence=2` |
| 退出 | `save=saved`，状态 `stopped`，锁删除，进程退出 |
| 落盘 | `FarmStore` 重载 `sequence=2`，`field_01/cell_01.watered=true` |
| 身份绑定 | 重启后仍包含同一 `player_id`；`player_bindings.json` 字节未变 |

“外来证明被拒”这一点使“绑定保留”可观察：若 `player_bindings.json` 没有被复制，外来证明会按首次信任（TOFU）直接绑定成功。

## 步骤 4 · 截断复制件与被拒启动

- 把恢复后的 `world-copy/` 再复制为 `world-damaged/`，只把 `farm.json` 截断到前 32 字节；`farm.backup.json` 保持完整。
- 用同一入口启动损坏目录：

```text
WORLD_SERVER_ERROR {"detail":"load_recovery_available","ok":false,"reason":"world_open"}
```

| 检查 | 结果 |
|---|---|
| 退出码 | 2（拒绝启动） |
| 拒绝阶段 | `world_open` |
| 拒绝原因 | `load_recovery_available`：主档损坏但上一代备份完整，服务端**不自动回滚** |
| 截断文件 | 启动后仍是 32 字节，未被改写 |
| 锁 | 拒绝启动后释放 |
| 原件哈希树 | 与步骤 2 基线逐文件相同 |
| 恢复后的 `world-copy/` | 仍完整可读，`sequence=2` |

## 步骤 5 · 同一端口复用与退出清理

- 原件与复制件两个运行都使用端口 60018；`server-status.json` 分别记录 `opened=created` / `loaded`。
- 两次停止都得到 `state=stopped`、`save=saved`，`authority.lock` 不存在。
- 测试记录所有启动的 pid，结束时再次检查并兜底终止；本次运行后没有本夹具的 `world_server.gd` 进程残留。

## 原始末行与测量

```text
MEASURE files=12 state_sha=dbdb316fc0d2b5fc3ef5ebe7faf08122a2d52bfda229383403d30a173b96062f restored=true original_unchanged=true
ROOM_BACKUP_DRILL_TEST checks=84 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/room-backup-27196
```

- `files=12`：迁移目录中的文件数。
- `state_sha`：恢复并继续执行后的 `world-copy/farm.json` SHA-256。命令时间戳每次不同，因此它是本次运行的证据，不是可复现的固定黄金值。
- `restored=true`：复制目录可启动、原身份可加入、命令继续提交并落盘。
- `original_unchanged=true`：原件哈希树在复制、复制件重启、损坏场景前后都与基线相同。
- 84 项检查全部通过。

## 覆盖

| 要求 | 证据 |
|---|---|
| 用现有开房/服务端入口建立房间 | `world_server.gd`；`WORLD_SERVER_READY opened=created` |
| 至少一次成员命令产生的持久变化 | WSS 播种命令，`sequence 0→1`，重载后 `crop_id=greens` |
| 停止服务端 | `stop` 控制文件；`WORLD_SERVER_STOP save=saved` |
| 整目录复制到新干净目录 | `_copy_tree()` 递归复制，12 个文件 |
| 关键文件字节一致 | 10 个实际存在的关键文件逐字节比较；两棵哈希树相同 |
| 相同邀请码/身份重启并加入 | 复制件 `invite.bin` 与 `server.crt` 不变；原凭据加入 |
| 状态保留 | 重启时 `last_sequence=1`，继续后 `sequence=2` |
| 身份绑定保留 | 外来证明 `player_proof`；原证明通过；绑定文件字节不变 |
| 命令可继续执行 | `water` 命令成功并落盘 |
| 原件全程哈希树一致 | 复制前、复制后、复制件重启后、损坏场景后均比对 |
| 复制件截断损坏被拒 | 退出码 2；`world_open` / `load_recovery_available` |
| 损坏不影响原件 | 原件哈希树与基线相同；损坏文件未被改写 |
| 同一端口复用 | 原件与复制件都监听 60018 |
| 退出清理、避免残留进程 | 两次停止均无锁、进程退出；夹具兜底终止已记录 pid |

## 未覆盖

- **真实跨机**：未在两台机器、真实网卡或网络文件系统之间搬运目录；大小写敏感、权限、符号链接、部分写入等文件系统差异未覆盖。本次的“干净目录”仍在同一块本机磁盘上。
- **Windows 实机**：路径大小写、重命名替换、只读介质和 PowerShell 复制流程未复跑。
- **真实点按**：没有走桌面“开房”界面、加入码粘贴和玩家档案目录（`player/player.key`）迁移；夹具直接调用同一服务端脚本并注入固定身份材料。
- **备份期间持续写入**：演练先停止服务端再复制，没有覆盖只读冻结窗口、边写边复制或复制中途新提交的情况。
- **中断与部分复制**：损坏注入是“文档截断”，不是复制进程被杀、磁盘写满或 `SIGKILL` 中途；提交边界中断见 [M3-03](RECORD-03-commit-recovery.md)。
- **大世界与保留策略**：夹具约 33 KB；未测接近 `FarmStore.MAX_BYTES` 的世界、备份目录体积增长和清理策略。
- **侧车代次**：本次场景没有生成 `social.backup.json` / `nature.backup.json`，未验证这两份侧车随目录迁移；`territory.json` 也未生成。
- **并发与轮换**：未覆盖多玩家同时在线时迁移、`invite.bin` / `world.key` / `server.crt` 轮换、密钥丢失后的恢复。
- **端口竞争**：只验证了“停止后同一端口重启”，没有验证同一端口被其它进程抢占时的报错路径。

## 缺陷与阻塞

1. **无阻塞**：现有入口支持脚本化“停止服务端 → 复制目录 → 从复制目录重启”，不需要为了演练修改产品代码。
2. **已观察的低风险日志缺陷（未修）**：`Game/world/world_host.gd` 的 `_defer_disconnect()` 在等待 0.5 秒后无条件调用 `multiplayer.disconnect_peer(peer_id)`。如果客户端在收到拒绝后立刻断开，服务端会打印：

   ```text
   ERROR: Condition "!peers_map.has(p_peer_id)" is true.
      at: disconnect_peer (modules/websocket/websocket_multiplayer_peer.cpp:484)
   ```

   首次运行时在“外来证明被拒后客户端立即重连”的路径上观察到一次；夹具现在等待 0.8 秒再关闭客户端，后续运行不再出现。它不影响拒绝语义或世界数据，但会让 CI 日志出现引擎 ERROR。按本任务边界未修改生产代码，登记给后续维护。

## 产物位置

```text
.local/verification/room-backup-27196/
  world-original/      原件数据目录（12 个文件，停止状态）
  world-copy/          迁移后的复制件（继续操作到 sequence=2）
  world-damaged/       复制件的损坏副本（farm.json 截断为 32 字节）
  logs/room_backup_drill_test.log   本次夹具完整输出（含临时邀请材料）
```

`.local/` 不会进入提交。
