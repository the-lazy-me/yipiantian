# M4-05 · 服务器部署入口

执行日期：2026-11-15。状态：切片完成，不表示 M4 或 M4-05 验收完成。前置：[M4-04 世界搬迁](RECORD-03-move.md)。

## 实现

此前权威宿主只存在于测试进程内，没有可执行的服务入口。本切片新增 `Game/world/world_server.gd`，不依赖场景、DisplayServer、GPU 或音频：

```sh
godot --headless --path Game --script res://world/world_server.gd -- \
  --data-dir=/srv/farm/world --port=7777 --world=world-alpha
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--data-dir` | 无（必需） | 世界目录；`farm.json`、材料与状态文件都在此 |
| `--port` | 7777 | WSS 监听端口，绑定 `0.0.0.0` |
| `--world` | `world` | 世界 ID，加入时校验 |
| `--generation` | 1 | 运行代次，加入回复与迁移描述符使用 |
| `--key-file` / `--cert-file` / `--invite-file` | 数据目录内 | 首次运行自动生成；也可外部挂载 |
| `--run-seconds` | 0 | 0 表示常驻；大于 0 时到点保存并退出（用于验收与定时任务） |
| `--now-utc` | 系统时间 | 世界起算时间 |

运行约定：

- **材料一次生成**：首次运行生成 RSA 2048 世界密钥、自签证书与 32 字节邀请，写盘后只在 stdout 打印一次 `invite_code`；之后的重启不再打印邀请（避免出现在日志里）。
- **健康检查**：`server-status.json` 常驻数据目录，含 `state`、`port`、`pid`、`world_id`、`run_generation`、`sequence`、`read_only`、`members`、`cert_fingerprint`。
- **运维控制用文件**：数据目录下的 `stop` 与 `read-only` 两个文件即控制入口。文件方式是为跨平台一致：Windows 没有可移植的进程信号。
- **启动清理控制文件**：启动时删除残留的 `stop`/`read-only`，否则上次停止会变成永久停机；停用状态需要重启后重新写入。
- **指纹可校验**：`cert_fingerprint` 是证书 DER 的 SHA-256，已用 `openssl x509 -fingerprint -sha256` 逐字节比对一致；成员可据此固定证书。
- **快门安全**：每个命令提交是原子的（[M3-03](../M3/RECORD-03-commit-recovery.md)），SIGKILL 不会留下半写世界；优雅停机额外保存并写 `state=stopped`。已验证 Godot 4.7.2 的 SIGTERM 不触发 `_finalize()`，所以不把清理逻辑放在那里。

## 验证

`tests/m4_server_test.gd`：把真实入口当子进程运行，共 42 项检查。

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 280 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m4_server_test.gd"
```

结果：`M4_SERVER_TEST checks=42 failures=0`，本机连续复跑 2 次通过。

| 用例 | 实际输出 | 结果 |
|---|---|---|
| 缺 `--data-dir` | 非零退出，stdout `missing_data_dir` | 通过 |
| 非法端口 | 非零退出，stdout `invalid_option`，不建世界也不建材料 | 通过 |
| 首次就绪 | `opened=created`、`state=running`、指纹 32 段 | 通过 |
| 邀请只打印一次 | 首次 `invite_code` 与磁盘 `invite.bin` 相同；重启输出无该字段 | 通过 |
| 成员连接 | 仅凭邀请 + 证书经 WSS 加入，提交成功 `sequence=1` | 通过 |
| 停止 | 状态文件 `state=stopped`、`saved=true`；落盘序号 1 | 通过 |
| 重启续接 | `opened=loaded`、`sequence=1`，新命令到 `sequence=2` | 通过 |
| 停写 | `read-only` 文件生效后状态 `read_only=true`；已连成员被拒 `read_only` | 通过 |
| 停写不落盘 | 重载序号仍为 2 | 通过 |
| 控制文件不粘滞 | 写 `stop` 后再次启动成功 | 通过 |

用例已加入 `.github/workflows/rule-tests.yml`，双平台绿色证据：CI 运行 `43635219694`（提交 `34e24de`），`rules (macos-latest)` 与 `rules (windows-latest)` 均通过。

## 支持矩阵

| 平台 | 状态 | 依据 |
|---|---|---|
| macOS (arm64) | 已验证 | 本机执行全部 42 项 |
| Windows x64 | 已验证 | CI 运行 `43635219694`，`rules (windows-latest)` 通过 |
| Linux x64 | 未验证 | 无 Linux 运行环境；入口不含平台分支，但未实测 |

## 未覆盖

- 没有导出（export）产物：当前以编辑器二进制 + `--script` 运行，没有独立服务器包。发行形态留给 M13。
- 没有 systemd / launchd / Windows 服务封装、日志轮转、崩溃自动重启或端口占用处理。
- 房主休眠行为未测：服务端世界时间由 `--now-utc` 起算的单调时钟推进，但没有覆盖系统睡眠后长区间补算的实测。
- 无中心目录：加入仍需完整地址 + 邀请 + 证书，没有发现服务或地址簿。
- 邀请没有有效期、一次性使用、吊销或按命令的权限矩阵；`--world` 与实际身份也未绑定到持久化元数据。
- 未覆盖多实例同目录、并发运维控制与真实网络（非回环）环境。
- 服务端目前没有外部地址发布机制（NAT/证书域名），只有自签证书与 IP 地址。

## 关联

- 前序：[M4-04 世界搬迁](RECORD-03-move.md)；传输与身份裁决 [ADR-004](../../decisions/ADR-004-transport.md)。
- 提交原子性：[M3-03](../M3/RECORD-03-commit-recovery.md)。
- 阶段计划：[M4 PLAN](PLAN.md) M4-05。
