# M7-05 · 运行供需实验

状态：实验完成（2026-11-15），未验收。范围：用现有 `FarmState` / `Market` / `Economy` 规则在无头环境驱动普通生产与交易、歉收、囤积、无人交易、循环套利、关闭市场与自给、订单容量和重复周期场景；固化货币守恒、商品口径、费用销毁、无零成本循环和可自给的关键断言。不包含规则改动、产品功能、网络、UI、存档迁移或 Windows 实机验证。

权威设计：[经济与金融](../../systems/economy-finance.md)、[M7 PLAN](PLAN.md)；前置：[ADR-010](../../decisions/ADR-010-economy-initial-conditions.md)、[ADR-011](../../decisions/ADR-011-market-orders.md)、[ADR-012](../../decisions/ADR-012-matching-settlement.md)、[ADR-013](../../decisions/ADR-013-limited-logistics.md)、[M7-01](RECORD-01-economy-initial.md)～[M7-04](RECORD-04-logistics.md) 记录。

## 方法与边界

- 夹具：`tests/market_supply_demand_test.gd`，`extends SceneTree`，固定 UTC 起点 `1800000000`，只调用 `FarmState.sow` / `mature_all_crops` / `harvest`、`economy_open_account`、`market_open_merchant`、`market_place_order`、`market_cancel_order`、`market_match`、`market_expire`、`market_ship`、`market_deliver` 等现有入口。
- 隔离：运行目录 `.local/verification/supply-demand-<pid>`；夹具只在该目录写 `rows.txt`，不读写玩家存档、不启场景、不读系统时钟、不修改 `Game/` 规则代码。实验脚本与临时探针只放在 Git 忽略的 `.local/experiments/`（本次探针已删除，最终证据由夹具重现）。
- 需求是**合成**的：生产者在真实地块上播种、成熟、收获；居民需求由限价买单加一个实验步骤表示——成交后从消费者口袋扣除已购数量并计入“已消耗”。当前规则没有“具名玩家口袋进食”路径（厨房只读共享 `inventory`，见下），所以这是实验假设，不是游戏行为。
- 限价、买卖数量和节奏都是场景输入。规则只执行订单，不做价格发现；下表的价格是成交价（maker 限价），不能当作“市场出清价”或“真实供需结论”。

## 参数

| 参数 | 当前值 | 来源 |
|---|---|---|
| 成交费 | 每笔成交固定 1 COIN，由卖方成交款扣除并销毁 | `Market.TRADE_FEE` |
| 运费 | 每笔发货固定 2 COIN，由发货方支付并销毁，双向相同 | `Market.SHIPMENT_FEE` |
| 到货时间 | 600 秒，`arrive_utc = depart_utc + 600` | `Market.DELIVERY_SECONDS` |
| 商人预算 | 开户时一次性 600 COIN，不再补发 | `Market.MERCHANT_BUDGET` |
| 商人报价 | `bid = max(1, floor(base * 4/5))`；`ask = base + max(1, floor(base/4))` | `Market.quote` |
| 订单表上限 | 256 条，含已关闭订单；无归档 | `Market.MAX_ORDERS` |
| 成交记录上限 | 512 条；每笔成交至少关闭一张订单 | `Market.MAX_TRADES` |
| 物流表上限 | shipments 256、deliveries 256；无归档 | `Market.MAX_SHIPMENTS` / `MAX_DELIVERIES` |
| 开户发行 | 每位具名玩家一次性 120 COIN | `Economy.OPENING_GRANT` |

青菜参考价 6，因此商人报价为 bid 4 / ask 7，价差 3。

## 场景与结果

“产出/消费”只统计青菜；“成交量”是成交篮数；“费用”只含成交费；“运费”只含发货费。`BALANCE` 行的 `end` 是**可用余额**，买单纯托管另计；`total_cash` 包含托管现金与商人现金。

