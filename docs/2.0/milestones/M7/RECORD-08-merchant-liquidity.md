# M7-07 · 规则商人流动性

- 状态：完成（2026-11-15），未验收
- 裁决：[ADR-016](../../decisions/ADR-016-merchant-liquidity.md)
- 前置：[M7-02 订单](RECORD-02-market-orders.md)、[M7-03 撮合](RECORD-03-matching.md)、[M7-06 市场界面](RECORD-06-market-panel.md)

## 目标

单机玩家原本只能开户、挂单，无法与规则商人成交（M7-06 已知阻塞）。本切片给商人一次性库存和滚动双边报价，让玩家卖得出、买得进，同时保持现有现金/商品守恒、农场格式 27 和 256 行订单上限。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/farm/market_state.gd` | 一次性商品授予 `merchant.granted`；开市即生成 12 条滚动报价；固定 base−1/base+1 价差；`match()` 前确定性维护；商人 id 保护；`granted` 与 12 行上限严格校验；自成交分录按科目合并 |
| `tests/merchant_liquidity_test.gd` | 新增 310 项检查的无头隔离夹具（授予、成交、重复开市、现金/库存耗尽与恢复、12 行、确定性、旧市场） |
| `tests/market_orders_test.gd` | 报价改为 base±1；商人开市后的现金/托管/库存断言同步 |
| `tests/market_matching_test.gd` | 商人参与改为滚动报价；新增“自成交价差退款”分录回归 |
| `tests/market_supply_demand_test.gd` | 商人价差场景改用滚动报价；商品守恒只补授予项 |
| `tests/ledger_test.gd` | 商人在场时玩家成交价改为 6，避免卷入商人价差；断言同步 |
| `docs/2.0/decisions/ADR-016-merchant-liquidity.md` | 新增裁决 |
| `docs/2.0/milestones/M7/RECORD-08-merchant-liquidity.md` | 本记录 |

## 规则

1. **一次性库存**：`market_open_merchant` 向六种商品各授予 20，写入 `merchant.granted = {good: 20}`；`goods` 同步增加。开市按 `merchant.opened` 幂等，第二个开市 id 返回 `already_opened`，不再授予或挂单。
2. **固定价差**：bid = `max(1, base−1)`，ask = `base+1`，数量 4；买单从 `merchant.cash` 托管，卖单从 `merchant.goods` 托管。
3. **滚动同 id**：`merchant_bid_<good>` / `merchant_ask_<good>` 各有稳定行。每次 `Market.match(data, now)` 在撮合前检查：缺失、已关闭或已到期的行，在商人有足够现金/库存时原地重开，刷新 `sequence`/价格/数量/到期/托管；不新增行。到期未扫的行先释放再重开。
4. **成交**：沿用 `_execute_trade` 的 `@merchant` 分支。买单成交写 `merchant.goods`，卖单成交写 `merchant.cash`；商品在卖单开出时即离开库存，不能再次托管或发货。
5. **新增守卫**：玩家不能使用 `merchant_bid_*`/`merchant_ask_*` 作为自己的订单 id；快照校验拒绝超过 12 条商人报价前缀行。
6. **旧市场**：缺少 `granted` 时按六个 0 读入并补成规范字段；商人已开市的旧市场不补发授予。旧档无需迁移即可开市。
7. **自成交分录修复**：同一所有者同时是买卖方时，退款与成交款合并为一个 `account:<owner>` 借方行；净额为零则省略。分录仍逐笔平衡且不超过 4 行，`Ledger` 的“同一分录科目唯一”校验未放宽。

## 守恒

- 现金：`total_cash == issued`，费用继续销毁。
- 商品：`产出 + granted = 口袋 + 商人库存 + 卖单托管 + 在途 + 已消耗`。
- 商人开市后（新农场）：现金 600 → 免费现金 260 + 买单托管 340；每种商品 20 → 库存 16 + 卖单托管 4；授予记录 20×6。
- 供需实验商人价差场景：8 笔成交、8 COIN 费用，`issued == total_cash == 832`；玩家合计 204，商人现金 288 + 托管 340 = 628，商人从 600 到 628（+7/轮次），玩家端净损失 36，费用 8。

## 原始测试输出

```text
MERCHANT_LIQUIDITY_TEST checks=310 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/merchant-liquidity-19983
MARKET_ORDERS_TEST checks=191 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/market-orders-20069
MARKET_MATCHING_TEST checks=241 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/matching-20101
MARKET_LOGISTICS_TEST checks=174 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/logistics-20189
MARKET_SUPPLY_DEMAND_TEST checks=1220 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/supply-demand-20233
LEDGER_TEST checks=1841 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/ledger-20514
ECONOMY_INITIAL_TEST checks=154 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/economy-initial-264780
```

自成交价差回归位于 `MARKET_MATCHING_TEST`：A 先挂 5 COIN 卖单再挂 10 COIN 买单，2 单位成交价为 maker 的 5；退款 10、卖方净得 9、费用 1；A 现金 −1、货物恢复；`Ledger` 分录为 `account:A` 借 19、`burn` 借 1、`escrow` 贷 20，三科目各一行、借贷各 20。

## 未覆盖

- 动态调价、做市 AI、按地点/玩家拆分流动性。
- Windows 实机（CI 已双平台通过：`MERCHANT_LIQUIDITY_TEST checks=330 failures=0`，见下）。
- 长寿命世界的商人耗尽/恢复频率、订单与账本上限统计。
- 市场面板的商人库存/报价展示与网络角色权限。

## 主会话补充

- **旧世界补授予**：已开市但没有 `granted` 字段的商人，在首次扫描时补发一次 6×20 库存；字段本身是幂等标记，重载不会二次授予。这是规则生效，不是存档迁移。
- **仅重开报价的扫描落盘**：`Market.match` 结果新增 `changed`，`FarmState.market_match` 在无成交但报价被重开/到期时也提交候选，否则刷新只存在于被丢弃的候选里。
- 两条补充各有断言：`MERCHANT_LIQUIDITY_TEST` 从 310 项增至 330 项。

## 双平台 CI

提交 `ab1d97a` 的 [Rule fixtures 43684813326](https://github.com/the-lazy-me/yipiantian/actions/runs/43684813326) 两平台均通过：

```text
macOS   MERCHANT_LIQUIDITY_TEST checks=330 failures=0
Windows MERCHANT_LIQUIDITY_TEST checks=330 failures=0
macOS   rule fixtures: 60 listed, 7 skipped for missing art
Windows rule fixtures: 60 listed, 7 skipped for missing art
```
