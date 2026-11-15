# RECORD-07 · 居民角色权限矩阵（M10-04 第一切片）

- 状态：实现完成（2026-11-15），纯规则；未接网络、未写存档、未调用模型
- 范围：M10-04“扩展角色与社会事件”的第一个切片

## 问题

M10-02 已给三名居民稳定身份、性格与初始记忆，但居民没有任何“能做什么”的
规则边界。继续扩展社会事件前，必须先回答：商人、银行家、官员分别可以提交
哪些既有经济/治理动作；单笔与周期内最多多少；模型生成的叙述若声称“我把
市场送给你”“批准一笔贷款”，规则是否照办。

本切片只建立角色动作准入矩阵，不实现账户、订单、贷款或权属记账，也不改变
现有世界、经济或农场文档。

## 边界

- **纯规则**：`Game/npc/npc_roles.gd` 只有静态入口，不读 RNG、系统时钟、磁盘、
  场景或网络，不持有可变状态，不写存档。
- **身份仍来自连接**：ADR-019 规定付款人、借款人、订单所有者只能由权威从
  连接解析并以 `actor` 绑定。本模块不接收身份字段，角色不是连接身份，返回
  `ok=true` 也不构成权属、余额或账户证明；它只是 `WorldHost` / `FarmCommand`
  前置过滤。
- **不记账**：不在本模块扣款、开单、放贷、改合同或改权属；这些仍由既有
  经济规则处理。
- **叙事不是权限来源**：`claim_from_narrative()` 无论角色是否存在、声明什么
  动作，都返回 `ok=false, reason="not_authority", authority=false,
  proposal_only=true`。模型输出只能作为提案，必须再走规则与权威提交路径。

## 权限矩阵

白名单只引用 `Game/farm/farm_command.gd` 的既有 kind 常量，未知 kind 一律
拒绝。`market_deliver` 是权威扫描，`loan_borrow` / `loan_repay` 是借款人本人
的合同路径，均不列入角色白名单。

| 命令 kind | merchant（阿舟） | banker（许伯） | official（林婶） |
|---|---|---|---|
| `account_open` | 允许 | 允许 | 允许 |
| `pay` | 允许 | 允许 | 允许 |
| `market_open` | 允许 | 拒绝 `forbidden_kind` | 拒绝 |
| `market_place` | 允许 | 拒绝 | 拒绝 |
| `market_cancel` | 允许 | 拒绝 | 拒绝 |
| `market_ship` | 允许 | 拒绝 | 拒绝 |
| `bank_open` | 拒绝 | 允许 | 拒绝 |
| `gift` | 拒绝 | 拒绝 | 允许 |
| `market_deliver` | 拒绝（权威扫描） | 拒绝 | 拒绝 |
| `loan_borrow` | 拒绝（本人合同） | 拒绝 | 拒绝 |
| `loan_repay` | 拒绝（本人合同） | 拒绝 | 拒绝 |
| 农活与其它 kind | 拒绝 | 拒绝 | 拒绝 |
| 未知 kind | 拒绝 | 拒绝 | 拒绝 |

名册映射是设定常量，不是随机或模型输出：

| 居民 | 名册 id | 角色 | 设定理由 |
|---|---|---|---|
| 阿舟 | `npc_a_zhou` | `merchant` | 以渡口为家，迎来送往、负责交易 |
| 许伯 | `npc_xu_bo` | `banker` | 在竹汀做竹活并记账理息，掌管钱庄 |
| 林婶 | `npc_lin_shen` | `official` | 在柳岸辈分最高，承担调解与公共事务 |

金额上限（`amount` 为命令主数量：付款按 COIN，市场与礼物按商品数量；无金额
动作传 0）：

| 角色 | 单笔上限 | 周期累计上限 |
|---|---|---|
| `merchant` | 200 | 800 |
| `banker` | 1000 | 2000 |
| `official` | 100 | 300 |

