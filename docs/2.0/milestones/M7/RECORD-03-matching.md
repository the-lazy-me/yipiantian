# M7-03 · 撮合与交割

状态：已实现（2026-11-15），未验收。范围：确定性撮合扫描、买卖两侧价格时间优先、部分成交、maker 成交价、固定费用销毁、资金与商品同一候选快照交割、耐久成交记录，以及撤单/到期/重复结算/重开边界。不包含物流、在途库存、网络命令权限、UI/HUD、订单归档或旧档迁移。

权威设计：[ADR-012](../../decisions/ADR-012-matching-settlement.md)；上层规格：[经济与金融](../../systems/economy-finance.md)、[M7 PLAN](PLAN.md)；前置：[ADR-010](../../decisions/ADR-010-economy-initial-conditions.md)、[ADR-011](../../decisions/ADR-011-market-orders.md)、[M7-02 记录](RECORD-02-market-orders.md)。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/farm/market_state.gd` | 新增 `match`、`match_error`、`trades`、`trade`、价格/序号排序、maker 定价、部分成交、费用销毁、托管退回、成交记录与校验；`market` 增加 `trades`/`trade_sequence`。 |
| `Game/farm/farm_state.gd` | 新增 `market_match(now_utc, command_id = "")`、`market_trades()`、`market_trade(id)`；恢复时归一化成交数字；撮合仍走候选快照。 |
| `Game/farm/economy_state.gd` | 收款账户 `granted=false` 仍可在之后开户并领取一次性金额；仍只有一个 `issued` 和一套账户。 |
| `tests/market_matching_test.gd` | 新增 224 项无头检查。 |
| `docs/2.0/decisions/ADR-012-matching-settlement.md` | 本切片的持久裁决。 |
| `docs/2.0/decisions/README.md` | 决策入口增加 ADR-012 一行。 |
| `docs/2.0/decisions/ADR-010-economy-initial-conditions.md` | 注明 `issued` 在 M7-02/M7-03 后是净发行。 |
| `docs/2.0/decisions/ADR-011-market-orders.md` | 状态指向 ADR-012 的 M7-03 实现。 |
| `docs/2.0/milestones/M7/PLAN.md` | M7-03 增加记录与决定链接。 |
| `docs/2.0/milestones/M7/RECORD-03-matching.md` | 本记录。 |

未新增依赖、网络消息、场景节点、HUD、美术资源或旧存档迁移器。农场格式版本保持 27；没有新增农场顶层键，`FarmState._valid_snapshot` 键数、`V27Importer.KNOWN_FARM_KEYS` 与 `valid_cell_snapshot` 均未改。

## 撮合规则

撮合只有一条入口：权威调用 `market_match(now_utc)`。下单、撤单和到期只修改订单簿，不隐式成交。

- **排序**：买单价格从高到低、同价按 `sequence` 从小到大；卖单价格从低到高、同价按 `sequence` 从小到大。`best_bid >= best_ask` 时成交，数量为 `min(remaining)`。
- **可成交**：`open`、`remaining > 0`、`created_utc <= now_utc < expires_utc`。到期当秒的订单归到期规则处理，因此同一 `now_utc` 下撮合与到期顺序无关。
- **成交价**：先到订单（`sequence` 较小者）的限价，双方使用同一单价和 notional。买方限价与成交价的差额立即退回买方；卖方收到 `notional - fee`。
- **部分成交**：`filled += qty`、`remaining -= qty`；买单 `reserved = remaining * price`，卖单 `reserved = remaining`。未成交部分保持 `open`，全成交关闭为 `filled`。
- **费用**：每笔成交固定 1 COIN，由卖方支付并销毁。`total_cash` 与 `issued` 同步减少 1，`total_cash == issued` 仍是唯一守恒等式。
- **原子交割**：买方商品、买方退款、卖方成交款、费用销毁、两张订单行和成交记录都在 `_data.duplicate(true)` 上写入；成功才替换权威状态。
- **耐久记录**：`market.trades` 以 `trade_<sequence>` 保存成交；上限 512，按最小 sequence 淘汰。成交幂等由订单 `filled`/`remaining` 保证，不依赖 64 条命令窗口，也不依赖成交记录本身。
- **可选命令 id**：`market_match(now_utc, command_id)` 的同 id 同 UTC 返回原成交笔数并标记 `duplicate=true`，同 id 不同 UTC 返回 `command_conflict`；id 只用于重试回放，不保存逐笔明细，不构成第二次结算。不传 id 时是纯扫描。

## 命令与接口

```text
market_match(now_utc)                 # 确定性撮合扫描，无命令 id
market_match(now_utc, command_id)     # 可重试扫描：回放成交笔数 / 冲突
market_trades()                       # 按成交序号升序的耐久记录
market_trade(trade_id)                # 单笔成交查询
market_place_order(...)               # 仍只建单/托管，不隐式撮合
market_cancel_order(...)              # 仍只释放未成交托管
market_expire(now_utc)                # 仍只关闭到期订单
```

成交结果字段：`count`、`trades`、`fee`、`notional`。每笔成交记录包含 `id`、`sequence`、`good`、`price`、`quantity`、`notional`、`fee`、`buy_id`、`sell_id`、`buy_owner`、`sell_owner`、`buy_price`、`sell_price`、`buy_refund`、`sell_credit`、`at_utc`。

## 实测输出

匹配夹具使用隔离目录 `.local/verification/matching-<pid>`，不读写玩家存档：

```
MARKET_MATCHING_TEST checks=224 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/matching-22082
```

同引擎（4.7.2-stable）、同工作树的回归：

```
MARKET_ORDERS_TEST checks=188 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/market-orders-22129
ECONOMY_INITIAL_TEST checks=154 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/economy-initial-257799
FARM_STATE_TEST checks=385 failures=0
FARM_STORE_TEST checks=109 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/farm-store-232251
FARM_COMMAND_TEST checks=45 failures=0
V27_IMPORTER_TEST checks=69 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/v27-import-261862
WORLD_PACKAGE_TEST checks=123 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/world-package-286275
HEADLESS_WORLD_RUNTIME_TEST checks=60 failures=0
WORLD_TRANSFER_TEST checks=113 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/world-transfer-274384
PLAYER_BAGS_TEST checks=114 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/player-bags-269000
```

`WORLD_TRANSFER_TEST` 日志中的 `Could not create directory: .../save-write-failure/...` 是该夹具故意构造的写入失败路径，最终仍为 0 失败。

规则工作流双平台证据（run `43678002188`，提交 `dd7ca62`，干净检出）：

```text
macOS   market_matching_test MARKET_MATCHING_TEST checks=215 failures=0
macOS   market_orders_test MARKET_ORDERS_TEST checks=188 failures=0
Windows market_matching_test MARKET_MATCHING_TEST checks=215 failures=0
Windows market_orders_test MARKET_ORDERS_TEST checks=188 failures=0
```

## 关键实验数据

固定夹具：三名玩家 A/B/C 各种 8 篮青菜（真实播种、成熟、收获）并各开户 120 COIN，`issued = total_cash = 360`。初始 24 篮青菜。

| 观测 | 结果 |
|---|---|
| 卖单 9 与卖单 10 同时存在，买单限价 12 | 先成交 9；成交价 9；买方 12 托管退回 3，实付 9；卖方得 8；`issued` 360 → 359 |
| 买单 9（先）与买单 12（后），卖单 10 | 高买价 12 先成交；买方为 maker 时成交价 12；卖方得 11 |
| 同价两张卖单 10 | 接收序号较小者成交，另一张保持 open |
| 卖 5 @10 + 买 2 @10 | 第一笔成交 2；卖单 `remaining=3`、`filled=2`、`reserved=3`；买单关闭 |
| 再买 5 @10 | 用剩余 3 成交；卖单关闭；新买单 `remaining=2`、`reserved=20`；卖方累计 168 COIN |
| 卖 2@9 + 卖 3@10 + 卖 2@11，买 6@11 | 三笔成交 2/3/1；notional 18/30/11；费用合计 3；买方实付 59；`issued` 357 |
| 1 COIN 成交 | notional 1、fee 1、卖方成交款 0；`issued` 359 = `total_cash` |
| 撮合先于撤单（全成交） | 成交一次；随后撤单 `order_closed`，不二次释放 |
| 撤单先于撮合 | 卖单退回 5 篮、买单退回 50 COIN；无成交、无费用 |
| 部分成交后撤单 | 已成交 2 篮保留在买方；撤单只退回剩余 3 篮 |
| 到期前 1 秒撮合 | 成交一次；到期扫描 `expired=0` |
| 到期边界同秒先撮合/先到期 | 两种顺序快照完全相等；卖单到期、买单保留 |
| 清空 64 条命令窗口后重扫 | 0 笔新成交；下单 id 返回 `order_exists`；成交记录仍可查 |
| 同撮合 id 同 UTC 重试 | `duplicate=true`，成交笔数不变，快照不变 |
| 同撮合 id 换 UTC | `command_conflict`，无第二笔结算 |
| 清空命令窗口后同撮合 id | 0 笔新成交；账目与成交记录不变 |
| 存盘重开后再撮合 | 部分成交的 `remaining`/`reserved`/`filled` 与成交记录逐项恢复；后续补完剩余数量 |
| 商人买 5 @4、卖 5 @7 | 商人现金 600 → 580 → 614；货物 0 → 5 → 0；两次费用后 `issued` 958 |
| 未开户卖方成交 | 创建 `granted=false` 收款账户 9 COIN；之后开户再发 120，总计 129，且只能一次 |
| 非法快照 | 成交 id/序号/金额/退款/费用/所有者/重复字段/`trades` 类型错误等均拒绝，权威快照不变；仅 `trades` 与 `trade_sequence` 同时缺失的 M7-02 市场按空成交记录读入 |

## 对抗审查与加固

提交 `dd7ca62` 之后另做了一次只读审查，按真实缺陷修复了以下边界，并各加回归断言（夹具从 215 项增至 224 项）：

| 缺陷 | 修复 |
|---|---|
| `Economy.valid` 的现金上限检查写在账户循环内，账户表为空时整段跳过；且只挡 `total > issued` | 检查移到循环外并改为严格等式 `total_cash == issued`（ADR-012 §5）；空账户与 `issued` 虚增的快照都被拒绝 |
| `trade_sequence`、`economy.sequence`（及物流计数器）接受安全整数上界，下一次写入产生读不回的存档 | `valid` 要求计数器严格小于 `MAX_SAFE_INTEGER`，与 `market.sequence` 的既有保护一致 |
| 成交校验不检查固定费用，也不检查 `buy_id`/`sell_id` 是否存在 | 要求 `fee == min(1, notional)`，且两个订单行仍存在、owner/商品/方向/限价一致 |
| 命令账本重放找不到耐久订单时回退原账本，伪造账本可假装下单/撤单成功；商人开户重放缺 `budget` | 下单重放缺订单返回 `unknown_order`，撤单缺 `closed_by` 返回 `order_closed`，发货缺行返回 `unknown_shipment`；商人重放补齐 `budget` |
| 亚微秒到期时间在 JSON 往返后与 `created_utc` 相等，存档写出后无法读回 | 下单要求至少 1 秒存活期，返回 `invalid_expiry` |

审查确认无问题的部分：随机 700 步与 500 步序列中每步 `total_cash == issued`、账户非负；商品守恒与部分成交只释放剩余；撮合失败候选整体丢弃；同 id 同 UTC 重放不重复结算；价格时间优先与撤单/到期顺序无关；JSON 往返后金额与序号全部为整数。

仍无法在不改代码的情况下黑盒确认：`_credit_cash` 中“买方商品已入袋后现金入账失败”的半写路径（`valid` 通过的状态下不可达）；`_maker_price` 的 id 兜底分支（重复 `sequence` 被快照校验拒绝）。撮合笔数在命令窗口淘汰后无法重算，仍只是缓存值。

## 未覆盖

- **网络角色权限与调用点**：`market_match` 尚未接入 `FarmCommand`/WorldHost 角色权限表；权威在应用命令后调用扫描的确切时机需要网络切片固定。
- **UI/HUD**：没有订单簿、成交历史、钱包或费用展示。
- **物流与在途库存**：同市场现货即时交割，跨区域运输、仓储位置和在途不可售未实现。
- **订单归档**：订单表上限 256（含已关闭订单）仍无归档；成交表上限 512，当前每笔成交至少关闭一个订单，因此合法世界理论上最多 256 笔成交，淘汰路径未在真实数据中触发。
- **费用调参**：固定 1 COIN/笔是实验值，未验证比例费用、集中抛售、囤积、无人交易或跨商品套利；M7-05 必须复评。
- **自成交策略**：当前允许同一所有者自成交（商品回到原所有者、净减少一笔费用），未评估是否需要禁止或单独计费。
- **价格历史与市场统计**：成交记录是可查询的原始记录，但没有成交量/均价/库存紧张的聚合视图。
- **商人策略**：仍按参考价与预算/库存报价，未读取近期成交或库存压力。
- **Windows 实机画面与 UI**：规则夹具已在 macOS／Windows 干净检出双平台通过；Windows 实机运行画面与任何 HUD 未验证。
- **真实玩家数据**：未使用真实存档；全部夹具为隔离目录。
- **世界包 `money`**：仍是 v27 导入信封字段，不随实时余额变化。

## 主会话登记（已完成）

- `.github/workflows/rule-tests.yml`：`market_matching_test` 已登记在 `market_orders_test` 之后，注释说明价格时间优先、maker 定价、部分成交、固定费用销毁、原子交割与耐久成交 id。
- `rules/project-context.md`：已登记 `economy.market` 的 `trades`/`trade_sequence`、`FarmState` 的三个撮合接口、价格与序号规则、maker 限价、部分成交托管、每笔 1 COIN 费用销毁、`issued` 净发行与 `total_cash == issued`、成交记录上限 512，以及市场命令仍未接入网络角色权限。
- 主会话复核时补了 M7-02 旧市场读入路径：`trades` 与 `trade_sequence` 同时缺失时按空成交记录恢复（与 M7-01 无 `market` 的既有先例一致），只缺其一或类型/金额不符仍拒绝。新增 2 项检查；用只读探针加载当前开发存档确认 `kind=loaded`、`restore=true`、`trade_sequence=0`、存档字节不变。

## 双平台证据

- 规则工作流 run `43678002188`（提交 `dd7ca62`）两平台均成功，执行行见「实测输出」中的 215 项版本。
- 加固后 run `43679606897`（提交 `b2d4400`）两平台均成功：

```text
macOS   market_matching_test MARKET_MATCHING_TEST checks=224 failures=0
Windows market_matching_test MARKET_MATCHING_TEST checks=224 failures=0
macOS   market_logistics_test MARKET_LOGISTICS_TEST checks=174 failures=0
Windows market_logistics_test MARKET_LOGISTICS_TEST checks=174 failures=0
```

- 干净检出无 LFS 美术，`market_matching_test`、`market_logistics_test` 与 `market_orders_test` 都不依赖场景，因此两平台实际执行而非跳过。

