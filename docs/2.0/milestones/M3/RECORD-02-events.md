# M3-02 · 事件调度实现记录

执行日期：2026-11-15。基线提交：`952caaf`；本记录与切片同批提交。规则版本：FarmState v27，存档信封 `version=27`。本记录只证明事件调度与分段推进的最小切片，不表示 M3 或 M3-02 已完成验收。

## 环境与输入

- macOS 27.0.1，arm64（Apple M4 Pro）。
- Godot 4.7.2-stable，`4.7.2.stable.official.ed1daf0bf`；仅使用 `--headless`。
- 隔离目录：`.local/verification/`；无玩家真实存档参与。
- 种子 `7`，逻辑起点 `1800000007`。

## 改动

- `Game/world/headless_world.gd`：
  - 新增 `next_event_utc()`：遍历权威 FarmState 快照中的作物格，用 `Crops.definition().duration_seconds` 与 `Crops.YOUNG_PROGRESS` 计算下一次 `sprout→young` 或 `young→mature` 的时刻。阈值仍由规则目录提供，无头入口不复制生长公式。
  - `advance_to()` 改为事件分段推进：先把可能落后的结算基准规整到当前世界时间，再在每个 `next_event_utc()` 落在事件上调用 `FarmState.settle()`，最后补到 target。`changed_fields` 与 `visual_changed` 去重合并，返回值保留 `ok`/`reason`/`changed_fields`/`reward_crop_id`/`reward_amount`/`visual_changed`，并新增 `segments`。
  - `summary()` 增加 `next_event_utc`；没有未来事件时输出 JSON `null`（方法本身返回 `INF`）。
- `Game/world/headless_runner.gd`：摘要增加 `segments`；`next_event_utc` 随 `summary()` 输出。参数、单行 `HEADLESS_WORLD {json}` 和退出码行为不变。
- `tests/headless_event_schedule_test.gd`：新增 56 项检查，覆盖事件阈值、连续推进与按事件分段逐字段一致、30 天离线分段、回拨不负增长、成熟／空世界返回 `INF`。
- `docs/2.0/milestones/M3/PLAN.md`：在 M3-02 下加入本记录链接，阶段状态保持未验收。

## 事件与时间语义

- `next_event_utc()` 只考虑有作物且 `growth_seconds < threshold` 的格；事件时刻为
  `last_settled_utc_seconds + (threshold - growth_seconds)`。空地块与已成熟作物不产生事件。
- 若算出的时刻早于当前世界时间（例如读档后尚未结算的旧基准），方法返回当前世界时间，表示“结算到当前即会触发”；没有可用事件时返回 `INF`。
- `advance_to(target)` 先结算到当前时间以消除旧基准，再从严格晚于当前时间的事件开始分段；事件时刻必须大于当前游标，避免零进度循环。后段时间到 target 的最终 settle 一定执行一次，因此 `segments` = 事件边界段数 + 最终段（`target == now` 时为 0）。
- 30 天离线最多每格两次阶段变化：现有场景（4 个初始作物 + 1 个新播种作物）实际为 5 个事件边界 + 1 个最终段 = 6 段，测试上界取 `2 × 作物格数 + 1`。
- 不引入随机或伪随机分支；事件顺序由快照遍历和最小值决定，结果可重复。

## 回拨取舍

- `HeadlessWorld.advance_to()` 继续拒绝 `target < now_utc`，返回 `ok=false`、`reason=time_backwards`，世界时间与 FarmState 状态不变。
- `FarmState.settle(更早时刻)` 保持既有语义：`_settle_data` 对 `now <= last_settled_utc_seconds` 的格直接跳过，因此直接调用不会减少 `growth_seconds`、库存或已收获数。
- 选择“会话边界拒绝回拨、规则层安全跳过”的组合：调用方若绕过无头会话直接向 FarmState 传入更早时间，会得到无变化结果而不是负生长；正常运行器不接受回拨目标。未添加自动校时、反作弊或收益上限。

