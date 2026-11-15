# M11-03 · 规则决议纯规则切片

执行日期：2026-11-15。状态：切片完成，不表示 M11-03 或 M11 验收完成。前置：[M11 PLAN](PLAN.md)、[领土政治、私兵与法律](../../systems/politics-conflict-law.md)、[M11-02 · 组织规则](RECORD-04-organizations.md)。

## 问题

M11-02 已经冻结组织成员、职位、权限与公共账户引用，但没有回答“组织如何改变规则”：谁提案、谁表决、何时预告、何时生效、旧规则如何撤销，以及这些变化如何保留历史版本。若把表决和版本散落在命令处理器或界面里，重复投票、过期窗口和追溯改写就无法用同一套规则约束。

本切片冻结规则决议的最小纯规则层。它只操作一个决议文档，所有时刻由调用方显式传入，不接网络、不写存档、不做界面，也不读取组织、农场或经济文档。接线与成员资格校验留给后续切片。

## 边界

- 新增 `Game/world/resolution_state.gd`、`tests/resolution_state_test.gd` 与本记录。
- 未修改 `docs/2.0/milestones/M11/PLAN.md`、`rules/project-context.md`、`RISKS.md`、其他规则、存档格式或任何既有模块。
- 无 RNG、无系统时钟、无磁盘、无场景、无网络；同一命令序列得到同一文档。
- 不读取组织或成员表。撤案人必须是提案人，撤销人必须是曾投赞成票的成员；负责人/干事等职位校验由上层权威另行完成。
- 不执行税费或公共建设效果，不接线 `HeadlessWorld`，不写持久化 sidecar。
- 决策：**提案人不能给自己的提案投票**。设计文档只要求“明确提案、表决/授权、生效与撤销流程”，没有规定自投；禁止自投可以避免一个人同时提出并满足最低赞成数，也避免提案人既当提案方又当表决方。本切片选择禁止，并在值域和命令层同时校验。

## 文档形状

```text
{
  "rules_version": 0,
  "resolutions": {
    "<resolution_id>": {
      "kind": "public_works" | "tax",
      "title": "修桥",
      "proposed_by": "<player_id>",
      "proposed_utc": 1800000000.0,
      "vote_start_utc": 1800000060.0,
      "vote_end_utc": 1800003660.0,
      "effective_utc": 1800007260.0,
      "status": "proposed" | "passed" | "rejected" | "withdrawn"
              | "effective" | "revoked",
      "approvals": ["<player_id>"],
      "rejections": ["<player_id>"],
      "revision": 1,
      "effective_version": 0,
      "revoked_by": "",
      "revoked_utc": 0.0,
      "revoked_version": 0
    }
  }
}
```

相对任务建议的形状，额外保留四个审计字段：

- `effective_version`：决议生效时分配到的全局规则版本，未生效为 0。
- `revoked_by` / `revoked_utc`：撤销人与撤销时刻，未撤销为空串和 0。
- `revoked_version`：撤销时分配到的全局规则版本，未撤销为 0。

字段约束：

- 顶层恰好两个键；决议行恰好十五个键。未知键一律拒绝，避免旧权威静默丢掉未来字段。
- `kind` 只接受 `public_works` 和 `tax`；`title` 非空、不超过 128 字符、无首尾空白和控制字符。
- 所有 id 复用 `owner_id.gd` 的格式与长度上限。
- 四个时刻都是 `[0, 2^53-1]` 内的有限值；`proposed_utc <= vote_start_utc < vote_end_utc`，且 `effective_utc - vote_end_utc >= NOTICE_SECONDS`（3600 秒）。
- 赞成票和反对票各自最多 128 人，数组内不重复、两边不重叠，且不包含提案人。
- 决议数最多 128。
- `revision` 与状态严格对应：`proposed=1`、`passed/rejected/withdrawn=2`、`effective=3`、`revoked=4`。
- 版本不变式：`rules_version == 生效决议数 + 2 × 已撤销决议数`；所有生效/撤销版本号在文档内唯一，并恰好覆盖 `1..rules_version`。每个撤销行的 `revoked_version > effective_version`。

