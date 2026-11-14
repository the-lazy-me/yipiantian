# M3-01 · 无头入口实现记录

执行日期：2026-11-15。基线提交：`b7c26fb`；本记录与切片同批提交。规则版本：FarmState v27，存档信封 `version=27`。本记录只证明无头入口的最小切片，不表示 M3 或 M3-01 已完成验收。

## 环境与输入

- macOS 27.0.1，arm64（Apple M4 Pro）。
- Godot 4.7.2-stable，`4.7.2.stable.official.ed1daf0bf`；仅使用 `--headless`，本轮未运行窗口测试。
- 隔离目录：`.local/verification/`；无玩家真实存档参与。
- 种子 `7`，逻辑起点 `1800000007`（`1800000000 + seed mod 86400`），推进至 `1800009007`（+9000 秒）。

## 改动

- `Game/world/headless_world.gd`：新的无头世界会话。从 FarmStore 打开或创建世界，在 FarmState 候选状态上执行命令，保存成功后才接受并记录命令；时间推进调用 `FarmState.settle()`，不复制农场规则。不加载场景、节点、DisplayServer、GPU 或网络。
- `Game/world/headless_runner.gd`：`extends SceneTree` 的可执行入口。参数 `--data-dir --seed --start-utc --advance-seconds --target-utc --commands`，输出一行 `HEADLESS_WORLD {json}`，包含检查数、命令结果、库存、地块、耗时和引擎内存指标。
- `Game/farm/farm_command.gd`：命令边界从收获扩展到播种和浇水；收获/浇水的字典形状保持 5 键，播种增加 `crop_id` 为 6 键。回放、冲突和“保存后才 commit”的语义不变。
- `tests/headless_world_runtime_test.gd`：新增 53 项检查，覆盖无头启动、命令链、重复命令、长时间推进、重开和失败路径。
- `docs/2.0/milestones/M3/PLAN.md`：在 M3-01 下加入本记录链接。

## 实际命令与结果

测试入口（仓库根目录，`GODOT_PATH` 指向锁定的 4.7.2 编辑器）：

```sh
"$GODOT_PATH" --headless --path Game --script "$PWD/tests/headless_world_runtime_test.gd"
```

结果：`HEADLESS_WORLD_RUNTIME_TEST checks=53 failures=0`，退出码 0。

无头运行器（实际执行的参数）：

```sh
"$GODOT_PATH" --headless --path Game --script res://world/headless_runner.gd -- \
  --data-dir=.local/verification/m3-01-final3-20261115-000949 \
  --seed=7 --advance-seconds=9000 \
  --commands="sow:field_01:cell_01:greens@0;water:field_01:cell_01@60;harvest:field_01:cell_01@9000"
```

结果：退出码 0，摘要 `checks=13`、`failures=[]`、`committed_commands=3`。三条命令均为 `committed`；`field_01/cell_01` 收获后为 `empty`，`inventory.greens=1`、`harvested.greens=1`；`root_children=0`，即未实例化主场景节点。

同一序列改用 `--target-utc=1800009007` 也以退出码 0 完成。故意在空地块执行收获（`--commands="harvest:field_01:cell_01@10"`）返回 `ok=false`、`reason=empty`，退出码 1，未保存。把 `--data-dir` 指向运行存档 `user://farm-v27` 会在打开前被拒绝（`live_save_directory`，退出码 1），不会读写玩家存档。

日志检查：成功与失败运行的 stdout/stderr 均未出现 `/Users/`、`/Volumes/` 或用户名；`data_directory` 只输出仓库相对路径。

## 资源数据

| 指标 | 数值 |
|---|---|
| 运行器内部检查 | 13 项，0 失败 |
| 端到端耗时（含启动、打开、命令、保存、重开） | 9.684 ms |
| Godot 静态内存 `OS.get_static_memory_usage()` | 28,242,282 B（约 26.9 MiB） |
| Godot 静态内存峰值 `OS.get_static_memory_peak_usage()` | 45,099,961 B（约 43.0 MiB） |
| 场景根子节点 | 0 |
| 默认世界地块数 | 6 个田块 × 16 格 + 10 个菜架格 |

这些是引擎静态分配指标，不是进程 RSS 或 macOS `phys_footprint`。短时单世界数据不足以给出长期驻留预算。

## 设计取舍

- 规则只有一个权威来源：生长结算全部由 `FarmState.settle()` 完成，无头入口只负责世界时间基准、命令顺序和持久化。
- 命令链复用现有 `FarmCommand`：新增 `make_sow()`、`make_water()` 和按 kind 分派，没有在无头入口另写一套幂等逻辑。收获命令的 5 键形状与既有调用方保持不变。
- 持久化顺序沿用 M0：候选状态 → `FarmStore.save_state()` → 接受候选 → commit。保存失败时丢弃候选并恢复内存中的装饰解锁，避免未落盘结果进入权威状态。
- `advance_to()` 拒绝回拨时间；`execute()` 拒绝新的回拨动作，但已提交 id 的重试仍进入回放。回拨、分段补算和事件调度属于 M3-02。
- 命令幂等集仍只存在于单个会话内，不跨进程持久化；崩溃提交与恢复属于 M3-03。
- 种子当前只决定逻辑起点偏移。现有农场规则没有随机源，因此种子不影响生长结果；不为实验入口虚构随机分支。
- 运行器把相对数据目录解析到仓库根，输出时优先使用仓库相对路径，其次 `<home>/…` 或仅目录名；不输出账户名。运行存档 `user://farm-v27` 在打开前被拒绝，M3-01 实验只能写隔离目录。
- `root_children=0` 是“未加载主 3D 场景”的运行期证据。Godot 引擎自身在 `--headless` 下仍会初始化无头显示后端，本代码不调用 DisplayServer 或渲染能力。

## 未覆盖项

- Windows 证据来自干净检出 CI 的同一夹具（`rule-tests.yml` 运行 43617023131，`HEADLESS_WORLD_RUNTIME_TEST checks=53 failures=0`）；未验证 Windows 桌面宿主接入。
- 未测长时间驻留、连续多世界、CPU/GPU 时间、整机功耗或真实进程 RSS；只有引擎静态内存和短时端到端耗时。
- 未做崩溃注入、提交中断恢复或跨进程命令幂等；留待 M3-03。
- 未实现按下一事件唤醒、时间回拨和长区间分段；留待 M3-02。当前 `advance_to()` 与新的 `execute()` 动作均拒绝回拨，已提交命令的重试仍可回放；未验证真实时钟异常。
- 未实现多世界固定种子批量实验和事件摘要；留待 M3-04。运行器一次只处理一个目录。
- 新测试已加入 `.github/workflows/rule-tests.yml` 的 macOS/Windows 矩阵（`a08457f`）；本轮仍未运行窗口、场景或全量规则测试以外的新增场景覆盖。
- 失败路径测试中，FarmStore 的 `push_warning` 会由 Godot 输出调试栈（含工程绝对路径）；这是测试仪器的错误诊断，不属于运行器摘要，摘要本身已去除真实路径。

## 结论

无头入口切片已可执行并通过上述定向检查，且在 macOS 与 Windows 干净检出上结果一致；仍缺少长时间资源和崩溃恢复证据。M3-01 仍按 PLAN 保持未验收，M3-02 已建立切片，M3-03/04 未完成。
