# ADR-014 · 双重记账：账户余额权威、借贷分录与对账

- 状态：采纳（2026-11-15），M8-01 实现完成；贷款、存款、保险与公共基金仍待 M8-02..M8-04
- 关联：[M8-01 记录](../milestones/M8/RECORD-01-ledger.md)、[经济与金融](../systems/economy-finance.md)、[M8 PLAN](../milestones/M8/PLAN.md)、[ADR-010](ADR-010-economy-initial-conditions.md)、[ADR-011](ADR-011-market-orders.md)、[ADR-012](ADR-012-matching-settlement.md)、[ADR-013](ADR-013-limited-logistics.md)

## 背景

M7 已经把现金放在三个权威位置：`economy.accounts[owner].cash`、规则商人的 `market.merchant.cash`，以及未成交买单的 `market.orders[id].reserved`。买入、撤单、到期、撮合退款、成交款、成交费用和物流运费都直接修改这些整数；唯一的守恒等式是 `total_cash == issued`（ADR-012，`issued` 是净发行）。

这条链已经能防止余额被单边改动，但还没有逐笔证据：从一份快照只能算出期末总额，无法回答“这 1 COIN 是付款、成交费还是运费”“账户余额为何比上一版少”“哪个业务事件发行了商人预算”。M8 的贷款、保险和公共基金需要借贷相等、冻结额与可用额、准备金与对账；如果先建立第二套余额表，所有消费路径都必须同时维护两处，最终仍无法证明哪一处是权威。

本裁决因此只增加一层**分录证据**，不替换余额权威，也不进入存款、贷款、保险或公共基金。

## 决定

### 1. 余额唯一权威，分录只做证据与对账

- 玩家、商人和买单托管的整数余额仍是唯一可花费口径。`available + frozen == 下单前余额` 继续由订单行本身成立：买单从账户扣现金，卖单从口袋扣商品。
- `economy.ledger` 只保存两类数据：
  - 有界分录日志：每个业务事件一条借贷相等的记录；
  - 紧凑余额检查点：每个科目一个带符号净额，用于在分录淘汰后继续对账。
- 分录不能被任何消费路径读取为“可花费金额”，也不提供第二个钱包、第二套冻结额或第二套商品库存。

### 2. 科目表与带符号余额

```text
account:<owner>   玩家现金账户，与 economy.accounts[owner].cash 同一个整数
merchant          规则商人现金，与 market.merchant.cash 同一个整数
escrow            未成交买单托管，与所有 open 买单的 reserved 之和相同
issuance          发行权益科目，贷方增加
burn              费用销毁科目，借方增加
```

余额按**借方为正**保存：现金科目增加记借方，`issuance` 增加记贷方（带符号为负），`burn` 增加记借方（带符号为正）。因此：

```text
每条分录：sum(debit) == sum(credit) > 0
所有检查点：sum(balances) == 0
现金科目合计 == total_cash
issuance(贷方) - burn(借方) == issued == total_cash
```

`@world` 可以出现在 `account:` 科目中（公共库存所有者的潜在账户），`@merchant` 不是玩家 id，只能使用 `merchant` 科目。科目名、事件 id 和金额都在权威边界校验，不接受负数、小数、`NaN`、无穷或超出安全整数的值。

### 3. 分录形状与业务事件

```text
economy.ledger = {
  sequence: int,                  # 最后一条分录的序号
  entries: {entry_id: entry},     # 有界日志，entry_id = "ledger_" + sequence
  balances: {account_code: int},  # 带符号检查点，包含已淘汰分录的净影响
}

entry = {
  id, sequence, kind, event_id, at_utc, debit, credit,
  lines: [{account, debit, credit}, ...]
}
```

`kind` 只取七种业务事件，`event_id` 指向命令 id、成交 id 或到期释放的订单序号：

| kind | 借方 | 贷方 | 业务入口 |
|---|---|---|---|
| `open_account` | `account:<owner>` 120 | `issuance` 120 | `economy_open_account` |
| `pay` | `account:<to>` 金额 | `account:<from>` 金额 | `economy_pay` |
| `merchant_budget` | `merchant` 600 | `issuance` 600 | `market_open_merchant` |
| `escrow_hold` | `escrow` 限价×数量 | `account:<owner>` 或 `merchant` | 买单下单 |
| `escrow_release` | `account:<owner>` 或 `merchant` 剩余托管 | `escrow` 同额 | 买单撤单或到期 |
| `trade` | 买方价差退款、卖方成交款、`burn` 费用 | `escrow` 买方原托管全额 | `market_match` |
| `shipping_fee` | `burn` 2 | `account:<owner>` 2 | `market_ship` |

