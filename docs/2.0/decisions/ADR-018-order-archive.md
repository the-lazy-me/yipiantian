# ADR-018 · 订单、发货与交付归档：只淘汰终点证据，保留计数

- 状态：采纳（2026-11-15），M7-09 切片实现完成；网络、UI 与真实长寿命世界验证仍待后续
- 关联：[M7-09 记录](../milestones/M7/RECORD-09-archive.md)、[ADR-011](ADR-011-market-orders.md)、[ADR-012](ADR-012-matching-settlement.md)、[ADR-013](ADR-013-limited-logistics.md)、[ADR-016](ADR-016-merchant-liquidity.md)、[M7 PLAN](../milestones/M7/PLAN.md)

## 背景

订单表上限 256（含已关闭订单），shipment 表上限 256，delivery 表上限 256。M7-02/M7-04 把关闭订单、已交付 shipment 和交付事件都当作永久审计证据，长寿命世界会先把三张表填满，然后永久返回 `order_limit` / `shipment_limit` / `delivery_limit`。成交校验要求 `buy_id`/`sell_id` 指向两张现存的订单行，交付校验要求 delivery 与 shipment 双向对应，因此不能直接删行而不改校验。

需要在不改变现金/商品口径、不破坏耐久证据、不改变农场格式 27 的前提下，让三张有界表继续可用。

## 决定

### 1. 只淘汰终点证据：已关闭订单、已交付 shipment、最旧 delivery

- `place` 在 `orders.size() >= MAX_ORDERS` 时，先淘汰一条“已关闭且 `sequence` 最小”的玩家订单行，再继续下单；没有可淘汰行时仍返回 `order_limit`。
- 已关闭状态包括 `cancelled`、`expired`、`filled`。它们的 `reserved` 已归零，拒绝下单、撤单或到期时已经把钱/货退回，所以删行不移动任何资金或商品。
- `open` 行永不淘汰：它仍托管着现金或商品，删行会凭空丢失余额。
- `merchant_bid_*` / `merchant_ask_*` 永不淘汰：滚动报价规则复用同一 12 行，删掉会破坏稳定 id 和行数上限。即使该商人报价行已过期关闭，也按 id 排除。
- `ship` 在 `shipments.size() >= MAX_SHIPMENTS` 时，只淘汰一条“`delivered` 且 `sequence` 最小”的 shipment 行。`in_transit` 行仍代表未回到口袋的商品，永不淘汰；全部在途时返回原 `shipment_limit`。
- `deliver` 在 `deliveries.size() >= MAX_DELIVERIES` 时，淘汰 `sequence` 最小的 delivery 行再写入新事件。delivery 行只在货物已经回到口袋后写入，没有“在途”状态，因此每一行都是终点证据，直接淘汰最旧即可。
- 三张表在淘汰后仍保持 256 行上限；归档发生次数只由计数器记录。成交记录仍按原有 512 上限自淘汰，不属于本次三张证据表。

### 2. 证据行缺失时信任证据行自身，存在时仍交叉校验

归档让成交/交付引用可以合法地指向已删除行。校验因此分成两条路径：

- **行存在**：继续逐项交叉校验。成交的 `buy_id`/`sell_id` 行必须 owner、good、side、limit price 全部一致；delivered shipment 与其 delivery 必须 owner、good、quantity、route、`delivered_utc`/`at_utc` 一致。没有放宽任何现有字段。
- **行缺失**：由成交行/交付行/发货行自身承担证据。`_valid_trade` 仍检查 id、序号、商品、价格区间、`notional = price × quantity`、费用公式、`buy_price`/`sell_price` 范围，以及成交价等于买卖限价之一且介于两者之间；`_valid_delivery` 仍检查 id、序号、owner、good、quantity、路线和时间；delivered shipment 行本身也仍由 `_valid_shipment` 检查 owner、good、quantity、路线、费用和 `delivered_utc`。缺失行不得是 `merchant_bid_*`/`merchant_ask_*`，因为商人行从不归档。
- 双向对应：delivery 行存在而 shipment 行缺失时信任 delivery；shipment 行存在且已交付而 delivery 行缺失时信任 shipment；两者都存在时逐项交叉校验。
- 缺失引用不是任意值：不同缺失订单 id 数 ≤ `archived_orders`，不同缺失 shipment id 数 ≤ `archived_shipments`，不同缺失 delivery id 数 ≤ `archived_deliveries`。这防止伪造日志凭空声明大量不存在的证据行。

