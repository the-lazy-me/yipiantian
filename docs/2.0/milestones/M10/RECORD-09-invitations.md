# M10-04 · NPC 邀约可拒绝（纯规则切片）

执行日期：2026-11-15。状态：切片完成，不表示 M10-04 或 M10 验收完成。前置：[M10 PLAN](PLAN.md)、[M10-03 意图规则](RECORD-04-intent-rules.md)、[M10-04 居民角色权限](RECORD-07-resident-roles.md)、[M10-04 居民自发社交](RECORD-08-social.md)。

## 问题

M10-04 的验收判据是“NPC 邀约可拒绝，模型不凭叙述改变权属”。[RECORD-08](RECORD-08-social.md) 已经能规划 `invite` 动作，但明确把“被邀请方接受/拒绝、过期邀请清理”留待后续；居民发出的邀请仍然只是一个动作记录，没有可拒绝的对象，也没有状态机。

本切片冻结邀约本身的规则：一条邀约怎样创建、谁可以决定、过期怎样处理、接受或拒绝后文档怎样变化。它不调用模型、不接网络、不写存档、不做 UI，也不执行真实拜访、赠礼、扣款或任何权属变更。

## 边界

- 新增 `Game/npc/npc_invitation.gd`、`tests/npc_invitation_test.gd` 与 [RECORD-09](RECORD-09-invitations.md) 本身。
- 未修改 `PLAN.md`、`rules/project-context.md`、`.github/workflows`、`Game/farm/*`、`Game/world/*`、`Game/ui/*`、`Game/scenes/*`、`Game/ai/*`、`Game/npc/npc_social.gd`、`WorldHost`、`HeadlessWorld`、`main.gd` 或其他 `tests/*`。
- 纯静态规则：无 RNG、无系统时钟、无磁盘、无场景、无网络；`propose` / 决策 / `expire` 都显式接收 `now_utc`，同一输入得到同一输出。
- 所有写入口写时复制，绝不修改输入；除下文说明的“过期决策”路径外，失败只返回 `{ok:false, reason}`，不带候选文档。
- 不读取 `FarmState`，不写市场、银行、账户或账本；邀约文档只记录发起人、收件人、种类、时刻与状态。
- 接受或拒绝不授予财产、权属、账户或命令权限；`claim_from_narrative()` 永远返回 `not_authority`。

## 邀约文档形状

```text
{
  "invitations": {
    "<invite_id>": {
      "id": "<invite_id>",              # 必须等于字典键
      "from": "<npc_id>",               # OwnerIds.valid，且不等于 to
      "to": "<npc_id>",
      "kind": "visit",                  # visit / meal / trade_talk
      "created_utc": 1800000000.0,
      "expires_utc": 1800003600.0,      # 严格晚于 created_utc
      "status": "pending",              # pending 时恰好这七个键
    },
    "<decided_id>": {
      # ... 同样七个键 ...
      "status": "accepted",             # accepted / declined / expired / withdrawn
      "decided_utc": 1800000100.0,      # created_utc <= decided_utc <= expires_utc
      "reason": "accepted",             # 固定等于 status，不接受自由文本
    },
  },
}
```

- 根键恰好 `invitations`；pending 行恰好七个键，非 pending 行恰好九个键。未知键、缺字段一律拒绝。
- 上限：`MAX_INVITATIONS = 128` 条邀约；邀约 id 长度不超过 `MAX_INVITATION_ID_LENGTH = 128`。
- `from` / `to` 使用 `OwnerIds.valid`，且必须不同。
- 时刻有限、非负且不超过安全整数；`created_utc < expires_utc`；非 pending 行的 `decided_utc` 落在 `created_utc..expires_utc` 闭区间内。
- id 必须由 `FNV-1a(["npc_invitation_v1", from, to, kind, 过期毫秒])` 确定性派生；`valid()` 会重新推导并与字典键、行内 `id` 比对，调用方不能自造 id 冒充。
- `reason` 固定等于 `status`（`accepted` / `declined` / `expired` / `withdrawn`），避免自由文本进入权威状态。

## 种类与有效期

种类来自固定枚举，不接受自由文本：

| 种类 | 含义 | 固定有效期 |
|---|---|---|
| `visit` | 邀请来访 | 3600 秒 |
| `meal` | 邀请吃饭 | 1800 秒 |
| `trade_talk` | 邀请谈交易 | 900 秒 |

`expires_utc = now_utc + TTL_SECONDS[kind]`；因此 id 只由 `now_utc`、发起人、收件人和种类决定，不受字典顺序影响。

## 状态机

