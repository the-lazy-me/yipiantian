# M8-03 · 保险纯规则

状态：纯规则切片完成（2026-11-16），未验收。范围：保单报价、承保扣费、理赔校验与唯一赔付。不包含世界权威接线、`FarmState` 封装、UI、网络权限、真实损失联调、可选保险的风险定价裁决或 Windows 验证。

权威设计：[ADR-022](../../decisions/ADR-022-insurance-loss-evidence.md)（条件性保单与理赔设计）；前置：[RECORD-03a 运输损失证据](RECORD-03a-transport-loss.md)、[ADR-014](../../decisions/ADR-014-double-entry-ledger.md)、[ADR-017](../../decisions/ADR-017-bank-loans.md)；上游：[M8-03 调查](RECORD-03-insurance.md)、[经济与金融](../../systems/economy-finance.md)、[M8 PLAN](PLAN.md)。

## 结论

1. 世界现在能把“谁、何时、因何、损失了什么、多少价值”的既有 `transport_loss` 行接到唯一理赔上：理赔只读损失行与 shipment 行，不接受玩家自报金额或损失证据。
2. **已发生的损失不能追溯投保**有两道独立闸门：承保要求 `starts_utc >= now_utc`（不能倒签），理赔要求 `policy.starts_utc < loss.cause_start_utc` 且 `loss.cause_end_utc <= policy.ends_utc`（保单必须在损失开始前生效、在损失结束时仍在保）。此外，同一 owner、同商品、同路线且损失窗口结束不早于申请生效时间的已有损失会直接拒绝承保（`loss_already_occurred`）；已在途且与本保单路线/商品相同、出发时间不晚于保单生效的声明风险发货也会被拒（`risk_already_in_transit`）。
3. **同一损失只赔一次**由派生 id 保证：`claim_<loss.sequence>` 与损失行序列一一对应，`claims` 以 claim id 为键，策略行只保存一个 `claim_id`。重放从耐久理赔行返回 `duplicate`，赔付只发生过一次。
4. 保费与赔付都走既有的 `Economy.pay`，是转移而不是销毁或发行：`issued` 不变、`total_cash` 不变、对账通过。准备金来自保费累积的 `@world` 现金；不足时理赔记为 `pending`，不凭空发钱。
5. 保单/理赔表是独立的严格有界文档，**没有**塞进 `Economy.STATE_KEYS`：那会同时破坏所有既有经济文档形状。调用方负责持久化；本切片只提供纯规则函数与校验。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/farm/insurance_state.gd` | 新增。报价、承保、理赔、待赔结算、过期扫描、查询视图、严格文档校验与 JSON 归一化；固定费率、免赔、单保单数量、路线/商品重叠上限、单 owner 单张有效保单。 |
| `tests/insurance_state_test.gd` | 新增 1688 项无头检查：报价边界、承保扣费与分录、追溯投保拒绝、理赔一次与重放、免赔/保额上下界、路线/商品/数量/受害者/时间窗不匹配、策略与理赔表上限、待赔与结算队列、过期后仍按时间窗赔付、JSON/磁盘往返、现金守恒与账本平衡。 |
| `docs/2.0/milestones/M8/RECORD-15-insurance-rules.md` | 本记录。 |

未修改 `economy_state.gd`、`market_state.gd`、`FarmState`、场景、UI、网络、规则、`PLAN.md`、`.github/` 或 `player-guide.md`。农场格式仍为 27，没有新增农场顶层键或经济子文档。

## 规则与数值

```text
COVERAGE_PERMILLE          800      # 保额 = 锁定货值 × 80%
FLAT_DEDUCTIBLE              3 COIN # 免赔额（固定）
PREMIUM_PERMILLE            50      # 保费 = 保额 × 5%，最少 1 COIN
MAX_QUANTITY                64      # 单张保单覆盖数量上限
ROUTE_GOOD_QUANTITY_LIMIT   64      # 同路线+商品重叠时间窗的合计覆盖上限
MIN_TERM_SECONDS          3600      # 最短 1 小时
MAX_TERM_SECONDS       2592000      # 最长 30 天
MAX_POLICIES               128
有效保单                     每 owner 同时最多 1 张
```

- `terms()` 是唯一费率来源：报价、承保与文档校验都用它重算，因此伪造的 `premium`/`coverage`/`deductible` 无法载入。
- 货值只取 `EconomyCatalog.base_price(good)`；没有参考价的商品（当前 6 种之外）直接 `invalid_good`。
- 免赔固定 3 COIN，所以“免赔”和“保额”两种边界都真实存在：1 篮青菜（货值 6）赔付 3（免赔下界），6 篮青菜（货值 36）赔付保额 28（保额上界）。
- `payout = min(coverage, max(0, assessed_value - deductible))`，`assessed_value = base_price × loss.quantity`。

## 数据形状

```text
insurance = { policies: {policy_id: policy}, claims: {claim_id: claim} }
policy = {
  policy_id, owner, route, good, quantity_covered, premium, coverage,
  deductible, starts_utc, ends_utc, status, claim_id
}
claim = {
  id, policy_id, owner, loss_id, assessed_value, coverage, deductible,
  payout, created_utc, paid_utc, status
}
route   = "<origin>><destination>"    # 例如 "farm_market>harbor_market"
policy.status ∈ { active, expired, claimed }
claim.status  ∈ { pending, paid }
```

- 键集严格：多一个键、少一个键都拒绝载入。
- `claim.id == "claim_" + loss.sequence`，`loss_id == "loss_" + loss.sequence`；带前导零的变体不是同一个 id。
- 策略与理赔 id 共享事件 id 空间：两者之间不得重名，也不得落在 `Ledger.RESERVED_EVENT_PREFIXES`；本模块另行保留 `claim_`/`loss_` 前缀，调用方不能把策略 id 取成这两类。
- 策略 id 同时是保费支付的命令 id，理赔 id 同时是赔付的命令 id。若该 id 已在经济命令窗口中，承保/理赔返回 `id_in_use`，避免“支付被重放、策略却真的写入”。
- `valid()` 交叉校验：策略 ↔ 理赔双向引用、同一损失只有一条理赔、claimed 策略必须有对应理赔、非 claimed 策略不得带 `claim_id`、同 owner 不得两张 active、同路线+商品重叠窗口的合计覆盖不得超过上限、理赔表不得大于策略表。

## 接口

```text
Insurance.quote(route, good, quantity, starts_utc, ends_utc, now_utc)
Insurance.underwrite(economy, insurance, policy_id, owner, route, good,
                     quantity, starts_utc, ends_utc, now_utc)
