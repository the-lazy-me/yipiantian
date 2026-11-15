# M10-02/M10-04 · 居民社交与邀约结果写入有界记忆

执行日期：2026-11-15。状态：切片实现，未验收。前置：[M10-01 有界记忆](RECORD-01-memory.md)、[M10-03 世界事件到记忆](RECORD-03-memory-feed.md)、[M10-04 居民自发社交](RECORD-08-social.md)、[M10-04 NPC 邀约](RECORD-09-invitations.md)；上层计划：[M10 PLAN](PLAN.md)。

## 问题

M10-01 已提供有界记忆和严格 `valid()`，M10-03 已把世界事件投影成记忆，M10-04 已能规划社交动作并接受/拒绝/撤回邀约，但两者之间没有适配层：一次已经发生的社交动作或邀约结果怎样写进“本人”的记忆、哪些结果不该写、重复投递怎样保持幂等，此前都没有规则。

本切片只冻结这一层：把一次社交动作结果或一次邀约决策结果，转换为 M10-01 的候选记忆文档。它不调用模型、不接权威、不改关系文档、不扣款、不改变任何权属。

## 边界

- 新增 `Game/npc/npc_social_memory.gd`、`tests/npc_social_memory_test.gd` 与本记录。
- 未修改 `npc_memory.gd`、`npc_memory_feed.gd`、`npc_social.gd`、`npc_invitation.gd`、`PLAN.md`、`rules/project-context.md`、`.github/workflows`、`Game/world/*`、`Game/farm/*`、`Game/scenes/*`、`Game/ui/*`、`Game/ai/*`、`WorldHost`、`HeadlessWorld` 或农场存档格式。
- 纯静态适配：无 RNG、无系统时钟、无磁盘、无场景、无网络；`now_utc` 由调用方显式传入，同一输入得到同一候选文档。
- 所有写入口写时复制：先校验上下文、记忆文档和事件形状，再深拷贝记忆文档并调用 `NpcMemory.remember()`；输入文档、事件投影和上下文都不被修改。
- 只接受结构化事件，不接受叙事文本；摘要全部由固定中文模板和结构化 id/状态拼装。
- 不读取 `FarmState`，不修改 `npc_social.gd` 的关系文档，不扣款、不移动物品、不改变任何权属或命令权限。

## 输入与上下文

事件投影恰好是下面两种形状之一（顶层只有 `ok` 和一个事件体）：

```text
{ok: bool, act: {id, kind, from, to, expires_utc}}
{ok: bool, invitation: {id, from, to, kind, status, decided_utc?}}
```

- `act.kind` 来自 `npc_social.gd` 的 `ACTIONS`（`greet` / `gift` / `invite` / `apologize`）；`expires_utc` 必须有效且 `now_utc < expires_utc`。
- `invitation.kind` 来自 `npc_invitation.gd` 的 `KINDS`；`status` 来自其 `STATUSES`。
- 实际 `npc_invitation.gd` 的 pending 行恰好七个键，没有 `decided_utc`；因此本适配层对 pending 接受缺省 `decided_utc`，对非 pending 要求必填且 `decided_utc <= now_utc`。

上下文严格校验，未知键拒绝：

```text
{
  now_utc: float >= 0,
  world_id: String,                  # 必须与记忆文档 world_id 一致
  resident_id: String,               # 目标居民（本人视角）
  names?: {npc_id: display_name},    # 可选只读显示名投影，仅用于摘要
}
```

`names` 只影响中文摘要里的称呼，不参与事实归属；缺失时退回居民 id。它不是叙事来源，也不允许非字符串或空名称。

## 事件 → 记忆映射

只写“已发生且与本人相关”的事实。记忆 `kind` 与显著性由固定的动作/状态映射决定；`importance` 在 M10-01 中对应 `salience`。

### 社交动作（`act`）

| 条件 | 记忆主体 | 记忆 kind | salience | 摘要模板 |
|---|---|---|---|---|
| `resident_id == act.from`，`greet` | 发起人 | `dialogue` | 20 | `我向<to名>打了招呼。` |
| `resident_id == act.from`，`gift` | 发起人 | `gift` | 45 | `我向<to名>送了礼。` |
| `resident_id == act.from`，`invite` | 发起人 | `dialogue` | 30 | `我邀请<to名>来做客。` |
| `resident_id == act.from`，`apologize` | 发起人 | `dialogue` | 50 | `我向<to名>道了歉。` |
| `resident_id == act.to` | 不写 | — | — | `skipped: counterparty_only` |
| 其他居民 | 不写 | — | — | `skipped: not_participant` |

