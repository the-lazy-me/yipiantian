# M8-17 · 银行存款与取款命令接线

状态：切片完成（2026-11-16），未验收。范围：把 RECORD-16 的存款纯规则接成正式命令（`bank_deposit` / `bank_withdraw`）、成员权限与命令级测试。不含 UI、RPC 面板、真实网络联调、存款摘要投影与耐久重放守卫。

权威设计：[ADR-030](../../decisions/ADR-030-bank-deposits.md)；前置：[RECORD-16 存款纯规则](RECORD-16-deposits.md)、[ADR-014](../../decisions/ADR-014-double-entry-ledger.md)、[ADR-017](../../decisions/ADR-017-bank-loans.md)；上游：[经济与金融](../../systems/economy-finance.md)、[M8 PLAN](PLAN.md)。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/farm/farm_command.gd` | 新增 `BANK_DEPOSIT` / `BANK_WITHDRAW` 两种 kind，进入 `KINDS` 与 `ECONOMY_KINDS`；`valid()` 要求恰好 4 个键、无身份字段、金额为正整数；`_apply` 分支调用 `FarmState` 包装；`_economy_payload` 绑定金额与 actor；新增 `make_bank_deposit` / `make_bank_withdraw`。 |
| `Game/farm/farm_state.gd` | 新增薄包装 `economy_deposit_cash` / `economy_withdraw_deposit`，以及只读查询 `economy_deposit_principal`。存款规则返回写时复制候选，包装只在 `ok` 且非重放时用 `result.document` 替换 `economy` 子文档。 |
| `Game/world/world_invite.gd` | `PERMISSIONS[MEMBER]` 加入 `bank_deposit` / `bank_withdraw`；`VISITOR` 不变。 |
| `tests/deposit_command_test.gd` | 新增 83 项无头检查（见下）。 |
| `docs/2.0/milestones/M8/RECORD-17-deposit-commands.md` | 本记录。 |

未修改 `headless_world.gd`、`world_host.gd`、`organization_state.gd`、`Game/conflict/**`、场景、UI、`.github/**`。农场格式仍为 27，经济文档形状不变（`deposits` 子文档由 RECORD-16 提供）。

## 接线判定

- `world_host.gd` 对经济命令使用通用判定：`if FarmCommand.is_economy_kind(kind) ... if not WorldInvite.allows(role, kind)`（第 565–573 行）。两种新 kind 同时进入 `ECONOMY_KINDS` 与成员权限表后，权限判定自动生效，无需改动 `world_host.gd`；访客在规则看到命令之前就被 `forbidden` 拒绝。
- `headless_world.execute` 对 `is_economy_kind` 的命令照常提交、保存并广播摘要，存款命令因此与贷款/支付走同一条权威路径。

## 规则与数值

```text
命令形状        {id, kind, amount, at_utc}
身份            actor 恒来自连接；命令中出现 from/from_id/owner/owner_id/payer/borrower 即非法
金额边界        单一来源：Deposits.MIN_DEPOSIT=10、MAX_DEPOSIT=1000、MAX_PRINCIPAL=1000
                bank_deposit  10..1000
                bank_withdraw 1..1000（可从任意正整数开始取，避免留下小于下限的余额）
重放            命令窗口（farm transaction 64 条 / economy.command_results 64 条）+ 实时日志 event_id
```

- 命令边界只校验“正整数形状”，不复制业务上限；越界金额仍进入规则并得到具名 `invalid_amount`，因此上下限只有 `deposit_state.gd` 一个来源。
- 既有拒绝原因原样透传：`invalid_amount`、`not_open`、`unknown_account`、`insufficient`、`deposit_capacity`、`insufficient_reserve`、`command_conflict`、`duplicate_event`。

## 测试

```text
DEPOSIT_COMMAND_TEST checks=83 failures=0
DEPOSIT_TEST checks=236 failures=0
FARM_COMMAND_TEST checks=136 failures=0
M4_ECONOMY_COMMANDS_TEST checks=169 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/m4-economy-commands-593508
WORLD_INVITE_TEST checks=33 failures=0
FONT_COVERAGE_TEST checks=1272 failures=0 missing=0
```

`deposit_command_test` 覆盖：

- 两种 kind 进入 `KINDS` / `ECONOMY_KINDS`；命令恰为 4 个键；六个身份字段逐个注入均判非法；零/负数/小数/字符串/NaN/INF 金额被边界拒绝；越界但形状合法的金额仍进入规则（证明没有第二套上限）。
- 真实 `FarmState` + `FarmCommand`：开户 → 开行 → 存入 100 后玩家现金 120→20、银行现金 `BANK_CAPITAL+100`、`deposit_in` 分录平衡；取出 40 后余额与银行现金同步回落、`deposit_out` 分录平衡；取空后行删除、双方余额精确还原。
- 具名拒绝：低于下限、高于单笔上限、超过账户现金、未开户（存/取）、无本金取款、超过本金、超过 `MAX_PRINCIPAL`、保留前缀命令 id、空 actor、银行未开（存/取）、单账户本金上限 `deposit_capacity`；每次拒绝后经济快照逐字节不变。
- 同一 command id 重放返回首次结果、无候选提交、快照不变；换金额 `command_conflict`；另一玩家复用同一 id 也是 `command_conflict`（payload 绑定 actor）。
- `total_cash == issued`、`reconcile()` 与银行等式在存取后保持；访客角色两种 kind 均不允许，成员均允许。

## 未覆盖

- UI 与银行面板：存款/取款按钮、余额与准备金展示、拒绝原因提示未接。
- RPC/网络面板与真实网络联调：仅验证 `WorldInvite.allows` 的角色表与 `world_host` 的通用判定，未跑多端联机。
- `world_host._reason_text` 尚无 `deposit_capacity` / `insufficient_reserve` / `invalid_deposits` 的中文文案，这些原因目前回落到“操作没有完成：<reason>”；该文件由并行工作占用，本次未改。
- 耐久重放守卫：命令窗口与实时日志都淘汰后，旧存款 id 仍可能再次移动现金（与 ADR-014 §6.1 的 `pay` 同类），RECORD-16 已记录，本切片未新增账户级序号护栏。
- ADR-027 摘要投影未加入 `deposits`，成员端看不到自己的存款本金。
- 存款金额/上限仍为实验值，未做经济调参；Windows 与 CI 实机未验证。