```text
pending ── accept（收件人，未过期）──> accepted
pending ── decline（收件人，未过期）─> declined
pending ── withdraw（发起人）───────> withdrawn
pending ── expire / 过期后决策 ─────> expired
```

- 只有 `pending` 可以转换；任何非 pending 再次决策返回 `not_pending`。
- 只有收件人 `to` 可以接受或拒绝，否则 `not_recipient`；只有发起人 `from` 可以撤回，否则 `not_initiator`。
- 到达 `expires_utc` 即视为过期（`now_utc >= expires_utc`）；过期后继续接受、拒绝或撤回返回 `expired`，并把该行转为 `expired`。
- 状态没有反向或二次转换；接受与拒绝不改变任何财产、权属、账户或命令权限。

## 接口与规则

```text
empty_document()                                        # {invitations: {}}
valid(document)                                        # 严格形状/id/时刻校验
normalize(document)                                    # JSON float 归一
validate_proposal(document, request, now_utc)          # {ok, reason, invitation}
propose(document, request, now_utc)                    # 写时复制，成功带 document/invitation
validate_decision(document, invite_id, actor, decision, now_utc)
accept(document, invite_id, actor, now_utc)
decline(document, invite_id, actor, now_utc)
withdraw(document, invite_id, actor, now_utc)
expire(document, now_utc)                              # {ok, reason, document, expired}
claim_from_narrative(actor, claimed_action)            # 永远 not_authority
```

`request` 恰好 `{from, to, kind}`，未知键拒绝。

### propose

按顺序检查：时间、文档、请求形状、`from` / `to`、`from != to`、种类、同 `(from,to,kind)` 的 pending、派生 id 是否已存在、总上限。成功创建 pending 行并返回写时复制的候选文档。

- 同一 `(from,to,kind)` 在未决期间重复提议，无论 `now_utc` 是否相同，都返回 `already_pending`。
- 派生 id 已存在但该行已决策（同 `now_utc` 重放）返回 `duplicate_id`。
- 不同时刻或不同种类的再次提议会产生新 id，可以并存。

### accept / decline / withdraw

共用 `validate_decision`，判定顺序固定为：时间 → 文档 → 决策种类 → id 形状 → 邀约存在 → 权限 → 状态 → 过期。成功时写时复制并替换为对应状态，`decided_utc = now_utc`，`reason = status`。

**过期决策的例外：** 对仍为 pending 但已到期的邀约执行决策，返回 `ok=false, reason="expired"`，同时附带一份把该行转为 `expired` 的候选文档（`decided_utc = expires_utc`）。这是“过期后决定转 expired”判据的实现方式；输入仍不被修改。其他失败路径均不带候选文档。

### expire

按 id 升序扫描 pending 行，把所有 `now_utc >= expires_utc` 的行转为 `expired`，`decided_utc = expires_utc`。返回候选文档与本次新过期的条数 `expired`；重复调用返回同样的文档且 `expired == 0`，不会重复计数。

### 具名原因

| 场景 | reason |
|---|---|
| 时间不合法 | `invalid_time` |
| 文档形状/字段/时刻/id 派生不合法 | `invalid_document` |
| 请求不是恰好 `{from,to,kind}` | `invalid_request` |
| 发起人或收件人非法 | `invalid_from`、`invalid_to` |
| 自己邀请自己 | `invalid_target` |
| 目录外邀约种类 | `invalid_kind` |
| 同 `(from,to,kind)` 已有 pending | `already_pending` |
| 派生 id 已存在且已决策 | `duplicate_id` |
| 达到邀约总上限 | `over_capacity` |
| 未知决策种类 | `invalid_decision` |
| 邀约 id 形状非法 | `invalid_invitation_id` |
| 邀约不存在 | `unknown_invitation` |
| 不是收件人 | `not_recipient` |
| 不是发起人 | `not_initiator` |
| 邀约已非 pending | `not_pending` |
| 邀约已过期 | `expired` |
| 候选文档未通过不变式 | `invalid_state` |
| 叙事声称权属/授权 | `not_authority` |

## 叙事与权限边界

- 邀约文档没有 `ownership`、`accounts`、`cash`、`authority` 一类字段；接受或拒绝只改变 `status`、`decided_utc` 和 `reason`。
- `claim_from_narrative(actor, claimed_action)` 与 `npc_social.gd`、`npc_roles.gd` 保持同一原则：无论叙述声称“我接受了邀约，所以渡口归我”“我授权你付款”，都返回 `ok=false, reason="not_authority", authority=false, proposal_only=true`。
- 叙事只能作为提案；真正的权属和命令仍须走既有权威与角色准入路径。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/npc/npc_invitation.gd` | 新增纯规则模块：邀约文档严格校验、确定性 id、提议/接受/拒绝/撤回/批量过期、决策前复校验、叙事不授权入口 |
| `tests/npc_invitation_test.gd` | 新增无头夹具，159 项检查 |
| `docs/2.0/milestones/M10/RECORD-09-invitations.md` | 本记录 |

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian && \
perl -e 'alarm shift; exec @ARGV' 180 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/npc_invitation_test.gd"
```

