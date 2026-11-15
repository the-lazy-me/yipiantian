# M8-02 · 规则银行与简单贷款

状态：已实现（2026-11-15），未验收。范围：一次性银行资本、固定期限固定费用贷款、全额还款、确定性违约状态，以及账本期初检查点与事件 id 唯一性硬化。不包含存款、复利、抵押物正式化、延期协商、核销、AI 银行家、UI、网络或 Windows/CI 变化。

权威设计：[ADR-017](../../decisions/ADR-017-bank-loans.md)；上层规格：[经济与金融](../../systems/economy-finance.md)、[M8 PLAN](PLAN.md)；前置：[ADR-014](../../decisions/ADR-014-double-entry-ledger.md)。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/farm/ledger_state.gd` | 新增 `bank` 科目与 `bank_open`/`loan_issue`/`loan_repay`；新增持久 `opening` 期初净额、淘汰时把净额移入 `opening`、旧账本派生；新增活跃事件 id 唯一性校验与 `duplicate_event`。 |
| `Game/farm/loan_state.gd` | 新增。报价、借款、还款、违约扫描、合同校验、准备金银行/贷款视图；本金 10..1000，7/14/30 天，5% 向上取整、最少 1 COIN，最多 256 条合同，一人一笔在贷。 |
| `Game/farm/economy_state.gd` | 新增 `bank`/`loans` 子文档、`open_bank`、贷款命令入口、旧档空形状、JSON 归一化、银行现金对账与准备金扩展；银行现金守恒等式纳入 `valid`。 |
| `tests/loan_test.gd` | 新增 1871 项无头检查：报价、开行、借款、一笔在贷、未开户、银行现金不足、越界、还款、重复命令、违约与 365 天离线、旧经济、JSON/磁盘恢复、对账与准备金、篡改、淘汰后耐久 id、`opening` 与事件 id 硬化。 |
| `docs/2.0/decisions/ADR-017-bank-loans.md` | 本切片的持久裁决。 |
| `docs/2.0/milestones/M8/RECORD-02-loans.md` | 本记录。 |

未修改 `FarmState`、`market_state.gd`、场景、UI、工作流、规则或 `PLAN.md`；决策入口 `decisions/README.md` 由主会话统一登记。农场上限格式仍为 27，无新增农场顶层键。

**FarmState 封装待主会话接入**：本切片只提供 `Economy.open_bank`、`Economy.borrow_loan`、`Economy.repay_loan`、`Economy.settle_loans` 与查询视图；`economy_bank`、`economy_loans`、`economy_borrow_loan` 等 `FarmState` 薄封装尚未接入。

## 规则与数值

```text
BANK_CAPITAL     2000 COIN（一次性发行）
MIN_PRINCIPAL      10 COIN
MAX_PRINCIPAL    1000 COIN
TERMS            7 / 14 / 30 天
FEE_RATE          5%（向上取整，最少 1 COIN）
MAX_LOANS         256 条合同
在贷上限          每人 1 笔 open/overdue
```

- 报价：`fee = ceil(principal × 5%)`，最少 1；`total = principal + fee`；`due = now + term`。费用不随时间增长。
- 借款：银行已开市、银行现金 ≥ 本金、借款人已开户、无未结清贷款、参数在范围内；同一次候选写余额、合同和 `loan_issue` 分录。
- 还款：仅借款人本人；可用余额 ≥ `principal + fee`；一次结清；写 `loan_repay` 分录；费用留在银行。
- 违约：`due_utc <= now` 且 `open` → `overdue`；不追加费用、不扣押、不核销；`overdue` 阻止新借但允许结清。

## 命令与接口

```text
Economy.open_bank(state, id, now)                      # 一次性资本 + bank_open
Loans.quote(principal, term, now)                      # {principal, fee, total, due_utc}
Loans.validate_borrow(economy, borrower, principal, term, now)
Loans.borrow(economy, borrower, principal, term, id, now)
Loans.repay(economy, borrower, loan_id, id, now)
Loans.settle(economy, now)                             # {count, overdue}
Economy.borrow_loan / repay_loan / settle_loans        # FarmState 封装前的入口
Economy.bank_snapshot / banks / loan / loans_snapshot
```

`FarmState` 之后只需把上述入口包成与 `economy_pay` 相同的候选提交；业务规则不需要复制。

## 会计

```text
bank_open    借 bank 2000             贷 issuance 2000
loan_issue   借 account:<borrower>    贷 bank（本金）
loan_repay   借 bank（本金+费用）     贷 account:<borrower>
```

新增 `bank` 科目；`bank.cash` 是银行真实现金。分录仍只做证据，余额权威不变。

```text
每笔借贷相等
Σ balances == 0
issuance - burn == issued == total_cash
bank.cash == capital - 未结清本金合计 + 已收费用合计
```

最后一条在本切片只有开行、放款、还款三条银行现金路径时精确成立；`Economy.valid` 会拒绝违反它的快照。

## 账本完整性硬化

1. **期初检查点**：`ledger.opening` 保存活跃日志之外的历史净额。
   - 不变量：`balances[code] == opening.get(code,0) + Σ(活跃分录该科目 debit − credit)`，且 `Σ opening == 0`。
   - 淘汰一条分录时把其净额加入 `opening`；没有 `opening` 的旧账本按 `opening = balances − Σ活跃净额` 派生；`adopt_ledger` 令 `opening = balances`。
   - 篡改用例：追加一条自平衡分录但不改 `balances`，被 `Ledger.valid` 与 `Economy.valid` 拒绝。
2. **事件 id 唯一**：`Ledger.valid` 拒绝活跃日志中重复的 `event_id`；`Ledger.post` 写入前返回 `duplicate_event`。篡改用例在余额同步移动、零和仍成立时插入重复 `event_id`，仍被拒绝；正常命令 id 与 `trade_<n>`/`expire_<n>` 不冲突。

## 测试

原始输出行（无头、隔离目录；`root` 为各次运行的实际临时目录）：

```text
LOAN_TEST checks=1871 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/loan-44516
LEDGER_TEST checks=1841 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/ledger-44918
ECONOMY_INITIAL_TEST checks=154 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/economy-initial-286346
MARKET_ORDERS_TEST checks=191 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/market-orders-45450
MARKET_MATCHING_TEST checks=241 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/matching-45513
MARKET_LOGISTICS_TEST checks=174 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/logistics-45569
MARKET_SUPPLY_DEMAND_TEST checks=1220 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/supply-demand-45638
```

`loan_test` 覆盖：固定费用不随 `now` 增长；开行幂等；借款后银行现金/借款人余额/分录/合同一致；一笔在贷、未开户、银行现金不足、越界本金/期限、due 溢出拒绝且状态不变；全额还款与重复命令；到期扫描、365 天离线费用不变、overdue 阻止新借、结清后恢复；旧经济开行；JSON + `FarmStore` 往返；`reconcile` 与 `reserve_statement`；余额/合同/银行/检查点篡改；600 笔转账淘汰日志后合同与耐久 id；`opening` 派生与事件 id 重复。

## 守恒数据

测试夹具（4 个 120 COIN 开户）：

| 时点 | issued | total_cash | bank.cash | 借款人现金 | 未结清本金 | 费用累计 |
|---|---:|---:|---:|---:|---:|---:|
| 开行前 | 480 | 480 | 0 | 120 | 0 | 0 |
| 开行后 | 2480 | 2480 | 2000 | 120 | 0 | 0 |
| 借 50 | 2480 | 2480 | 1950 | 170 | 50 | 0 |
| 到期 365 天后 | 2480 | 2480 | 1950 | 170 | 50 | 0 |
| 结清 53 | 2480 | 2480 | 2003 | 117 | 0 | 3 |

- 每行 `issuance - burn == issued == total_cash` 成立。
- 结清后 `bank.cash == capital - 0 + 3` 成立。
- 600 笔 1 COIN 往返后双方余额回到 120/120，`Σ opening == 0`，`reconcile` 仍通过。

## 与现有规则的交互风险

- **账本事件 id**：新唯一性会让固定前缀事件与同名用户命令 id 冲突时拒绝写入。现有市场命令没有使用 `trade_<n>`/`expire_<n>` 作为用户 id；未来 UI/网络若允许此类 id，需要在命令入口先黑名单或改名。
- **`opening` 与淘汰**：`Ledger.post` 现在每次满 512 条时排序并搬移最旧分录净额。行为仍是确定性的，但单次写入成本从常数变为 O(512 log 512)；当前锁页规模下可接受。
- **银行不变量**：`bank.cash == capital - loans_asset + fees` 是精确等式。未来若允许银行支出、存款或核销，必须同时更新 `Economy.valid`、`reserve_statement` 与本记录，否则合法新状态会被拒绝。
- **市场与银行共用命令窗口**：贷款命令和 `pay`/市场命令共用 64 条 `economy.command_results`；合同行与 `repay_id` 承担淘汰后的借款/还款幂等，不依赖窗口。
- **FarmState 未接入**：在薄封装完成前，UI/网络不能直接调用贷款；测试通过 `Economy`/`Loans` 候选入口并走 `restore_snapshot` 验证边界。

## 未覆盖

存款、利息复利、抵押物正式化、延期协商、核销、AI 银行家、银行支出、UI/HUD、网络命令权限、Windows 实机、CI 工作流、真实旧存档样本、银行流动性压力模拟（集中提款/低收成）与 M8-03 保险。
