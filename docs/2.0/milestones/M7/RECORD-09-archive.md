# M7-09 · 订单、发货与交付归档

- 状态：完成（2026-11-15），未验收
- 裁决：[ADR-018](../../decisions/ADR-018-order-archive.md)
- 前置：[M7-02 订单](RECORD-02-market-orders.md)、[M7-03 撮合](RECORD-03-matching.md)、[M7-04 物流](RECORD-04-logistics.md)、[M7-07 商人流动性](RECORD-08-merchant-liquidity.md)

## 目标

订单表、shipment 表和 delivery 表都有 256 行上限，且已关闭订单、已交付 shipment、交付事件原本永不释放。长寿命世界会永久 `order_limit` / `shipment_limit` / `delivery_limit`。本切片只淘汰三类终点证据，用单调计数记录归档，并让成交/交付在引用行缺失时仍能严格校验。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/farm/market_state.gd` | `archived_orders` / `archived_shipments` / `archived_deliveries` 计数；满表时淘汰最早关闭玩家订单 / 最早已交付 shipment / 最旧 delivery；商人报价行、open 行、在途行保护；成交与交付缺行校验；归档 id 引用守卫；旧市场缺计数按 0 读入 |
| `Game/farm/farm_state.gd` | 只在市场恢复段补三个计数默认并归一化为整数 |
| `tests/market_archive_test.gd` | 新增 2660 项检查的无头隔离夹具 |
| `tests/market_supply_demand_test.gd` | order-cap 场景改为“淘汰最早关闭行后接受”，并断言 `archived_orders=1` |
| `docs/2.0/decisions/ADR-018-order-archive.md` | 新增裁决 |
| `docs/2.0/milestones/M7/RECORD-09-archive.md` | 本记录 |

## 规则

1. **订单归档**：`place` 遇到 `orders.size() >= MAX_ORDERS` 时，淘汰 `sequence` 最小的已关闭（`cancelled`/`expired`/`filled`）玩家订单行，`archived_orders += 1`，再继续下单。没有可淘汰行（全部 open 或只剩商人行）时仍返回 `order_limit`。
2. **保护行**：`merchant_bid_*` / `merchant_ask_*` 永不被淘汰（即使已过期关闭）；`open` 行永不被淘汰。关闭时 `reserved` 已归零，删行不改变现金或商品。
3. **发货归档**：`ship` 遇到 `shipments.size() >= MAX_SHIPMENTS` 时，淘汰 `sequence` 最小的 `delivered` shipment 行，`archived_shipments += 1`，再继续发货。`in_transit` 行永不淘汰；全部在途时仍返回 `shipment_limit`。
4. **交付归档**：`deliver` 遇到 `deliveries.size() >= MAX_DELIVERIES` 时，淘汰 `sequence` 最小的 delivery 行，`archived_deliveries += 1`，再写入新事件。delivery 只在货物回到口袋后写入，没有在途状态，因此每一行都是终点证据。
5. **成交缺行校验**：订单行存在时逐项交叉校验 owner/good/side/limit price；缺失时信任成交行的 `buy_owner`/`sell_owner`/`good`/`buy_price`/`sell_price` 语义。`_valid_trade` 仍要求成交价等于买卖限价之一且介于两者之间、金额与费用公式成立。缺失的 `merchant_bid_*`/`merchant_ask_*` 直接拒绝。
6. **交付缺行校验**：delivery 行与 shipment 行都存在时交叉校验 owner/good/quantity/route/时间；shipment 行缺失时信任 delivery 行自身的 durability 字段；delivery 行缺失时信任 delivered shipment 行自身由 `_valid_shipment` 检查的字段。
7. **计数约束**：不同缺失订单 id 数 ≤ `archived_orders`，不同缺失 shipment id 数 ≤ `archived_shipments`，不同缺失 delivery id 数 ≤ `archived_deliveries`；三个计数非负、安全整数、分别 ≤ `sequence`/`shipment_sequence`/`delivery_sequence`，且必须一起存在或一起缺失。
8. **id 重用**：命令窗口仍在时，归档 id 的重放找不到耐久行，返回 `unknown_order`/`unknown_shipment`。窗口淘汰后，归档订单 id 仍被保留成交引用时返回 `order_exists`，成交淘汰后才可重用；归档 shipment id 在其 delivery 仍保留时返回 `shipment_exists`，delivery 也归档后守卫不再保留该 id，但账本的永久事件 id 检查仍会以 `duplicate_event` 拒绝真正重用。
9. **形状**：农场格式仍为 27，`_valid_snapshot` 键数、`valid_cell_snapshot`、`V27Importer.KNOWN_FARM_KEYS` 不变。旧市场缺三个计数时按 0 读入并补默认。

## 守恒数据

- 订单归档夹具：A/B 两次开户共发行 240；257 次下单/撤单（全部卖单，无费用）后 `issued == total_cash == 240`，商品合计 2，`archived_orders=1`，`economy_reconcile().ok`。
- 成交后归档夹具：一笔 2 单位成交，价格 10，费用 1 → `issued == total_cash == 239`；两次归档后 `archived_orders=2`，商品 2（两张 open 卖单托管），成交行在两张订单行都缺失后仍可重载。
- 物流归档夹具：5 次开户共发行 600；255 次发货+交付后保留 1 条在途，再发货 2 次；共 257 次发货、每次销毁 2 → `issued == total_cash == 86`；商品 2（1 口袋 + 1 在途），`archived_shipments=1`，`economy_reconcile().ok`。
- 交付归档夹具：同样发行 600；256 次发货+交付填满两表后再发货并交付，共 257 次发货、每次销毁 2 → `issued == total_cash == 86`；商品 2；`archived_shipments=1`、`archived_deliveries=1`，`economy_reconcile().ok`。
- 全部在途的规则级夹具：300 商品、1000 现金、256 次发货全部在途，第 257 次返回 `shipment_limit`，`archived_shipments` 仍为 0。

## 原始测试输出

```text
MARKET_ARCHIVE_TEST checks=2660 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/market-archive-46858
MARKET_LOGISTICS_TEST checks=174 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/logistics-47333
MARKET_ORDERS_TEST checks=191 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/market-orders-47372
MARKET_SUPPLY_DEMAND_TEST checks=1220 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/supply-demand-47460
MARKET_MATCHING_TEST checks=241 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/matching-47698
MERCHANT_LIQUIDITY_TEST checks=330 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/merchant-liquidity-47737
LEDGER_TEST checks=1841 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/ledger-47820
```

## 双平台 CI

2026-11-15，`a711524` 在 `rule-tests.yml`（run 43686065199）上双平台通过，两个宿主结果一致：

```text
macOS   market_archive_test MARKET_ARCHIVE_TEST checks=2660 failures=0
macOS   rule fixtures: 61 listed, 7 skipped for missing art
Windows market_archive_test MARKET_ARCHIVE_TEST checks=2660 failures=0
Windows rule fixtures: 61 listed, 7 skipped for missing art
```

清理检出不含 LFS 美术，7 个场景夹具按既有规则跳过（含 `market_panel_test`）；规则夹具本身不加载美术。CI 只覆盖干净检出上的规则与命令边界，不替代真实长寿命世界和 Windows 实机。

## 未覆盖

- 网络命令权限、重放与客户端/权威侧归档语义。
- UI/HUD 展示归档计数或历史不可查提示；`Game/scenes`、`Game/ui` 未改。
- Windows/CI 实机与跨平台存档往返。
- 真实长寿命世界的归档频率、归档 id 永久占用分布。
- 三张证据表都已归档；成交记录仍按原有 512 上限自淘汰。
- 归档后的 shipment id 在其 delivery 仍保留时不可重用；delivery 也归档后引用守卫放行，但账本永久事件 id 仍以 `duplicate_event` 拒绝真正重用。订单 id 只有在成交表淘汰相关引用后才可重用。
