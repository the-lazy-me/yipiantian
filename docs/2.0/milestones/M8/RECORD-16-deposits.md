# M8-16 · 银行存款与准备金拒绝（纯规则）

状态：切片完成（2026-11-16），未验收。范围：玩家本金存款、全额取款、存款负债进入准备金报告、银行现金不足时具名拒绝、旧文档兼容。不含利息、命令/权威接线、UI、网络、Windows。

权威设计：[ADR-030](../../decisions/ADR-030-bank-deposits.md)；上层规格：[经济与金融](../../systems/economy-finance.md)、[M8 PLAN](PLAN.md)；前置：[ADR-014](../../decisions/ADR-014-double-entry-ledger.md)、[ADR-017](../../decisions/ADR-017-bank-loans.md)。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/farm/deposit_state.gd` | 新增。本金存款/取款、存款文档校验与归一化、负债与单账户本金派生；写时复制，返回 `{ok, reason, amount, duplicate, principal, document}`（`document` 是候选经济文档，调用方仅在 `ok` 时提交），输入对象不被修改。 |
| `Game/farm/ledger_state.gd` | 新增 `deposit_in` / `deposit_out` 两种业务事件，事件 id 使用调用方命令 id，不进保留前缀。 |
| `Game/farm/economy_state.gd` | `STATE_KEYS` 增加 `deposits`、初值、旧档空形状与归一化、`deposit_cash` / `withdraw_deposit` / `deposits_liability` / `deposit_principal`；`_bank_consistent` 加入存款负债；`reconcile` 与 `reserve_statement` 报告 `deposits`；`claims` 变为真实负债，`reserve` 变为银行现金。 |
| `tests/deposit_test.gd` | 新增 236 项无头检查（见下）。 |
| `tests/loan_test.gd` | 一条准备金断言随 `reserve` 语义更新（原本假设 `reserve == total_cash`）。 |
| `docs/2.0/decisions/ADR-030-bank-deposits.md` | 本切片的持久裁决。 |
| `docs/2.0/decisions/ADR-017-bank-loans.md` / `ADR-014-double-entry-ledger.md` | 补存款切片链接，并把“无存款 → claims=0 / reserve=total_cash”改为现状描述。 |
| `.github/workflows/rule-tests.yml` | 纯规则组登记 `deposit_test`。 |

未修改 `FarmState`、`FarmCommand`、世界权威、场景、UI、网络；农场格式仍为 27，`deposits` 只在既有 `economy` 子文档内。

## 规则与数值

```text
MIN_DEPOSIT              10 COIN（单笔下限）
MAX_DEPOSIT            1000 COIN（单笔上限，与贷款本金上限同量级）
MAX_PRINCIPAL          1000 COIN（单账户本金上限）
MAX_DEPOSIT_ACCOUNTS    256 个存款账户
利息                      无（ADR-017 禁止复利/利息，本切片只做本金）
命令窗口                  共用 economy.command_results 的 64 条
```

- 存款：银行已开市、玩家账户存在、账户现金 ≥ 金额、单账户本金不超上限、金额为整数且在范围内。
- 取款：本金 ≥ 金额（正整数）、`bank.cash >= 金额`；任一不满足即具名拒绝，余额不变。
- 拒绝原因：`invalid_command`、`invalid_time`、`invalid_player`、`invalid_amount`、`invalid_deposits`、`not_open`、`unknown_account`、`insufficient`、`deposit_capacity`、`insufficient_reserve`、`command_conflict`、`duplicate_event`。

## 会计

```text
deposit_in    借 bank              贷 account:<player>
deposit_out   借 account:<player>  贷 bank

bank.cash == capital - 未结清本金 + 已收费用 + 存款负债
每笔借贷相等；Σ balances == 0；issuance - burn == issued == total_cash
```

存款和取款都是资金转移，`total_cash` 与 `issued` 不变；存款负债只在报表与银行等式里出现，不是新的账本科目。

## 准备金语义

- `claims` = 存款本金合计（真实负债）；`deposits` 同值，`deposit_accounts` 为账户数。
- `reserve` = `bank.cash`（银行自己的现金），不是所有持有人现金。
- `covered = reserve >= claims`；贷款把银行现金借出后会翻转为 false。
- 准备金不足时取款返回 `insufficient_reserve`：全额支付先到者、保护剩余存款人，不设固定准备金率、不按比例兑付。

## 测试

```text
DEPOSIT_TEST checks=236 failures=0
LEDGER_TEST checks=1841 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/ledger-51205
LOAN_TEST checks=1885 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/loan-53353
ECONOMY_INITIAL_TEST checks=154 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/economy-initial-447189
M8_STRESS_TEST checks=926 failures=0
MARKET_MATCHING_TEST checks=241 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/matching-53984
WORLD_PROJECTION_TEST checks=172 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/world-projection-625483
CHAIN_INTEGRATION_TEST checks=509 failures=0
```

`deposit_test` 覆盖：

- 存入后玩家现金减少、银行现金增加、`total_cash` 与 `issued` 不变，`deposit_in` 分录平衡。
- 部分/全额取出还原，`deposit_out` 分录平衡，行随本金归零删除。
- 两玩家独立；一人取款不影响另一人。
- 同 id 同参数重放返回首次结果且不二次移动；同 id 换参数 `command_conflict`；与 `pay` 共用命令命名空间；窗口淘汰后日志仍阻止重复事件。
- 超额存款/取款、零/负数/小数/字符串/超大数、`@world` 与 `org_` 存款人、保留前缀命令 id、未开户、银行未开、单账户上限全部具名拒绝且状态不变。
- `reserve_statement().claims` 为真实负债，`reserve` 为银行现金；贷款借出现金后 `covered` 翻转。
- 3 名存款人各 100 COIN，银行借出 2040 COIN 后只剩 260 COIN：前两人全额取出（银行剩 60），第 3 人被 `insufficient_reserve` 拒绝且状态不变；拒绝后剩余存款 100 与银行现金 60 的一致性；取款 60（等于剩余现金）仍可支付，剩余 40 作为未备付债权保留而不是透支银行。

  （夹具数值：开行 2000 + 3×100 存款 = 2300；D 借 1000、E 借 900、F 借 140 后银行现金 2300-2040=260；前两人各取 100 后为 60。）
- 无 `deposits` 键的旧文档（开行但未存款）`valid()` 通过并恢复为空表；银行真的持有存款时删键被拒绝。
- JSON 往返与 `restore_snapshot` 后本金/时刻类型正确；重放不二次移动。
- 篡改本金、加行、删表、改银行现金均被 `Economy.valid` 拒绝。

## 未覆盖

- 命令接线（`FarmCommand` / `FarmState` 薄封装 / 世界权威 / 重启幂等策略）——由后续切片完成。
- UI、网络权限、摘要投影；存款视图未加入 ADR-027 投影。
- 利息、到期、保障基金、按比例兑付、挤兑队列、多银行。
- 存款金额与上限是本切片的实验值，未做经济调参；Windows、真实墙钟与 CI 实机未验证。
- 窗口与日志都淘汰后旧存款 id 可能再次移动现金（与 ADR-014 §6.1 的 `pay` 同类），接线前必须补耐久守卫。
