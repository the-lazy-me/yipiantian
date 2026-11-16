# M10-04 · 邀约终态行淘汰（纯规则切片）

执行日期：2026-11-16。状态：切片完成，未验收；只表示邀约表的容量回收规则，不表示
M10-04 或 M10 完成。前置：[M10 PLAN](PLAN.md)、[NPC 邀约规则](RECORD-09-invitations.md)、
[社交结果写入记忆](RECORD-10-social-memory.md)、[邀约持久化与裁决](RECORD-15-resident-invitations.md)、
[M13 长驻留观察](../M13/RECORD-12-residency-soak.md)。

## 问题

M13 的 600 秒驻留记录了一处真实缺陷：`residents.json` 的 `invitations` 表在约 22 逻辑日后
被 64 条 `expired` 行填满。裁决路径只把 pending 转成 expired，从不删除历史行；
`HeadlessWorld._create_invitation()` 在 `invitations.size() >= ResidentsStore.MAX_INVITATIONS`
时直接返回 `over_capacity`。此后该世界里所有居民永久停止发起邀约——不会崩溃、不破坏守恒，
但社交演化在长驻留中静默失效。

本切片只补**纯规则**的容量回收：新增 `NpcInvitation.prune()`，删除已决终态行并释放槽位。
不接权威、不改 `residents.json` 调用方、不改存档格式，也不改任何既有行形状。

## 产品取舍

**释放槽位优先于在表内永久保留全部历史。** 理由：

1. 结果已经保存在居民有界记忆里。接受、拒绝、撤回三种决策分别由 `NpcSocialMemory` 写成
   `invitation` 事实（高显著度，拒绝 65、接受 40、撤回 35），表格行不是这些历史的唯一载体。
   过期行本来就被该适配层按 `expired` 跳过，从未写成记忆；淘汰过期行不丢失任何被记录过的事实。
2. 永久保留的代价是功能永久失效。64 行容量被终态行占满后，居民此后完全无法发起邀约
   （M13 记录的当前缺陷），而保留这些行只为了在面板上多显示几条早已过期的历史。
3. 记忆层自身也有 64 行上限并按显著度淘汰；如果在表内要求“永久全文”，就与记忆层的既有
   有界设计互相矛盾。两处都采用“有界 + 释放”才是同一策略。

## 规则

```text
NpcInvitation.prune(document, now_utc, retain_seconds) -> {
  ok, reason, document, removed
}
```

- 输入必须整体通过 `valid()`；`now_utc` 必须有限、非负、不超过安全整数。
- `retain_seconds` 必须为正、有限、不超过安全整数；`0`、负数、`INF`、`NAN`、非数字都返回
  `invalid_retain_seconds`。未知或非法参数失败关闭，不返回候选文档。
- 只删除**同时**满足以下条件的行：
  - `status != pending`（pending 行永不淘汰，无论时刻多晚）；
  - `decided_utc + retain_seconds <= now_utc`（窗口内保留；恰好等于窗口即释放）。
- 终态行的 `decided_utc` 已在 `valid()` 里被夹在 `created_utc..expires_utc`，因此无需按状态
  分别取时刻；accepted / declined / expired / withdrawn 使用同一判据。
- 成功返回按 id 升序排列的 `removed` 列表与候选文档；输入文档和行对象不被修改。删除只会
  减少行数，不会新增根键或行字段，因此输出仍通过 `valid()`；`expire()`、`validate_decision()`
  等后续入口只按现有 id 查找，不会引用已删除的行。
- 确定性：同一输入（同文档、同 `now_utc`、同窗口）得到逐字节相同的文档与相同的 `removed`；
  重复淘汰已淘汰文档不再删除任何行。

## 保留窗口

`DEFAULT_RETAIN_SECONDS = 604800.0`，即 7 天。选择理由：

- 与季节长度一致（`NatureState.SEASON_SECONDS = 7 × 86400`）。项目的长期状态与曲线评估都以
  7 日季节为节点，邀约的“最近历史”按同一尺度保留。
- 与贷款最短期限（`LoanState.TERMS[0] = 604800`）和纠纷证据窗口
  （`DisputeState.EVIDENCE_WINDOW_SECONDS = 604800`）相同，避免再引入一个孤立的时间常数。
