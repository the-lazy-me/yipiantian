# ADR-012 · 撮合与交割：价格时间优先、部分成交、费用与耐久成交记录

- 状态：采纳（2026-11-15），M7-03 实现完成；物流、网络权限与真实供需调参仍待后续
- 关联：[M7-03 记录](../milestones/M7/RECORD-03-matching.md)、[ADR-011 市场报价与订单](ADR-011-market-orders.md)、[ADR-010 经济初始条件](ADR-010-economy-initial-conditions.md)、[经济与金融](../systems/economy-finance.md)、[M7 PLAN](../milestones/M7/PLAN.md)

## 背景

M7-01 固定了六种商品、整数 `COIN`、一次性开户发行和农场快照中的 `economy` 子文档。M7-02 固定了限价单形状、托管式预留、接收序号 `sequence`、撤单和 UTC 到期，并明确留下三个未决问题：成交价由谁决定、部分成交如何同时更新 `remaining`/`reserved`/`filled`、以及成交幂等不能只依赖 64 条命令窗口。

M7-03 必须让一笔成交里的商品与现金在同一次 `FarmState` 提交中移动。如果撮合读系统时钟、在多个入口隐式触发，或把成交拆成“先扣款、后送货”的两步，那么撤单、到期、断线重试和重开都可能只完成一侧。如果成交只记在命令窗口，窗口淘汰后同一笔成交就可能被再次结算。本裁决因此只解决撮合与交割，不进入物流、网络角色权限或价格发现实验。

## 决定

### 1. 唯一撮合入口：确定性 `market_match(now_utc)` 扫描

- 撮合只有一条路径：权威在确定的时间点调用 `market_match(now_utc)`。下单、撤单和到期都不隐式撮合；它们只修改订单簿。
- 本模块不读系统时钟、不读磁盘、不读场景；`now_utc` 由调用方传入，与 M6/M7 其他 UTC 规则一致。
- 同一快照、同一 `now_utc` 重放得到同一成交序列；重复扫描是状态驱动的 no-op。
- 需要断线重试的调用方可传入可选命令 id（`market_match(now_utc, command_id)`）：同 id、同 UTC 返回原成交笔数并标记 `duplicate=true`；同 id、不同 UTC 返回 `command_conflict`。命令 id 只记录已接受扫描的成交笔数，不保存逐笔明细，也不构成第二次结算入口；不传 id 时就是纯扫描。
- 选择独立扫描而不是“下单后立即撮合”，是为了让命令保持纯订单簿操作、让并发顺序显式、并让撤单/到期/成交的竞态可以用同一套规则验证。代价是权威必须在应用命令后调用扫描；M7-04 和网络接入需要把这个调用点固定到命令提交之后。

### 2. 价格优先，同价按接收序号

- 买单排序：价格从高到低；同价按 `sequence` 从小到大；再按订单 id 字典序。
- 卖单排序：价格从低到高；同价按 `sequence` 从小到大；再按订单 id 字典序。
- 只有 `best_bid >= best_ask` 时成交；每次成交数量为 `min(buy.remaining, sell.remaining)`。
- 可成交订单必须同时满足：`status == open`、`remaining > 0`、`created_utc <= now_utc`、`now_utc < expires_utc`。
- 到期条件仍是 ADR-011 的 `expires_utc <= now_utc`。因此订单在到期当秒既不参与撮合，也只由到期规则关闭；在同一 `now_utc` 下先撮合或先到期结果相同。

### 3. 成交价：先到订单（maker）的限价

- 每一笔成交的 maker 是买卖两单中 `sequence` 较小的一方；合法快照中 `sequence` 唯一，id 只是不可达的确定性兜底。
- 成交单价 `price` 取 maker 的限价，因此 `sell_price <= price <= buy_price` 必然成立，不会越过任何一方的限价。
- 双方按同一 `price` 和 `quantity` 计算 notional：
  - `notional = price * quantity`
  - 买方的托管按自己的限价预留，成交后立即退回 `buy_refund = (buy_price - price) * quantity`；
  - 卖方收到 `sell_credit = notional - fee`。
- 如果 maker 是买单，成交价等于买方限价，买方没有价差退回；如果 maker 是卖单，成交价等于卖方限价，买方获得价差退回。
- 不采用买卖价中点：中点可能在整数上产生舍入，且可能越过一方的限价；maker 限价是整数、可重放、且双方金额天然一致。

### 4. 部分成交

一次成交后：