## 规则

### empty / valid

`empty()` 返回 `{"rules_version": 0, "resolutions": {}}`。`valid()` 严格校验上述全部键集、枚举、id、时间、窗口、预告期、投票人和版本不变式；空文档合法，经过 JSON 往返也合法。旧决议行只允许状态迁移修改 `status`、`revision` 和撤销字段，任何提案、表决、时间或历史版本字段被重写都会让文档失效。

### propose

`propose(state, resolution_id, proposer, proposal, now_utc)` 返回 `{ok, reason, state}`，输入文档不被修改。`proposal` 必须恰好包含 `kind`、`title`、`vote_start_utc`、`vote_end_utc`、`effective_utc`。

按顺序拒绝：

1. 文档不合法 -> `invalid_state`。
2. 决议 id 不合法 -> `invalid_resolution`。
3. 提案人不合法 -> `invalid_player`。
4. 当前时刻不合法 -> `invalid_time`。
5. 提案不是精确键集的字典 -> `invalid_proposal`。
6. 类型或标题不合法 -> `invalid_kind` / `invalid_title`。
7. 提案时刻不合法 -> `invalid_time`。
8. `vote_start_utc < now_utc` 或 `vote_end_utc <= vote_start_utc` -> `invalid_window`。
9. 预告期不足 -> `notice_too_short`。
10. id 已存在 -> `already_exists`；决议数已满 -> `too_many`。

成功后写入一条 `proposed` 行，`revision=1`，投票与撤销字段为初始值。

### vote

`vote(state, resolution_id, voter, approve, now_utc)` 只在半开窗口 `[vote_start_utc, vote_end_utc)` 内接受投票，并且只接受 `proposed` 状态。开始时刻可以投，结束时刻已经关闭。

拒绝原因：`not_started`、`closed`、`not_proposed`、`self_vote`、`already_voted`、`too_many_votes`，以及通用的 `unknown_resolution`、`invalid_player`、`invalid_time`。同一玩家无论先投赞成还是反对，之后都不能改投。投票不改变 `revision`。

### tally / close

`tally()` 是只读查询，返回 `{ok, reason, approvals, rejections, passed}`。通过阈值是**至少 2 张赞成票，且赞成票严格多于反对票**；零票、平票和只有一票赞成都会被否决。阈值只基于已投票成员计算，本切片没有选民名册。

`close()` 只能在 `now_utc >= vote_end_utc` 时关闭，提前关闭返回 `window_open`。达到阈值写 `passed`，否则写 `rejected`，两者 `revision=2`。关闭本身不推进 `rules_version`，也不产生生效规则；因此过了投票窗口而没人调用 `activate()` 时，规则仍然不生效。

### activate

`activate()` 只接受 `passed` 状态，且必须等到 `effective_utc`（提前返回 `too_early`）。成功后状态变为 `effective`、`revision=3`，并分配下一个全局规则版本：`rules_version += 1`，写入该行的 `effective_version`。

### withdraw

`withdraw()` 只接受 `proposed` 状态，只允许提案人调用，并且必须在投票窗口结束前。窗口结束后返回 `window_closed`，避免看到票数后临时撤案。成功写 `withdrawn`、`revision=2`，保留已投票作为历史，不推进规则版本。

### revoke

`revoke()` 只接受 `effective` 状态，只允许在该行 `approvals` 中的人调用。成功写 `revoked`、`revision=4`，记录 `revoked_by`、`revoked_utc`，分配新的全局版本到 `revoked_version` 并推进 `rules_version`。

撤销只修改生命周期字段，不重写 `kind`、`title`、`proposed_by`、三个窗口时刻、`effective_utc`、`approvals`、`rejections` 和 `effective_version`。已撤销规则也不再参与后续投票或撤销。