Insurance.claim(economy, insurance, claim_id, policy_id, loss_id, now_utc)
Insurance.settle_claims(economy, insurance, now_utc)
Insurance.expire(insurance, now_utc)
Insurance.policy / policies / claim_row / claims
Insurance.valid(insurance) / normalize(insurance) / initial_state()
```

- `underwrite` 成功时用 `policy_id` 作 event id 从 owner 扣保费到 `@world`；同 id 同参数重放返回原结果，同 id 不同参数返回 `command_conflict`。
- `claim` 只接受 `economy.losses` 中的真实行；`loss.kind` 必须是 `transport_loss`，证据行缺失、路线无法从 shipment 行确认（已被归档）时拒绝而不是假设。
- `settle_claims` 按 `created_utc, id` 顺序尝试待赔；资金不足的大额理赔被跳过且保持 `pending`，后续小额理赔仍可正常赔付。
- `expire` 只改状态标签；覆盖资格始终由时间戳判断，不依赖标签。

## 会计

```text
保费  借 account:<owner>        贷 account:@world   （Economy.pay）
赔付  借 account:@world         贷 account:<owner>   （Economy.pay）
```

两条都用现有 `pay` 分录：`issued` 不变，`total_cash == issued` 仍成立，`reconcile()` 通过。准备金只来自 `@world` 已收保费，不足时记 `pending`，不发行新钱。

## 实测输出

隔离目录、无头 Godot 4.7.2：

```text
INSURANCE_STATE_TEST checks=1688 failures=0
```

同工作树关联回归（未修改这些模块，仅确认未破坏）：

```text
LOAN_TEST checks=1885 failures=0
LEDGER_TEST checks=1841 failures=0
MARKET_LOGISTICS_TEST checks=1274 failures=0
```

关键观测（夹具）：

| 观测 | 结果 |
|---|---|
| 2 篮青菜报价 | 货值 12、保额 9、免赔 3、保费 1 |
| 承保后现金 | owner 120→119、`@world` 0→1、`issued` 与 `total_cash` 不变 |
| 保费分录 | 一条平衡 `pay`：owner −1、`@world` +1 |
| 承保重放 / 冲突重放 | 分别返回原结果 / `command_conflict`，现金与表均不变 |
| 先损失后投保 | `loss_already_occurred`；损失之后才生效的保单允许，但旧损失仍无法理赔（`not_in_force`） |
| 已在途发货后再投保 | `risk_already_in_transit` |
| 1 篮青菜损失 | 赔付 3（免赔下界，未触保额） |
| 6 篮青菜损失 | 赔付 28（保额上界） |
| 2 篮青菜损失 | 赔付 9；owner +9、`@world` −9、`issued` 不变 |
| 同 loss 重放 | `duplicate=true` 且金额相同，不再赔付 |
| 同一保单第二条损失 | `policy_claimed` |
| 路线/商品/数量/受害者不匹配 | 分别 `route_mismatch`/`good_mismatch`/`quantity_exceeded`/`not_victim` |
| 池不足 | 记 `pending`、`paid_utc=0`、现金不变；补足后 `settle_claims` 一次付清 |
| 队列跳过大额 | 大额保持 `pending`，小额 `paid` |
| 文档篡改 | 保费/保额/赔付/损失引用/双向链接/双 active/超重叠上限/未知键/未知状态/`@world` 作 owner 均拒绝 |
| 磁盘往返 | JSON 写读后归一化结果与内存逐字段相等，重放仍为 duplicate |
| 过期后再理赔 | 损失仍在窗口内，`expired` 标签不阻止赔付，`paid_utc` 记理赔时刻 |
| 表满 | `policy_limit` 拒绝且不扣保费；理赔表不得超过策略表 |

## 未覆盖

- **世界权威接线**：`Game/world/headless_world.gd` 没有 `settle_economy()` 的保险分支，也没有保险 sidecar 的读取、保存、摘要或广播；仅损失结算后不会自动理赔。`FarmState` 没有 `economy_underwrite`/`economy_claim` 等候选提交封装。
- **UI/HUD**：没有保险面板、报价展示、理赔入口或准备金显示。
- **网络权限**：承保/理赔没有 WorldHost 角色权限表条目，成员提交路径未接入；`claim_<n>` 与 `loss_<n>` 的保留前缀也没有在网络层登记。
- **真实运输损失联调**：夹具用直接构造的 economy/bags 驱动 `Market.ship`/`deliver`，没有跑真实世界扫描、真实存档或跨客户端会话；没有验证损失行归档（256 行淘汰）与尚未理赔的损失之间的关系。ADR-022 要求“待赔损失不能被淘汰”，本切片**未**解决该边界：丢失的损失行会让理赔变成 `unknown_loss`，需要世界侧在归档前绑定或保留待赔行。
- **可选保险定价语义**：ADR-022 指出的“只给注定损失对象投保”套利仍未裁决。本切片的固定费率（8/3/5%）是实验值，不能作为已批准的市场定价。当前规则靠“损失窗口必须整体落在保单窗口内”阻止追溯，但无法阻止客户端在已知确定性损失结果后只为该次发货投保。
- **保单形状与 ADR 草案的差异**：ADR-022 的条件性设计使用 `product/subject_type/subject_id/coverage_limit/remaining_coverage/exclusions/rule_version` 并要求“运输保单在发货前绑定 shipment_id”。本切片按任务给定的严格键集实现，不绑定具体 shipment，而是用路线+商品+数量+时间窗约束；`remaining_coverage` 由“一张保单只赔一次”取代。若后续要一保单多次赔付，需要新增额度扣减与新的唯一性论证。
- **`reserve_statement.claims`**：仍固定为 0。本切片没有把保险表接入经济文档，因此准备金报告不会显示 `insurance_cash`、`claims_pending` 或 `claims_paid`。
- **灾害作物损失**：ADR-022 的 P0-B 与风险模式仍未实现。
- **平台**：只在本机 macOS 无头运行，未验证 Windows、CI、真实存档或共享世界。
