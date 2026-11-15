# M8-01 · 建立双重记账

状态：已实现（2026-11-15），未验收。范围：在现有现金账户、商人现金和买单托管之上增加逐笔记账分录，提供冻结额/可用额、准备金与对账工具，并把开户、付款、商人预算、消费性托管/释放、成交费用和物流运费接入分录。不包含存款、贷款、利息、保险、公共基金、UI/HUD、网络角色权限或旧档迁移器。

权威设计：[ADR-014](../../decisions/ADR-014-double-entry-ledger.md)；上层规格：[经济与金融](../../systems/economy-finance.md)、[M8 PLAN](PLAN.md)；前置：[ADR-010](../../decisions/ADR-010-economy-initial-conditions.md)、[ADR-011](../../decisions/ADR-011-market-orders.md)、[ADR-012](../../decisions/ADR-012-matching-settlement.md)、[ADR-013](../../decisions/ADR-013-limited-logistics.md)。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/farm/ledger_state.gd` | 新增。纯规则双重记账：科目表、带符号检查点、平衡分录写入、512 条有界日志与最旧序号淘汰、结构校验和 JSON 数字归一化。 |
| `Game/farm/economy_state.gd` | 新增 `ledger` 子文档与 `reconcile`、`funds`、`reserve_statement`、旧档 `adopt_ledger`；开户与付款在同一候选内写分录；`valid` 要求现存日志逐科目对账。 |
| `Game/farm/market_state.gd` | 商人预算、买单托管、撤单/到期释放、成交退款/成交款/费用销毁和物流运费写分录；新增 `escrowed_cash_for`。 |
| `Game/farm/farm_state.gd` | 经济命令改为候选提交；恢复时补空日志或期初检查点并归一化数字；新增账本查询、资金、对账与准备金接口。 |
| `tests/ledger_test.gd` | 新增 1817 项无头检查：逐笔平衡、转账、冻结/可用、托管与释放、商人预算、成交费用、运费、重复命令、JSON/磁盘恢复、旧档检查点、非法分录、与撮合/物流/费用组合对账、淘汰后检查点。 |
| `tests/market_matching_test.gd` | 既有“未开户卖方”夹具在删除账户后同时删除 `ledger`，按旧档读入重建期初检查点；断言本身不变。 |
| `docs/2.0/decisions/ADR-014-double-entry-ledger.md` | 本切片的持久裁决。 |
| `docs/2.0/decisions/README.md` | 决策入口增加 ADR-014 一行。 |
| `docs/2.0/milestones/M8/PLAN.md` | M8-01 增加记录与决定链接。 |
| `docs/2.0/milestones/M8/RECORD-01-ledger.md` | 本记录。 |

未新增依赖、网络消息、场景节点、HUD、美术资源或旧存档迁移器。农场格式版本保持 27；没有新增农场顶层键，`FarmState._valid_snapshot` 的键数、`V27Importer.KNOWN_FARM_KEYS` 与 `valid_cell_snapshot` 均未改。分录只扩展 `economy.ledger` 内部形状。

## 科目与分录

余额权威不变：`economy.accounts[owner].cash`、`market.merchant.cash`、未成交买单的 `market.orders[id].reserved`。分录不提供第二个钱包。

```text
account:<owner>   玩家现金
merchant          商人现金
escrow            买单托管
issuance          发行权益（贷方）
burn              费用销毁（借方）
```

每条分录借贷相等；检查点为借方为正的带符号净额，所有检查点合计为零：

```text
sum(debit) == sum(credit) > 0
sum(balances) == 0
issuance - burn == issued == total_cash
available + frozen == 下单前余额
```

| 业务 | kind | 借方 | 贷方 |
|---|---|---|---|
| 开户 120 COIN | `open_account` | `account:<owner>` | `issuance` |
| 转账 | `pay` | `account:<to>` | `account:<from>` |
| 商人预算 600 COIN | `merchant_budget` | `merchant` | `issuance` |
| 买单托管 | `escrow_hold` | `escrow` | `account:<owner>`/`merchant` |
| 买单撤单/到期 | `escrow_release` | `account:<owner>`/`merchant` | `escrow` |
| 成交 | `trade` | 买方退款 + 卖方成交款 + `burn` 费用 | `escrow` 原托管 |
| 物流运费 | `shipping_fee` | `burn` 2 | `account:<owner>` 2 |

`convert_demo` 与 `market_deliver` 不改变现金，不写分录；卖单托管商品，也不写现金分录。

## 命令与接口

```text
economy_open_account(id, owner, now)     # 写入 grant 分录
economy_pay(id, from, to, amount, now)   # 写入 pay 分录
economy_funds(owner)                     # {available, frozen, total}
economy_reconcile()                      # 逐科目对账与净发行报告
economy_reserve_statement()              # 现金、发行/销毁、claims、reserve、covered
economy_ledger() / economy_ledger_entries() / economy_ledger_entry(id)
```

市场沿用原命令；下列路径自动写分录：`market_open_merchant`、买单 `market_place_order`、`market_cancel_order`、`market_expire`、`market_match`、`market_ship`。

经济命令现在和 M7 市场命令一样在 `_data.duplicate(true)` 上执行，成功后才替换权威状态；任何规则或分录失败都丢弃整个候选。

## 存档与旧档

```text
economy.ledger = {
  sequence: int,
  entries: {entry_id: entry},     # entry_id = "ledger_" + sequence，最多 512 条
  balances: {account_code: int},  # 淘汰后仍保留的累计检查点
}
```

- 超出 512 条时淘汰最小 `sequence`；删除日志行的同时把它的净额并入 `opening`，`balances` 不变，所以对账等式和幂等不受淘汰影响。强制 `balances == opening + Σ活跃分录净额` 且 `Σ opening == 0`（M8-02 硬化）。
- 旧经济文档没有 `ledger` 时仍可通过校验；恢复时得到**空日志 + 期初检查点**，现金科目取现有账户、商人现金和托管，净发行整体放在 `issuance`（旧档无毛利/销毁拆分），`burn = 0`。不写迁移器，不伪造历史分录。
- 只要 `ledger` 存在，快照必须对账通过；不平衡分录、未知科目、非零和检查点或“余额改了但分录未写”都会拒绝。

## 实测输出

命令均在仓库根目录执行，引擎为 `/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot`：

```bash
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
"$GODOT" --headless --path Game --script "$PWD/tests/ledger_test.gd"
```

原始结果行：

```text
LEDGER_TEST checks=1817 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/ledger-56186
```

同一工作树的相关回归：

```text
ECONOMY_INITIAL_TEST checks=154 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/economy-initial-281666
MARKET_ORDERS_TEST checks=188 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/market-orders-56624
MARKET_MATCHING_TEST checks=224 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/matching-56682
MARKET_LOGISTICS_TEST checks=174 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/logistics-56742
MARKET_SUPPLY_DEMAND_TEST checks=1205 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/supply-demand-56813
```

前三轮开发中出现并已修复的夹具算术错误：买单 `price 10 × quantity 1` 的托管是 10，不是 100。修正后全部通过；没有放宽生产断言。

## 守恒数据

| 步骤 | 账户 A | 账户 B | 商人 | 托管 | 全服现金 | issued | 检查点 issuance/burn |
|---|---:|---:|---:|---:|---:|---:|---|
| 新农场 | 0 | 0 | 0 | 0 | 0 | 0 | 0 / 0 |
| 开户 A、B | 120 | 120 | 0 | 0 | 240 | 240 | 240 / 0 |
| A 付 B 50 | 70 | 170 | 0 | 0 | 240 | 240 | 240 / 0 |
| 买单托管 10 | 60 | 170 | 0 | 10 | 240 | 240 | 240 / 0 |
| 商人预算 | 60 | 170 | 600 | 10 | 840 | 840 | 840 / 0 |
| 成交 10（买 A / 卖 B） | 60 | 179 | 600 | 0 | 839 | 839 | 840 / 1 |
| 运费 2（A 发货） | 58 | 179 | 600 | 0 | 837 | 837 | 840 / 3 |

成交行中 A 的 10 托管释放、B 收到 9、1 COIN 销毁；运费行再销毁 2 COIN。每个步骤后 `total_cash == issued` 且 `issuance - burn == issued`。

## 覆盖

- 每笔业务分录借贷平衡，含发行（`issuance`）与回收（`burn`）对手科目。
- 典型转账；买单冻结额与可用额；撤单和到期释放。
- 重复开户、付款、下单、撮合命令返回原结果且不追加分录。
- 分录取整、JSON 恢复、`FarmStore` 磁盘恢复后日志逐项一致。
- 空账本旧档读入：空日志、期初检查点、不发行不销毁，随后命令可从序号 1 开始。
- 非法分录拒绝：不平衡、未知 kind、非法科目、负数、双方向行、序号/ id 不符、非法检查点、非零和、缺键、分录引用缺失科目。
- 余额与 issued 同时被改但未写分录的快照被拒绝。
- 与撮合、物流、成交费和运费组合后逐科目对账。
- 600 笔转账后日志停在 512 条、最旧条目淘汰、检查点仍零和、近期命令仍可回放。

## 未覆盖

- **M8-02..M8-04**：存款、贷款、利息、抵押、违约、保险、赔付和公共基金尚未实现；准备金报告当前 `claims = 0`。
- **网络与权限**：经济命令仍未接入 `FarmCommand`/WorldHost 角色权限；哪些角色可开户、转账、查账和对账尚未决定。
- **UI/HUD**：玩家看不到分录、冻结额、对账或准备金报告。
- **外部审计导出**：没有导出格式或签名；日志淘汰后无法还原被删除的逐笔历史。
- **比例费用与真实量级**：512 条上限、4 行和 160 字符事件 id 是实验边界，未用长期真实世界验证。
- **`pay` 的窗口幂等**：命令窗口淘汰后仍不保证回放；本切片没有把日志当作第二套幂等账本。
- **干净检出**：双平台 CI 已通过（见下），但仍只有 LFS 指针的美术场景夹具按 `skipped=no-art` 跳过，没有眼见的画面证据。
- **真实玩家数据**：未使用真实存档；全部夹具为隔离目录。
- **内容派生标识**：世界包摘要包含农场快照，新增 `ledger` 会改变新导入/导出的 `world_id`/`farm_id`；已有导出不回溯重算，尚未验证历史导入目录的去重行为。

## 对抗性审查与处理

独立审查覆盖了六条资金路径的金额与方向、冻结释放、候选提交、检查点淘汰和非法分录面。发现并处理：

- **高：自成交带价差时整轮撮合失败。** 同一所有者先挂低价卖单再挂高价买单时，成交分录出现两条 `account:<A>` 行，`Ledger.post` 以重复科目拒绝，整个扫描失败。已在 M7-08 商人流动性切片中按科目合并借方净额修复，并补了回归断言（`MARKET_MATCHING_TEST checks=241`）。
- **中：伪造活跃分录可通过校验。** 只追加一条自平衡分录、不改余额的快照此前会被接受。M8-02 增加 `opening` 期初检查点与等式校验后拒绝。
- **中：`pay` 在命令窗口淘汰后重放会二次转账。** 已记入 ADR-014 §6.1，网络接入前必须补时间窗或耐久付款行；当前没有调用方。
- **低：市场扫描命令淘汰后重试返回与首次不同；`event_id` 不查重。** 后者已由 M8-02 的 `event_id` 唯一性修复；前者无二次记账，记入 ADR-014 §6.1。

## 双平台 CI

`ledger_test` 已登记进 `.github/workflows/rule-tests.yml`；提交 `4567bfe` 的 [Rule fixtures 43681389742](https://github.com/the-lazy-me/yipiantian/actions/runs/43681389742) 两平台均通过：

```text
macOS   ledger_test LEDGER_TEST checks=1817 failures=0
macOS   rule fixtures: 57 listed, 7 skipped for missing art
Windows ledger_test LEDGER_TEST checks=1817 failures=0
Windows rule fixtures: 57 listed, 7 skipped for missing art
```

项目事实已登记进 `rules/project-context.md`（可选 `economy.ledger`、余额权威不变、七类业务分录、旧档期初检查点、格式仍为 27）。