## 规则

### 入口

- `role_of(resident_id)`：居民 → 角色；未知居民或非字符串返回空串。
- `resident_of(role)`：角色 → 居民；与 `role_of()` 互为反查。
- `allowed_kinds(role)`：返回白名单副本；未知角色为空数组。
- `call_limit(role)` / `window_limit(role)`：未知角色返回 0。
- `may_submit(role, command_kind, amount, spent_in_window, now_utc, window)`：
  返回 `{ok, reason}`；成功时另带 `role`、`kind`、`bucket`、`remaining`。
- `window_bucket(now_utc, window)`：按传入时刻确定性分桶，只作为调用者的
  窗口键，不保存累计值。
- `claim_from_narrative(role, claimed_action)`：永远 `not_authority`。

### 判定顺序与失败原因

固定顺序：`unknown_role` → `forbidden_kind` → `invalid_amount` →
`invalid_time` → `unknown_window` → `limit_per_call` → `limit_window`。

- `unknown_role`：角色不在 `merchant` / `banker` / `official` 中。
- `forbidden_kind`：kind 不在 `FarmCommand.KINDS`，或不在该角色白名单。
- `invalid_amount`：`amount` 或 `spent_in_window` 非数字、非有限、负数或非整数。
- `invalid_time`：`now_utc` 非数字、非有限、负数或超过安全整数。
- `unknown_window`：`window` 不是 `hour` / `day`。
- `limit_per_call`：`amount` 大于角色单笔上限。
- `limit_window`：`spent_in_window` 已越界，或 `spent + amount` 大于累计上限。

### 边界语义

- 金额恰好等于单笔上限通过；超 1 拒绝。
- 窗口累计恰好等于上限通过（`remaining == 0`）；超 1 拒绝。
- 已用满窗口后，无金额动作（`amount == 0`）仍可通过；任何正数量拒绝。
- 窗口只按 `now_utc` 分桶：同一窗口内不同时刻判定一致；跨过边界桶号递增。
- 相同输入始终得到相同结果；拒绝路径同样确定。
- 超出安全整数范围的金额按 `invalid_amount` 拒绝，不做越界整数转换。

## 验证

运行：

```sh
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 120 /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot --headless --path Game --script "$PWD/tests/npc_roles_test.gd"
```

原始末行：

```text
NPC_ROLES_TEST checks=85 failures=0
```

测试不启动世界、不写 `.local/verification` 产物、不接网络，覆盖三角色白名单、
越权、金额与窗口边界、未知角色/命令/时间/窗口、名册映射完整性、确定性、
分桶边界，以及叙事永不授权。

## 未覆盖

- 网络接线与 `WorldHost` 门禁：本切片只提供角色矩阵，尚未接入命令提交路径。
- 角色矩阵与真实账户、订单、贷款、权属记账的联动。
- 官员的纠纷、组织、裁定等治理命令：当前 `FarmCommand` 没有对应 kind，本
  切片不发明命令。
- 窗口累计的持久化：`spent_in_window` 由调用者统计并传入，本模块不保存。
- 居民主动发起动作的 AI/模型决策、关系冲突与长期行为评估（M10-05）。
- UI、存档格式、客户端展示。

## 关联

- [M10 PLAN](PLAN.md) M10-04
- [ADR-019 共享世界经济命令：身份、权限与权威扫描](../../decisions/ADR-019-economy-command-permissions.md)
- [ADR-016 规则商人流动性](../../decisions/ADR-016-merchant-liquidity.md)
- [ADR-017 规则银行与固定费用简单贷款](../../decisions/ADR-017-bank-loans.md)
- [RECORD-02 确定性居民名册](RECORD-02-roster.md)
- `Game/farm/farm_command.gd`：命令 kind 常量与 `is_economy_kind`
- `Game/npc/npc_roles.gd`、`tests/npc_roles_test.gd`
