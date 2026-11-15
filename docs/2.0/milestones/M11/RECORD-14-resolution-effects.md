# M11-03 · 规则决议效果纯规则切片

执行日期：2026-11-16。状态：切片完成，不表示 M11-03 或 M11 验收完成。前置：[M11 PLAN](PLAN.md)、[领土政治、私兵与法律](../../systems/politics-conflict-law.md)、[动态交易市场、银行与公共金融](../../systems/economy-finance.md)、[RECORD-05 · 规则决议](RECORD-05-resolutions.md)、[RECORD-12 · 规则决议权威](RECORD-12-resolutions-authority.md)。

## 问题

RECORD-05 冻结了决议的生命周期与版本，RECORD-12 把决议接进了世界权威，但 `kind` 仍然只是两个标签：设计文档要求“税费需预告，不能暗中扣除玩家既有资产”和“公共建设先形成预算、决策和支出权限”，而此前没有任何模块把已生效的决议换算成可计算的税费与折减。若把换算散落在命令处理器、经济结算或界面里，撤销后的规则会继续扣税、未生效的提案会提前打折、同一条规则可能被重复应用，而且很容易顺手从既有余额扣除。

本切片只做效果换算的纯规则层。它同时接收**效果文档**与**决议文档**，所有时刻由调用方传入，不接经济、账本、农场、存档、网络、界面或系统时钟。

## 边界

- 新增 `Game/world/resolution_effects.gd`、`tests/resolution_effects_test.gd` 与本记录。
- 未修改 `Game/world/**` 中任何既有模块（包括 `resolution_state.gd` 与 `resolutions_store.gd`）、`Game/farm/**`、`Game/scenes/**`、`.github/`、`rules/`、任何 `PLAN.md` 或文档索引。
- 无 RNG、无系统时钟、无磁盘、无场景、无网络；同一命令序列得到同一文档。
- 不写 ADR：本切片只实现既有设计文档已经要求的预告与折减，没有新的长期决策。
- 不执行任何真实扣款、转账、会计分录或余额修改；不创建持久化 sidecar；不接线 `HeadlessWorld`。

## 文档形状

```text
{
  "applied_version": 0,
  "applied": [
    {"resolution_id": "tax_1", "version": 1, "kind": "tax",
     "at_utc": 1800007260.0},
  ],
}
```

顶层恰好两个键，记录恰好四个键，未知键一律拒绝。

- `applied_version` 是**应用水位**：生效版本不大于它的决议视为已应用。水位单调前进，不会被记录淘汰回退，因此重放旧命令不会第二次产生效果。
- `applied` 是有界应用记录，最多 `MAX_APPLIED = 64` 行；超过时淘汰 `at_utc` 最早的一行（同刻按版本号，再按位置，保证确定性）。
- 记录按 `version` 严格递增且不超过水位。`kind` 保存决议类型（`public_works` / `tax`），不是效果类型。

效果文档必须与决议文档一致：水位不超过决议的 `rules_version`，仍保留的每条记录都要对应同一决议行上相同的 `kind` 和 `effective_version`。不一致按 `invalid_state` 拒绝，避免把别人的决议或过期版本误当成本世界的效果。

## 规则

### 效果来源

只有同时满足以下条件的决议产生效果：

1. 决议文档通过 `ResolutionState.valid()`，效果文档通过本模块 `valid()`，且两者一致。
2. 决议行 `status == effective`。
3. 该决议的生效版本已经被登记进 `applied`（或已低于水位被淘汰）。

未生效、已否决、已撤案、已撤销的决议都不产生效果。已撤销决议不再被 `ResolutionState.is_effective_at()` 认可，因此撤销即刻让后续查询归零，不追溯重算撤销前的收益。

### apply

`apply(state, resolutions, resolution_id, now_utc)` 登记一条决议的效果版本。

按顺序拒绝：

1. 任一文档不合法或两者不一致 -> `invalid_state`。
2. 决议 id 不合法 -> `invalid_resolution`。
3. 决议不存在 -> `unknown_resolution`。
4. 时刻不合法 -> `invalid_time`。
5. 状态不是 `effective` -> `not_active`。
6. `now_utc` 早于 `effective_utc` -> `not_effective`。
7. 版本不大于水位 -> `already_applied`。

成功后追加一条记录、推进水位，必要时淘汰最旧一行。输入文档不被修改。

### 税费

税费**只面向未来收入**，接口不接收也不返回任何既有余额：

