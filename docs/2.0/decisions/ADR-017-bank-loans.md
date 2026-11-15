# ADR-017 · 规则银行与固定费用简单贷款

- 状态：采纳（2026-11-15），M8-02 切片实现完成；未验收
- 关联：[M8-02 记录](../milestones/M8/RECORD-02-loans.md)、[经济与金融](../systems/economy-finance.md)、[M8 PLAN](../milestones/M8/PLAN.md)、[ADR-014](ADR-014-double-entry-ledger.md)

## 背景

M8-01 已有逐笔借贷分录、账户/商人/托管余额权威、准备金与对账，但没有负债或有期限的业务合同。M8-02 需要一个能提前报价、不会因长离线无限复利、违约不扣押基本生活的首版银行：银行有真实现金，贷款是合同资产，还款是全额结清，过期只改变状态。

首版不引入存款、复利、抵押物正式化、延期协商、核销、AI 银行家、UI 或网络。

## 决定

### 1. 银行现金是余额权威，资本一次性发行

`economy.bank` 保存 `opened`、`opened_by`、`opened_utc`、`cash`、`capital`。`Economy.open_bank(command_id, now)` 发行固定 `BANK_CAPITAL = 2000 COIN`，写一条 `bank_open` 分录（借 `bank`、贷 `issuance`）；`opened` 与 `command_results` 共同保证同一资本不重复发行。重复调用返回已发行资本（`duplicate=true`），不同 id 也不会二次发行。

银行现金与商人现金、玩家账户、买单托管一样进入 `total_cash` 和逐科目对账；分录仍是证据，不是第二套余额。

旧经济没有 `bank` 时按“未开市、0 现金、0 发行”读取。`Economy.valid` 接受缺失键，恢复时补空形状，不写迁移器、不凭空发行。

### 2. 合同表与边界

`economy.loans` 是有界合同表（`MAX_LOANS = 256`），键为借款命令 id。每行：

```text
id, borrower, principal, fee, due_utc, opened_utc, status, paid, repaid_utc, repay_id
```

- `status` 只取 `open`、`overdue`、`repaid`。
- `id` 同时是借款命令 id；`repay_id` 是首次成功还款命令 id，用于日志淘汰后的幂等。
- 本金 10..1000 COIN；期限只允许 7、14、30 天；金额、时间、id 在权威边界按整数、非负、安全整数校验。
- `fee == ceil(principal × 5%)`，最少 1 COIN；`paid == principal + fee` 或 0。
- 一个借款人同时最多一笔 `open`/`overdue` 合同。

### 3. 报价固定，不随时间增长

`Loans.quote(principal, term, now)` 返回 `{principal, fee, total, due_utc}`，费用只由本金决定，`now` 只移动到期时间。`validate_borrow` 和 `borrow` 只接受报价允许的本金与期限。提款前即可看到全部费用和到期日。

### 4. 借款在同一候选内移动现金与合同

`Loans.borrow` 要求银行已开市、银行现金 ≥ 本金、借款人已开户（`granted`）、无未结清贷款、参数在范围内。成功后同一次候选提交：银行现金减少、借款人账户增加、写 `loan_issue` 分录（借 `account:<borrower>`、贷 `bank`）、记录合同。失败不留下半份余额或合同。

### 5. 全额还款，费用留在银行

`Loans.repay(borrower, loan_id, ...)` 只接受合同借款人或调用方解析出的本人；要求账户可用余额 ≥ `principal + fee`；一次结清。成功后现金从借款人转银行、合同置 `repaid`、写 `loan_repay` 分录（借 `bank`、贷 `account:<borrower>`）。费用不销毁、不发行，留在银行现金中。

### 6. 违约只改状态，不扣押、不核销、不追加费用

`Loans.settle(economy, now)` 确定性扫描：`due_utc <= now` 且 `open` 的合同置为 `overdue`。它不写分录、不改变本金/费用、不扣押住所、建筑或库存、不核销债权。长离线只留下 `overdue`，不会产生无限复利。`overdue` 借款人在结清前不能新借；`overdue` 合同仍可正常全额结清。

