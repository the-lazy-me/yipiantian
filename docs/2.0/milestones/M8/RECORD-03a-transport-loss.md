# M8-03a · 运输风险损失证据

状态：切片完成（2026-11-15），未验收。范围：为后续保险提供“权威生成、逐笔耐久、可防重复”的运输损失证据；发货时可显式声明运输风险，到达扫描确定性判定交付或丢失，丢失写入唯一 `economy.losses` 行。不包含保单、保费、理赔、保险现金科目、风险模式作物损失、UI/HUD、风险信息定价或旧档迁移器。

权威设计：[ADR-022](../../decisions/ADR-022-insurance-loss-evidence.md) 的 P0-A；前置：[M7-04 记录](../M7/RECORD-04-logistics.md)、[ADR-013](../../decisions/ADR-013-limited-logistics.md)、[ADR-014](../../decisions/ADR-014-double-entry-ledger.md)；上游：[M8-03 调查](RECORD-03-insurance.md)、[经济与金融](../../systems/economy-finance.md)、[M8 PLAN](PLAN.md)。

## 结论

1. 世界现在能回答“谁、何时、因何、损失了什么、多少价值”：每条损失行包含唯一 `loss_<sequence>` id、受害者、发货 id、商品、数量、路线与原因窗口、发货时锁定的参考单价、总价值与规则版本。
2. 损失由权威到达扫描在**同一候选快照**内生成，与 shipment 的终态 `lost` 一起提交；货物销毁、现金不变，`total_cash == issued` 与既有货币守恒口径不变，商品守恒增加 `lost` 终点。
3. 判定是持久字段的纯函数（FNV-1a 派生，不读系统时钟、不使用 RNG、不把命令 id 纳入），因此重开、长离线补算和重复扫描得到同一结论；shipment 的持久 `status` 保证不重复决议、不重复写行。
4. 证据行只保存终态损失，上限 256，淘汰最旧事件并递增单调 `archived`；`archived + 活跃行 == sequence` 由校验强制。这与 M7-09 归档策略一致，但没有为旧档写迁移器。
5. 本切片**不产生任何赔付**，也没有保费；`reserve_statement.claims` 仍为 0。损失行是后续保单与理赔的唯一输入，不是保险本身。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/farm/market_state.gd` | shipment 新增 `risk`/`lost_utc`/`loss_id` 与终态 `lost`；确定性风险判定；到达扫描对声明风险写损失行；`economy.losses` 初始化/校验/查询/归档；发货与损失双向引用校验；旧 shipment 按 safe 读入。 |
| `Game/farm/economy_state.gd` | `STATE_KEYS` 增加 `losses`；初始状态包含空损失表；缺失 `losses` 按空表恢复；`valid` 调用 `Market.valid_losses`。 |
| `Game/farm/farm_state.gd` | `market_ship` 增加可选 `risk`；`market_deliver` 在仅有损失时也提交候选；新增 `market_losses()`/`market_loss()`；恢复时归一化 shipment 风险字段与损失表。 |
| `Game/farm/farm_command.gd` | `market_ship` 命令接受可选 `risk`（7 键旧形状仍有效且等价于 safe）；命令执行与 payload 绑定风险。 |
| `tests/market_logistics_test.gd` | 新增风险损失、无损路径、重开持久、回放幂等、旧档读入、损失表校验夹具；商品口径计入 `lost`。 |
| `tests/market_archive_test.gd` | 新增损失行 256 上限、归档计数、伪造计数/数量/单价/窗口/终态互斥夹具。 |
| `tests/m8_stress_test.gd` | 新增声明风险损失场景：损失无现金变化、60 天重复扫描不二次决议、无保险子文档；商品口径计入 `lost`。 |

未新增依赖、场景节点、HUD、网络消息或美术资源。农场格式仍为 27；没有新增农场顶层键，`FarmState._valid_snapshot` 的键数、`V27Importer.KNOWN_FARM_KEYS` 与 `valid_cell_snapshot` 均未改。新键只进入 `economy.losses` 与 `economy.market.shipments` 的行内字段。

## 规则

### 风险声明

```text
shipment = 现有字段 + {
  risk: "safe" | "declared",
  lost_utc: 0.0,
  loss_id: ""
}
```

- 默认 `safe`：与 M7-04 完全一致，到达必交付。
- `declared`：到达时按权威规则判定交付或丢失；发货前可由调用方展示最大损失（当前 UI 未做）。
- 旧 shipment 行没有这三个字段时按 `safe`、未丢失读入并补齐键，这不是迁移文件；出现部分字段则整体拒绝。
- 风险声明只允许 `safe`/`declared`，其他值返回 `invalid_risk` 且不移动货物或现金。

### 确定性判定

```text
roll = fnv1a("transport_loss_v1", sequence, owner, good, quantity,
             origin, destination, int(depart_utc)) mod 1000