- 成交分录满足 `buy_refund + sell_credit + fee == buy_price * quantity`，正好覆盖买方托管减少额；费用只出现在 `burn`，不进入任何账户。
- `convert_demo` 只登记已有货物，`market_deliver` 只移动货物，两者都不改变现金，因此**不写分录**；为无现金事件伪造借贷对会制造没有资金含义的噪声。
- 卖单托管的是商品，不涉及现金，因此下单、撤单、到期和成交都不为商品写现金分录。商品守恒仍由现有口袋、订单 `reserved` 和在途表核验。
- 每条分录最多 4 行。当前唯一的四行事件是成交；固定上限同时约束存档大小。

### 4. 同一候选快照内同时写余额与分录

- `Economy.open_account`、`Economy.pay`、`Market.open_merchant`、`Market.place`、`Market.cancel`、`Market.expire`、`Market.match`、`Market.ship` 都在调用方提供的候选 `data/economy` 上先完成规则校验，再写入余额和分录。
- `FarmState` 的经济命令改为和 M7 市场命令相同的候选模式：`economy_open_account`、`economy_pay`、`economy_convert_demo` 在 `_data.duplicate(true)` 上执行，成功后才替换权威状态。任何分录拒绝或后续规则失败都会丢弃整个候选，不留下“余额已扣、分录未写”或相反的状态。
- 首次迁移到分录格式的旧文档在恢复时建立检查点（见第 7 节），不在业务命令里惰性补写历史分录。

### 5. 有界日志与淘汰

- `MAX_ENTRIES = 512`，`MAX_LINES = 4`。
- 超出上限时按最小 `sequence` 淘汰最旧分录。淘汰**只删除日志行**，不改变检查点余额；因此零和等式、`issuance - burned == issued` 和逐账户对账在淘汰后仍成立。
- 检查点科目不会被淘汰；它记录的是所有已接受分录的累计净额。只有当前 `economy.accounts` 与商人/托管权威消失时，未知 `account:` 科目才会让对账失败，而不是被静默丢弃。
- 512 是实验值。合法世界可能长期超过它；当前切片只保证有界、确定性和对账不受淘汰影响，不承诺永久保留每一笔历史。

### 6. 幂等不从分录表推导

- 命令回放继续使用现有 64 条 `economy.command_results` 窗口；开户、转换和商人预算另有 `granted`、`conversion`、`merchant.opened` 持久标记；订单 id、成交 id、shipment id 仍是耐久行。
- 分录日志是有界证据，可以淘汰；它不承担“同一命令最多执行一次”的守卫。重复命令在写入任何分录之前就由上述机制回放或拒绝，因此不会产生第二条分录。
- 这一边界与 M7 一致：`pay` 等只靠命令窗口的幂等在窗口淘汰后仍不保证，M8-01 不把日志冒充成第二套幂等账本。

### 7. 存档位置、格式与旧档读取

- 分录放在现有 `economy` 子文档的 `ledger` 键内，不新增农场顶层键。农场格式仍为 `27`，`FarmState._valid_snapshot` 的键数不变，`V27Importer.KNOWN_FARM_KEYS` 与 `valid_cell_snapshot` 不变。
- M7 经济没有 `ledger`：`Economy.valid` 把它视为合法旧文档；`restore_snapshot` 建立一个**空日志 + 期初检查点**，没有迁移文件、没有伪造历史分录。检查点直接取现有 `accounts`、商人现金、买单托管和 `issued`：
  - 现金科目等于各自权威余额；
  - `escrow` 等于未成交买单托管；
  - 由于旧文档没有毛利/销毁拆分，整个净发行先放在 `issuance`，`burn` 为 0。
- 这样旧档读入后 `sum(balances) == 0` 且 `issuance - burn == issued`；下一条命令即可正常记账。旧档不会凭空发行或销毁现金。
- 只要 `ledger` 存在，快照校验就要求它结构合法并对账通过。一个被篡改的检查点、未知科目、非零和余额或不平衡分录都会被拒绝，而不是被默认修复。

### 8. 工具：冻结额、可用额、准备金与对账

```text
economy_funds(owner) -> {owner, available, frozen, total}
economy_reconcile() -> {ok, reason, legacy, total_cash, issued, issuance, burned,
                         accounts, merchant, escrow, entries, sequence}
economy_reserve_statement() -> {ok, total_cash, issued, accounts, merchant, escrow,
                                issuance, burned, claims, reserve, covered, entries, sequence}
economy_ledger() / economy_ledger_entries() / economy_ledger_entry(id)
```

