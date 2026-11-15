# ADR-011 · 市场报价与订单：托管式预留、规则商人与到期语义

- 状态：采纳（2026-11-15），M7-02 实现完成；撮合与交割由 [ADR-012](ADR-012-matching-settlement.md) 在 M7-03 实现
- 关联：[M7-02 记录](../milestones/M7/RECORD-02-market-orders.md)、[ADR-010 经济初始条件](ADR-010-economy-initial-conditions.md)、[经济与金融](../systems/economy-finance.md)、[M7 PLAN](../milestones/M7/PLAN.md)、[ADR-005 物资归属](ADR-005-player-bags.md)

## 背景

M7-01 已固定六种商品、整数 `COIN`、一次性开户发行和农场快照里的可选 `economy` 子文档。M7-02 需要在不做撮合的前提下，先让“报价、限价单、预留、撤单、到期”成为可持久、可重放的规则，并为 M7-03 的成交留下足够字段。

如果预留只做一份“冻结额”视图，现有 `gift`、厨房、动物、`pay` 等消费路径仍会花掉已冻结的资源；如果订单放在独立文件，资金、商品与预留无法在 `FarmStore` 的同一次提交中保持一致。M7-01 还明确说明 `pay` 的幂等只靠 64 条有界窗口，M7-03 必须另有耐久记录。因此本裁决固定订单状态与预留的归属，不进入价格发现或撮合算法。

## 决定

### 1. 订单形状：限价、整数量、接收序号与成交余量

订单只属于六种目录商品，方向为 `sell`（卖）或 `buy`（买）：

```text
order = {
  id, owner, side, good, price, quantity, remaining, filled,
  reserved, sequence, created_utc, expires_utc,
  status, released, closed_by, closed_utc
}
```

- `price` 是每单位限价，`quantity` 是原始数量；两者都是正安全整数。价格上限 `MAX_PRICE = 1000000`，数量上限 `MAX_QUANTITY = 9999`；负数、零、小数、非数字、超上限与目录外商品一律拒绝。
- `remaining` 是尚未成交数量，`filled` 是已成交数量，二者满足 `filled + remaining == quantity`。M7-02 不做撮合，`filled` 始终为 0，但字段和校验先固定下来。
- `sequence` 是权威接收序号，单调递增；M7-03 的“价格优先、同价按接收序号”直接使用它。
- `created_utc` / `expires_utc` 是调用方传入的 UTC 秒，本模块不读系统时钟。
- `status` 取 `open`、`cancelled`、`expired`、`filled`。M7-02 只产生前三种；`filled` 留给 M7-03。
- `released` 是关闭时释放的预留量（买单为现金、卖单为商品数量），`closed_by` 是撤单命令 id（到期关闭为空），`closed_utc` 是关闭时间。关闭后 `reserved` 归零、`remaining` 保留未成交数量用于审计。它们使重开和账本淘汰后的重放仍能给出同一个释放结果。
- 下单命令 id 就是订单 id。同一个下单 id 永远对应同一张订单，即使命令账本淘汰了旧记录，`orders.has(id)` 仍会拒绝第二次下单。

### 2. 预留是托管，不是第二套余额

- **卖单**：下单时立即从所有者的口袋 `bags[owner][good]` 扣除 `quantity`，记入订单的 `reserved`。口袋只剩未预留数量，厨房、动物、赠礼和再次下单都看不到已托管商品。
- **买单**：下单时立即从 `economy.accounts[owner].cash` 扣除 `price * quantity`，记入订单的 `reserved`。`pay` 和再次下单只能使用剩余现金。
- 因此账目只有一个权威口径：**可用余额 + 订单托管 = 原余额**。没有第三份“冻结额”表，也不需要让每个消费路径分别减去冻结额。
- 预留与订单写入同一个 `FarmState` 候选快照，成功后由 `FarmStore` 一次提交；失败路径先完成全部校验，候选被丢弃，实际快照不变。
- 撤单或到期把 `reserved` 原路退回：卖单退回口袋，买单退回账户（账户缺失时以 `granted=false` 重建，不发行新币）。

