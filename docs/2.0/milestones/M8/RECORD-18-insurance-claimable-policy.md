# M8-18 · 按损失查询可理赔保单（纯规则）

状态：纯规则切片完成（2026-11-16），未验收。范围：给定一条权威运输损失，按理赔同一套谓词找出可赔付的保单，作为只读查询返回。不含权威自动理赔接线、玩家主动投保的共享写入口、UI、网络权限、Windows。

权威设计：[ADR-022](../../decisions/ADR-022-insurance-loss-evidence.md)；前置：[RECORD-15 保险纯规则](RECORD-15-insurance-rules.md)、[RECORD-03a 运输损失证据](RECORD-03a-transport-loss.md)；上层：[M8 PLAN](PLAN.md)。

## 结论

1. `Insurance.claim()` 原本要求调用方先知道 `policy_id`，权威侧要在“复制一套匹配谓词”与“无法自动理赔”之间二选一。本切片新增只读查询 `Insurance.claimable_policy(economy, insurance, loss_id, now_utc)`，只凭损失 id 就能得到 `{ok, reason, policy_id, claim_id}`。
2. **匹配谓词只有一份**：`claim()` 与新查询都调用内部 `_loss_claim_check(economy, policy_row, loss, now_utc)`。受害者、商品、数量、路线、时间窗、保单状态、损失形状与金额一致性全部在该 helper 内判定，读路径与写路径无法各自漂移。`claim()` 的对外拒绝原因与数值没有变化。
3. 多条候选时的选择是**确定的**：按 `policy_id` 升序取第一条通过谓词的保单。理由是 id 的排序只取决于持久化的拼写，不依赖 `Dictionary` 插入顺序或历史写入顺序；“最早时间窗”是另一条规则，且调用方自选的 id 无法编码它；按表顺序取会让答案随历史变化，重放和跨客户端比较都不可靠。
4. 已理赔的损失不再返回候选：`claims` 中只要存在 `loss_id` 相同的行，查询返回 `already_claimed` 并给出已记录的 `policy_id`/`claim_id`。该分支先于损失行读取，因此**损失行已归档时仍能回答**，不依赖 `loss` 事件存活。
5. 查询是纯读：不写 `economy`、不写 `insurance`，也不使用时钟；`now_utc` 只作为参数参与时间窗判定。
6. 与 `claim()` 一致性的边界也复用：损失已作为命令 id 记录（`id_in_use`）、文档非法（`invalid_state`）、时间非法（`invalid_time`）、损失 id 非规范（`invalid_loss`）都在选保单之前拒绝，避免查询点名一条 `claim()` 实际不会支付的保单。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/farm/insurance_state.gd` | 抽出共享谓词 `_loss_claim_check`；`claim()` 改为调用它（行为不变）；新增 `claimable_policy` 与 `_claimable_error`。 |
| `tests/insurance_state_test.gd` | 新增 1362 项无头检查（3050 − 1688）：唯一匹配、各拒绝原因、确定性选择、已理赔/待赔/已归档损失、非法输入失败关闭、入参不被修改、与 `claim()` 结论一致。 |
| `docs/2.0/milestones/M8/RECORD-18-insurance-claimable-policy.md` | 本记录。 |

未修改 `Game/world/**`、`economy_state.gd`、`market_state.gd`、`farm_command.gd`、`world_package.gd`、`world_transfer.gd`、场景、UI 与 `.github/`；没有新增或改动持久化字段。

## 接口

```text
Insurance.claimable_policy(economy, insurance, loss_id, now_utc)
  -> {ok, reason, policy_id, claim_id}
```

拒绝原因：

```text
invalid_state      insurance 文档不合法
invalid_time       now_utc 非法
invalid_loss       loss_id 不在规范的 loss_<n> 序列命名空间
unknown_loss       economy 中没有该损失事件
id_in_use          claim_<n> 已作为经济命令 id 记录
already_claimed    该 loss_id 已有理赔行（待赔或已赔）
no_policy          没有任何保单通过谓词（且无候选可给出更具体原因）
not_victim / good_mismatch / quantity_exceeded / shipment_missing /
route_mismatch / claim_before_loss / not_in_force / invalid_loss /
policy_claimed / policy_inactive
                   与 claim() 完全相同的单条保单拒绝原因
```

- `already_claimed` 是查询新增的聚合拒绝；`claim()` 在等价场景返回 `duplicate`（同 policy/loss 重放）或 `command_conflict`/`policy_claimed`，两者语义不冲突：查询回答“现在还能否自动发起理赔”，写入回答“这次命令是什么结果”。
- 多条候选且全部被拒时，返回**最小 `policy_id` 那条保单的原因**，保证同一输入稳定给出同一答案。只有一条候选时，该原因与 `claim()` 对该保单的原因逐字相同。

## 一致性论证

| 检查 | `claim()` | `claimable_policy()` |
|---|---|---|
| 文档/时间/损失 id 校验 | 有 | 有 |
| 理赔行重放守卫 | 按 `claim_id` 查 | 按 `loss_id` 查（先于损失行） |
| `claim_<loss.sequence>` 派生 | 有 | 有 |
| 已用命令 id | `id_in_use` | `id_in_use` |
| 保单存在性 | `unknown_policy` | 无候选则 `no_policy` |
| 匹配谓词 | `_loss_claim_check` | `_loss_claim_check` |

## 测试

```text
INSURANCE_STATE_TEST checks=3050 failures=0
FONT_COVERAGE_TEST checks=1272 failures=0 missing=0
```

`claimable_policy` 覆盖：

- 唯一匹配：返回该保单与派生 `claim_id`，再交给 `claim()` 原样成功。
- 拒绝原因各一：`invalid_state`、`invalid_time`、`invalid_loss`、`unknown_loss`、`no_policy`、`not_victim`、`good_mismatch`、`quantity_exceeded`、`route_mismatch`、`shipment_missing`、`claim_before_loss`、`not_in_force`、损失种类非法、损失金额与目录不一致、`id_in_use`。
- 确定性选择：两张 `expired` 保单重叠同一损失窗口，插入顺序为 `policy-b`、`policy-a`，查询返回 `policy-a`；重复查询答案不变；`claim()` 用该 id 成功。
- 已赔/待赔：两种状态都返回 `already_claimed`；删掉 `loss_1` 事件行后仍从 `claims` 回答。
- 非法输入失败关闭：空 economy 返回 `unknown_loss`，空 insurance 返回 `invalid_state`，`now_utc=-1` 返回 `invalid_time`，非规范损失 id 返回 `invalid_loss`。
- 入参不变：成功与拒绝路径都对 `economy`/`insurance` 做深拷贝前后比较。
- 与 `claim()` 一致：六个场景（匹配、`not_in_force`、`good_mismatch`、`quantity_exceeded`、`route_mismatch`、`claim_before_loss`）逐项比较 `ok` 与 `reason`，另加 `not_victim`。

## 未覆盖

- **权威自动理赔接线**：`Game/world/headless_world.gd` 仍没有在损失结算后调用本查询，也没有保险 sidecar 的读取、保存、摘要或广播。本切片只提供可被该接线调用的纯查询。
- **玩家主动投保的共享写入口**：本切片**不做**。ADR-022 的固定保费套利问题尚未裁决：世界从持久种子推导灾害与损失结果，客户端也能推导，因此可以“只给即将受灾的对象投保”。在风险信息可见性与定价语义决定之前，开放共享写入口等于把套利做成协议。若将来要开写入口，必须先决定两件事：(1) 投保时客户端能看到哪些风险信息、由谁裁定可保范围；(2) 固定费率、按风险定价或事后追缴之间选哪一种，以及对应的重放与审计语义。当前 `underwrite` 只作为规则函数存在，没有命令/网络入口。
- **候选选择的业务优先级**：按 `policy_id` 升序是确定性与可重放优先的规则，不代表经济上最优（例如“先到期先赔”或“覆盖不足者优先”）。若将来需要业务排序，必须先把它写成持久化可重放的字段，而不是依赖内存顺序。
- **多保单分摊**：一条损失仍只由一张保单赔付；不做按保额比例分摊或超额再保。
- **UI/网络/平台**：没有面板展示查询结果，没有 WorldHost 权限条目，未在 Windows 或 CI 实机验证。