### 7. 会计与准备金

新增 `bank` 科目和 `bank_open`、`loan_issue`、`loan_repay` 三种业务事件。每笔分录借贷相等，检查点零和，`issuance - burn == issued == total_cash`。

本切片只有三条银行现金路径，因此有一条可校验的精确等式：

```text
bank.cash == capital - 未结清本金合计 + 已收费用合计
```

`Economy.reconcile` 把银行现金纳入逐科目对账；`reserve_statement` 增加 `bank`、`bank_capital`、`loans_asset`（未结清本金）、`loans`、`loans_overdue`、`loans_repaid`。没有存款，所以 `claims = 0`、`reserve = total_cash`。

### 8. 幂等与候选提交

借款 id 等于合同 id，还款 id 写入合同：命令窗口仍在时回放首次结果，窗口淘汰后合同行仍拒绝二次放款/二次扣款。同一 id 换借款人或金额是 `command_conflict`；已还清合同再次还款是 `already_repaid`。所有命令与合同、余额、分录同进同退。

### 9. 账本完整性硬化

同时补两项 ADR-014 未覆盖的缺口：

- `ledger.opening`：保存活跃日志之外的历史净额，持久不变量为
  `balances[code] == opening.get(code,0) + Σ(活跃分录净额)` 且 `Σ opening == 0`。
  淘汰分录时把其净额加入 `opening`；没有该字段的旧账本按 `opening = balances - Σ活跃净额` 一次性派生；`adopt_ledger` 令 `opening = balances`。仅在 `entries` 追加自平衡分录而不改 `balances` 的伪造状态会被拒绝。
- `event_id` 唯一：活跃日志中重复的事件 id 被 `Ledger.valid` 拒绝，`Ledger.post` 在写入前返回 `duplicate_event`。银行使用业务命令 id，不使用固定前缀，因此不与 `trade_<n>`/`expire_<n>` 冲突。

### 10. 存档

新增键都在现有 `economy` 子文档内。农场格式仍为 27，没有新增农场顶层键，`FarmState._valid_snapshot` 键数与 `V27Importer.KNOWN_FARM_KEYS` 不变。缺失 `bank`/`loans` 的旧经济可读；恢复时归一化 JSON 数字并补空形状。

## 为什么不是另一侧

- **不建第二套余额**：银行现金必须和账户、商人、托管一起被 `total_cash` 与检查点解释，第二套钱包无法证明权威。
- **不做复利或按日计费**：长离线会把一次借款放大成不可恢复的债务，直接违背规格。
- **不扣押或核销**：本切片没有正式抵押物与回收流程；扣押基本住所或生活资源超出授权，核销则会在没有资金来源与证据的情况下消灭债权。
- **不把费用销毁**：费用是银行收入，销毁会让银行资本与对账口径失真；`burn` 只保留给成交与运费。
- **不用日志做幂等**：日志有界且会淘汰，合同行与还款 id 才是耐久证据。

## 后果

- 新增 `Game/farm/loan_state.gd`；`Economy` 增加银行、合同、命令入口、对账与准备金扩展；`Ledger` 增加银行科目、三种事件、`opening` 与事件 id 唯一性。
- `FarmState` 未在本切片修改：`economy_bank`、`economy_borrow_loan`、`economy_repay_loan`、`economy_settle_loans` 等薄封装待主会话接入。
- 没有存款、利息复利、抵押物、延期、核销、AI 银行家、UI、网络、Windows 或 CI 变化。
- `bank.cash == capital - loans_asset + fees` 是本切片的强不变量；未来增加银行支出、存款或核销时必须显式修改，不能默默放宽。

## 复审触发条件

出现以下任一情况时重开本裁决：引入存款或银行其他支出、需要抵押物/回收/核销、需要延期协商或浮动费用、真实贷款量级超过 256 条合同、网络接入要求银行命令权限或逐笔确认、或旧经济在没有 `opening` 时无法解释真实存档。
