# M7-04 · 有限物流

状态：已实现（2026-11-15），未验收。范围：两处固定市场、在途货物托管、固定运费销毁、确定性到达扫描、耐久交付事件、与撮合/撤单/到期的顺序无关性，以及物流快照的持久化和拒绝边界。不包含全区域运输网、承运人、保险、风险路线、中途取消、UI/HUD、网络命令权限或旧档迁移。

权威设计：[ADR-013](../../decisions/ADR-013-limited-logistics.md)；上层规格：[经济与金融](../../systems/economy-finance.md)、[M7 PLAN](PLAN.md)；前置：[ADR-010](../../decisions/ADR-010-economy-initial-conditions.md)、[ADR-011](../../decisions/ADR-011-market-orders.md)、[ADR-012](../../decisions/ADR-012-matching-settlement.md)、[M7-03 记录](RECORD-03-matching.md)。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/farm/market_state.gd` | 新增 `farm_market`/`harbor_market` 两处固定市场、对称路线、`shipments`/`deliveries` 子账本、发货托管、确定性交付扫描、查询、重放与校验；`market` 增加四个物流键。 |
| `Game/farm/farm_state.gd` | 新增 `market_ship`、`market_deliver`、`market_shipments`、`market_shipment`、`market_deliveries`、`market_delivery`、`market_route(s)`；恢复时补空物流并归一化整数/浮点。 |
| `tests/market_logistics_test.gd` | 新增 174 项无头检查。 |
| `docs/2.0/decisions/ADR-013-limited-logistics.md` | 本切片的持久裁决。 |
| `docs/2.0/decisions/README.md` | 决策入口增加 ADR-013 一行。 |
| `docs/2.0/milestones/M7/PLAN.md` | M7-04 增加记录与决定链接。 |
| `docs/2.0/milestones/M7/RECORD-04-logistics.md` | 本记录。 |

未新增依赖、网络消息、场景节点、HUD、美术资源或旧存档迁移器。农场格式版本保持 27；没有新增农场顶层键，`FarmState._valid_snapshot` 的键数、`V27Importer.KNOWN_FARM_KEYS` 与 `valid_cell_snapshot` 均未改。物流只扩展 `economy.market` 内部形状。

## 物流规则

- **两处市场**：`farm_market` 与 `harbor_market`。发货必须从一个已知市场到另一个已知且不同的市场。路线双向固定 2 COIN、600 秒。
- **在途托管**：发货在同一候选快照中从所有者口袋扣除数量、从账户扣除运费并销毁、写入 shipment 行。口袋里没有的货物无法被卖单托管、赠礼、厨房、动物或再次发货使用。
- **到达**：`arrive_utc = depart_utc + 600`。`market_deliver(now_utc)` 扫描 `status == in_transit && arrive_utc <= now_utc` 的 shipment，按 `sequence` 升序交付；到达前 1 秒不交付，到达当秒交付，之后重复扫描为 no-op。
- **交付事件**：`delivery_<sequence>` 唯一编号，持久记录 `shipment_id`、owner、good、quantity、origin、destination、`at_utc`。一个 shipment 最多对应一个 delivery，双向引用在快照校验中检查。
- **费用**：每笔发货固定 2 COIN，由发货方支付并销毁，`issued` 与 `total_cash` 同步减少。费用没有承运人收款方。
- **幂等**：shipment id 就是发货命令 id，命令账本淘汰后仍返回 `shipment_exists`；交付幂等由 shipment 的持久 `status` 保证。可选交付命令 id 只用于重试回放，同 id 同 UTC 返回原笔数，同 id 不同 UTC 为 `command_conflict`。
- **守恒**：商品口径为“口袋 + 订单托管 + 在途 + 已消耗 = 产出”；货币仍为 `total_cash == issued`。
- **上限**：shipments 256、deliveries 256；交付记录保留用于追溯，不归档。

## 命令与接口

```text
market_ship(command_id, owner, origin, destination, good, quantity, now_utc)
market_deliver(now_utc)                    # 确定性到达扫描
market_deliver(now_utc, command_id)        # 可重试扫描：回放交付笔数 / 冲突
market_shipments() / market_shipment(id)
market_deliveries() / market_delivery(id)
market_route(origin, destination) / market_routes()
```

发货结果字段：`ok`、`reason`、`duplicate`、`shipment_id`、`owner`、`good`、`quantity`、`origin`、`destination`、`fee`、`depart_utc`、`arrive_utc`、`status`、`delivery_id`、`amount`。

交付结果字段：`ok`、`reason`、`duplicate`、`count`、`deliveries`。

## 实测输出

物流夹具使用隔离目录 `.local/verification/logistics-<pid>`，不读写玩家存档：

```
MARKET_LOGISTICS_TEST checks=174 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/logistics-52611
```

同引擎（4.7.2-stable）、同工作树、受影响夹具的回归：

```
MARKET_ORDERS_TEST checks=188 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/market-orders-52739
MARKET_MATCHING_TEST checks=215 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/matching-52643
ECONOMY_INITIAL_TEST checks=154 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/economy-initial-245799
FARM_STATE_TEST checks=385 failures=0
FARM_STORE_TEST checks=109 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/farm-store-232069
V27_IMPORTER_TEST checks=69 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/v27-import-241793
WORLD_TRANSFER_TEST checks=113 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/world-transfer-267603
```

`WORLD_TRANSFER_TEST` 日志中的 `Could not create directory: .../save-write-failure/...` 是该夹具故意构造的写入失败路径，最终仍为 0 失败。

## 关键实验数据

固定夹具：三名玩家各种 8 篮青菜（真实播种、成熟、收获）并各开户 120 COIN，`issued = total_cash = 360`，初始 24 篮青菜。

| 观测 | 结果 |
|---|---|
| A 发货 8 青菜（farm → harbor） | 口袋 8 → 0，运费 2 销毁，现金 120 → 118，`issued = total_cash = 358`，商品总量仍 24 |
| 在途时卖 1 青菜 | `insufficient_goods`，快照不变 |
| 在途时再次发货 1 青菜 | `insufficient_goods`，快照不变 |
| 同发货 id 同 payload 重放 | `duplicate=true`，返回原 shipment，不二次扣货/扣费 |
| 同发货 id 换数量 | `command_conflict`，快照不变 |
| 清空 64 条命令窗口后重放发货 id | `shipment_exists`，不再次托管 |
| 先卖单托管 2、再发货 4 | 口袋 2、在途 4；到期/撤单退回 2 → 口袋 4、在途 4，总量 8 |
| 到期扫描 | 只释放订单托管；shipment 仍 `in_transit` |
| 到达前 1 秒扫描 | `count=0`，shipment 仍 `in_transit`，口袋 5 |
| 到达当秒扫描 | `count=1`，口袋 8，`delivery_1`，`delivered_utc = depart + 600` |
| 到达后 1 秒重复扫描 | `count=0`，快照不变 |
| 两笔不同时发货在 700 秒扫描 | 一次交付 2 笔，`delivery_1`/`delivery_2` 唯一且按 shipment 序号排序 |
| 同交付命令 id 同 UTC 重试 | `duplicate=true`，交付笔数不变，快照不变 |
| 同交付命令 id 换 UTC | `command_conflict`，无第二次交付 |
| 清空命令窗口后同交付 id | 0 笔新交付，交付记录仍可查 |
| 两笔发货费用 | `issued` 360 → 356，`total_cash = 356`；交付后不变 |
| 交付 + 撮合 + 撤单 + 到期两种顺序 | 两张候选快照完全相等（`trade_1`、一张到期、一张撤单、一次交付） |
| 存盘重开 | 3 笔 shipment（2 已交付 + 1 在途）、2 条 delivery、序号、费用与袋中商品逐项恢复 |
| 非法快照 | 额外键、id/序号不符、商人/`@world` 所有者、目录外商品、零/超限数量、同市场/未知市场、错误运费、错误到达差、未知状态、在途带交付 id、已交付缺交付 id、计数器过低、表类型错误、交付事件与 shipment 不匹配、重复交付、孤立交付、只缺部分物流键均被拒绝；全部缺失按 M7-03 空物流读入 |

验证过程中发现并修复了一个真实问题：JSON 往返后 `sequence` 是浮点数，交付事件 id 若直接 `str(sequence)` 会得到 `"delivery_1.0"`，导致合法快照被拒绝。校验现在先转成 `int` 再拼 id，夹具的 JSON 往返断言覆盖该回归。

## 未覆盖

- **全区域运输网**：只有两处固定市场和一条对称路线；没有距离、路网、据点或按地点分区的库存。订单簿仍是无位置现货市场。
- **承运人与收款方**：运费直接销毁，没有承运人账户、分成、承运人 AI 或运输能力。
- **保险、风险与损失**：没有丢失、损坏、拒收、中途取消、退款或风险路线；shipment 只有 `in_transit`/`delivered`。
- **网络角色权限与调用点**：`market_ship`/`market_deliver` 尚未接入 `FarmCommand`/WorldHost 角色权限表；权威调用交付扫描的确切时机需要网络切片固定。
- **UI/HUD**：没有发货、在途、交付历史或运费界面。
- **订单归档与物流归档**：订单表上限 256、shipments/deliveries 各 256，均无归档；长期世界上限影响留给后续。
- **费用与时长调参**：固定 2 COIN、600 秒和固定市场 id 都是实验值；M7-05 必须用真实供需、集中抛售、囤积和无人交易场景复评。
- **商人/公共库存运输**：`@merchant` 和 `@world` 明确不能发货；商人库存的跨市场流动未实现。
- **Windows 实机与 UI**：规则夹具已在 macOS／Windows 干净检出双平台通过（见下）；Windows 实机运行画面与任何 HUD 未验证。
- **真实玩家数据**：未使用真实存档；全部夹具为隔离目录。

## 主会话登记（已完成）

- `.github/workflows/rule-tests.yml`：`market_logistics_test` 已登记在 `market_matching_test` 之后。
- `rules/project-context.md`：已登记两处固定市场、`economy.market` 的物流子账本、`FarmState` 的物流接口、发货即转入在途、固定运费销毁、600 秒到达、耐久交付事件、守恒口径与农场格式仍为 27。
- 主会话复核：本地复跑上面的物流与回归夹具，全部零失败；M7-03 无物流键的市场恢复为空物流的路径由夹具的“全部缺失按 M7-03 空物流读入”断言覆盖。

## 双平台证据

- 规则工作流 run `43679013546`（提交 `ec88609`）两平台均成功：

```text
macOS   market_logistics_test MARKET_LOGISTICS_TEST checks=174 failures=0
Windows market_logistics_test MARKET_LOGISTICS_TEST checks=174 failures=0
macOS   market_matching_test MARKET_MATCHING_TEST checks=215 failures=0
Windows market_matching_test MARKET_MATCHING_TEST checks=215 failures=0
```

- 干净检出无 LFS 美术，物流与撮合夹具都不依赖场景，因此两平台实际执行而非跳过。
- Windows 实机、UI/HUD 与网络权限不在本切片范围。