社交动作只有发起人视角写入；被招呼/被赠礼的一方本切片不写，避免把“别人对我做了某事”与“我做了某事”混成同一条事实。

### 邀约决策（`invitation`）

| 条件 | 记忆主体 | 记忆 kind | salience | 摘要模板 |
|---|---|---|---|---|
| `status == accepted`，`resident_id == to` | 收件人 | `dialogue` | 40 | `我接受了<from名>的<种类>邀约。` |
| `status == declined`，`resident_id == from` | 发起人 | `conflict` | 65 | `<to名>拒绝了我的<种类>邀约。` |
| `status == withdrawn`，`resident_id == to` | 收件人 | `observation` | 35 | `<from名>撤回了给我的<种类>邀约。` |
| `status == pending` | 不写 | — | — | `skipped: pending` |
| `status == expired` | 不写 | — | — | `skipped: expired` |
| 其他当事人视角 | 不写 | — | — | `skipped: not_subject` |

种类中文标签固定为 `visit` → 来访、`meal` → 共餐、`trade_talk` → 谈交易。邀约只有“收件人接受”“发起人被拒绝”“收件人被撤回”三种已发生事实写入；未决、过期和未发生的提案都不写。

### 其他跳过

| 输入 | 结果 |
|---|---|
| `ok == false`（动作/决策失败） | `skipped: not_committed`，不写任何行 |
| 社交发起人、收件人之外的第三人 | 不写 |
| 未知 kind/status、缺键、额外键、非法 id/时刻 | 具名拒绝，不写 |

## 记忆条目形状与时间

M10-01 的记录是固定八个字段：`id, kind, participants, summary, salience, at_utc, world_id, state_version`。本适配层复用该形状，不新增第九个字段：

- `id`：`"sm_" + FNV-1a(source, event_id, resident_id)`，最多 19 字符，满足 `OwnerIds` 的 64 字符上限。
- `participants`：`[from, to]`，去重且只含合法 owner id。
- `summary`：固定中文模板，按 M10-01 的 200 字符上限截断。
- `salience`：上表的固定映射，不使用模型或外部评分。
- `at_utc`：社交动作使用调用方注入的 `now_utc`（投影里没有执行时刻）；邀约使用 `decided_utc`（事实发生时刻，且已校验不晚于 `now_utc`）。
- `world_id`：上下文 `world_id`，并已与记忆文档一致。
- `state_version`：`0`，本适配层不持有世界状态版本。

## 幂等、容量与失败

- **重复 id**：同一 `(source, event_id, resident_id)` 再次投递时派生出相同记忆 id；`NpcMemory.remember()` 返回 `duplicate`，适配层返回 `{ok: true, reason: "duplicate", duplicate: true, written: false, memory: <未变候选>}`。文档逐字节不变。
- **容量**：完全沿用 M10-01 的每位居民 64 条上限，以及“最低显著性 → 最旧 `at_utc` → id 升序”的淘汰规则；适配层不新增容量参数、不自行删除。淘汰后 `dropped` 单调增加，候选文档仍通过 `valid()`。
- **写时复制**：输入记忆文档先深拷贝，`remember()` 只改候选；失败路径不返回 `memory` 键。
- **具名原因**：

| 场景 | reason |
|---|---|
| 记忆文档不是字典或未通过 M10-01 校验 | `invalid_memory` |
| 上下文形状/未知键/缺键 | `invalid_context` |
| `now_utc` 非法 | `invalid_time` |
| `world_id` 非法 | `invalid_world_id` |
| 上下文世界与记忆文档不一致 | `world_mismatch` |
| `resident_id` 非法 | `invalid_resident` |
| `names` 不是字典、键非法或值为空/非字符串 | `invalid_names` |
| 结果不是字典、额外键、`act`/`invitation` 数量不为 1 | `invalid_result` |
| `ok` 缺失或非 bool | `invalid_ok` |
| 事件体不是字典或键集不对 | `invalid_act` / `invalid_invitation` |
| 事件 id 为空/非字符串/超过 128 字符 | `invalid_act_id` / `invalid_invitation_id` |
| `from` / `to` 非法 | `invalid_from` / `invalid_to` |
| `from == to` | `invalid_target` |
| 动作/邀约种类不在固定目录 | `invalid_kind` |
| 邀约状态不在固定目录 | `invalid_status` |
| 动作有效期非法 | `invalid_expiry` |
| 邀约决策时刻非法 | `invalid_decided_utc` |
| 已过动作有效期 | `expired` |
| 决策时刻晚于 `now_utc` | `future_time` |
| `remember()` 在预校验后仍失败 | `invalid_memory`（附 `detail`） |

