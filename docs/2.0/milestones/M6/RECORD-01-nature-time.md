# M6-01 · 固定自然时间语义

状态：切片完成（2026-11-15）。范围：确定性天气事件、时间解释与持久化；未接入降雨或湿度对生长的影响。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/farm/nature_state.gd` | 纯规则所有者。保存 `{seed, rules_version}`；由种子与事件序号推导天气块，提供 `weather_at()`／`next_weather_at()`、`daylight_at()`、`agricultural_day_at()`、`season_at()`。 |
| `Game/farm/nature_store.gd` | `nature.json` 独立文档存储，临时文件＋回读校验＋替换；缺失时返回固定默认种子而不是重新抽样；版本不符或损坏拒绝。 |
| `Game/world/headless_world.gd` | 打开时读取或创建自然状态；首个农场提交前写入种子；`state_snapshot()` 带 `nature`；`summary()` 暴露只读 `nature` 视图。 |
| `Game/world/world_member.gd` | 从权威摘要恢复自然状态；缺失时使用固定默认种子，损坏时返回 `invalid_nature`。 |
| `Game/farm/world_package.gd` | 世界包 `FORMAT_VERSION=3`；v3 信封键集增加 `nature`，用 `NatureState.restore_snapshot()` 校验且不复制规则。v1/v2 旧包读取后升级为 v3，缺失自然状态时补固定默认种子。 |
| `Game/farm/world_transfer.gd` | 导出读取活存档目录的 `nature.json`；缺失用默认种子，损坏或版本较新拒绝且不写目标目录。导入把包内种子写入目标目录的 `nature.json`，内容相同不重写；迁移备份包含 `nature.json`。 |
| `Game/farm/v27_importer.gd` | v27 没有自然文档，生成的世界包写入固定默认种子；活世界导出可传入从存档读到的真实种子。 |
| `tests/nature_state_test.gd` | 新增 136 项检查，覆盖确定性、分段／一次推进、存档往返、在线／离线路径、首次创建竞争、边界与非法输入。 |
| `tests/world_snapshot_test.gd` | 摘要文档由三键扩为四键，增加自然种子随快照传递、恢复与损坏拒绝断言。 |
| `tests/world_package_test.gd` | 扩到 123 项，覆盖 v3 往返、v1/v2 升级默认种子、自然状态损坏／较新规则拒绝与未知字段。 |
| `tests/world_transfer_test.gd` | 扩到 113 项，覆盖导出携带真实种子、v3 往返、v2 导入默认种子、包内自然状态失败、目标不同种子的替换与备份、重复导入不重写、损坏种子导出不改目标。 |
| `tests/v27_importer_test.gd` | 增加 v27 包携带默认种子断言。 |

农场文档、`FarmState._valid_snapshot` 与 `V27Importer.KNOWN_FARM_KEYS` 未改动；世界包格式与迁移按下方“世界包与运行时迁移”补齐到 v3。

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

复核（2026-11-15，切片作者以外）：`NATURE_STATE_TEST 136 failures=0`、`WORLD_SNAPSHOT_TEST 31 failures=0`。CI 证据：规则工作流 run `43650423779`（提交 `0e306ac`，macOS 与 Windows）全部通过；该次运行尚未把 `nature_state_test` 列入工作流清单，登记随下一批提交生效。

世界包迁移补测（2026-11-15）：

```
WORLD_PACKAGE_TEST checks=123 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/world-package-212944
V27_IMPORTER_TEST checks=69 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/v27-import-207705
V27_FIXTURES_TEST checks=27 failures=0 root=/Volumes/Disk-1tb/yipiantian/tests/fixtures/v27
WORLD_TRANSFER_TEST checks=113 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/world-transfer-215588
HEADLESS_WORLD_RUNTIME_TEST checks=60 failures=0
WORLD_SNAPSHOT_TEST checks=31 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/world-snapshot-209055
NATURE_STATE_TEST checks=136 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/nature-state-206811
```

世界包切片的 CI 证据：规则工作流 run `43651368899`（提交 `4919a32`，macOS 与 Windows）全部通过，含 `world_package_test`、`world_transfer_test`、`v27_importer_test` 与 `farm_v27_fixtures_test`。作者以外复核：`WORLD_PACKAGE_TEST 123`、`WORLD_TRANSFER_TEST 113`、`V27_IMPORTER_TEST 69`、`V27_FIXTURES_TEST 27`，均 `failures=0`。

## 世界包与运行时迁移

2026-11-15 补齐。世界包格式升到 v3，v3 信封携带 `nature`，形状与 `NatureState.snapshot()` 一致，校验复用 `NatureState.restore_snapshot()`。

- **导出**：从被导出世界所在目录读取 `nature.json`。缺失按 `NatureStore.load_state()` 的 missing 语义使用固定默认种子；文档损坏或版本较新时以 `nature_corrupt`／`nature_unsupported` 失败，且在写入前停止，目标目录不产生任何文件。
- **导入**：把包内自然状态写到目标目录的 `nature.json`。目标已有相同内容时不重写（`nature_written=false`）；不同内容按既有“先备份旧世界再替换”的导入规则处理，旧 `nature.json` 与其他文档一起进入 `import-backups`。写入失败按既有回滚路径恢复备份。
- **兼容**：v1/v2 旧包仍可读取，缺少自然状态时升级为固定默认种子，绝不重新抽样。v27 一次性导入没有自然文档，生成的世界包写默认种子。

## 未覆盖

- M6-02：降雨／湿度尚未改变地块或生长，天气目前只有只读解释。
- M6-03：没有灾害、预警、影响范围或恢复路径。
- 单机场景尚未显示或消费自然视图；本次不改 `Game/scenes/main.gd` 与住宅呈现文件。规则、存储和权威摘要已可供其接入。
- 没有真实天气、地理位置、系统时区或联网校时。

## 相关裁决

- [ADR-007 自然状态独立文档](../../decisions/ADR-007-nature-time.md)
