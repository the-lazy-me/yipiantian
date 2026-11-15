# M6 集成验收 · 生态气象规则证据

状态：集成验收的规则证据完成（2026-11-15），**未**据此宣称 M6 阶段整体验收通过。范围是无头、固定种子、固定 UTC 起点的集成夹具；画面、Windows 实机、三模式进程与风险模式不在本记录内。

## 结论

- Q1 规则一致：单机 `FarmState` 结算与 `HeadlessWorld` 权威推进在 40 个天气块上逐块一致；一次推进、天气边界推进、不等长分段和 3600 次一秒推进结果相同。
- 跨季节与长离线：21 天跨 3 次季节转换、60 天 240 个天气块、106 个格子、25,440 次格子-块结算，均可在固定种子下重复，快照逐字段相等。
- 临界成熟：在种子推导出的「雨＋干旱」块结束边界前 1 秒、边界当秒和后 1 秒收获，结果由成熟规则明确决定；提前 1 秒被 `not_mature` 拒绝且不改状态，边界及之后各得到且只得到 1 篮。
- 灾害预警：同一种子下预警的 `kind`、`severity`、起止时间与结算后的 `disaster` 记录逐字段一致。
- Q2 相关：保存后重开农场与种子逐字节一致；重复命令 ID 不重复发奖；损坏的 `nature.json` 拒绝打开且不改写农场或自然文档。
- 发现并修复 1 个真实缺陷：`HeadlessWorld.open()` 在农场文档缺失但自然文档已存在时重新抽种子（见下）。

## 固定输入与环境

| 项 | 值 |
|---|---|
| 基线提交 | `1886cd0`（本次夹具与修复尚未提交，工作树基于该提交） |
| 引擎 | Godot `4.7.2.stable.official.ed1daf0bf` |
| 平台 | 本机 macOS（Darwin 27.0.0），无窗口、无 GPU、无音频 |
| 规则版本 | `NatureState.RULES_VERSION = 2`，农场文档版本 27 |
| 自然种子 | `424242` |
| 固定 UTC 起点 | `1800000000.0` 秒 |
| 天气块 | `21600` 秒（6 小时），与 UTC 午夜对齐 |
| 场景 | 默认院落 6 块地 ×16 格 + 藤架 10 格，共 106 格；初始 4 株作物，夹具补种 96 格，长离线结束时 100 株成熟并收获 |
| 冻结事件 | 块 `1803384000` 为 `rain`，同块灾害为 `drought`，用于临界成熟与预警对照 |

命令（仓库根目录执行，临时产物在 `.local/verification/nature-integration-<pid>/run-<ticks>/`）：

```
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/nature_integration_test.gd"
```

## 覆盖与断言

`tests/nature_integration_test.gd`，共 856 项检查：

1. **单机 vs 权威逐块一致**（`_test_single_player_matches_authority`）
   - 同一固定种子、同一补种与浇水输入；权威路径 `advance_to()` 每次跨一个天气块，单机路径 `FarmState.settle()` 结算到同一时刻。
   - 40 个块逐块比较整份农场快照（命令账本除外）与格子视图；比较项含 `moisture`、`moisture_label`、`growth_rate`、`crop_id`、`stage`、`growth_seconds`。
   - 结束时比较 `planted`／`mature`／`total_growth`，再在两条路径收获全部成熟格，比较收获数、库存和累计收获。
2. **分段等价**（`_test_segmentation_equivalence`）
   - 10 天一次结算 = 每个天气边界结算 = 不等长分段（997／1／7200／17／3600／21599／2 秒循环）。
   - 另取跨越一个天气边界的 3600 秒，一次结算 = 3600 次一秒结算，对应在线空闲节拍。
3. **跨季节可重复**（`_test_cross_season_determinism`）
   - 两个独立 `FarmState` 用同一种子并行跑 21 天，每块比较快照；记录季节标签与转换次数。
   - 逐块追踪 `field_01/cell_01` 的湿度，要求出现「湿度低于 0.5 后遇到降雨块并被补湿」。
4. **长离线**（`_test_long_offline`）
   - 60 天、240 个天气块、106 格，一次结算、逐块结算与权威 `advance_to()` 三条路径比较整份快照与收获结果。
   - 断言湿度在 `[0,1]`、生长不超过成熟时长、离线不销毁或新增作物；记录三条路径实际耗时。