- 买单：`filled += quantity`、`remaining -= quantity`、`reserved = remaining * buy.price`。
- 卖单：`filled += quantity`、`remaining -= quantity`、`reserved = remaining`。
- `filled + remaining == quantity` 始终成立；未成交部分继续保持 `open`，托管按剩余数量递减。
- 某侧 `remaining == 0` 时关闭为 `filled`：`reserved = 0`、`released = 0`、`closed_by = ""`、`closed_utc = now_utc`。
- 部分成交后的撤单或到期只释放剩余托管，`released = remaining * unit`；已成交部分不回滚。
- 因为每次成交量取 `min(remaining)`，每笔成交至少关闭一个订单。当前订单表上限 256，所以一个合法世界最多产生 256 笔成交。

### 5. 费用：每笔成交固定 1 COIN，由卖方支付并销毁

- `fee = min(TRADE_FEE, notional)`，`TRADE_FEE = 1`；费用只从卖方成交款扣除，不向买方另收，不进入任何账户。
- 资金影响：
  - 买方托管减少 `buy_price * quantity`，其中 `price * quantity` 支付成交，差额退回买方可用余额；
  - 卖方可用余额增加 `notional - fee`；
  - 销毁的 `fee` 不进入任何账户，因此 `total_cash`（账户现金 + 商人现金 + 未成交买单托管）减少 `fee`；
  - `issued` 同步减少 `fee`。`issued` 因此是**净发行**（开户发放 + 商人预算 − 销毁费用），不是历史累计发行。
- 守恒等式保持为 `total_cash == issued`；没有第二套账本、公共账户余额或额外费用字段。成交记录保存 `notional`、`fee`、`buy_refund`、`sell_credit`，满足 `sell_credit + fee == notional` 和 `buy_refund + price * quantity == buy_price * quantity`。
- 固定费用是实验参数。极小成交（`notional = 1`）的卖方成交款为 0，这是明确边界；M7-05 用真实供需实验决定是否改为比例费用。
- 费用不在成交前预扣，不在撤单时收取；未成交部分不产生费用。

### 6. 资金与商品同一次候选快照提交

- `FarmState.market_match` 在 `_data.duplicate(true)` 上执行整次扫描；只有 `Market.match` 返回成功且至少一笔成交时才用候选替换权威状态。
- 一笔成交内依次检查并在同一候选上写入：买方商品入袋、买方价差退回、卖方成交款入账、费用销毁、买卖双方订单行、耐久成交记录。任一步失败则丢弃整个候选，不提交任何一侧。
- 商品仍以 `bags`/公共 `inventory` 为权威，现金仍以 `economy.accounts` 与商人现金为权威；不新增第二库存或第二余额。
- 卖方没有开户时，成交款创建一个 `granted=false` 的收款账户，不发行新币；之后 `open_account` 仍会一次性发放开户金额（`granted` 从 false 变 true）。这只修正“先卖后开户”的收款路径，不新增发行入口。
- 同一所有者同时是买卖双方的自成交在当前切片允许：商品回到原所有者，净现金减少一笔费用。规则没有为它增加分支，保证扫描对任意合法订单簿都有定义。

### 7. 耐久成交记录与幂等

- 成交记录放在现有 `economy.market` 内：

```text
economy.market = {
  merchant: {...},
  orders: {order_id: order},
  sequence: int,          # 订单接收序号
  trades: {trade_id: trade},
  trade_sequence: int     # 成交序号
}

trade = {
  id, sequence, good, price, quantity, notional, fee,
  buy_id, sell_id, buy_owner, sell_owner, buy_price, sell_price,
  buy_refund, sell_credit, at_utc
}
```

- `trade_id = "trade_" + sequence`，`trade_sequence` 单调递增且持久化；同一快照重放产生相同的 id 与金额。
- 上限 `MAX_TRADES = 512`，超出时按最小 `sequence` 淘汰最旧记录。当前每笔成交至少关闭一个订单、订单表上限 256，因此合法世界最多 256 笔成交，实际不会触发淘汰；未来订单归档后即使触发，淘汰的也只是审计记录。
- **成交幂等不依赖命令窗口，也不依赖成交记录本身**：订单行上的 `filled`/`remaining`/`reserved` 是耐久守卫，重复扫描没有可成交余量。成交记录是有界、可查询的结算证据，不提供“拿 trade id 再结算一次”的入口，所以不存在未完成结算或重复结算路径。
- 命令窗口（64 条）继续只服务开户、转换、付款、下单、撤单、商人开户和可选的撮合命令 id 重放。清空窗口后：重复扫描 0 笔；重放下单 id 命中 `order_exists`；重放撤单 id 命中 `order_closed`；成交记录仍然可查；同一个撮合 id 因窗口淘汰而重新执行时，也只会看到没有可成交余量的订单。

### 8. 并发、到期与重试的确定性顺序

