# ADR-008 · 区域降雨与地块湿度

- 状态：采纳（2026-11-15）
- 关联：[M6-02](../milestones/M6/RECORD-02-rain-moisture.md)、[自然系统](../systems/nature.md)、[ADR-007](ADR-007-nature-time.md)、[农场模拟规则](../../../rules/farm-simulation.md)

## 背景

M6-02 的第一项是区域降雨和地块湿度：降雨补水、非雨时段失水、浇水改变局部状态。温度、肥力、排水与灾害不在本切片。

约束来自两侧：

- 天气已经由 `NatureState` 独占：种子持久化、`weather_at(t)` 是纯函数，读档不重抽（ADR-007）。若 `FarmState` 自己去读全局或存储，就会出现第二个天气所有者。
- 结算必须分段无关：同一快照与同一时间区间，一次推进和任意分段推进的离散事件、生长、湿度、产出逐项相同。这排除了按帧、按调用次数或按“现在几点”取样。

同时，`FarmState` 的格子形状被三处耦合校验：`_valid_snapshot` 的键数、`valid_cell_snapshot`、`V27Importer.KNOWN_FARM_KEYS`。能少加持久字段就少加。

## 决定

1. **依赖方向：`FarmState` 接收一个环境对象，不读取全局。** `FarmState.set_environment(NatureState)` 只依赖 `weather_at(utc_seconds) -> {index, kind, start_utc, end_utc}` 这一契约；`NatureState` 仍是天气的唯一所有者。没有注入环境时，`FarmState` 保持 M6-01 之前的加法生长规则，单机场景不需要改动。
2. **会话负责提供环境并加入分段点。** `HeadlessWorld.open()` 在拿到自然状态后调用 `farm.set_environment(nature)`；`advance_to()` 在每次循环里同时比较生长事件与 `nature.next_weather_at(now_utc)`，天气块边界与生长事件一样是推进分段点。`WorldMember.restore_state()` 与无场景单命令入口 `world_command_entry.gd` 做同样接线，保证在线、离线和单命令路径看到同一段天气。
3. **每个格子只新增一个持久字段 `moisture`（0–1，初始 0.5）。** 它只在完整天气块结束时变化，变化发生在绝对 UTC 块边界上，因此所有推进会得到同一个值：`rain` +0.25（上限 1）、`cloudy` −1/16、`clear` −1/8（下限 0）。浇水的 `water` 命令把该格湿度置为 1（当地灌溉），相邻格不变。
4. **生长倍率是块内常量。** `rain` 时 1.0；`clear`/`cloudy` 时，土壤湿度 ≥ 0.5 为 1.0，< 0.5 为 0.5；未知天气 1.0。倍率取 2 的幂，块内按 `(分段时长 × 倍率)` 累加，不会额外引入乘法误差；在整秒、天气边界与生长边界这些实际分段点上，一次推进与任意分段推进的结果逐项相同（测试直接比较整份快照）。效果有界：作物只会变慢，成熟后封顶，产量、收获上限、偷菜与住宅语义不变。湿度只在块边界以 1/16 的整数倍变化，不涉及浮点漂移。
5. **湿度不新增“干燥累计”等派生字段。** 块次序由时间决定，湿度是“上次结算 + 期间完成的天气块”的结果；跨块区间按块逐段推进。默认新格湿度 0.5，所以一块晴朗后即进入干燥，玩家浇水或降雨可立即恢复；连续晴朗的失水下限为 0，但只影响倍率，不会枯死。
6. **格子形状兼容当前 v27 夹具。** 规范格为 7 键（增加 `moisture`）；`valid_cell_snapshot` 要求原有 5 个键，`planted_by` 与 `moisture` 各自可缺省（v27 两者都没有），未知键仍拒绝；`restore_snapshot` 在缺失时补 `planted_by=""`、`moisture=0.5`。`V27Importer.KNOWN_FARM_KEYS` 不含格子内部键，因此不需改；没有新增迁移分支，世界包格式不变（湿度随农场快照自然携带）。
7. **玩家可解释的视图。** `get_cell()` 增加派生只读值 `moisture`、`moisture_label`（dry/damp/wet）和 `growth_rate`（当前块倍率）。它们不参与存档，不能通过视图修改权威状态。

## 为什么不是另一侧

- **不让 `FarmState` 读 `nature.json` 或全局单例**：那会让规则所有者依赖存储和进程生命周期，候选事务（`copy()`）也会共享可变外部状态；测试需要写文件才能验证纯规则。
- **不让 `NatureState` 拥有湿度**：天气是世界级的，湿度是格子级的玩家状态，属于 `FarmState`；把湿度塞进自然状态会让 save/load、世界包和成员恢复都改格式，扩大范围。
- **不新增随机源或帧率驱动**：天气种类已由种子和时间推导，湿度只做确定性累加/扣减。

## 后果

- 格子形状只剩 `valid_cell_snapshot` 与 `restore_snapshot` 的默认值两处维护点；农场文档的 `_valid_snapshot` 键数与 `V27Importer.KNOWN_FARM_KEYS` 都未改动（`moisture` 是格子内部键，不在农场键表里）。`farm_v27_fixtures_test` 的 5 键夹具与 6 键中间形状继续通过。
- 单机场景（`Game/scenes/main.gd`）在 M6-02 场景接入切片后按同一语义读取 `nature.json` 并注入环境，所有农场提交先落种子；选中田格时 HUD 显示湿度与生长倍率（2026-11-15 补记，未改变本裁决结构）。
- 世界服务器的时间推进只要调用 `advance_to()`，天气块边界就会成为分段点；`next_event_utc()` 仍只报告生长事件，不改变既有调用契约。
- 数值（0.5/0.75 阈值、1/0.5 倍率、每块 +0.25/−0.125/−0.0625）是 M6 实验参数，可由后续实验在不改变本结构的前提下调整。