## 实际命令与结果

测试入口（仓库根目录）：

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
"$GODOT" --headless --path Game --script "$PWD/tests/headless_event_schedule_test.gd"
"$GODOT" --headless --path Game --script "$PWD/tests/headless_world_runtime_test.gd"
"$GODOT" --headless --path Game --script "$PWD/tests/farm_command_test.gd"
```

结果：

- `HEADLESS_EVENT_SCHEDULE_TEST checks=56 failures=0`，退出码 0。
- `HEADLESS_WORLD_RUNTIME_TEST checks=53 failures=0`，退出码 0（原 53 项不变）。
- `FARM_COMMAND_TEST checks=26 failures=0`，退出码 0。

无头运行器，30 天离线（实际执行）：

```sh
"$GODOT" --headless --path Game --script res://world/headless_runner.gd -- \
  --data-dir=.local/verification/m3-02-long-20261115-002328 --seed=7 --advance-seconds=2592000 \
  --commands="sow:field_01:cell_01:greens@0;water:field_01:cell_01@60"
```

摘要片段（其他字段省略，路径为仓库相对路径）：

```json
{"ok":true,"checks":12,"failures":[],"start_utc":1800000007.0,"target_utc":1802592007.0,"advance_seconds":2592000.0,"segments":6,"next_event_utc":null,"now_utc":1802592007.0,"opened":"created","committed_commands":2,"root_children":0,"data_directory":".local/verification/m3-02-long-20261115-002328"}
```

其中 `field_01/cell_01` 为 `mature`、`growth_seconds=1800.0`、`watered=true`，`inventory.greens=0`。

同一运行器带收获命令（`sow@0;water@60;harvest@9000`、`--advance-seconds=9000`）退出码 0，`checks=13`、`committed_commands=3`、`segments=0`、`next_event_utc=null`：收获命令已把世界结算到 target，之后没有剩余事件。摘要仍为单行 `HEADLESS_WORLD {json}`。

## 设计取舍

- 事件调度只读取 FarmState 快照和 Crop 目录，不复制生长规则；阶段阈值变化只需改规则目录。
- `next_event_utc()` 每次从权威快照重新计算，不持久化事件序号或游标。这样不新增存档格式字段，也能在命令、重开和回拨后自然得到一致结果；代价是每次调用复制一次快照，调用次数受事件上界约束。
- 长离线不做逐帧或逐秒重放，只按阶段边界分段；单次 30 天推进为常数级事件数。
- `segments` 只描述本次推进的结算段数，不进入持久化状态；运行器把它作为诊断字段输出。
- `summary()` 的 `next_event_utc` 使用 `null` 表示无未来事件，避免在 JSON 中输出非标准 `Infinity`；方法 API 仍返回 `INF`。
- 归一化 settle 对已一致的世界是无副作用的重复结算；对读档后滞后基准则先补齐到当前时间，保证后续事件时刻基于最新成长值。

## 未覆盖项

- 未在 Windows 上运行；跨平台无头行为仍无证据。
- 未实现服务器时间与单机时间的来源区分：本切片只接受调用方提供的逻辑 UTC，不读取系统时钟，也不做联网校时。
- 未做崩溃注入、提交中断恢复或跨进程事件序号；留待 M3-03。
- 未持久化下一事件游标；每次调用按权威快照重算。当前规模（106 格）开销可接受，未测更大世界或高频唤醒。
- 未验证真实时钟异常（系统时钟回拨、异常前跳）对上层调用方的影响；只覆盖显式传入的时间。
- 新测试未加入 `.github/workflows/rule-tests.yml`，本轮未运行窗口、场景或全量规则测试。
- 未实现多世界固定种子批量实验；留待 M3-04。

## 结论

事件调度切片已实现并通过上述定向检查：连续推进与事件分段结果逐字段一致，30 天离线段数有界，回拨不产生负增长。缺少 Windows、真实时钟异常和恢复事务证据，M3-02 仍按 PLAN 保持未验收。
