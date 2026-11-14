# M6-01 · 固定自然时间语义

状态：切片完成（2026-11-15）。范围：确定性天气事件、时间解释与持久化；未接入降雨或湿度对生长的影响。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/farm/nature_state.gd` | 纯规则所有者。保存 `{seed, rules_version}`；由种子与事件序号推导天气块，提供 `weather_at()`／`next_weather_at()`、`daylight_at()`、`agricultural_day_at()`、`season_at()`。 |
| `Game/farm/nature_store.gd` | `nature.json` 独立文档存储，临时文件＋回读校验＋替换；缺失时返回固定默认种子而不是重新抽样；版本不符或损坏拒绝。 |
| `Game/world/headless_world.gd` | 打开时读取或创建自然状态；首个农场提交前写入种子；`state_snapshot()` 带 `nature`；`summary()` 暴露只读 `nature` 视图。 |
| `Game/world/world_member.gd` | 从权威摘要恢复自然状态；缺失时使用固定默认种子，损坏时返回 `invalid_nature`。 |
| `tests/nature_state_test.gd` | 新增 136 项检查，覆盖确定性、分段／一次推进、存档往返、在线／离线路径、首次创建竞争、边界与非法输入。 |
| `tests/world_snapshot_test.gd` | 摘要文档由三键扩为四键，增加自然种子随快照传递、恢复与损坏拒绝断言。 |

农场文档、`FarmState._valid_snapshot`、`V27Importer.KNOWN_FARM_KEYS` 与世界包格式均未改动。

## 时间语义

- **唯一权威是 UTC 时间点。** 自然规则不读取系统时区、真实地理位置或外部天气。
- **现实昼夜**：固定 24 小时民用周期，06:00–18:00 UTC 为昼，其余为夜。这是世界约定，不是当地太阳时。
- **农业时间**：沿用现有 1:1 UTC 生长钟，`agricultural_day_at()` 只是给它命名，避免昼夜或季节变成第二套生长时钟。
- **季节**：固定 7 天一个季节、四季循环的标签周期。长度是 M6 实验参数，本次不影响生长、产量或经济。

## 天气确定性

- 每 6 小时一个天气块，块边界与 UTC 午夜对齐；`weather_at(t)` 返回该时刻所在块、区间起止和天气种类，`next_weather_at(t)` 返回下一块结束（即再下一块开始）。
- 天气种类由持久化种子和块序号的固定整数散列决定。种子和 `rules_version=1` 一起保存；未知规则版本拒绝加载，不会用同一颗种子悄悄推导出另一段历史。
- 读档只读取种子，事件是纯函数的重新求值，因此不会重抽；同一 `target` 无论一次推进还是任意分段推进，事件序列与权威状态都相同。
- 没有自然文档的旧开发存档沿用固定默认种子，并在下一次保存时写盘，保持读档前后一致。
- 首次创建竞争时，农场存储的 expected-file 检查拒绝落败者；自然存储先重读已有种子并采用胜者种子，避免在农场提交被拒前覆盖天气历史。

## 实际验证

命令均在仓库根目录执行，引擎为 `/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot`。

```
NATURE_STATE_TEST checks=136 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/nature-state-258529
HEADLESS_WORLD_RUNTIME_TEST checks=60 failures=0
HEADLESS_EVENT_SCHEDULE_TEST checks=56 failures=0
FARM_STATE_TEST checks=385 failures=0
FARM_STORE_TEST checks=109 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/farm-store-211310
V27_IMPORTER_TEST checks=68 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/v27-import-223043
WORLD_SNAPSHOT_TEST checks=31 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/world-snapshot-213539
M4_SYNC_TEST checks=39 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/m4-sync-255460
```

`M4_SYNC_TEST` 使用 360 秒超时运行（其宿主寿命为 150 秒），其余使用 240 秒。

## 未覆盖

- M6-02：降雨／湿度尚未改变地块或生长，天气目前只有只读解释。
- M6-03：没有灾害、预警、影响范围或恢复路径。
- 单机场景尚未显示或消费自然视图；本次不改 `Game/scenes/main.gd` 与住宅呈现文件。规则、存储和权威摘要已可供其接入。
- 世界包与运行时迁移尚未携带 `nature.json`；导出／导入一个世界会保留目标目录原有的种子。接入前需要在包格式和迁移备份中显式处理。
- 没有真实天气、地理位置、系统时区或联网校时。

## 相关裁决

- [ADR-007 自然状态独立文档](../../decisions/ADR-007-nature-time.md)
