# M8-05 · 金融压力模拟

状态：已执行（2026-11-15），未验收。范围：纯规则压力夹具 `tests/m8_stress_test.gd`，覆盖坏账与银行准备金、集中提款、歉收与商人流动性、60 天长离线、拒绝金融仍可生活、以及“当前不存在自动赔付”的边界确认。不涉及产品代码、UI、网络、存档或规则修改。

前置：[M8 PLAN](PLAN.md)、[RECORD-01-ledger](RECORD-01-ledger.md)、[RECORD-02-loans](RECORD-02-loans.md)；权威设计 [ADR-014](../../decisions/ADR-014-double-entry-ledger.md)、[ADR-017](../../decisions/ADR-017-bank-loans.md)。

## 模拟场景与参数

夹具继承 `SceneTree`，无渲染、无网络、无磁盘、无系统时钟；固定 `START = 1800000000`，每次场景独立构造 `FarmState`。所有贷款走 `FarmState.economy_borrow_loan` / `economy_repay_loan` / `economy_settle_loans`，市场走 `market_place_order` / `market_match` / `market_expire` / `market_deliver` / `market_ship`。

| 场景 | 参数与动作 | 主要断言 |
|---|---|---|
| 坏账与准备金 | 5 个账户各 120 COIN；银行资本 2000；A 借 1000、B 借 900、C 借 100 后还 105、D 借 100；A/B/D 到期不还 | 银行现金 5，未结清本金 2000，已收费用 5，`bank.cash == capital - outstanding + fees`；E 借 10 被 `bank_insufficient` 拒绝；逾期只改状态，`issued` / `total_cash` / 各账户余额不变 |
| 集中提款 | A 借 1000 后现金 1120，全部托管在 10×112 买单；B 再借走剩余 1000 并同样托管 | 可用余额 0、冻结 1120、总额 1120；再下 1 COIN 单被 `insufficient_cash` 拒绝；A 再借被 `loan_active` 拒绝；C 借 10 被 `bank_insufficient` 拒绝；拒绝前后快照一致；取消后现金恢复 |
| 歉收与商人 | 2 格青菜尝试卖 3 格；商人开市 600/20；5 笔买单买空 20 格库存；19 轮“种 4 卖 4”耗尽报价现金；1 笔买入回笼 | 超库存卖出被 `insufficient_goods` 拒绝且快照不变；库存归零后卖价报价行保持 filled、`sell_capacity=0`；卖回 4 格后 ask 重开；现金降到 15 后 buy 报价停补，回笼后 bid 重开；商品与现金守恒 |
| 60 天长离线 | 7 天贷款 50；卖单第 2 天到期、买单第 3 天到期、3 格运费在第 600 秒到达、商人报价持续刷新；一次推进 60 天 vs 逐日推进 60 次 | 两条路径都得到贷款 overdue、订单 expired、1 次交付；经济投影完全一致；重复扫描不产生第二次交付/逾期/发行；所有余额非负 |
| 拒绝金融 | 不开户、不开行、不下单；匿名播种/成熟/收获，再用 `leaf_stir` 做饭 | 作物与厨房路径可用；`issued=0`、`total_cash=0`、无账户、银行关闭、无合同/订单、商人关闭；经济文档仍合法 |
| 赔付边界 | A 借 1000、B 借 900，60 天后逾期 | 贷款扫描不写新分录、不发行、不增加任何账户或银行现金；只改合同状态；分录 kind 全在现有 10 种业务事件内；无 `insurance` / `claims` 键、无赔付字段、`claims=0` |

## 实际原始输出

本机无头运行（`Godot 4.7.2.stable`，隔离进程），三轮结果相同：

```text
SCENARIO bad_debt issued=2600 total_cash=2600 bank=5 outstanding=2000 fees=5 overdue=3 refused=bank_insufficient negative=no
SCENARIO concentrated_withdrawal issued=2360 total_cash=2360 bank=0 a_cash=0 a_frozen=1120 over_order=insufficient_cash over_loan=loan_active negative=no
SCENARIO poor_harvest granted=20 grown=76 goods_total=96 trades=26 fees=26 issued=934 total_cash=934 merchant_cash=22 ask_capacity=72 bid_capacity=4 negative=no
SCENARIO long_offline days=60 loan=overdue orders=expired delivered=1 delivery_events=1 once_daily_projection_equal=yes raw_snapshot_equal=no observation_time_gap=expiry/delivery stamps use sweep time duplicate_work=no
SCENARIO no_finance issued=0 total_cash=0 accounts=0 bank=closed loans=0 orders=0 meal=1 harvest=1
SCENARIO no_payout insurance=absent claims=0 payout_entries=0 new_entries_on_default=0 issued_delta=0 cash_delta=0 status_only=yes
M8_STRESS_TEST checks=882 failures=0
M8_STRESS_TEST checks=882 failures=0
M8_STRESS_TEST checks=882 failures=0
```

