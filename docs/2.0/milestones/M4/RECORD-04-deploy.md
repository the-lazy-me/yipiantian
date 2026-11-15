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
- **健康检查**：`server-status.json` 常驻数据目录，含 `state`、`port`、`pid`、`world_id`、`run_generation`、`sequence`、`read_only`、`members`、`cert_fingerprint`，以及 `save`（正常退出为 `saved`，只读退出为 `read_only_skipped`）。
- **运维控制用文件**：数据目录下的 `stop` 与 `read-only` 两个文件即控制入口。文件方式是为跨平台一致：Windows 没有可移植的进程信号。
- **启动清理只针对 `stop`**：`stop` 是上一次运行的临时控制文件，启动成功后在就绪之后删除；`read-only` 是持久部署态，启动、运行与退出都保留，退役目录不会因为重启而重新可写。启动参数校验失败时不触碰任何控制文件。
- **世界名一次固定**：首次成功启动把 `--world` 记到数据目录的 `world-id.txt`；之后用不同 `--world` 启动以 `world_mismatch` 拒绝（加入码携带世界名，静默改名会让已发出的码全部失效）。要改名，先停服、删除该文件再启动。
- **参数范围即拒绝**：端口、代次与 `--now-utc` 越界按 `invalid_option` 拒绝而不是夹到边界值；参数校验在建目录之前完成，被拒绝的启动不留下空目录。
- **单实例目录锁**：`authority.lock/` 目录用 `make_dir` 的原子性占位，`owner` 文件每 5 秒刷新 mtime 作为心跳；心跳超过 30 秒视为崩溃残留并回收。第二个进程启动返回 `data_dir_locked` 并退出 2，不再依赖 `OS.is_process_running`（它只回答子进程）。
- **指纹可校验**：`cert_fingerprint` 是证书 DER 的 SHA-256，已用 `openssl x509 -fingerprint -sha256` 逐字节比对一致；成员可据此固定证书。
- **快门安全**：每个命令提交是原子的（[M3-03](../M3/RECORD-03-commit-recovery.md)），SIGKILL 不会留下半写世界；优雅停机额外保存并写 `state=stopped`。已验证 Godot 4.7.2 的 SIGTERM 不触发 `_finalize()`，所以不把清理逻辑放在那里。只读权威在运行中跳过生长推进、经济扫描与保存，退出时也不写盘；`read-only` 标记在世界打开前读取，因此打开时的社交表清理只在内存中生效，不会改写 `social.json`。

## 验证

`tests/m4_server_test.gd`：把真实入口当子进程运行，共 79 项检查。

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 280 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m4_server_test.gd"
```

结果：`M4_SERVER_TEST checks=79 failures=0`。2026-11-15 在 30 余个并发 Godot 进程的负载下，68 项版本连续 6 次通过；加入只读社交、参数范围与世界名固定断言后逐轮通过。

| 用例 | 实际输出 | 结果 |
|---|---|---|
| 缺 `--data-dir` | 非零退出，stdout `missing_data_dir` | 通过 |
| 非法端口 | 非零退出，stdout `invalid_option`，不建世界也不建材料 | 通过 |
| 超范围参数 | `--port=70000` 非零退出并报 `invalid_option`；不建目录，也不静默夹到 65535 | 通过 |
| 世界名固定 | 首次启动把 `--world` 写入 `world-id.txt`；改值启动报 `world_mismatch` 且不改盘，删除该文件后才按新名启动 | 通过 |
| 相对数据目录 | 非零退出，stdout `relative_data_dir`，工作目录中不产生任何目录 | 通过 |
| 失败启动保留部署态 | 带 `read-only` 的目录用非法参数启动失败后标记仍在，`authority.lock` 已释放 | 通过 |
| 首次就绪 | `opened=created`、`state=running`、指纹 32 段 | 通过 |
| 邀请只打印一次 | 首次 `invite_code` 与磁盘 `invite.bin` 相同；重启输出无该字段 | 通过 |
| 成员连接 | 仅凭邀请 + 证书经 WSS 加入，提交成功 `sequence=1` | 通过 |
| 停止 | 状态文件 `state=stopped`、`saved=true`；落盘序号 1 | 通过 |
| 重启续接 | `opened=loaded`、`sequence=1`，新命令到 `sequence=2` | 通过 |
| 停写 | `read-only` 文件生效后状态 `read_only=true`；已连成员被拒 `read_only` | 通过 |
| 停写不落盘 | 重载序号仍为 2；运行中与退出后 `farm.json` 字节都不变，退出 `save=read_only_skipped` | 通过 |
| 停写不写社交 | 只读权威下新玩家加入后 `social.json` 字节不变（显示名留给下一个可写权威） | 通过 |
| 停写跨重启 | 退役目录重启后仍 `read_only=true`，读取仍可用 | 通过 |
| 控制文件不粘滞 | 写 `stop` 后再次启动成功 | 通过 |
| 目录已被占用 | 同目录第二个进程返回 `data_dir_locked`，不触碰世界 | 通过 |

用例已加入 `.github/workflows/rule-tests.yml`，双平台绿色证据：CI 运行 `43635219694`（提交 `34e24de`），`rules (macos-latest)` 与 `rules (windows-latest)` 均通过。

## 支持矩阵

| 平台 | 状态 | 依据 |
|---|---|---|
| macOS (arm64) | 已验证 | 本机执行全部 79 项 |
| Windows x64 | 已验证 | CI 运行 `43635219694`，`rules (windows-latest)` 通过 |
| Linux x64 | 未验证 | 无 Linux 运行环境；入口不含平台分支，但未实测 |

## 未覆盖

- 没有导出（export）产物：当前以编辑器二进制 + `--script` 运行，没有独立服务器包。发行形态留给 M13。
- 没有 systemd / launchd / Windows 服务封装、日志轮转、崩溃自动重启或端口占用处理。
- 房主休眠行为未测：服务端世界时间由 `--now-utc` 起算的单调时钟推进，但没有覆盖系统睡眠后长区间补算的实测。
- 无中心目录：加入仍需完整地址 + 邀请 + 证书，没有发现服务或地址簿。
- 邀请没有有效期、一次性使用、吊销或按命令的权限矩阵；`--world` 与实际身份也未绑定到持久化元数据。
- 未覆盖并发运维控制（两个操作者同时写 `stop`/`read-only`）与真实网络（非回环）环境；目录锁只保证单进程写入，不做跨机协调。
- 服务端目前没有外部地址发布机制（NAT/证书域名），只有自签证书与 IP 地址。

## 关联

- 前序：[M4-04 世界搬迁](RECORD-03-move.md)；传输与身份裁决 [ADR-004](../../decisions/ADR-004-transport.md)。
- 提交原子性：[M3-03](../M3/RECORD-03-commit-recovery.md)。
- 阶段计划：[M4 PLAN](PLAN.md) M4-05。
