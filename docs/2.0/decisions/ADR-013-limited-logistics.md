# ADR-013 · 有限物流：两处市场、在途托管、固定运费与耐久交付事件

- 状态：采纳（2026-11-15），M7-04 实现完成；全区域运输网、承运人、保险、风险路线与网络角色权限仍不在范围
- 关联：[M7-04 记录](../milestones/M7/RECORD-04-logistics.md)、[ADR-011 市场报价与订单](ADR-011-market-orders.md)、[ADR-012 撮合与交割](ADR-012-matching-settlement.md)、[ADR-010 经济初始条件](ADR-010-economy-initial-conditions.md)、[经济与金融](../systems/economy-finance.md)、[M7 PLAN](../milestones/M7/PLAN.md)

## 背景

M7-02/M7-03 的市场是同一市场内的现货订单簿：卖单从口袋托管商品，撮合时直接交付给买方口袋，商品从未离开“可结算”的范围。M7-04 要验证的是另一件事：货物在两地之间运输时既不属于可出售库存，也不能被撤单或到期释放；到达后必须产生可追溯的交付事件。

现有约束决定了可用的最小方案：

- 商品权威仍是 `FarmState.bags` 与公共 `inventory`，订单托管只是从口袋扣除；没有按地点分区的第二套库存。
- 市场状态放在 `economy.market`，与订单、成交记录和命令账本共用同一次 `FarmStore` 提交；新增独立文件无法保证商品、费用与交付的原子性。
- 农场格式仍为 27。新增顶层键会同时牵动 `FarmState._valid_snapshot` 的键数、`V27Importer.KNOWN_FARM_KEYS` 和迁移边界；本切片没有必要改变农场形状。
- 所有规则接收调用方传入的 UTC 秒，不读系统时钟；每笔状态变化先落在候选快照，失败时整次丢弃。
- 早期开发不写旧存档迁移器。M7-03 已有“缺少 `trades`/`trade_sequence` 按空成交记录读入”的先例，可沿用于缺失物流子账本。

## 决定

### 1. 两处固定市场与一条对称路线

```text
LOCATION_FARM  = "farm_market"
LOCATION_HARBOR = "harbor_market"
fee              = 2 COIN
delivery_seconds = 600
```

- 发货必须在两个已知且不同的市场之间；同一市场、未知市场一律拒绝。路线双向同价同时长，本切片不建距离、路网或据点表。
- 市场位置只是发货记录的声明，不是第二套库存分区。商品从所有者的全局口袋移入“在途”，到达后回到同一全局口袋。这样“在途不可出售”由口袋权威直接成立，不需要让订单簿、厨房、赠礼、动物等所有消费者同时理解地点。
- 这是一个明确的切片边界：订单簿仍是无位置的现货市场。把位置加到订单或按地点切分 `bags` 会让 ADR-011/012 的订单形状、撮合和全部消费路径一起变化，超出 M7-04 要验证的问题。

### 2. 在途与交付放进现有 `economy.market`

```text
economy.market = {
  merchant, orders, sequence, trades, trade_sequence,   # M7-01..03
  shipments: {shipment_id: shipment},
  deliveries: {delivery_id: delivery},
  shipment_sequence: int,
  delivery_sequence: int
}

shipment = {
  id, sequence, owner, good, quantity, origin, destination,
  fee, depart_utc, arrive_utc, status, delivered_utc, delivery_id
}

delivery = {
  id, sequence, shipment_id, owner, good, quantity,
  origin, destination, at_utc
}
```

- `shipment.id` 就是发货命令 id，因此命令账本淘汰后同一 id 仍返回 `shipment_exists`，不会再次扣货或扣费。
- `status` 只有 `in_transit` 和 `delivered`。没有 `cancelled`：本切片不提供中途取消、拒收、丢失或退款，避免引入第二个权威和补偿规则。
- `delivery.id = "delivery_" + sequence`，由持久 `delivery_sequence` 单调生成；`shipment.delivery_id` 指向唯一事件。一个 shipment 最多对应一个 delivery，校验同时检查双向引用，孤立或重复的交付事件整体拒绝。
- `shipments` 上限 256、`deliveries` 上限 256；交付记录保留用于追溯，不归档。合法世界最多 256 次交付，因此 256 个交付行不会触发淘汰；发货表满后拒绝新发货并返回 `shipment_limit`。