| 场景 | 产出 / 消费 | 成交量 | 成交价 | 费用销毁 | 运费销毁 | 发行 → 总现金 | 余额特征 |
|---|---|---:|---|---:|---:|---|---|
| normal 普通生产交易 | 24 / 24 | 24 | 6 | 4 | 0 | 600 → 596 | 生产者 167/166/167，居民各 48 |
| poor_harvest 歉收 | 6 / 6 | 6 | 6 | 3 | 0 | 480 → 477 | 需求剩余 4 篮、24 COIN 托管，到期退回 |
| scarcity_no_fill 歉收且价格不成交 | 6 / 0 | 0 | ask 8 / bid 6 | 0 | 0 | 480 → 480 | 需求剩余 6 篮，无费用 |
| hoarding 囤积 | 24 / 0 | 15 | 8 | 2 | 0 | 480 → 478 | 囤积者现金 0、持货 23；再售 0 篮；消费者 20 + 100 托管 |
| buy_only 只有买单 | 0 / 0 | 0 | — | 0 | 0 | 120 → 120 | 60 COIN 托管，到期全退 |
| sell_only 只有卖单 | 16 / 0 | 0 | — | 0 | 0 | 240 → 240 | 16 篮托管，到期全退 |
| no_orders 无订单 | 4 / 0 | 0 | — | 0 | 0 | 0 → 0 | 收获留在口袋，空扫描不改状态 |
| merchant_spread 商人买卖 | 8 / 5 | 28 | bid 4 / ask 7 | 8 | 0 | 840 → 832 | 商人 600 → 638，玩家 120 → 109，消费者 85 |
| freight 两市场运费 | 8 / 8 | 8 | 6 | 1 | 2 | 240 → 237 | 发货者 120 → 165，消费者 72 |
| freight_loop 往返运输 | 0 成交 | 0 | — | 0 | 4 | −4 | 货物还原，利润 −4 |
| player_round_trip 玩家来回 | 16 / 0 | 6 | 6 | 6 | 0 | 240 → 234 | 双方各 120 → 117 |
| self_trade 自成交 | 1 / 0 | 1 | 6 | 1 | 0 | 120 → 119 | 现金 −1，货物不变 |
| market_off 关闭市场 | 8 / 0 | 0 | — | 0 | 0 | 0 → 0 | 无商人、无订单、无现金，收获 8 |
| self_sufficient_meal 自给一餐 | 1 / 1 | 0 | — | 0 | 0 | 0 → 0 | 共享厨房消耗 1 青菜，产出 1 份菜 |
| order_cap 订单上限 | 0 | 0 | — | 0 | 0 | 120 → 120 | 256 条关闭订单占满，第 257 条 `order_limit` |
| repeated_cycles 重复周期 | 72 / 20 | 20 | 6 | 3 | 0 | 480 → 477 | 居民 120 → 0；未售 52 篮；需求停止 |

所有场景均满足：

- `total_cash == issued`，且 `issued >= 0`、所有账户与商人现金 `>= 0`。
- 商品口径 `口袋（含商人库存）+ 卖单托管 + 在途 + 已消耗 == 产出`；无负数量。
- 无成交、撤单、到期和空扫描不销毁费用；成交与发货的费用按规定销毁。
- 任何被执行成交都满足 `notional = price × quantity`、`fee = min(1, notional)`、`sell_credit + fee = notional`、`buy_refund = (buy_price − price) × quantity`、成交价位于双方限价之间。

## 原始输出行

夹具 `MARKET_SUPPLY_DEMAND_TEST checks=1205 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/supply-demand-40067`；第二次运行（PID 71139）同为 `checks=1205 failures=0`，且 `SCENARIO` / `BALANCE` / `CYCLE` 行逐字相同：

