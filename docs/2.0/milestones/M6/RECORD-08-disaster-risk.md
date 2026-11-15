# M6-03 · 风险灾害模式与农场损失上限

状态：切片完成（2026-11-16），未验收。范围：`nature_state.gd` 增加确定性的 `"risk"` 灾害模式；`farm_state.gd` 在风险模式下把灾害严重度换算为受上限约束的湿度损失；设置菜单与状态文案已接线。权威网络切换、灾害表现与 Windows 验证不在本切片。上位记录：[RECORD-03-disasters](RECORD-03-disasters.md)。

## 问题

M6 验收原文是「温和模式不毁基本生活，风险模式损失受规则上限约束」。此前的灾害只有 `gentle` / `off` 两个模式，`severity` 仅作展示元数据、不参与任何计算，因此「风险模式」与「损失上限」两条都无实现可验。本切片补上纯规则层：

- 风险模式必须比温和模式更容易受灾，且完全由持久种子和块索引推导，读档不重抽。
- 风险损失必须有明确的单格、单次结算、单日上限，不能一次灾害就把作物或成长清零。
- 温和模式的数值与行为逐字节不变。

## 规则与常量

### 灾害推导（`Game/farm/nature_state.gd`）

| 项 | 温和（默认） | 风险 |
|---|---|---|
| 可产生事件的 5 天窗口 | 仅偶数窗口 | 全部窗口 |
| 单窗口事件概率 | 2/3 | 2/3 |
| 严重度上界 `severity` | `DISASTER_MAX_SEVERITY = 3` | `RISK_MAX_SEVERITY = 4` |
| 事件时长／块对齐 | 1 个 6 小时块 | 同左 |
| 单窗口事件数 | 至多 1 | 至多 1 |
| 天气序列 | 不变 | 不变 |

- `DISASTER_MODES = ["gentle", "risk", "off"]`，`DEFAULT_DISASTER_MODE` 仍为 `"gentle"`，默认快照仍只有 `{seed, rules_version}` 两个键。
- 风险模式只增加「可产生事件的窗口」。窗口内的块位置、种类散列完全未改，所以温和模式已有的每个事件在风险模式下仍是同一块、同一 `kind`，只是 `severity` 取值范围从 1–3 扩到 1–4。长期平均事件率约为温和模式的两倍。
- 推导只看 `seed` 与窗口索引，不新增持久字段；切换模式不会回写已结算块。同一 seed 同一窗口在任何模式、任何进程、任何读档次数下都得到同一块位置。
- 风险模式下相邻窗口各自至多一个事件，跨窗口边界可能相邻；同一 5 天窗口内仍至多一次。`next_disaster_at()` 的 60 天有界搜索不变。

### 农场损失上限（`Game/farm/farm_state.gd`）

| 常量 | 值 | 含义 |
|---|---|---|
| `RISK_DROUGHT_LOSS_PER_SEVERITY` | 0.0625 | 每级严重度的湿度损失 |
| `RISK_DROUGHT_MAX_LOSS` | 0.1875 | 单次灾害（单块）损失上限 |
| `RISK_CELL_DAILY_LOSS_MAX` | 0.5 | 单格每 UTC 日累计灾害损失上限 |
| `RISK_SETTLE_LOSS_MAX` | 0.75 | 单次结算（一次 `settle()`／离线上限推进）灾害损失上限 |

- **只作用于风险干旱**。风险暴雨仍走原 `STORM_MOISTURE_GAIN`（+1/4），不随严重度缩放；未知种类不产生任何损失，避免未来种类变成未解释的第二重损失。
- **单次**：`severity × 0.0625`，封顶 0.1875。严重度 1 → −1/16，2 → −1/8，3 → −3/16，4 → −3/16（被单次上限截断）。即最高严重度与温和模式干旱的基础 −1/8 相比仍更高，但不会超过 3/16。
- **单日**：同一格每 UTC 日累计只扣 0.5。按风险模式平均约 1.5 次灾害／天、单次最多 0.1875，正常节奏远达不到 0.5；该上限只在不常见的密集事件或人为构造环境时生效。
- **单次结算**：一次调用跨越多日时最多扣 0.75（= 1.5 倍单日上限）。这保证长时间离线一次性追赶不会把整片农场抽干；在线逐日结算则每天获得新的单日预算，因此离线追赶的损失不会比在线更重。
- **基本生活保护**：灾害从不删除作物、成熟批次、背包、仓库或建筑，也不产生第二个生长倍率。成长值只增不减，灾害只通过 `weather_growth_factor()` 的湿度档位降低生长速率。测试直接断言 60 天连续最高严重度风险干旱后成长单调不减、仍成熟、仍收获恰好 1 份。
- **温和路径不变**：`risk_mode == false` 时走原来的 `_moisture_after_disaster()`，常量与调用顺序未改。
- **旧环境**：注入对象若没有 `get_disaster_mode()`，`_environment_disaster_mode()` 返回 `"gentle"`，因此 M6-02 的天气源不会凭空获得风险损失。

### 模式回退

世界设置从 `risk` 改回 `gentle` 或 `off` 时：