### is_effective_at

`is_effective_at(state, resolution_id, at_utc)` 用来回答历史时刻的规则有效性：

- `effective`：`at_utc >= effective_utc` 即有效，持续到撤销。
- `revoked`：只在 `[effective_utc, revoked_utc)` 内有效。
- 其他状态或非法输入：`false`。

因此撤销和新版本都不会追溯改变撤销/生效前已经发生的事件；既有合同应按事件发生时的版本继续成立。

### 具名原因

| 场景 | reason |
|---|---|
| 文档形状/字段/不变式不合法 | `invalid_state` |
| 决议 id 不合法 | `invalid_resolution` |
| 提案人/投票人/撤销人不合法 | `invalid_player` |
| 时刻不合法 | `invalid_time` |
| 提案键集或类型不合法 | `invalid_proposal` |
| 未知决议类型 | `invalid_kind` |
| 标题不合法 | `invalid_title` |
| 投票窗口早于提案或结束不晚于开始 | `invalid_window` |
| 预告期不足 | `notice_too_short` |
| 决议 id 已存在 | `already_exists` |
| 决议数量超限 | `too_many` |
| 未知决议 | `unknown_resolution` |
| 投票未开始/窗口已关闭 | `not_started` / `closed` |
| 当前状态不允许该命令 | `not_proposed` / `not_passed` / `not_effective` |
| 提案人自投 | `self_vote` |
| 已经投过票 | `already_voted` |
| 单边投票人数已满 | `too_many_votes` |
| 窗口未结束就关闭 | `window_open` |
| 未到生效时刻 | `too_early` |
| 非提案人撤案 | `not_proposer` |
| 窗口结束后撤案 | `window_closed` |
| 非赞成者撤销 | `not_approver` |

## 验证

实际运行：

```text
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 120 /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot --headless --path Game --script "$PWD/tests/resolution_state_test.gd"
```

原始末行：

```text
RESOLUTION_STATE_TEST checks=330 failures=0
```

覆盖提案与重复 id、窗口边界（开始/结束）、重复投票与自投、计票阈值、通过/否决、撤案、撤销、版本递增与唯一性、新版本与撤销不追溯改写旧行、过期窗口不自动生效、JSON 往返、非法文档拒绝、决议与投票人数上限、输入不变性和同一序列确定性。

## 未覆盖

- 未接 `HeadlessWorld`、网络、存档或界面；本切片只返回候选文档。
- 没有组织成员/职位校验。撤销授权目前只检查“曾投赞成票”，没有检查负责人/干事权限；上层接线必须补这一层，否则任何赞成者都能撤销。
- 没有选民名册或法定人数。阈值只按已投票人数计算，无法表达“全体成员过半数”或“负责人授权”。
- 没有委托表决/授权代表；“表决或授权”目前只实现直接投票。复杂派系、多级代表和授权链保留候选。
- 没有规则冲突、取代关系或适用区域字段。新决议不会自动废止旧决议；需要显式撤销，或由上层按业务语义处理。
- 没有税费/公共建设的具体效果，也不执行合同变更。
- 未验证 Windows 实机、真实局域网或多端并发；纯规则层不涉及这些环境。
- `valid()` 无法判断关闭是否发生在真实时钟的窗口之后；生命周期顺序由命令层保证，文档只校验最终形状。

## 关联

- 阶段计划与验收：[M11 PLAN](PLAN.md)（由主会话登记，本记录不修改）。
- 权威设计：[领土政治、私兵与有限 PvP 与官府执法](../../systems/politics-conflict-law.md) 的“土地与政治”“官府与法律”。
- 前序组织规则：[M11-02 · 组织规则](RECORD-04-organizations.md)。
- 同类纯规则先例：[M10-03 意图执行账本](../M10/RECORD-05-intent-state.md)、[冲突参与规则](../../decisions/ADR-025-conflict-participation.md)。