相关回归复跑（只读）：

```text
LOAN_TEST checks=1885 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/loan-33979
MARKET_MATCHING_TEST checks=241 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/matching-34482
MARKET_SUPPLY_DEMAND_TEST checks=1220 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/supply-demand-34525
```

## 守恒恒等式

每次场景操作后都实际比较：

```text
Σ 玩家现金 + 银行现金 + 商人现金 + 买单托管 == issued
issuance - burn == issued == total_cash
bank.cash == bank.capital - 未结清本金 + 已收费用
buyer escrow 可用 + 冻结总额不因拒绝减少，任何余额不为负
商品：库存 + 商人库存 + 卖单预留 + 在途 + 已消耗
      == 种植产出 + 商人一次性授予
```

具体数值：坏账场景 `issued = total_cash = 2600`，`bank=5, outstanding=2000, fees=5`；集中提款 `2360`；歉收/商人场景 `issued = total_cash = 934`，商品 `granted 20 + grown 76 = 96`（12 + 4 + 4 在袋、72 商人库存、4 卖单预留），26 笔成交各销毁 1 COIN；60 天场景 `raw_snapshot` 不逐字相等，但经济投影中的 `issued`、`total_cash`、双方余额、银行现金完全一致。

## 发现

1. **坏账不会暗中增发**。两份合同逾期后，银行现金、未结清本金和已收费用满足精确恒等式；新增借款因 `bank.cash` 不足被拒绝，拒绝前后快照完全一致。逾期不追加费用、不扣押、不核销，也不产生补偿性分录。
2. **可用余额是派生量而非第二余额**。买单托管后账户现金已经减少，`funds.available` 为 0 且 `frozen` 等于托管额；超额下单与在贷借款都被拒，取消后余额原样恢复。
3. **商人流动性有明确停补与恢复**。库存耗尽只停止 ask 补充，现金不足只停止 bid 补充；两者都在下一次扫描按真实库存/现金恢复，不靠刷新时钟或新发行。
4. **60 天推进的经济结果与逐日推进一致，但完整快照不逐字相等**。差异全部来自“观察时间”，不是资金或商品差额：
   - 订单到期写入的 `closed_utc` 是扫描时刻（逐日路径为第 2 天，一次推进为第 60 天）；到期时刻本身没有单独字段。
   - 交付事件 `at_utc` / shipment `delivered_utc` 同样是扫描时刻（逐日第 1 天 vs 一次推进第 60 天）。
   - 商人滚动报价在每次扫描按当前时刻重建，`created_utc` / `expires_utc` / `sequence` 与 `market.sequence` 随扫描次数变化；逐日路径还会把每天 12 条托管/释放写进有界日志，导致日志条目、`opening` 和 `ledger.sequence` 不同（余额不变）。
   - 因此夹具比较的是“经济投影”：余额、合同、玩家订单（去掉 `closed_utc`）、shipment/delivery 状态、商人现金/库存、作物与商品总量。该投影逐字相等；原始 `snapshot()` 被明确断言为不同。若未来要求崩溃恢复后逐字重放同一快照，需要为到期/交付记录到期时刻，或让状态扫描幂等到不随观察时刻写入字段。
   - 复现：在 `START` 建立“7 天贷款 + 已开商人 + 第 2 天到期的卖单 + 第 3 天到期且不跨价的买单 + 第 600 秒到达的 3 格运费”，对一份状态只在 `START + 60d` 调一次四类扫描，对另一份每天各调一次；比较 `market_order(...).closed_utc` 与 `market_deliveries()[0].at_utc` 即可看到上述差异。
5. **拒绝金融仍可正常生活**。不开户、不开行、不产生任何订单时，匿名播种/收获与厨房做饭正常完成，经济文档保持零发行、无账户、银行关闭、无合同。
6. **赔付高峰尚不存在，这是边界确认而非功能通过**。当前 10 种分录 kind 中没有保险/理赔/补偿事件，`economy` 没有 `insurance` / `claims` 子文档，合同 11 个字段中没有赔付字段；60 天逾期只改变合同状态。M8-03 落地后，本场景的“无赔付”断言必须替换为真实保单与唯一赔付用例。

## 未覆盖

- 保险承保与赔付（M8-03 尚未实现），因此“赔付高峰”只确认了当前无自动赔付。
- 存款、准备金率不足时的正式处置流程（当前只有拒绝新贷款与零发行，没有存款负债或挤兑队列）。存款纯规则已由 [RECORD-16](RECORD-16-deposits.md) / [ADR-030](../../decisions/ADR-030-bank-deposits.md) 补上：真实存款负债、`insufficient_reserve` 具名拒绝与集中提款场景；本记录的 882 项断言早于该切片，未包含存款，接线与 UI/网络仍未覆盖。
- 网络权威/客户端重放、真实墙钟长时运行、崩溃中断、Windows 实机与 CI；本轮只在本机无头跑规则夹具并做了三项相关回归。