5. **临界成熟动作**（`_test_boundary_maturity_action`）
   - 冻结边界：块 `1803384000`（`rain`＋`drought`）结束于 `1803405600`；从结束前 1800 秒种下 30 分钟青菜。
   - 前 1 秒：生长 1799 秒、未成熟、收获返回 `not_mature`，重试同样拒绝且快照不变。
   - 边界当秒：生长 1800 秒、成熟、湿度按「雨 +1/4、干旱 −1/8」只应用一次；收获 1 篮，重复收获返回 `empty` 且库存仍为 1。
   - 后 1 秒：仍成熟，收获 1 篮；与边界当秒的作物与数量一致。两者收获后结算到下一块边界，空土湿度收敛相同。
6. **灾害预警与结算一致**（`_test_disaster_warning_matches_settlement`）
   - 在灾害开始前一个块读取 `summary().nature.warning` 与 `disaster_view()`，要求提前量 1800 秒。
   - 结算到事件块起点，`summary().nature.disaster` 与预警的 `kind`／`severity`／`starts_utc`／`ends_utc` 完全相同；`disaster_view()` 与摘要相同。
   - 灾害块完成后按天气增量与灾害增量顺序改变湿度，视图清空。
7. **保存与损坏拒绝**（`_test_storage_recovery`）
   - 播种、浇水、收获均经命令链提交；保存后用新会话重开，农场快照逐字节一致，种子仍为 `424242`；重放已提交收获 ID 返回 `duplicate` 且不增加库存。
   - 将 `nature.json` 改成 `{not json` 后打开，返回 `load_nature_corrupt`，自然文档与农场文档都保持原字节，不重抽天气。

## 实测输出

本机 macOS 代表性运行（原样）：

```
CROSS_SEASON span_days=21 transitions=3 seasons=4 dry_rain_at=1800446400 final_season=winter
LONG_OFFLINE days=60 blocks=240 cells=106 cell_blocks=25440 one_shot_ms=54.1 stepped_ms=98.7 authority_ms=154.2 harvests=100
PASS Harvesting one second early is refused by the maturity rule
PASS Harvesting at the exact boundary yields one basket
PASS The warning reports the exact lead time
PASS The settled disaster record matches the earlier warning field by field
NATURE_INTEGRATION_TEST checks=856 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/nature-integration-46627/run-230864 fingerprint=ec1a394cdb471aa90f3901d9a10d14db58cd53540a3dc937d191a2c5444b5c4b
```

整个夹具进程约 2.2 秒（同一机器，`time` 实测），远低于 300 秒超时。连续 6 次独立进程运行均为 `checks=856 failures=0`，`fingerprint` 均为 `ec1a394c…e4b5c4b`；指纹覆盖权威路径、跨季节、长离线最终快照与边界／预警／存储结果，因此同时证明跨进程可重复。`one_shot_ms`／`stepped_ms`／`authority_ms` 只说明本机有限时间完成，不作为性能预算。

回归（同一修复后）：`HEADLESS_WORLD_RUNTIME_TEST 60`、`DISASTER_TEST 247`、`NATURE_STATE_TEST 149`、`RAIN_MOISTURE_TEST 100`、`WORLD_SNAPSHOT_TEST 31`、`HEADLESS_EVENT_SCHEDULE_TEST 56`、`PLAYER_BAGS_TEST 114`、`HEADLESS_CRASH_COMMIT_TEST 51`，均 `failures=0`。

最终复跑时工作树还包含其他并行工作的未提交改动（经济与居民作息，不属于本记录）。在此状态下集成夹具仍为 `checks=856 failures=0`、指纹不变，`HEADLESS_WORLD_RUNTIME_TEST 60`、`DISASTER_TEST 247`、`NATURE_STATE_TEST 149`、`RAIN_MOISTURE_TEST 100` 也仍为零失败；这只能说明并行改动没有破坏本夹具口径，不能替代合并后固定提交上的干净复跑。

## 发现的缺陷与处置

**缺陷：农场文档缺失时，`HeadlessWorld.open()` 会重新抽自然种子。**