- `tax_rate(state, resolutions, at_utc)` 返回 `rate_permille`。每条已应用且在 `at_utc` 有效的税费决议贡献 `TAX_STEP_PERMILLE = 10`；合计超过 `MAX_TAX_PERMILLE = 200` 时返回 `over_rate`，附带实际费率与上限，不做静默截断。
- `tax_for(state, resolutions, amount, at_utc)` 在费率基础上返回 `{rate_permille, amount, tax, net}`。税额用整数计算并向下取整：`amount * rate / 1000`。`amount` 必须是非负安全整数且不超过 `MAX_AMOUNT`，否则 `invalid_amount` / `amount_limit`。

因此调用方只能在处理未来收入时扣取税额，既有余额不会被追溯扣除。费率查询是只读的，可用于提前向成员预告。

### 公共建设

公共建设只提供两个可解释的固定系数，不做通用公式引擎：

| 效果类型 | 常量 | 系数（千分比） |
|---|---|---|
| `public_works_expense` | 公共项目相关支出折减 | 100 |
| `disaster_loss` | 灾害损失折减 | 50 |

`coefficient_for(state, resolutions, kind, at_utc)` 在存在任意一条已应用且在该时刻有效的公共建设决议时返回对应固定系数，否则为 0。**多条公共建设决议不叠加**；未知效果类型返回 `unknown_kind`。系数上界 `MAX_COEFFICIENT_PERMILLE = 500` 只用于常量自检。

### valid

`valid()` 严格校验键集、水位与记录版本为非负安全整数、记录数上限、记录版本严格递增且不超过水位、id 合法、类型属于 `ResolutionState.KINDS`、时刻合法。空文档合法，JSON 往返后合法。

### 具名原因

| 场景 | reason |
|---|---|
| 文档形状、不变式或两文档不一致 | `invalid_state` |
| 决议 id 不合法 | `invalid_resolution` |
| 决议不存在 | `unknown_resolution` |
| 时刻不合法 | `invalid_time` |
| 未知效果类型 | `unknown_kind` |
| 决议未处于生效状态 | `not_active` |
| 未到生效时刻 | `not_effective` |
| 该版本已经应用 | `already_applied` |
| 税费合计费率超过上限 | `over_rate` |
| 收入金额非法 / 超上限 | `invalid_amount` / `amount_limit` |

## 验证

实际运行：

```text
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 180 /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot --headless --path Game --script "$PWD/tests/resolution_effects_test.gd"
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 180 /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot --headless --path Game --script "$PWD/tests/resolution_state_test.gd"
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 300 /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot --headless --path Game --script "$PWD/tests/font_coverage_test.gd"
```

原始末行：

```text
RESOLUTION_EFFECTS_TEST checks=100 failures=0
RESOLUTION_STATE_TEST checks=330 failures=0
FONT_COVERAGE_TEST checks=1273 failures=0 missing=0
```

覆盖：空文档与严格键集、非法水位；未生效/已通过/已否决/已撤案/已撤销/未到生效时刻的决议一律不产生效果；同一版本只应用一次、JSON 往返后仍拒绝重复；撤销后费率归零；税费只由给定收益计算（小额向下取整、零收入、非法与超限金额）、两条税费决议合计、公共建设不计入税费；公共建设两个固定系数、生效前为零、多条不叠加、撤销后按剩余决议归零；费率恰好到达上限与超限 `over_rate`；应用记录上限与按时间淘汰；一致性拒绝；输入不变性、查询不改文档、同一序列同一 JSON。字体子集未扩充，新增中文注释用字全部包含在现役子集中。

## 未覆盖

- **未接权威与经济**：`HeadlessWorld` 不加载效果文档，`execute_resolution()` 不调用 `apply()`，真实收入结算也还没有接入 `tax_for()`。本切片只返回候选文档与计算结果。
- **没有持久化**：效果文档没有 sidecar。接权威时需要与 `resolutions.json` 同批原子保存，并处理“决议已生效但效果未应用”的重启补齐；`applied_version` 正是为这种幂等补齐准备的水位。
- **应用顺序由调用方保证**：水位是全局的，`apply()` 必须按决议生效版本递增的顺序调用。若先应用版本 2 再补应用版本 1，后者会被水位判为 `already_applied`。权威接线时应在每次 `activate()` 成功后立即应用；乱序补齐需要单独的记录匹配策略。
- **税费只在未来收入上体现**：本层无法阻止调用方误用结果；是否只对某类收入征收、由谁承担、何时结算，属于经济切片。
- **固定系数是实验值**：10/1000 的税费步进、200 上限与两个折减系数都未经模拟校准。
- **公共建设不区分项目**：只要存在一条已应用的公共建设决议，两项系数同时生效；没有按项目类型、地块或规模区分。
- **记录淘汰后不再计入**：被容量淘汰的旧税费决议不再产生费率，费率可能随文档老化下降。这是有界文档的既定安排，未做“冻结费率快照”。
- **未验证 Windows、真实局域网或多端并发**；纯规则层不涉及这些环境。