```text
BALANCE normal owner=player_supply_demand_0001 start=120 end=167 delta=47
BALANCE normal owner=player_supply_demand_0002 start=120 end=166 delta=46
BALANCE normal owner=player_supply_demand_0003 start=120 end=167 delta=47
BALANCE normal owner=player_supply_demand_0004 start=120 end=48 delta=-72
BALANCE normal owner=player_supply_demand_0005 start=120 end=48 delta=-72
SCENARIO normal good=greens rounds=1 produced=24 consumed=24 volume=24 trades=4 price=6 fees=4 shipping=0 issued=596 total_cash=596 pockets_end=0 escrow_end=0 transit_end=0 zero_cost_loop=no negative_balance=no
BALANCE poor_harvest owner=player_supply_demand_0001 start=120 end=137 delta=17
BALANCE poor_harvest owner=player_supply_demand_0002 start=120 end=131 delta=11
BALANCE poor_harvest owner=player_supply_demand_0003 start=120 end=125 delta=5
BALANCE poor_harvest owner=player_supply_demand_0004 start=120 end=84 delta=-36
SCENARIO poor_harvest good=greens rounds=1 produced=6 consumed=6 volume=6 trades=3 price=6 fees=3 shipping=0 issued=477 total_cash=477 unmet=4 escrow_cash_end=0 pockets_end=0 zero_cost_loop=no negative_balance=no
SCENARIO scarcity_no_fill good=greens rounds=1 produced=6 consumed=0 volume=0 trades=0 ask=8 bid=6 price_gap=2 fees=0 shipping=0 issued=480 total_cash=480 unmet=6 zero_cost_loop=no negative_balance=no
BALANCE hoarding owner=player_supply_demand_0001 start=120 end=0 delta=-120
BALANCE hoarding owner=player_supply_demand_0002 start=120 end=175 delta=55
BALANCE hoarding owner=player_supply_demand_0003 start=120 end=183 delta=63
BALANCE hoarding owner=player_supply_demand_0004 start=120 end=20 delta=-100
SCENARIO hoarding good=greens rounds=1 produced=24 consumed=0 volume=15 trades=2 price=8 fees=2 shipping=0 issued=478 total_cash=478 hoarder_cash=0 hoarder_goods=23 locked_supply=23 resale_volume=0 zero_cost_loop=no negative_balance=no
SCENARIO buy_only good=greens produced=0 consumed=0 volume=0 trades=0 fees=0 issued=120 total_cash=120 escrow_cash_start=60 escrow_cash_end=0 negative_balance=no
SCENARIO sell_only good=greens produced=16 consumed=0 volume=0 trades=0 fees=0 issued=240 total_cash=240 escrow_goods_start=16 escrow_goods_end=0 negative_balance=no
SCENARIO no_orders good=greens produced=4 consumed=0 volume=0 trades=0 fees=0 issued=0 total_cash=0 pockets_end=4 negative_balance=no
BALANCE merchant_spread owner=player_supply_demand_0001 start=120 end=109 delta=-11
BALANCE merchant_spread owner=player_supply_demand_0004 start=120 end=85 delta=-35
SCENARIO merchant_spread good=greens produced=8 consumed=5 volume=28 trades=8 clearing_bid=4 clearing_ask=7 fees=8 shipping=0 merchant_start=600 merchant_end=638 player_start=120 player_end=109 issued=832 total_cash=832 zero_cost_loop=no negative_balance=no
BALANCE freight owner=player_supply_demand_0001 start=120 end=165 delta=45
BALANCE freight owner=player_supply_demand_0004 start=120 end=72 delta=-48
SCENARIO freight good=greens produced=8 consumed=8 volume=8 trades=1 price=6 fees=1 shipping=2 issued=237 total_cash=237 transit_end=0 zero_cost_loop=no negative_balance=no
SCENARIO freight_loop good=greens quantity=1 out_fee=2 back_fee=2 profit=-4 goods_delta=0 issued_delta=-4 zero_cost_loop=no negative_balance=no
BALANCE player_round_trip owner=player_supply_demand_0001 start=120 end=117 delta=-3
BALANCE player_round_trip owner=player_supply_demand_0002 start=120 end=117 delta=-3
SCENARIO player_round_trip good=greens produced=16 consumed=0 volume=6 trades=6 price=6 fees=6 shipping=0 player_a_start=120 player_a_end=117 player_b_start=120 player_b_end=117 issued=234 total_cash=234 zero_cost_loop=no negative_balance=no
SCENARIO self_trade good=greens produced=1 consumed=0 volume=1 trades=1 price=6 fees=1 shipping=0 cash_delta=-1 goods_delta=0 issued=119 total_cash=119 zero_cost_loop=no negative_balance=no
SCENARIO market_off good=greens produced=8 consumed=0 volume=0 trades=0 fees=0 issued=0 total_cash=0 pockets_end=8 merchant=closed orders=0 zero_cost_loop=no negative_balance=no
SCENARIO self_sufficient_meal good=greens produced=1 consumed=1 meals=1 issued=0 total_cash=0 market_commands=0 zero_cost_loop=no negative_balance=no
SCENARIO order_cap good=greens lifetime_orders=256 closed_orders=256 next_order=order_limit cash=120 issued=120 total_cash=120 fees=0 zero_cost_loop=no negative_balance=no
CYCLE round=0 produced_total=24 consumed_total=12 volume_total=12 fees_total=2 demand=12 buyer_cash=48 expired=2
CYCLE round=1 produced_total=48 consumed_total=20 volume_total=20 fees_total=3 demand=8 buyer_cash=0 expired=2
CYCLE round=2 produced_total=72 consumed_total=20 volume_total=20 fees_total=3 demand=0 buyer_cash=0 expired=3
SCENARIO repeated_cycles good=greens rounds=3 produced=72 consumed=20 volume=20 trades=3 fees=3 shipping=0 issued=477 total_cash=477 buyer_cash_end=0 unsold=52 demand_stopped=opening_grant_spent zero_cost_loop=no negative_balance=no
```

