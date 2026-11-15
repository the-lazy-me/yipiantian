# M6-03 · 灾害与恢复

状态：切片完成（2026-11-15），未验收。范围：按种子确定性地推导干旱／暴雨，给出预警与只读视图，在温和模式下只通过土壤湿度影响生长；风险模式、灾害表现与新的存档字段不在本切片。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/farm/nature_state.gd` | `RULES_VERSION` 升到 2；`restore_snapshot()` 接受 1 和 2，其他版本拒绝；新增 `disaster_at()`、`next_disaster_at()` 与独立于天气 LCG 的确定性散列。灾害只从种子和 5 天窗口／6 小时块推导，不新增持久字段。 |
| `Game/farm/nature_store.gd` | `nature.json` 信封接受 version 1 和 2；读入的 version 1 状态在内存中即为当前版本，下一次 `save_state()` 写回 version 2。其他版本仍为 `unsupported`。 |
| `Game/farm/farm_state.gd` | 环境对象新增可选 `disaster_at()` 调用；每个完成块先应用天气增量，再叠加同块灾害增量（干旱 −1/8、暴雨 +1/4），并限制在 0–1。生长仍只走 `weather_growth_factor(kind, moisture)`，没有第二个倍率。旧环境没有 `disaster_at()` 时视为无灾害，不引入模式。 |
| `Game/world/headless_world.gd` | 新增只读 `disaster_view()`；`nature_view()` 与 `summary()["nature"]` 增加 `disaster`、`warning`，原有 `weather`、`next_weather_utc`、`season`、`daylight` 保持不变。 |
| `tests/nature_state_test.gd` | 规则版本改为 2；补 version 1 接受、version 0／较新版本拒绝、升级后天气一致与下一次保存重写版本的断言。共 149 项。 |
| `tests/rain_moisture_test.gd` | 补充“只有 `weather_at()` 的旧环境”仍按纯天气增量结算，不凭空产生灾害。共 100 项。 |
| `tests/disaster_test.gd` | 新增 247 项，覆盖确定性、版本升级、事件间隔、块边界湿度、分段一致性、长期离线、浇水缓解、无产出损失、旧／异常环境与摘要视图。 |
| `docs/2.0/milestones/M6/RECORD-03-disasters.md` | 本记录。 |

未改动 `nature.json` 的 `{seed, rules_version}` 形状、农场文档键、格子形状、`V27Importer.KNOWN_FARM_KEYS`、世界包 v3 信封、`Game/scenes/main.gd` 与 HUD。

## 规则与确定性

- **推导来源**：`disaster_at(utc)` 只使用持久种子和 6 小时块序号。时间线按 5 个农业日划窗；只有偶数窗口可能产生灾害，其中约三分之二有事件，因此同一 5 天窗口最多一次，相邻事件至少相隔 5.25 天，长期平均约 15 天一次。事件恰好覆盖一个 6 小时块，起始、结束与天气块边界完全对齐，`advance_to()` 不需要新的分段点。
- **种类与强度**：`kind` 只有 `drought`、`storm`；`severity` 为 1–3 的展示／排序整数，不参与湿度或生长计算。`nature.json` 仍只是 `{seed, rules_version}`，事件不逐条存盘。
- **世界年龄不参与推导**：`nature.json` 没有世界开始时间，因此新世界也可能在开头几天遇到灾害。温和模式下灾害只让土壤变干并减速，成熟产出与库存不受影响，所以不额外持久化世界年龄来“保证平静开局”；若将来要做平静期，需要把它作为显式世界字段另行裁决。
- **湿度**：只在完成天气块时变化。先应用该块天气增量（雨 +1/4、多云 −1/16、晴 −1/8），再叠加同块灾害（干旱额外 −1/8、暴雨额外 +1/4），最后限制在 0–1。晴＋干旱合计 −1/4；雨＋暴雨从 0.5 起封顶为 1.0。块内结算不改变湿度。
- **温和模式边界**：灾害不删除作物、成熟批次、背包、仓库或建筑，也不产生第二个生长倍率。成熟作物继续封顶，长期离线只可能让未浇水的地块变干并减速，不会枯死；浇水把该格置 1，是立即生效的当地保护。
- **预警视图**：`summary()["nature"]["disaster"]` 是当前覆盖时刻的事件（无则 `{}`），含 `kind`、`severity`、`starts_utc`、`ends_utc`；`warning` 是下一个块内开始的事件（无则 `{}`），含同样字段并额外带 `lead_seconds`。`disaster_view()` 与摘要使用同一推导。
- **旧环境**：`FarmState` 只依赖注入对象的 `weather_at()` 与可选的 `disaster_at()`。M6-02 的天气源没有后者时按无灾害处理；返回非字典或未知种类时同样忽略，不建立模式开关或全局回退。

### 规则版本 1 → 2 的取舍

`rules_version=1` 是 M6-01／M6-02 数小时前写下的当前开发文档，不是历史发行格式。项目规则不要求为早期开发数据建立迁移机制，因此这里不新增迁移器，只保留一条显式读取路径：

- version 1 的种子照常读出，天气散列输入完全未改，同一颗种子升级前后天气逐块相同。
- 已经结算过的农场状态保留自己的 `last_settled_utc_seconds` 与湿度，升级不会重算过去；只有升级之后才结算的块会包含灾害层。
- 下一次保存把信封与状态一起写成 version 2。
- version 0、version 3 及以上仍然拒绝；没有其他兼容分支。

这项升级被测试直接覆盖，见下节 `DISASTER_TEST` 与 `NATURE_STATE_TEST`。

## 实际验证

命令均在仓库根目录执行，引擎为 `/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot`，单测超时 300 秒。

```
DISASTER_TEST checks=247 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/disaster-224223
NATURE_STATE_TEST checks=149 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/nature-state-429876
RAIN_MOISTURE_TEST checks=100 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/rain-moisture-215685
FARM_STATE_TEST checks=385 failures=0
HEADLESS_WORLD_RUNTIME_TEST checks=60 failures=0
HEADLESS_EVENT_SCHEDULE_TEST checks=56 failures=0
WORLD_SNAPSHOT_TEST checks=31 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/world-snapshot-219926
WORLD_PACKAGE_TEST checks=123 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/world-package-236968
WORLD_TRANSFER_TEST checks=113 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/world-transfer-242349
V27_IMPORTER_TEST checks=69 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/v27-import-250359
```

复核（2026-11-15，切片作者以外）：作者最初实现了“前两个农业日无灾害”，但它只是绝对 UTC 日序号检查，`nature.json` 没有世界开始时间，实际无法表达“新世界先平静两天”。复核删除了这段死代码、相关测试与记录中的宣称，`DISASTER_TEST` 由 253 项变为 247 项；`DISASTER_TEST 247`、`NATURE_STATE_TEST 149`、`RAIN_MOISTURE_TEST 100` 复核全部 `failures=0`。

`NATURE_STATE_TEST` 与 `HEADLESS_WORLD_RUNTIME_TEST` 日志中的 `FARM_STORE stage=changed_on_disk` 和损坏档 `push_error` 栈是既有失败路径夹具的预期输出，断言仍为零失败。

`DISASTER_TEST` 覆盖：同种子重复调用、重新装载与不同种子对照；冻结的天气块序列；5 天窗口内至多一次、相邻事件至少 5 天、单块时长与种类／强度范围；version 1 文档读出后写回 2、天气逐块相同、升级后只对之后结算的块应用灾害、重复边界幂等；干旱／暴雨在精确块边界的 −1/8／+1/4 与上下限；30 天一次推进与按天气块推进的农场快照逐项相同；365 天离线的湿度范围与成熟批次保留；浇水在干旱块立即恢复满湿度和正常倍率；灾害不改变库存、收获计数或作物身份；无环境、只有天气、空灾害、非字典返回值与未知种类；摘要的当前灾害、下一块预警、提前量与原有键。

## 未覆盖

- 只有温和模式；没有风险模式、额外存档键或按地块的灾害范围。灾害的视觉、声音与 NPC 反应属于 M6-04，本切片不新增表现。
- 没有世界年龄保护：新世界开局也可能遇到灾害（详见“规则与确定性”）。
- `next_disaster_at()` 只有 60 天的有界搜索，超出范围返回 −1；预警只覆盖紧邻的下一个块。
- 温度、肥力、排水、真实天气适配器与跨季节数值仍未实现。
- 未运行场景／窗口测试；本记录只包含 macOS 无头引擎结果，未在 Windows 复跑。
- 世界包 v3 信封未改；携带 version 1 自然状态的包在读取时会规范化为 version 2。目前没有单独的包级升级测试，版本升级由 `NATURE_STATE_TEST` 和 `DISASTER_TEST` 的文档路径覆盖。

## 相关裁决

- [ADR-009 温和模式的灾害与预警](../../decisions/ADR-009-disasters.md)
- [ADR-008 区域降雨与地块湿度](../../decisions/ADR-008-rain-moisture.md)
- [ADR-007 自然状态独立文档与固定时间语义](../../decisions/ADR-007-nature-time.md)
