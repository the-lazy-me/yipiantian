# M7-02 · 报价与订单

状态：已实现（2026-11-15），未验收。范围：规则商人有限预算与报价、玩家限价买卖单、商品/现金托管预留、撤单、确定性 UTC 到期，以及订单的农场快照持久化。不包含撮合、部分成交、费用、交割、物流、UI/HUD 或网络命令权限。

权威设计：[ADR-011](../../decisions/ADR-011-market-orders.md)；上层规格：[经济与金融](../../systems/economy-finance.md)、[M7 PLAN](PLAN.md)；前置：[ADR-010](../../decisions/ADR-010-economy-initial-conditions.md)、[M7-01 记录](RECORD-01-economy-initial.md)。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/farm/market_state.gd` | 新增。订单规则、托管预留、撤单、到期、规则商人报价与预算、市场快照校验、重放结果重建。 |
| `Game/farm/economy_state.gd` | `economy` 增加 `market` 子文档；允许 M7-01 无 `market` 的经济读入；`total_cash`/`valid` 计入商人现金与未成交买单托管；公开有界命令账本的 `replay`/`record` 桥接。 |
| `Game/farm/farm_state.gd` | 接入市场候选提交、重放、初始化默认值和 JSON 整数/浮点归一化；新增 `market_*` 接口。 |
| `tests/market_orders_test.gd` | 新增 188 项无头检查。 |
| `docs/2.0/decisions/ADR-011-market-orders.md` | 本切片的持久裁决。 |
| `docs/2.0/decisions/README.md` | 决策入口增加 ADR-011 一行。 |
| `docs/2.0/milestones/M7/PLAN.md` | M7-02 增加记录与决定链接。 |
| `docs/2.0/milestones/M7/RECORD-02-market-orders.md` | 本记录。 |

未新增依赖、网络消息、场景节点、HUD、美术资源或旧存档迁移器。农场格式版本保持 27；没有新增农场顶层键，`FarmState._valid_snapshot` 键数、`V27Importer.KNOWN_FARM_KEYS` 与 `valid_cell_snapshot` 均未改。

## 订单与预留

订单放在 `economy.market.orders`，形状见 ADR-011。关键字段：`side`、`good`、`price`、`quantity`、`remaining`、`filled`、`reserved`、`sequence`、`created_utc`、`expires_utc`、`status`、`released`、`closed_by`、`closed_utc`。数量与价格为安全整数；负数、零、小数、非数字、超上限与目录外商品在下单边界拒绝。

预留是托管而不是第二套余额：

- 卖单立即从 `bags[owner][good]` 扣除数量，订单 `reserved` 记录该数量；
- 买单立即从 `economy.accounts[owner].cash` 扣除 `price * quantity`，订单 `reserved` 记录现金；
- 撤单或到期把 `reserved` 原路退回；`close` 后 `reserved` 为 0，`remaining` 保留未成交数量用于审计；
- 每一次接受都是“候选快照内的订单 + 余额变化 + 命令结果”，成功后才替换权威快照。

## 命令与接口

市场命令由权威在农场快照上调用，尚未接入网络角色权限：

```text
market_open_merchant(id, now)                                  # 一次性发行商人预算
market_quote(good) / market_quotes()                           # 确定性 bid/ask 与容量
market_place_order(id, owner, side, good, price, qty, expires, now)
market_cancel_order(id, owner, order_id, now)
market_expire(now)                                             # 到期扫描，无命令 id
market_orders() / market_order(id) / market_merchant() / market_snapshot()
```

- 下单 id 就是订单 id；同 id 同 payload 回放原结果，同 id 不同 payload 返回 `command_conflict`。
- 所有命令复用 `economy.command_results` 的 64 条有界窗口，没有市场专用命令账本；农场通用交易窗口 `transaction.command_results` 另有一份 64 条回放记录，两者独立淘汰。
- 订单是耐久记录：账本淘汰后，重放下单 id 返回 `order_exists`，重放撤单 id 返回 `order_closed`，都不会二次托管或二次释放。
- 撤单要求 `now < expires_utc`；到期条件固定为 `expires_utc <= now_utc`，`market_expire` 重复调用不再释放。
- 商人使用保留 id `@merchant`，不是玩家账户；玩家下单拒绝 `@world` 与非法 id。

## 商人报价

`market_open_merchant` 一次性发行 `MERCHANT_BUDGET = 600 COIN`，`issued` 与商人现金同时增加；商人现金、玩家账户现金与未成交买单托管一起计入 `economy_total_cash()`。

报价由商品参考价确定性派生：

```text
bid = max(1, floor(base_price * 4 / 5))
ask = base_price + max(1, floor(base_price / 4))
buy_capacity  = min(9999, floor(merchant.cash / bid))
sell_capacity = min(9999, merchant.goods[good])
```

| 商品 | 参考价 | bid | ask |
|---|---:|---:|---:|
| `greens` 青菜 | 6 | 4 | 7 |
| `spinach` 菠菜 | 9 | 7 | 11 |
| `radish` 白萝卜 | 18 | 14 | 22 |
| `carrot` 胡萝卜 | 24 | 19 | 30 |
| `celery` 芹菜 | 20 | 16 | 25 |
| `garlic` 青蒜 | 14 | 11 | 17 |

商人买单只能按 `bid`、卖单只能按 `ask` 下单，数量不得超过容量；现金不足不能买，库存为零不能卖。M7-02 不撮合，因此商人库存没有增长路径，卖出成功路径不在本切片验证。

## 实测输出

市场夹具使用隔离目录 `.local/verification/market-orders-<pid>`，不读写玩家存档：

```
MARKET_ORDERS_TEST checks=188 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/market-orders-87951
```

同引擎（4.7.2-stable）、同工作树的回归：

```
ECONOMY_INITIAL_TEST checks=154 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/economy-initial-258637
FARM_STATE_TEST checks=385 failures=0
FARM_STORE_TEST checks=109 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/farm-store-214217
FARM_COMMAND_TEST checks=45 failures=0
V27_IMPORTER_TEST checks=69 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/v27-import-235559
WORLD_PACKAGE_TEST checks=123 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/world-package-243563
WORLD_TRANSFER_TEST checks=113 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/world-transfer-285048
HEADLESS_WORLD_RUNTIME_TEST checks=60 failures=0
PLAYER_BAGS_TEST checks=114 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/player-bags-255158
```

规则工作流双平台证据（run `43676589169`，提交 `056bf19`，干净检出）：两平台都实际执行并输出

```text
macOS   market_orders_test MARKET_ORDERS_TEST checks=188 failures=0
Windows market_orders_test MARKET_ORDERS_TEST checks=188 failures=0
```

## 关键实验数据

| 观测 | 结果 |
|---|---|
| 新农场 | 无订单、`sequence = 0`、商人未开户且现金 0 |
| 玩家 A 初始 | 2 青菜（fixture 收获），现金 120 |
| A 卖 2 青菜 @10 | 口袋青菜 2 → 0，订单 `reserved = 2`，`sequence = 1` |
| 卖单再要 1 青菜 | `insufficient_goods`，快照不变 |
| 卖单预留后赠礼 1 青菜 | `insufficient`，托管商品不能被赠礼花掉 |
| A 买 3 胡萝卜 @30 | 现金 120 → 30，订单 `reserved = 90` |
| 再买 2 胡萝卜 @30 | `insufficient_cash`，快照不变 |
| A 买 1 胡萝卜 @30 | 现金 30 → 0，第二个订单 `reserved = 30` |
| 可用现金 + 买单托管 | `0 + 120 = 120`，等于原始余额 |
| 撤卖单 2 青菜 | 口袋 0 → 2，`released = 2`，`reserved = 0`，`remaining = 2` |
| 同撤单 id 重放 | `duplicate = true`，快照不变 |
| 同撤单 id 换时间 | `command_conflict`，快照不变 |
| 新 id 再撤同一订单 | `order_closed`，不二次释放 |
| 到期前 1 秒扫描 | `expired = 0`，订单仍 open |
| 到期当秒扫描 | `expired = 1`，卖单退回 1 青菜，买单退回 30 现金 |
| 到期重复扫描 | `expired = 0`，快照不变 |
| 到期边界后撤单 | `order_expired`，不释放；随后扫描释放一次 |
| 撤单先于到期 | 撤单释放一次，之后扫描 `expired = 0` |
| 到期先于撤单 | 扫描释放一次，之后撤单 `order_closed` |
| 商人开户 | `issued` 240 → 840，商人现金 600，`total_cash = 840` |
| 商人报价（greens） | bid 4 / ask 7，初始买容量 150、卖容量 0 |
| 商人买 100 greens @4 | 商人现金 600 → 200，订单 `reserved = 400` |
| 商人再买 51 greens @4 | 需 204 > 200，`insufficient_cash` |
| 商人卖 1 greens | `insufficient_goods`，没有库存不能卖 |
| 商人撤单 100 greens | 商人现金 200 → 600，买容量恢复 150 |
| 存盘重开 | 订单、托管现金/商品、商人预算与账本逐字节恢复 |
| 清空命令窗口后重放下单 id | `order_exists`，不再托管 |
| 清空命令窗口后重放撤单 id | `order_closed`，不再释放 |

## 未覆盖

- **M7-03 撮合与交割**：价格/接收序号排序、部分成交、`filled` 变更、费用、资金商品同时交割、成交幂等耐久记录均未实现；`filled` 只是为后续保留并校验的字段。没有成交价，因此“挂牌与成交价格区分”只验证了订单限价与商人 bid/ask 是不同字段，成交价由 M7-03 产生。
- **商人策略**：报价只按参考价与当前预算/库存派生，未读取近期消耗、目标库存或需求；M7-05 才能评估是否需要调价步幅。
- **商人库存来源**：M7-02 没有让商人获得商品的路径，因此商人卖出成功路径未执行；只验证了没有库存时拒绝。
- **网络与权限**：市场命令尚未进入 `FarmCommand`/WorldHost 角色权限表；哪些角色可开商人预算、下单和撤单尚未决定。
- **UI/HUD**：没有订单簿、钱包、报价或撤单界面。
- **费用、税与回收**：没有减少 `issued` 的市场费用。
- **物流与在途库存**：未实现跨区域运输，订单没有仓储位置字段。
- **订单归档**：订单表上限 256（含已关闭订单），没有归档或压缩策略；长期世界的上限影响留给 M7-03/M7-04。
- **深窗口重放**：订单行被 256 条上限归档、经济账本分录又被 512 条环形窗口淘汰之后，同一 `market_place` / `market_ship` 命令 id 会按新命令重新托管或重新发货；这只重复玩家自己的成本，不会增发货币或转移他人资产。当前不新增更大的已用 id 集，礼物命令的 `gift_ids` 是先例，若后续需要再按同一形状扩展。
- **旧存档迁移**：按早期开发约定不写迁移器；M7-01 的经济文档可读并补空市场，更早的 v27 文档由既有可选 `economy` 路径处理。
- **世界包 `money`**：仍是 v27 导入信封字段，不随实时钱包变化；导出余额定义仍未裁决。
- **跨平台 CI**：只在本机 macOS 4.7.2 无头运行；Windows 与干净检出 CI 未执行，夹具尚未登记到 `.github/workflows/rule-tests.yml`。
- **真实玩家数据**：未使用真实存档；全部夹具为隔离目录。

## 增补：两个命令窗口与旧时间重试（2026-11-16）

- 市场命令同时进入两个独立的 64 条 FIFO：农场通用交易窗口
  `transaction.command_results`（`FarmState.commit_command`）与经济窗口
  `economy.command_results`（`Economy._record`）。两者各自淘汰，顺序不保证。
- 之前外层时钟闸门只检查交易窗口（`FarmCommand.has_committed`）。交易窗口先
  淘汰、经济窗口仍保留时，同一 id、同一 payload、原时间的精确重试会被误判为
  `time_backwards`，而不是回放。现在 `HeadlessWorld.execute` 对
  `FarmCommand.ECONOMY_KINDS` 额外检查 `FarmState.economy_command_known`；
  命中则跳过时间闸门，交给规则层 `Economy.replay` 判定 duplicate 或
  `command_conflict`。两个窗口都不认识的旧时间命令仍返回 `time_backwards`。
- 上述“深窗口重放”指两个窗口都已淘汰后的 id 复用。那不是重放：命令会被当作
  新命令执行，是否重新托管/发货由订单行（耐久记录）决定；订单行也归档后才会
  重复成本。

测试 `HEADLESS_WORLD_RUNTIME_TEST` 83→91：开账户后提交 64 条填充命令淘汰交易
窗口、经济窗口仍保留该 id，时钟前移 120 秒后同 id 原时间重试返回
`duplicate`；两个窗口都不认识的旧时间命令仍 `time_backwards`。
回归 `MARKET_ORDERS_TEST 191/0`、`CHAIN_INTEGRATION_TEST 509/0`。

## 待主会话登记

`.github/workflows/rule-tests.yml` 的 `tests` 数组需要新增一行（建议放在 `economy_initial_test` 之后）：

```bash
# Market orders: limit buys and sells escrow cash or goods in the same farm
# snapshot, cancellation and deterministic UTC expiry release exactly once,
# and the rule merchant can neither overspend its budget nor sell absent stock.
market_orders_test
```

`rules/project-context.md` 需要登记的项目事实：`economy` 子文档新增 `market`（商人预算/现金/库存、订单、接收序号）；`FarmState` 新增 `market_*` 接口；市场命令尚未接入网络角色权限；订单表上限 256，撮合与成交耐久记录留给 M7-03；农场格式仍为 27，无新增顶层键。