原始末行：

```text
NPC_INVITATION_TEST checks=159 failures=0
```

覆盖矩阵：

| 用例 | 检查 |
|---|---|
| 空文档 | 空邀约文档合法；null/数组/空字典/非字典 invitations/未知根键被拒绝 |
| JSON 往返 | 空文档与含 accepted 邀约的文档均可解析回合法文档；归一后 JSON 一致 |
| 提议与确定性 id | 字段、固定 TTL、id 前缀与 FNV-1a 派生正确；同输入同 id；不同时刻不同 id；无关邀约不影响 id |
| 重复 pending | 同时刻/不同时刻同 `(from,to,kind)` 返回 `already_pending`；不同种类、反向邀约可并存；已决策行同 id 返回 `duplicate_id` |
| 提议拒绝 | 非法时间/文档/请求/发起人/收件人/自己邀请自己/目录外种类均具名拒绝且不带文档 |
| 接受/拒绝 | 收件人可接受或拒绝；状态、时刻、reason 正确；输入不变；非 pending 再决策拒绝；结果不含权属/账户/授权字段 |
| 权限 | 发起人不能接受/拒绝；第三方不能决策；非字符串决策人拒绝；收件人不能撤回；失败不带文档 |
| 撤回 | 发起人可撤回 pending；重复撤回、已撤回后接受均返回 `not_pending`；输入不变 |
| 过期决策 | 过期前一秒接受成功；到达 expires 时接受/拒绝/撤回返回 `expired`，附带转 expired 的候选文档，输入不变；之后决策返回 `not_pending` |
| 批量过期 | 按各自 TTL 分批转 expired；边界时刻生效；重复调用不重复计数且文档不变；空文档与非法输入 |
| 决策复校验 | 合法决策通过且不写文档；未知决策/id 形状/不存在/非法时间/非法文档/过期均具名拒绝 |
| 上限与严格 valid | 128 条合法、129 条拒绝、新增超限返回 `over_capacity`；未知键、缺字段、pending 携带 decided、reason 不一致、时刻倒置、from==to、未知种类、键/id 不一致、自造 id、非字符串键、超长 id 均拒绝 |
| 写时复制 | 接受/过期/失败后输入逐字节不变；修改候选不污染输入；普通失败不带 document/state |
| 叙事 | 权属/授权声明永远 `not_authority`，只作为提案；非字符串声明同样不授权 |

## 未覆盖

- **未接模型**：没有提示词、自然语言邀约生成、解释或人格化文案；邀约只有固定种类与数值规则。
- **未接网络与权威**：没有 `HeadlessWorld`、`WorldHost` 命令入口、客户端 RPC、权限门或成员/访客身份判断；接受只写邀约文档，不写世界状态。
- **未接存档**：邀约文档不进入农场存档或 sidecar，没有跨重启恢复、损坏恢复或世界隔离；128 条是单文档上限，不提供自动清理或归档策略。
- **未接 UI 与真实拜访**：没有邀约列表、通知、接受/拒绝按钮、场景或镜头变化；接受后不生成真实拜访、餐食、摊位或交易。
- **未联动赠礼、关系或记忆**：接受/拒绝不改变 `npc_social.gd` 的 affinity、赠礼次数、M10-01 记忆或 M10-03 意图账本；是否把邀约结果写回这些文档留待后续切片。
- **未接事件通知与重试**：没有事件总线、冷却、提醒或失败等待；调用方负责在成功后保存候选文档。
- **未接 CI、可玩性观察或 Windows 实机**：测试尚未加入 `.github/workflows`。

## 关联

- 阶段计划：[M10 PLAN](PLAN.md) M10-04。
- 前置切片：[M10-03 意图规则](RECORD-04-intent-rules.md)、[M10-04 居民角色权限](RECORD-07-resident-roles.md)、[M10-04 居民自发社交](RECORD-08-social.md)。
- 权威设计：[AI 系统](../../06-AI-SYSTEM.md)。
- 叙事不授权原则：`Game/npc/npc_roles.gd`、`Game/npc/npc_social.gd` 的 `claim_from_narrative()`。
- 确定性 id 参考：`Game/npc/npc_social.gd` 的 FNV-1a `_hash()`。