## 与 `Memory` 实际 API 的适配

任务描述假设条目使用 `type/summary/importance/at_utc`；实际 `npc_memory.gd` 使用 `kind/summary/salience/at_utc`，并且 `remember()` 会原地修改传入文档。适配方式：

- 用 `kind` 表达事件类型、用 `salience` 表达固定重要性；没有修改 `npc_memory.gd`，也没有新增字段。
- 每次写入先 `duplicate(true)` 记忆文档，再把副本传给 `remember()`，因此输入逐字节不变。
- 复用 `Memory.validate_document()` 做严格预校验，复用 `Memory.remember()` 做唯一写入口、容量淘汰和文档级 id 去重；适配层不复制这些规则。
- 实际 `npc_invitation.gd` 的 pending 行没有 `decided_utc`，所以 pending 投影允许省略该键；非 pending 仍要求提供。

## 接口

```text
SocialMemory.apply(document, result, context)                    # {ok, reason, memory?, ...}
SocialMemory.memory_id(source, event_id, resident_id)            # 确定性记忆 id

成功：{ok: true, reason: "", memory, memory_id, duplicate: false, skipped: "", written: true}
重复：{ok: true, reason: "duplicate", memory, memory_id, duplicate: true, skipped: "", written: false}
跳过：{ok: true, reason: "", memory, memory_id: "", duplicate: false, skipped: <原因>, written: false}
失败：{ok: false, reason: <具名原因>, memory_id: "", duplicate: false, skipped: "", written: false}
```

`source` 为 `"social"` 或 `"invitation"`；它进入散列，因此同 id 的社交动作与邀约不会互相判重。

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian && \
perl -e 'alarm shift; exec @ARGV' 180 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/npc_social_memory_test.gd"
```

原始末行：

```text
NPC_SOCIAL_MEMORY_TEST checks=145 failures=0
```

覆盖：

- 社交 `greet/gift/invite/apologize` 的发起人写入，kind、显著性、摘要、时间、世界字段、参与人正确；
- 被招呼方视角 `counterparty_only`、第三人 `not_participant` 不写；
- 待定、过期、失败结果不写；`ok: false` 的社交与邀约决策均不写；
- 接受写收件人、拒绝写发起人、撤回写收件人，其余当事人视角不写；
- 相同 act/invitation id 重放返回 `duplicate` 且文档逐字节不变；同内容不同 id 是两条；记忆 id 确定且按来源/居民区分；
- 70 条社交动作后每位居民恰好 64 条，`dropped` 单调，最低显著性/最旧淘汰，高显著性道歉保留，文档仍通过 `valid()`；
- 写时复制：输入记忆文档、事件投影和上下文逐字节不变；修改候选不会污染输入；失败不带 `memory`；
- 非法记忆文档、上下文、结果、动作和邀约字段均具名拒绝；
- JSON 往返后继续写入与直接写入一致；存储记录恰好八个 M10-01 字段，不含关系、现金或权属字段；
- 无 `names` 时摘要退回 id，部分 `names` 只替换对应称呼。

## 未覆盖

- **模型叙述**：没有提示词、自然语言生成、模型摘要或叙事转记忆；摘要只是固定模板，模型不能写入记忆，也不能凭叙述制造事实。
- **权威接线**：没有订阅社交/邀约成功事件，没有接入 `WorldHost`、`HeadlessWorld`、命令提交或事件 tail；调用方需要在权威状态提交后再投影到本适配层。
- **存档与多世界**：本切片不落盘、不进入农场存档或 sidecar；跨世界只做文档/上下文一致性校验。
- **关系联动**：不修改 `npc_social.gd` 的 affinity、赠礼计数或冷却，也不把记忆写回社交/邀约文档。
- **过期清理与批量**：不提供批量社交事件入口，也不负责把 pending 邀约转为 expired；过期结果由邀约模块决定。
- **UI 与可玩性**：没有记忆展示、邀约通知、接受/拒绝按钮或场景反馈；未做 Windows 实机与 CI 门禁登记。