### 3. 保留计数而不保留被删行

- `economy.market` 新增 `archived_orders`、`archived_shipments`、`archived_deliveries`，只增不减。每次淘汰加一，命令失败、撤单、到期、交付都不改计数。
- 不保存被删行副本：副本会重新引入同样的有界表和第二条权威，也会让“归档”变成复制而不是释放空间。计数只回答“是否发生过归档、发生多少次”，历史细节明确接受丢失。
- 三个计数分别不超过 `market.sequence` / `shipment_sequence` / `delivery_sequence`，且必须一起存在或一起缺失；只缺一部分的文档整体拒绝。

### 4. 命令 id 重用边界

- 命令窗口仍在时，重复的下单/发货 id 走原重放路径；若对应耐久行已被归档，`Market.replay` 找不到行并返回 `unknown_order` / `unknown_shipment`，不会二次扣款或扣货。
- 命令窗口淘汰后，归档订单 id 只有在没有任何保留成交行引用它时才能重新下单；否则返回 `order_exists`，避免旧成交与同名新行交叉校验失败。等引用它的成交记录自身从有界成交表中淘汰后，id 才重新可用。
- 归档 shipment id 只有在其 delivery 事件仍被保留时才返回 `shipment_exists`；该 delivery 也被归档后，引用守卫不再保留这个 id。实际重用仍受账本约束：shipment 命令都写过运费分录，`Ledger.post` 对永久事件 id 的重复检查会返回 `duplicate_event`。因此守卫的语义变化可验证，但同一发货命令 id 在正常世界中仍不可真正重用；这是已知边界。
- 上述行为在记录中列为已知限制：同一 id 在窗口内与窗口外的结果不同，且部分归档 id 永久不可重用。

### 5. 快照形状与旧市场

- 农场格式仍为 27；`_valid_snapshot` 键数、`valid_cell_snapshot`、`V27Importer.KNOWN_FARM_KEYS` 均不变。新状态全部在 `economy.market` 内。
- `Market.initial_state()` 写三个计数为 0。旧市场缺少三个键时按 0 读入，`valid()` 接受该形状，`FarmState.restore_snapshot` 补默认字段；不写迁移器，不凭空声明已归档行。
- 归档只改变 `orders`/`shipments` 的行数，不改变 `total_cash == issued`、商品“口袋 + 订单托管 + 在途 + 商人库存 + 已消耗”的口径，也不写账本分录。

## 为什么不是另一侧

- **不淘汰 open / in-transit 行**：它们仍托管余额或商品，删行等于凭空销毁；即使记入计数器也无法恢复。delivery 没有在途状态，所以最旧一行可以直接淘汰。
- **不复制被删行到另一张历史表**：历史表同样有上限，只是把问题推迟；无界历史会持续增大快照。计数已经能说明归档发生。
- **不放宽为“缺行即信任任意成交/交付”**：证据行自身仍执行完整的金额、价格、路线和序号校验，缺失 id 数量还受归档计数约束。
- **不为归档 id 建永久墓碑表**：墓碑随历史增长，且与“不保留被删行”冲突。用保留的成交/交付行做引用守卫，边界自然有界。
- **不改变 256 上限本身**：本切片只让有界表可长期使用，不重新设计每笔成交/每次发货的存储成本。

## 后果

- `Game/farm/market_state.gd` 新增三个归档计数、三张表的淘汰、`_archive_closed_order` / `_archive_delivered_shipment` / `_archive_delivery`、成交/交付缺行校验与 id 引用守卫。
- `Game/farm/farm_state.gd` 只在市场恢复段补三个计数默认并归一化为整数。
- `tests/market_archive_test.gd` 覆盖三张表的填满、淘汰顺序、商人/open/在途保护、缺行重载、篡改拒绝、守恒、旧市场与计数单调。
- `tests/market_supply_demand_test.gd` 的 order-cap 场景从“257 单被拒绝”改为“淘汰最早关闭行后接受”。
- 未覆盖：网络命令权限与重放、UI 展示、Windows/CI 实机、真实长寿命世界的归档频率。

## 复审触发条件

出现以下任一情况时重开本裁决：需要保留被归档行的完整内容或按 id 查询历史；成交表也需要归档；归档 id 重用边界造成实际冲突或不可接受的永久占用；订单、发货或交付上限在真实世界中仍不可维持；网络接入需要归档命令在客户端与权威侧有不同语义。