lost = risk == "declared" and roll < RISK_LOSS_PERMILLE   # 当前 250
```

- 只用持久字段；不考虑命令 id、结算扫描时刻或系统时钟，因此同一发货在任何重放路径得到同一结果。
- 风险判定在到达扫描内执行，与 `Market.deliver()` 的既有语义一致：`arrive_utc <= now_utc` 时一次结算全部到期 shipment，按 `sequence` 升序。

### 损失行

```text
economy.losses = {
  sequence: int,        # 只由它生成 loss id
  events: {loss_id: event},
  archived: int         # 单调淘汰计数
}
event = {
  id, sequence, kind, at_utc, cause_start_utc, cause_end_utc,
  victim, shipment_id, good, quantity, unit_value, value, rule_version
}
kind = "transport_loss";  id = "loss_" + sequence
```

- `unit_value` 取发货时 `EconomyCatalog.base_price(good)`，`value = unit_value × quantity`；校验按同一公式重算，玩家不能自报金额。
- `cause_start_utc = depart_utc`、`cause_end_utc = at_utc = arrive_utc`：损失时间用原因窗口，而不是扫描时刻；离线补算也能证明损失发生在哪一段。
- 丢失时同一候选把 shipment 置 `lost`、写 `lost_utc = arrive_utc`、`loss_id`，并清空 `delivered_utc`/`delivery_id`；不写交付事件。
- 丢失不移动现金，也不追加分录；发货时已经销毁的运费仍是唯一货币影响。

### 守恒

- 货币：损失前后 `total_cash == issued` 不变，`issued >= 0`。
- 商品：`口袋 + 商人库存 + 卖单托管 + 在途 + 已消耗 + lost == 产出 + 商人授予`。夹具把 `lost` 行数量计入总量，证明丢失是真实终点而非静默缺口。

### 幂等与归档

- shipment id 就是发货命令 id：同一 id 回放返回持久行（`duplicate=true`），不二次扣货、扣费或写损失；命令窗口淘汰后仍返回 `shipment_exists`。
- 到达扫描是状态驱动：`status != in_transit` 的行不会再次进入判定，因此同一 shipment 至多一条损失行；重复扫描是 no-op。
- 损失表达到 256 行时淘汰最旧 `sequence`，`archived` 递增；只有终态行可被淘汰。shipment 表满时淘汰最旧终态行（`delivered` 或 `lost`），在途行永不淘汰。
- 校验强制 `events.size() + archived == sequence`，缺失事件、膨胀归档数、倒序序号、伪造数量/单价/价值/窗口、`safe` 却 `lost`、`lost` 却带交付 id 均拒绝。

## 命令与接口

```text
market_ship(command_id, owner, origin, destination, good, quantity, now_utc)
market_ship(command_id, owner, origin, destination, good, quantity, now_utc, risk)
market_deliver(now_utc) / market_deliver(now_utc, command_id)
market_shipment(id) / market_shipments()
market_loss(loss_id) / market_losses()
```

- 发货结果新增 `risk`、`lost_utc`、`loss_id`。
- 交付结果新增 `lost`（笔数）与 `losses`（本次写入的事件数组）；`count` 仍只统计交付笔数。
- 命令层 `market_ship` 的旧 7 键形状继续有效并等价 `safe`；8 键形状必须携带已知风险值，payload 只在声明风险时追加该字段，因此旧命令重放字节不变。

## 实测输出

隔离目录、无头 Godot 4.7.2：

```text
MARKET_LOGISTICS_TEST checks=1274 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/logistics-21817
MARKET_ARCHIVE_TEST checks=3709 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/market-archive-22502
M8_STRESS_TEST checks=925 failures=0
FARM_STATE_TEST checks=385 failures=0
```

同工作树的关联回归：

```text
FARM_COMMAND_TEST checks=136 failures=0
LEDGER_TEST checks=1841 failures=0
MARKET_SUPPLY_DEMAND_TEST checks=1220 failures=0
MERCHANT_LIQUIDITY_TEST checks=347 failures=0
ECONOMY_INITIAL_TEST checks=154 failures=0
FARM_STORE_TEST checks=119 failures=0
V27_IMPORTER_TEST checks=69 failures=0
MARKET_PANEL_TEST checks=49 failures=0
LONG_SOAK_TEST checks=11340 failures=0 days=365 losses=4
WORLD_TRANSFER_TEST checks=113 failures=0
HEADLESS_WORLD_TEST checks=14 failures=0
WORLD_ECONOMY_CLOCK_TEST checks=43 failures=0
HEADLESS_WORLD_RUNTIME_TEST checks=70 failures=0
PLAYER_THEFT_TEST checks=128 failures=0
DISASTER_TEST checks=247 failures=0
M4_ECONOMY_COMMANDS_TEST checks=137 failures=0（只叠加本切片改动时）
```

`M4_ECONOMY_COMMANDS_TEST` 在当前未提交工作树会得到 `checks=151 failures=2`（`a-inner-dup` 的重放未标记 duplicate）。把本切片的七个文件叠加到干净 `HEAD` 后该夹具为 137/0，未叠加时为 137/0，因此该失败来自并行未提交的网络/时钟改动（`headless_world.gd` 的 future-clock 与 replay 分支），不是本切片。`LONG_SOAK_TEST` 含并行工作树改动，但损失的 365 天循环、有界与守恒断言均通过。

关键观测（夹具）：

| 观测 | 结果 |
|---|---|
| 声明风险 `sequence=1, quantity=2` | 命中损失判定；到达到期后 `lost=1`、无交付事件、袋中 6 篮 |
| 同参数 `safe` 发货 | 正常交付，袋中 8 篮，无损失行 |
| 声明风险但 roll 高于阈值（`quantity=1`） | 正常交付，无损失行 |
| 损失行字段 | `victim/shipment/good/quantity`、`cause_start=depart`、`cause_end=at=arrive`、`unit_value=6`、`value=12`、`rule_version=1` |
| 损失后现金 | 账户 118、`issued=total_cash=358`，无赔付、无新分录 |
| 同 shipment id 重放 | `duplicate=true`，快照不变；换风险为冲突 |
| 到达扫描重放 | 命令窗口内返回原结果；窗口淘汰后仍 0 笔新损失 |
| 存盘重开 | 损失行、`lost`/`delivered`/`in_transit` 三终态、序号、窗口与整数/浮点类型逐项恢复 |
| 60 天离线后补扫 | 损失不重算、不赔付、快照不变 |
| 损失表超过 256 行 | 保持在 256 行，`archived>0` 且 `archived + 活跃行 == sequence`；最旧 `loss_1` 被淘汰 |
| 伪造校验 | 缺行、膨胀 `archived`、序号倒退、价值≠单价×数量、单价偏离目录、窗口不符、`safe` 判 `lost`、`lost` 带交付 id 均拒绝 |
| 旧档 | 无风险字段的 shipment 按 safe 恢复并补齐键；缺 `losses` 恢复空表；旧 shipment 不能声称 `lost`；缺失部分损失键拒绝 |

## 未覆盖

- **保险本身**：无保单、保费、免赔、限额、理赔、保险现金科目或 `claims`；`reserve_statement.claims` 仍为 0。损失行只是输入。
- **风险信息与定价**：可选固定保费仍可被“只给即将损失对象投保”套利；本切片的判定对客户端可推导，不能替代 ADR-022 要求的强制/合作保险或不可推导风险裁决。
- **风险概率与展示**：`RISK_LOSS_PERMILLE=250` 是实验值，没有按路线/商品/价值差异化；UI 未展示声明风险与最大损失，单机市场面板无法选择 `declared`。
- **世界级接线（文件边界外，需主会话登记）**：`Game/world/headless_world.gd` 的 `settle_economy()` 用 `expired+matched+delivered+loans` 计算 `changed`，没有计入损失；仅发生损失的扫描会返回 `changed=false`，不会保存/广播。探针已验证：`FarmState.market_deliver` 正常写入损失并落盘后重开保留，但 `settle_economy_now()` 在该状态没有其他变化时不提交。`Game/scenes/main.gd` 的 `_settle_market()` 同样没有计入损失，仅损失的单机扫描不会触发 `_save_farm()`。两者都不在本切片允许修改的文件内。
- **网络权限**：`market_ship` 的 `risk` 尚未接入 WorldHost 角色权限表；成员可提交该字段，但仍受既有经济命令权限约束。
- **灾害作物损失**：ADR-022 的 P0-B 未实现，温和模式仍只改湿度。
- **长期世界**：损失行与 shipment 行都是有界证据，超过上限后旧证据只留计数；若保险上线，必须先保证每条待赔损失不会被淘汰。
- **平台**：本轮只在本机 macOS 无头运行，未验证 Windows、CI、真实存档或共享世界会话。

## 后续保险切片的输入

- 理赔以 `loss.id` 为全局唯一键；损失行已经提供受害者、原因窗口、数量与锁定价值，保单匹配无需玩家自报。
- 保单必须在 `cause_start_utc` 之前生效、`cause_end_utc` 之后仍有效；损失行的时间字段支持该判定。
- 一个 shipment 至多一条损失行，因此“同一损失不重复理赔”可建立在 `loss_id` 唯一之上；但仍需理赔行自身的持久唯一键，不能依赖 64 条命令窗口。