### 3. 规则商人：独立保留 id、一次性预算、受约束报价

- 商人使用保留所有者 `@merchant`。`@merchant` 不符合 `owner_id.gd` 的玩家格式，玩家无法占用；玩家下单和撤单都拒绝这个 id。公共库存所有者 `@world` 也不是本切片的可交易 id，匿名收获仍只进入 M7-01 的库存视图。
- 商人预算由一次性命令 `market_open_merchant` 发行 `MERCHANT_BUDGET = 600 COIN`，持久标记为 `merchant.opened` 与 `merchant.opened_by`。这是继一次性开户之后的第二个明确发行入口，`issued` 增加同样金额；商人现金与玩家账户现金、未成交买单托管一起计入 `total_cash`，因此无回收项时 `total_cash == issued` 仍然成立。
- 商人报价由商品参考价确定性派生，不读系统时钟、不读市场历史：
  - `bid = max(1, floor(base_price * 4 / 5))`
  - `ask = base_price + max(1, floor(base_price / 4))`
  - `buy_capacity = min(MAX_QUANTITY, floor(merchant.cash / bid))`
  - `sell_capacity = min(MAX_QUANTITY, merchant.goods[good])`
- 商人的买单只能按当前 `bid` 下单，卖单只能按当前 `ask` 下单；下单数量不得超过报价容量。商人现金不足时不能买入，没有库存时不能卖出。商人订单与玩家订单使用同一套托管和关闭规则。
- 报价公式与金额是实验参数；M7-05 用真实供需实验重新评估，M7-03 才让商人订单参与撮合。

### 4. 撤单与到期：确定性 UTC 边界、只释放一次

- 撤单只能由订单所有者发起，只能撤 `status == open` 的订单；释放 `reserved` 后把 `reserved` 清零，保留未成交的 `remaining` 用于审计，并写入 `released`、`closed_by`、`closed_utc`。
- 撤单在 `now_utc >= expires_utc` 时返回 `order_expired`，不释放；到期由权威的 `market_expire(now_utc)` 统一结算。这样同一订单在“到期时刻之前”和“到期时刻及之后”的结果只由 UTC 决定，不取决于撤单和结算的调用顺序。
- 到期条件固定为 `expires_utc <= now_utc`；`market_expire` 按订单 id 排序确定性遍历，重复调用不会再次释放（已关闭订单被跳过）。
- 同 id、同 payload 的撤单重放返回原释放结果；同 id、不同 payload 返回 `command_conflict`。即使命令账本淘汰了该 id，订单已关闭且 `reserved == 0`，再次撤单返回 `order_closed`，不会二次释放。

### 5. 持久化：放在现有 `economy` 子文档内

订单与商人状态作为 `economy.market` 保存，不新增农场顶层键：

```text
economy.market = {
  merchant: {opened, opened_by, opened_utc, cash, goods},
  orders: {order_id: order},
  sequence: int
}
```

- 农场文档仍是 `format_version = 27`，`FarmState._valid_snapshot` 的键数不变，`V27Importer.KNOWN_FARM_KEYS` 不变，`valid_cell_snapshot` 不变。
- M7-01 写出的 `economy`（没有 `market`）仍可读出：`Market.valid` 把缺失视为空市场，`restore_snapshot` 补默认值。这不是旧存档迁移器，只是可选子文档的默认形态。
- 订单表上限 `MAX_ORDERS = 256`（含已关闭订单）；满后拒绝新订单并返回 `order_limit`。已关闭订单保留用于审计与重放，归档策略留给 M7-03/M7-04。
- `market.sequence` 只在订单被接受时递增一次；撤单、到期和失败都不递增。

### 6. 幂等与账本边界