### 3. 发货是托管：扣货、扣费、销毁费用，同一次候选提交

- 只允许玩家所有者发货；`@merchant` 与 `@world` 不是玩家账户，也没有可支付运费的口袋账户，因此拒绝。商人若以后需要运输，必须另建规则入口，不能借用玩家发货。
- 发货前依次校验：命令 id、所有者、商品目录、路线、正安全整数数量、UTC、发货表上限、口袋数量、账户存在与余额。
- 校验通过后在同一候选快照内：从 `bags[owner][good]` 扣除数量；从账户现金扣除 `SHIPMENT_FEE`；`economy.issued -= SHIPMENT_FEE`；写入 `shipments` 行和 `shipment_sequence`。
- 费用没有任何收款方，直接销毁。买方/卖方账户、商人现金和未成交买单托管都不增加，所以 `total_cash == issued` 仍是唯一货币守恒等式。运费不是税，也不是承运人收入；承运人 AI 与保险不在范围。
- 发货成功后 `shipment_sequence` 递增一次；失败、重放、拒付都不递增。

### 4. 交付是确定性扫描，不是客户端命令

- 唯一交付入口是 `Market.deliver(data, now_utc)`（`FarmState.market_deliver(now_utc, command_id = "")`）。下单、撤单、撮合和到期都不会隐式交付。
- 条件固定为 `status == in_transit && arrive_utc <= now_utc`，按 shipment `sequence` 升序确定性遍历。一次扫描把所有已到期货运全部交付，类似到期扫描。
- 对每笔到期 shipment 在同一候选内：把数量加回所有者口袋；写 `delivery_<sequence>` 事件；把 shipment 置为 `delivered` 并写 `delivered_utc`、`delivery_id`。任一步失败则整次扫描丢弃，不提交部分交付。
- `arrive_utc = depart_utc + 600` 是持久规则；到达前 1 秒不交付，到达当秒交付，之后重复扫描是状态驱动的 no-op。
- 可选 `command_id` 只服务断线重试：同 id 同 UTC 返回原交付笔数并标记 `duplicate=true`，同 id 不同 UTC 返回 `command_conflict`。真正防止二次交付的是 shipment 的持久 `status`，不是 64 条命令窗口。

### 5. 与订单、撮合、撤单、到期和重开的关系

- 在途货物已不在口袋里，因此卖单托管、赠礼、厨房、动物与再次发货都看不到它；新卖单返回 `insufficient_goods`。
- 撤单和到期只释放订单自己的 `reserved`，不读取也不修改 `shipments`；交付只增加口袋和写交付事件，不读取订单。因此同一 UTC 下 `deliver` 与 `market_match`、`market_cancel_order`、`market_expire` 对彼此的行和余额顺序无关。
- 撮合仍是唯一成交入口；物流不改变价格时间优先、maker 定价、部分成交或费用规则。交付可能在撮合之后给卖方/买方增加可用商品，这只影响之后的订单，不影响已托管数量。
- 存盘重开后，shipment 状态、交付事件、序号与费用销毁原样恢复；重复交付扫描仍是 no-op，重复发货 id 仍被 shipment 行拒绝。

### 6. 快照形状与拒绝边界