- 位置：`Game/world/headless_world.gd` 的 `loaded.kind == "missing"` 分支。
- 根因：该分支无条件执行 `NatureState.create_seed()`，即使 `nature.json` 已存在并已成功读出。只有农场首次提交前的 `_ensure_nature_persisted()` 才回头采用文件中的种子。
- 影响：农场尚未提交但自然文档已落盘时（例如先写种子的创建流程、或农场文件被单独清理），该会话在首次提交前按随机天气推进；若期间发生结算或动作，候选状态可能带着被随后丢弃的天气历史进入保存。同一持久种子在单机路径与权威路径下会产生不同结果，预警／灾害视图也与文件中种子不一致。修复前探针实测：
  ```
  MISMATCH at 1800036000.0
  long equal one/stepped=true one/auth=false
  view before=... warning={ ... "severity": 3 ...}
  view after={ ... "severity": 2 ...}
  ```
- 修复：农场缺失时如果自然文档为 `loaded`，用 `NatureState.restore_snapshot()` 采用该种子并标记已持久化；只有自然文档本身缺失时才调用 `create_seed()`。读取失败仍返回 `restore_nature`，不覆盖文件。改动 14 行新增、2 行删除，不改变 `nature.json` 形状、农场文档、世界包或玩家数据语义。
- 回归：夹具中「A missing farm adopts the persisted natural seed」在修复前会失败；修复后 856 项通过，上述 8 个既有夹具与崩溃提交夹具全部 `failures=0`。

## Q1/Q2/Q4 对应

- **Q1 规则一致**：第 1、2、3、4、5、6 节；同输入、同逻辑时间、同规则版本下逐块等价，结果与分段方式无关。没有渲染帧参与。
- **Q2 数据可靠**：第 7 节覆盖保存后重开、重复命令不重复发奖、损坏自然文档拒绝且不改写；崩溃注入由既有 `HEADLESS_CRASH_COMMIT_TEST` 另行覆盖并通过，但未与「自然文档预置」组合。
- **Q4 模式能效**：本夹具只证明单机逻辑结算与权威会话的**状态等价**及离线恢复一致，不测量三模式的实际进程、休眠唤醒、GPU 或功耗。Q4 的能效部分仍需 M2 口径的实测，不能用本记录代替。

## 未覆盖与限制

- **没有 Windows 实机结果**：本记录只包含 macOS 无头引擎。夹具不依赖窗口、美术、字体或平台路径，已按规则工作流同样的 `--headless --path Game` 方式编写；需由主会话登记后，在两平台矩阵取得 Windows 证据，才能声称双平台通过。
- **没有截图或画面验收**：本任务只做规则与夹具；雨粒子、阴天光照、HUD 天气行等表现仍按 M6-04 记录保留为未截图。
- **没有三模式进程与能效测量**：只有逻辑状态对照，没有桌面、壁纸、无头服务三种进程的驻留、唤醒或资源数据。
- **单一固定种子**：`424242` 只覆盖一条天气／灾害序列；其他种子的边界分布不在本记录内。
- **夹具构造的临界状态**：边界前 1800 秒的作物进度由夹具构造（合法快照），不是从玩家操作自然长到该状态；验证的是边界结算与收获规则，不证明某个具体操作路径。
- **一次未能复现的存储失败**：夹具加入藤架覆盖后的第一轮曾出现一次「重开已提交世界」失败，之后 6 次连续运行均通过，未在现有代码与文件内容中找到原因。已把临时目录从仅 PID 改为 `PID/run-ticks` 以避免 PID 复用继承旧存档，并让该断言输出 `open()` 的实际返回值；这不构成产品缺陷结论。
- **风险模式、温度、肥力、排水、真实天气**未实现，不在本夹具。
- 世界包导入、v27 导入与资产授权分别由 M6-01／M0 记录和 Q10 流程覆盖，本夹具不重复。

## 相关记录与裁决

- [RECORD-01 固定自然时间](RECORD-01-nature-time.md)
- [RECORD-02 降雨与湿度](RECORD-02-rain-moisture.md)
- [RECORD-03 灾害与预警](RECORD-03-disasters.md)
- [RECORD-04 天气表现](RECORD-04-weather-presentation.md)
- [ADR-007 自然时间](../../decisions/ADR-007-nature-time.md) · [ADR-008 降雨与湿度](../../decisions/ADR-008-rain-moisture.md) · [ADR-009 灾害](../../decisions/ADR-009-disasters.md)