同引擎（4.7.2-stable）、同工作树的相关回归：

```text
MARKET_LOGISTICS_TEST checks=174 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/logistics-41790
MARKET_MATCHING_TEST checks=224 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/matching-41884
MARKET_ORDERS_TEST checks=188 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/market-orders-41896
ECONOMY_INITIAL_TEST checks=154 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/economy-initial-265086
FARM_STATE_TEST checks=385 failures=0
FARM_COMMAND_TEST checks=45 failures=0
```

`MARKET_MATCHING_TEST` 本次为 224 项；M7-03 记录写的是 215 项，差异来自本轮开始前仓库已有的 M7-03 校验边界提交（`b2d4400`），本次未修改该夹具，以本行为准。

## 零成本循环

实验没有发现能让玩家现金或货物净值增加的循环。已验证的四类：

- **商人 bid/ask**：玩家从商人买入 ask 7、再卖回 bid 4，单位毛损 3，另付两侧各 1 COIN 费用；三轮 3 篮往返后玩家 139 → 109，商人 614 → 638，系统发行净减 6。商人赚取的 24 少于玩家损失的 30，差额 6 正是销毁的费用。商人现金是有界初始资本的再分配，不是新发行。
- **两市场运费**：`farm_market` 与 `harbor_market` 共用同一张订单簿，报价接口没有地点参数。发货只把货物移入在途并销毁 2 COIN；往返一篮货物还原、现金 −4，不存在“低买高卖”的价格差。两市场运费是纯成本，不是套利空间。
- **玩家来回买卖**：同一价格 6 来回三轮，双方各 120 → 117，发行 240 → 234；每轮两笔成交销毁 2 COIN，商品总量回到 16。自成交更差：货物回到原主，现金 −1。
- **无成交不收费**：只有买单、只有卖单、价格不交叉和空市场均不产生费用，也不改变权威状态；到期只退回托管。

囤积本身也不是无成本套利：囤积者以 8 COIN 买入 15 篮青菜花掉 120 COIN，随后 12 COIN 的卖单无人接；若按商人 bid 4 变现只能回收 60 COIN（未计费用），规则内没有正收益循环。

一般条件：当前规则中每笔成交 `fee = min(1, notional) >= 1`，且所有成交满足 `sell_credit + fee = notional`；每笔运费 2。任何需要买入再卖出的循环至少付出一次买卖价差和费用，无法靠规则增发或复制货币。商品侧所有转移（托管、成交、发货、交付、撤单、到期）都只搬移既有数量，没有复制路径。

## 参数判断

| 参数 | 判断 | 证据与建议 |
|---|---|---|
| 1 COIN 成交费 | 短中期可持续，但惩罚小额交易 | 成交 4～8 篮时费用约占 notional 2%～4%；1 篮、价格 6 时约占 17%，1 COIN 价格时卖方实收 0。它有效阻断微交易循环，但会让小额正当交易不经济。M7-05 不需要改；后续应决定最低交易批量、按订单收费或比例费用。 |
| 2 COIN 运费 | 批量可持续，单篮不值 | 8 篮摊 0.25/篮；1 篮等于青菜价的 33%。由于没有地点价差，运费无法被套利。建议在 UI/规则中明确最低批量或按数量计费；当前固定费可保留。 |
| 600 秒到货 | 不造成不可维持 | 当前没有腐坏、仓储成本或按时间变价，600 秒只是延迟，不能产生套利，也不会阻止交易。若未来做地点价差或时间风险，需要重新评估。 |
| 商人 600 预算 | 有界但并非硬上限 | 600 只能买 150 篮青菜（bid 4）；买完后仍可靠卖出回款。商人现金可因价差增长到 638，规则没有补发，也没有无限需求。若设计要求“最多 600”，需要另加规则；当前不是漏洞。 |
| bid/ask 公式 | 不产生循环 | 任何商品都满足 ask > bid（青菜 4/7），买卖回转必亏；价差 3 也让 1 COIN 费用之外的循环更差。代价是商人报价偏宽、作为对手方的吸引力有限。建议保持，后续再评估按库存/消耗调价。 |
| 订单上限 256 | **长期不可维持** | 关闭订单不归档；256 次下单/撤单后第 257 条被 `order_limit` 永久拒绝，而现金和商品仍正常。这是长期世界的操作上限，不是货币或商品漏洞。需在长寿命世界前增加归档/压缩；本条不阻塞 M7-05，但必须登记。 |
| 120 开户发行 | 一次性需求，不能维持周期消费 | 一名居民在价格 6 下最多买 20 篮（120/6）；重复周期夹具中第 1 轮买 12、第 2 轮买 8、第 3 轮无钱可买，需求停止，生产者留下 52 篮未售。当前规则没有工资、分红或周期性发行，因此“居民周期性消费”只能是实验假设，不能宣称可持续需求。 |