- 所有市场命令沿用现有模式：命令 id + 规范化 payload + 候选快照 + 成功后才提交。命令结果复用 `economy.command_results` 的 64 条有界窗口，不新增第二份命令账本。
- 订单本身是耐久记录：下单 id 与订单 id 相同，订单状态、`released`、`closed_by` 都在快照里。即使命令窗口淘汰旧 id：
  - 重放下单 id 会命中 `order_exists`，不会第二次托管；
  - 重放撤单 id 会因订单已关闭而返回 `order_closed`，不会第二次释放。
- **M7-03 边界**：成交确认不能只靠 64 条命令窗口，必须用订单 id + 成交序号（或等价耐久记录）保证同一成交最多执行一次；部分成交要同时减少 `remaining`、`reserved` 并增加 `filled`，资金与商品与新订单状态需要在同一候选快照中提交。M7-02 不实现这些。

## 为什么不是另一侧

- **不做“冻结额”视图**：现有赠礼、厨房、动物和付款路径都直接读口袋与账户，派生冻结额需要同步修改所有消费路径，容易漏掉一条路径造成超预留。托管把可用余额直接变成权威值，只有一个口径。
- **不放独立 `market.json`**：M7-03 要求资金、商品、预留和成交同时提交，跨文件无法保证原子性；放进 `economy` 可直接复用 `FarmStore` 的临时文件替换与恢复。
- **不把商人做成玩家账户**：商人有规则报价与预算，不需要登录、开户或玩家 id 格式；独立 `@merchant` 状态更清楚，也避免 `pay` 被用来给商人转账。
- **不让撤单在到期时刻后也成功**：否则同一订单的结果取决于撤单与到期谁先被调用，违背“按 UTC 确定性判断”。到期结算统一释放，撤单只处理仍在有效期内的订单。
- **不在 M7-02 撮合**：撮合、部分成交、费用和单边交付失败需要成交事件与耐久确认，属于 M7-03；本切片只保证订单能被表达、预留能守恒、关闭只发生一次。

## 后果

- `economy` 子文档新增 `market`；M7-01 的无 `market` 经济仍可读并补空市场。
- `Economy.total_cash` 计入商人现金与未成交买单托管；`Economy.valid` 校验市场结构，并要求账户现金、商人现金与买单托管之和不超过 `issued`。
- 新增 `Game/farm/market_state.gd`；`FarmState` 暴露 `market_open_merchant`、`market_place_order`、`market_cancel_order`、`market_expire`、`market_quote(s)`、`market_orders`、`market_order`、`market_merchant`、`market_snapshot`。
- 市场命令尚未接入网络角色权限；接入时必须决定哪些角色可开户、开商人预算、下单和撤单。
- 没有 UI/HUD、撮合、部分成交、费用、物流、信誉或旧存档迁移器。
- `market.sequence`、商人预算与订单上限都是实验参数，M7-05 需要重新评估。

## 受影响规格

- [经济与金融](../systems/economy-finance.md)：确认“买单预留资金、卖单预留商品、撤单或到期只释放剩余部分”的首版实现方式。
- [M7 PLAN](../milestones/M7/PLAN.md) M7-02：交付报价、订单、托管预留、撤单、到期与无头夹具。
- [ADR-010](ADR-010-economy-initial-conditions.md)：`issued` 的第二个明确发行入口是商人预算；`pay` 的窗口幂等边界继续有效，M7-03 另建耐久成交记录。
- [ADR-005](ADR-005-player-bags.md)：商品仍以 `bags`/`inventory` 为权威；托管只是从口袋扣除，不复制库存。

## 复审触发条件

出现以下任一情况时重开本裁决：M7-03 发现 `reserved` 与 `remaining` 的派生关系无法表达部分成交；商人策略需要按库存、近期消耗或需求调整报价；订单表上限或保留策略影响长期世界；M7-03 的成交幂等无法用订单 id + 成交序号保证；或者接入网络后需要把商人预算和订单权限拆到不同角色。