- 邀约自身的 TTL 为 900–3600 秒，7 天的保留期是它的 168–672 倍，足以让面板在正常游玩节奏里
  显示最近结果，又远短于容量填满所需的约 22 逻辑日；按“每个居民每天至多 4 个动作”的节奏，
  7 天窗口内终态行数量不会接近 64。

窗口是调用方可调参数，不是写死在判据里；默认值只提供推荐值。调用方收紧窗口不会影响
pending 行。

## 边界

- 修改 `Game/npc/npc_invitation.gd`（新增 `prune()`、`DEFAULT_RETAIN_SECONDS`、
  `_valid_retain_seconds()` 与模块头部的容量说明）、`tests/npc_invitation_test.gd`，新增本记录。
- 未修改 `Game/world/headless_world.gd`、`Game/world/world_host.gd`、
  `Game/world/residents_store.gd`、`Game/world/*_state.gd`、`Game/conflict/**`、`Game/farm/**`、
  `Game/scenes/**`、`Game/ui/**`、`.github/**`（并行任务正在改动这些文件）。
- 未新增文档字段、未改行形状、未改 `MAX_INVITATIONS`、未改存档信封、未接权威调用点。

## 测试覆盖

`NPC_INVITATION_TEST checks=236 failures=0`（原 159 项，新增 77 项）：

- **容量回收**：128 条终态行（规则上限）与 64 条终态行（权威信封上限）在窗口外全部被删除；
  删除后同一张表接受新提议，且只增加一行。修复前满表返回 `over_capacity` 的现状也被断言，
  作为缺陷复现。
- **pending 保护**：3 条 pending 在 `now_utc` 取 0、1 秒、7 天、7000 天与极大值时都完整保留，
  候选文档逐字节不变。
- **窗口边界**：`decided_utc + retain - 1` 保留；`decided_utc + retain` 恰好释放；
  `+1` 释放；调用方用 60 秒更短窗口时同样按边界释放。
- **三种终态**：accepted / declined / withdrawn / expired 混合表在窗口外全部释放，`removed`
  按 id 升序并完整列出四种终态。
- **文档与引用**：淘汰后仍 `valid()`；只留一行 pending 时剩余 id 仍可 `validate_decision()`
  决策；重复淘汰不再删除且文档不变；空文档合法；非字典文档 `invalid_document`。
- **非法输入**：`now_utc` 为负、`INF`、字符串 → `invalid_time`；窗口为 0、负、`INF`、`NAN`、
  字符串、超过安全整数 → `invalid_retain_seconds`；失败均不带 `document` 或 `removed`。
- **确定性**：同一输入两次淘汰返回相同文档与相同 `removed`；`prune()` 不修改入参。

回归：`NPC_SOCIAL_MEMORY_TEST 145/0`、`FONT_COVERAGE_TEST 1272/0 missing=0`（本切片新增的
中文注释用字均在受管子集内，未改字体文件）。

## 未覆盖

- **权威接线**：`HeadlessWorld._create_invitation()` 仍先检查容量再调用 `propose()`，本切片
  未改它。接线时应在裁决/过期之后调用 `prune()`，用候选表替换 `resident_invitations`，并在
  同一候选里完成容量检查；否则满表缺陷依旧存在。
- **`command_id` 与行形状**：权威表的每行额外带 `command_id`（RECORD-15）。调用方需先把表投影为
  纯规则文档（现有 `_invitation_rules_document()`）、淘汰后再合并回去，不能直接把带
  `command_id` 的行交给 `prune()`——`valid()` 会以 `invalid_document` 拒绝。
- **面板显示**：`residents_view()` 的 `pending_invitations` 与 `last_invitation` 未变；淘汰会让
  “最近结果”在窗口外消失，是否在面板上提示窗口属于后续 UI 切片。
- **其他终态**：记忆层的 64 行淘汰、面板缓存或其他 sidecar 的容量策略不在本切片范围。
- **Windows 与 CI**：本切片只在 macOS 无头运行；未改 workflow。纯规则夹具可后续登记规则组。

## 产物

- 日志：`.local/verification/npc_invitation_test.log`。