结论：**短周期内没有不可维持交易**——每个场景货币守恒、无负余额、无零成本循环；**长期的两个具体风险**是订单/物流表无归档（256 条后停止）和一次性发行导致的需求枯竭。两者都不要求为 M7-05 改规则，但需要主会话决定后续切片。

## 自给与关闭市场

- `market_off`：无账户、无商人、无订单时，玩家仍可完整播种、成熟、收获 8 篮；`market_match` / `market_expire` / `market_deliver` 都是 no-op，快照不变，发行与现金均为 0。
- `self_sufficient_meal`：匿名播种收获进入共享 `inventory`，厨房 `leaf_stir` 消耗 1 青菜、按 20 秒完成并产出 1 份菜；全程没有市场命令、现金或商人。
- **边界**：厨房读取 `FarmState._data.inventory`（`Game/farm/farm_state.gd:765`），从不读具名玩家的 `bags`；具名收获的货物目前只能出售、赠送或继续持有，没有“从自己口袋吃”的规则路径。因此本实验证明的是“生产与共享厨房不依赖市场”，不能宣称“具名多人玩家可完全自给”。如果验收要求后者，这是需要另行裁决的规则缺口；本次未改规则。

## 未覆盖

- **真实玩家行为**：没有真实玩家、真实人口、收入、偏好或周期；需求是外生限价和实验扣除，价格不是规则发现的结果。不能从本报告得出“真实供需平衡”或“价格合理”的结论。
- **歉收的真实灾害路径**：M6 灾害只改变湿度与生长时间，不销毁成熟作物、不直接降低单次产量；本实验用较少成熟地块模拟歉收。若需要“灾害直接减产”，需要新的玩法决定。
- **地点价差**：只有一张全局订单簿和两处固定市场 id；没有按市场分区库存、地点价格或跨市场套利。运费只是成本。
- **商人策略**：报价不随库存目标、近期消耗或需求调整，也没有 AI 或预算外补发；本实验只验证固定公式。
- **生产机会成本**：Demo 种子免费、劳动力不计成本，生产者任何正价出售都获利；本实验不能评估真实农业利润。
- **仓储、腐坏、持有成本**：囤积没有时间成本，长期囤积的均衡无法从本实验推断。
- **费用/运费调参**：只验证了当前固定值；比例费、按订单费、最低批量、按距离/数量计费均未测试。
- **订单/物流归档**：仅证明 256 上限会阻塞，未实现归档方案。
- **网络、权限、UI、存档重开、Windows/CI**：均未覆盖；本机只在 macOS 4.7.2-stable 无头运行。
- **其他商品**：场景只使用青菜；其他五种商品的报价公式相同，但没有成交量/余额实验。

## 主会话登记（已完成）

- `.github/workflows/rule-tests.yml`：`market_supply_demand_test` 已登记在 `market_logistics_test` 之后。
- `rules/project-context.md`：已登记 M7-05 结论、隔离夹具、守恒证据，以及“订单表无归档”和“具名口袋进食缺口”两项待裁决事实。
- `docs/2.0/milestones/M7/PLAN.md`：M7-05 已加入本记录链接。
- 主会话复核：本地复跑夹具为 `checks=1205 failures=0`；M7-03/M7-04 的最近回归同为零失败。
- 两项规则裁决仍待做：具名口袋进食／转入共享库存；长寿命世界的订单与物流归档。本次不扩张规则。

## 待补证据

- 双平台 CI：本夹具登记后需回填 macOS/Windows 执行行（见下方补充）。
- Windows 实机与真实玩家数据：不在本切片范围。