- 农场格式版本保持 27；没有新增农场顶层键，`FarmState._valid_snapshot` 的键数、`V27Importer.KNOWN_FARM_KEYS` 与 `valid_cell_snapshot` 均不变。
- `Market.valid` 新增校验：shipment/delivery 表上限、精确键集合、id 与序号一致、商品/数量/费用范围、路线两端已知且不同、`arrive_utc - depart_utc == 600`、状态与交付字段互斥、序号唯一且不超过计数、交付与 shipment 的双向引用及 owner/good/quantity/route/`at_utc` 一致。
- 物流四个键必须同时存在或同时缺失。全部缺失视为 M7-03 市场，恢复为空物流；只缺一部分、类型错误或任一字段不符整体拒绝。这不是迁移器，老订单和成交记录原样保留。

## 为什么不是另一侧

- **不把地点加到订单或 `bags`**：这会把 M7-04 变成库存分区与订单契约重构，必须同步撮合、撤单、到期、赠礼、厨房和所有库存视图；本切片只需证明在途不可重复出售，整包移出/移回已经足够。
- **不把在途写成延迟的卖单**：卖单在订单簿里仍可被撮合、撤销或到期释放，正好与“在途不可重复出售”冲突；要修就得给订单加位置和运输状态，代价更大。
- **不放独立 `logistics` 文件或农场顶层键**：发货要同时扣货、扣费、写事件，跨文件无法复用 `FarmStore` 的单次提交；顶层键还会扩大格式与导入边界。
- **不做承运人、保险、风险路线或中途取消**：这些需要新的角色、赔付、损失与争议规则，属于后续阶段；本切片不先放开关或空接口。
- **不把运费付给商人或公共账户**：当前没有承运人账户或公共财政收款方；销毁与 ADR-012 的成交费用一致，保持单一 `total_cash == issued`。
- **不按单位或距离计价、不做可变时长**：两种情况不足以产生有意义的路由差异；先用固定参数验证在途语义，M7-05 再用真实供需调参。
- **不在发货时自动交付**：隐式副作用会让重试、断线和顺序验证变复杂；独立扫描与撮合/到期的模式一致。

## 后果

- `Game/farm/market_state.gd` 新增固定市场、路线、shipment/delivery 形状、发货、交付扫描、查询、重放和校验；`economy.market` 新增四个物流键。
- `Game/farm/farm_state.gd` 新增 `market_ship`、`market_deliver`、`market_shipments`、`market_shipment`、`market_deliveries`、`market_delivery`、`market_route(s)`，恢复时补空物流并归一化整数/浮点。
- 商品守恒口径扩展为“口袋 + 订单托管 + 在途 + 已消耗 = 产出”；货币守恒不变，运费销毁同时减少 `issued` 与 `total_cash`。
- 没有 UI/HUD、网络角色权限、订单/发货归档、承运人、保险、风险、取消或旧存档迁移器。农场格式仍为 27。
- `SHIPMENT_FEE = 2`、`DELIVERY_SECONDS = 600`、两个市场 id 与 256 上限都是实验参数；M7-05 必须用真实供需与集中抛售/囤积场景复评。

## 受影响规格

- [经济与金融](../systems/economy-finance.md)：确认“运输中的货物不同时可卖，交付事件具有唯一编号”的首版实现方式，并保留跨区域风险与承运人给后续阶段。
- [M7 PLAN](../milestones/M7/PLAN.md) M7-04：交付两处市场、在途不可重复出售、费用、交付事件与无头夹具。
- [ADR-011](ADR-011-market-orders.md)：托管、订单形状、撤单和到期规则继续有效；物流不改变订单。
- [ADR-012](ADR-012-matching-settlement.md)：撮合、maker 定价、费用销毁和耐久成交记录继续有效；运费销毁沿用同一守恒等式。
- [M7-04 记录](../milestones/M7/RECORD-04-logistics.md)：命令、实测输出、守恒数据与未覆盖项。

## 复审触发条件

出现以下任一情况时重开本裁决：订单需要按市场位置分簿；`bags` 改为按地点分区；需要中途取消、拒收、丢失、保险或承运人分成；固定运费/时长在真实供需中不可维持；发货表或交付表上限影响长期世界；或者网络接入需要把发货、交付拆成不同角色权限与逐笔确认。