- 已结算格子的 `moisture`、`growth_seconds`、`last_settled_utc_seconds` 不被重算或回滚，`snapshot()` 逐字节不变。
- 之后的结算从已存湿度与基线继续；`off` 只让后续 `disaster_at()` 为空。
- 与既有 `off` 开关语义一致，无迁移、无补偿。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/farm/nature_state.gd` | 模式枚举加入 `"risk"`；新增 `RISK_MAX_SEVERITY = 4`；`_disaster_for_window()` 在风险模式下接受全部窗口并按模式取严重度上界；头部注释更新。天气推导、`RULES_VERSION`（仍为 2）、文档形状、`restore_snapshot()` 均未改。 |
| `Game/farm/farm_state.gd` | 新增四个风险损失常量与说明；`_settle_cell_environment()` 在风险模式下对单次、单日、单次结算施加损失上限；新增 `_environment_disaster_mode()` 与 `_risk_disaster_loss()`。温和路径与 `_moisture_after_disaster()` 未改。 |
| `tests/nature_disaster_risk_test.gd` | 新增 259 项。 |
| `Game/ui/game_menu.gd` | 灾害选项改为三项，新增 `_disaster_mode_at(index)`，`set_disaster_mode()` 按名选中。 |
| `Game/scenes/main.gd` | 新增 `_disaster_mode_status(mode)`，切换后的提示按模式区分。 |
| `tests/game_menu_test.gd` | 新增 3 项灾害开关断言。 |
| `docs/2.0/decisions/ADR-009-disasters.md` | 追加决定 8 收下风险模式，取代原决定 6 的排除条款。 |
| `docs/2.0/milestones/M6/RECORD-08-disaster-risk.md` | 本记录。 |

## 菜单接线

- `Game/ui/game_menu.gd` 的「设置 → 世界 → 灾害」改为三项：`温和 / 风险 / 关闭`，顺序与 `_disaster_mode_at(index)` 一致；`set_disaster_mode()` 按名选中而不是按索引，新增模式不会再错位。菜单仍只发出 `disaster_mode_changed(mode)` 意图，`nature.json` 的写入仍由场景负责。
- `Game/scenes/main.gd` 新增 `_disaster_mode_status(mode)`：`risk` 提示「灾害已切换为风险模式，单次与单日损失有上限」，并沿用「切换不回写已结算湿度与生长」的说法。
- 联机时三项都只读，提示仍是「联机模式下，灾害由世界房主决定」。
- `tests/game_menu_test.gd` 新增 3 项断言：三项文本与顺序、选择只对实际变化的模式发信号、只读状态下三种模式都能按名显示。

## 实际验证

命令均在仓库根目录执行，引擎为 `/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot`，单测超时 300 秒。

```
NATURE_DISASTER_RISK_TEST checks=259 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/nature-disaster-risk-565762
NATURE_STATE_TEST checks=182 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/nature-state-604597
DISASTER_TEST checks=247 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/disaster-594173
DISASTER_TOGGLE_TEST checks=79 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/disaster-toggle-606614
FARM_STATE_TEST checks=582 failures=0
RAIN_MOISTURE_TEST checks=100 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/rain-moisture-630694
DISASTER_PRESENTATION_TEST checks=55 failures=0
NATURE_INTEGRATION_TEST checks=856 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/nature-integration-63100/run-607838
GAME_MENU_TEST checks=97 failures=0
FONT_COVERAGE_TEST checks=1271 failures=0 missing=0
```

`NATURE_STATE_TEST` 与 `FARM_STATE_TEST` 的检查数高于 RECORD-03 记录值，是这两个测试在此之后已有其他切片新增断言，并非本切片修改。

`NATURE_DISASTER_RISK_TEST` 覆盖：模式枚举与默认值；旧两键文档与 version 1 文档仍按温和读取；风险事件数严格多于温和、同种子两次推导逐项相同、不同种子不同、温和事件在风险下保持同块同种类、严重度达到 4、每窗口至多一次、天气序列不变；重载与 JSON 往返不重抽；单次损失按严重度精确为 1/16–3/16 且不超过单次上限；单日四次最高严重度爆发只扣 0.5；十天一次性追赶只扣 0.75 且不比逐日更重；60 天连续最高严重度干旱成长单调不减、仍成熟、仍收获 1 份；切回 `gentle` / `off` 后同刻结算与快照逐字节不变、后续成长不回滚；非法模式与含非法模式的快照被拒绝；三种模式快照与 JSON 往返。

## 复核中发现的缺陷

- 风险模式放宽窗口后，相邻窗口边界上的两个事件可以相距 1 个块，原先「相邻事件至少相隔 5.25 天」的注释与测试只对温和模式成立。已在 `_disaster_for_window()` 注释中区分两种模式，并在新测试里改断言「每 5 天窗口至多一次」。
- 首版测试把风险模式的单日预算误当作「雨后仍可观测」，实际上雨天会补水掩盖损失；已改为中性天气隔离灾难预算，断言逐项可复现。
- 首版测试断言「切换后 24 小时内成长严格增加」；成熟作物封顶后成长不再增加，断言改为「不小于已结算值」。这不是产品缺陷，是测试断言过强。

## 未覆盖

- 权威侧只验证本机 `HeadlessWorld.set_disaster_mode("risk")` 的保存、重开与单机逐字节一致（`NATURE_DISASTER_RISK_TEST` 末尾 21 项）；未新增 RPC，房主经网络切换风险模式仍未接入，联机下 `risk` 只随既有 `nature` 视图下发。
- 风险损失的 UI 说明、播种前损失预告、灾害表现、居民反应均未实现。
- 没有按地块范围的灾害，也没有温度、肥力、排水或保险等缓解机制。
- 只验证 macOS 无头引擎的纯规则与 `FarmState`；未运行场景／窗口测试，未在 Windows 复跑。
- 没有网络／共享世界的风险模式一致性测试（客户端摘要只读，服务端切换不在本切片）。

## 相关裁决

- [ADR-009 温和模式的灾害与预警](../../decisions/ADR-009-disasters.md)（2026-11-16 追加决定 8，取代原「风险模式不在本裁决内」条款）
- [RECORD-03 灾害与恢复](RECORD-03-disasters.md)