- **撤单 vs 成交**：权威串行提交。成交先提交时，撤单只能释放未成交余量（或返回 `order_closed`）；撤单先提交时，撮合看不到该订单。两条路径都不会同时交付商品和退回商品。
- **到期 vs 成交**：同一 `now_utc` 下，撮合只处理 `now < expires_utc` 的订单，到期只处理 `expires_utc <= now` 的订单，两者集合不相交，因此顺序无关。到期前撮合可以成交；之后到期只释放剩余部分。到期边界当秒撮合不成交，由到期释放全部剩余。
- **重复结算**：扫描是状态驱动的 no-op；没有独立结算命令。
- **断线重试**：下单/撤单沿用 ADR-011 的命令 id + 耐久订单；撮合扫描可安全重复。重复请求不会双花，也不会单边交付。

### 9. 快照形状与拒绝边界

- 农场格式版本保持 `27`；`trades`/`trade_sequence` 只加在 `economy.market` 内，不新增农场顶层键，`V27Importer.KNOWN_FARM_KEYS` 与 `valid_cell_snapshot` 不变。
- `Market.valid` 校验：市场键集合、订单表与成交表上限、每笔成交的键集合、id 与 sequence 一致、商品/价格/数量范围、`notional = price * quantity`、`sell_price <= price <= buy_price`、`buy_refund`/`sell_credit`/`fee` 的金额关系、订单与所有者引用、`sequence` 唯一且不超过 `trade_sequence`。
- M7-01 的无 `market` 经济仍恢复为空市场（既有行为）。M7-02 的旧市场形状没有 `trades`/`trade_sequence`，与 M7-01 同一先例：两者同时缺失时按空成交记录读入，恢复后写回完整形状；只缺其一、类型错误或成交字段不符仍整体拒绝。这不是迁移器，老订单原样保留，也不会凭空产生成交记录。

## 为什么不是另一侧

- **不在下单时隐式撮合**：隐藏副作用会让下单重放、撤单竞态和“同一条命令只执行一次”都变复杂；独立扫描只有一条结算路径。
- **不用中点价**：中点可能不是整数、可能越过限价，并让双方金额出现舍入差；maker 限价没有这些问题。
- **不把费用放进公共账户**：当前没有公共财政账户，凭空增加一个会形成第二套余额和后续支出权限；直接销毁使 `total_cash == issued` 保持单一等式。
- **不向买方收费**：买方已用限价托管，另收费需要修改托管与退款公式；卖方成交款是更小的改动面。
- **不保留无界成交流水**：成交记录有界，幂等由订单余量保证；无界历史会持续增大农场快照。
- **不按单位收费**：固定每笔费用更容易解释和验证；是否改为比例由 M7-05 的真实交易数据决定。

## 后果

- `Game/farm/market_state.gd` 新增 `match`、`match_error`、`trades`、`trade` 与内部成交/校验规则；市场状态新增 `trades`、`trade_sequence`。
- `FarmState` 新增 `market_match(now_utc, command_id = "")`、`market_trades()`、`market_trade(trade_id)`，并在恢复时归一化成交数字。
- `Economy.open_account` 允许把之前因收款创建、`granted=false` 的账户升级为已开户，仍只发放一次。
- `issued` 的语义从“只增的累计发行”扩展为“净发行”；`total_cash == issued` 仍是唯一守恒等式。
- 没有 UI/HUD、网络命令权限、订单归档、物流、在途库存、旧档迁移或商人策略变化。
- 费用、成交价规则和排序都是当前实验规则；M7-05 必须用真实供需与集中抛售/囤积场景复评。

## 受影响规格

- [经济与金融](../systems/economy-finance.md)：确认首版撮合按价格优先、同价按接收序号，部分成交只释放剩余预留，成交/费用/交割在同一提交内。
- [M7 PLAN](../milestones/M7/PLAN.md) M7-03：交付撮合、部分成交、费用、原子交割与无头夹具。
- [ADR-010](ADR-010-economy-initial-conditions.md)：`issued` 现为净发行；费用销毁是明确的负向变动。
- [ADR-011](ADR-011-market-orders.md)：`sequence`、订单形状、托管和撤单/到期规则继续有效；M7-03 的耐久成交边界由本裁决补上。
- [M7-03 记录](../milestones/M7/RECORD-03-matching.md)：命令、实测输出、守恒数据与未覆盖项。

## 复审触发条件

出现以下任一情况时重开本裁决：比例费用或公共财政账户进入范围；订单归档使成交记录淘汰成为常态；网络接入要求显式的逐笔结算确认；自成交被证明可被用于刷成交或绕过风险规则；或者 M7-05 证明固定费用、maker 定价或订单上限使基本交易不可维持。