- `available` 是账户当前 `cash`（买单托管已经扣走），`frozen` 是本人未成交买单的 `reserved` 之和，`total = available + frozen`。这三个值都是查询，不新增存储。
- `reconcile` 逐科目比较检查点与权威余额，并要求现金总额、净发行和零和等式同时成立。
- M8-01 没有存款或贷款，所以 `claims = 0`、`reserve = total_cash`、`covered` 只表示现金非负且账本有效；M8-02 增加存款负债后应在同一报告里加入真实负债，而不是另建钱包。

### 9. 校验边界

快照校验额外要求：

- `ledger` 恰好三键，`entries`、`balances` 为字典，序列小于安全整数上界；
- 分录恰好八键，`id == "ledger_" + sequence`，序号唯一且不超过日志序列，`kind` 在七种事件内，`event_id` 非空且不超过 160 字符；
- `lines` 为 2..4 行，每行恰好一个正方向，同一分录内科目不重复，行金额为安全整数；
- 每条分录借贷总额相等且大于零，行合计等于分录总额；
- 检查点科目合法、为带符号安全整数，总和为零；
- 活跃分录引用的科目必须仍存在于检查点。

## 为什么不是另一侧

- **不建第二套余额或冻结额表**：现有赠礼、厨房、动物、下单、撤单、撮合、到期和发货都直接读账户/口袋；第二套余额需要同步全部消费路径，且无法说明哪一套是权威。冻结额保留为订单行的派生查询。
- **不放独立 `ledger.json`**：成交、费用、退款和物流费必须与余额在同一次 `FarmStore` 提交中落盘；跨文件无法复用现有临时文件替换、冲突检测和恢复路径。
- **不做无界流水**：长期世界会持续增大农场快照。检查点让有界日志仍能对账，历史精度用淘汰策略明确。
- **不用分录表做幂等**：日志可以淘汰，而幂等必须跨淘汰成立；继续使用命令窗口和耐久业务行更可靠。
- **不给旧档补写历史分录**：这会发明不存在的业务事件。空日志加期初检查点既保留“旧档可读”，又不伪造证据。
- **不为商品托管写现金分录**：商品仍由 `bags`、订单 `reserved` 和在途表核验；混合两套守恒会让对账口径互相污染。

## 后果

- 新增 `Game/farm/ledger_state.gd`；`Economy` 增加分录校验、对账、资金视图、准备金报告和旧档检查点；`Market` 在开户、付款、商人预算、买单托管/释放、成交和运费路径写分录。
- `FarmState` 增加 `economy_ledger`、`economy_ledger_entries`、`economy_ledger_entry`、`economy_funds`、`economy_reconcile`、`economy_reserve_statement`；经济命令改为候选提交。
- `economy` 新增 `ledger` 子文档；农场格式仍为 27，没有新顶层键。
- 现金守恒扩展为逐笔借贷相等、检查点零和与 `total_cash == issued`；M7 的余额和商品守恒不变。
- 没有 UI/HUD、网络命令权限、存款、贷款、保险、公共基金、利息、外部支付或旧档迁移器。
- 世界包内容摘要包含农场快照，因此新增 `ledger` 会改变新导入/导出的 `world_id`/`farm_id`；已有导出不回溯重算，早期阶段不做标识迁移（与 ADR-010 的 `economy` 先例一致）。
- 512 条分录、4 行与 160 字符事件 id 是实验边界；M8-02 的真实贷款/存款量级会重新评估。

## 受影响规格

- [经济与金融](../systems/economy-finance.md)：确认“每笔资金变化用借贷相等的分录表示”的首版实现，账户/商人/托管仍是唯一余额权威。
- [M8 PLAN](../milestones/M8/PLAN.md) M8-01：交付账户、转账、冻结/可用、准备金与对账工具，以及所有现有资金路径的分录。
- [ADR-010](ADR-010-economy-initial-conditions.md)：`economy` 子文档继续承载账本；新增 `ledger` 内部键。
- [ADR-011](ADR-011-market-orders.md)：托管仍是订单行扣除，不新增冻结额表；买卖单的现金路径现在各有一条分录。
- [ADR-012](ADR-012-matching-settlement.md)：成交费用继续销毁，`issued` 仍是净发行；成交分录把退款、成交款和销毁放在同一借贷对中。
- [ADR-013](ADR-013-limited-logistics.md)：运费继续销毁；发货分录只记录销毁，不改变在途与交付规则。
- [M8-01 记录](../milestones/M8/RECORD-01-ledger.md)：命令、实测输出、守恒数据与未覆盖项。

## 复审触发条件

出现以下任一情况时重开本裁决：M8-02 的存款/贷款需要负债、利息或抵押科目；M8-03 的保险赔付需要独立准备金子账；M8-04 的公共基金需要多账户权限；真实世界长期超过 512 条分录且历史追溯成为需求；网络接入要求逐笔确认或外部审计导出；或者旧档检查点被证明无法解释真实 M7 存档的余额。
