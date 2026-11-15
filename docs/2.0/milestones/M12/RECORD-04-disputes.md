# RECORD-04 · 纠纷登记与裁定规则切片

状态：纯规则实现完成；只代表 M12-04 的案件基础切片，不表示 M12-04 已完成。
日期：2026-11-15。

## 问题

M12-04 要求完成执法的调查、证据、裁定、执行、申诉与补偿，并明确区分游戏官府与服务器管理。验收标准是恶意举报不能直接定罪，错判可以更正且审计保留。

本切片先解决不依赖网络、存档、UI 和真实资产扣减的部分：案件必须从权威事件进入；受理、裁定和更正只允许权威角色执行；AI 只能提出建议；每次管理员裁定与更正留下独立审计；申诉与更正不得删除原裁定和历史。

## 边界

- 纯规则：无 RNG、无系统时钟、无磁盘、无场景、无网络，也不访问 `FarmState`。所有时间由调用方显式传入。
- 不验证外部事件是否真实存在。`event_ids` 由权威事件日志提供，本切片只要求非空、格式合法且在案件内唯一。
- 不执行处罚、资产扣减、补偿分录、封禁、恢复备份或权属变更；`ruling.outcome` 只是可审计的语义记录。
- 不评估 AI 建议的内容质量。`advisor: true` 一律在读取案件前返回 `advisory_only`，不产生任何状态或审计变化。
- 玩家身份与连接的绑定不在本切片内。文档内的 `authority_roles` 决定谁可以受理、裁定、更正和结案；调用方不能仅凭自报的角色字符串取得权限。传输层的真实玩家绑定需由后续网络切片完成。

## 文档形状

```gdscript
{
  "authority_roles": {
    "admin": ["player id", ...],
    "arbiter": ["player id", ...],
  },
  "cases": {
    "case_id": {
      "filed_by": "player id",
      "against": "player id",
      "event_ids": ["authority event id", ...],
      "evidence": [
        {"id", "kind", "source", "submitted_by", "at_utc"},
      ],
      "status": "filed" | "accepted" | "rejected" | "ruled" |
                "appealed" | "corrected" | "closed",
      "ruling": {} | {"by", "at_utc", "outcome", "reason"},
      "appeals": [{"by", "at_utc", "reason"}],
      "corrections": [{"by", "at_utc", "reason"}],
      "manager_only": true,
      "filed_utc": 0.0,
      "audit": [{"action", "by", "at_utc"}],
    }
  }
}
```

相对任务中的建议形状多了三个字段，原因是它们必须由文档自身校验：

- `authority_roles`：管理员/仲裁花名册。角色不通过函数参数临时声明，而是查文档花名册；同一玩家不得同时出现在两组。
- `filed_utc`：证据窗口的锚点。没有它无法区分“立案前提交”和“过期提交”。
- `audit`：管理员动作的独立审计。受理、驳回、裁定、更正和结案各追加一条；AI 建议永远不写入。

`manager_only` 固定为 `true`，伪造为 `false` 的文档会被拒绝。

## 规则

### 写时复制

所有公开变更入口 `file()`、`accept()`、`reject()`、`submit_evidence()`、`rule()`、`appeal()`、`correct()`、`close()` 都先只读校验输入文档，校验通过后才 `duplicate(true)` 出候选，并只修改候选。

- 成功返回 `{ok: true, reason: "", case_id, status, state}`；调用方必须把返回的 `state` 作为下一次操作的输入。
- 失败返回 `{ok: false, reason, case_id}`，不携带 `state`。
- 输入文档在成功和失败路径上都保持逐字节不变。权威落盘失败时，内存不会留下半应用的案件状态。
- 候选与候选之间相互独立；连续变更不会修改前一个候选。

### 状态机

- `filed`：立案后状态。只能受理或驳回；不产生处罚。
- `accepted`：管理员/仲裁受理。可以裁定或继续收证据。
- `rejected`：恶意或无效举报被驳回，不再受理证据、不能裁定。
- `ruled`：管理员/仲裁作出裁定，写入裁定人和时间。
- `appealed`：案件双方之一对裁定提出一次申诉，原裁定保留。
- `corrected`：管理员/仲裁追加更正记录，原裁定和申诉历史保持不变。
- `closed`：已更正案件结案；所有历史保留。

### 权限

- `accept`、`reject`、`rule` 的权威模式、`correct`、`close` 只接受花名册中的管理员或仲裁。
- `file`、`submit_evidence` 和 `appeal` 是当事人/参与者动作：立案要求双方是不同的合法玩家；申诉只允许 `filed_by` 或 `against`。
- `rule` 的 `decision` 必须显式包含 `advisor` 与 `authority` 两个布尔值，且恰好一个为真。两个都为真或都为假均返回 `invalid_decision`。
- `advisor: true` 调用返回 `advisory_only`，且在读取案件之前结束，因此不可能修改状态。

### 证据

- 立案必须至少有一个合法且唯一的权威事件 id。
- 证据只受理 `filed`、`accepted`、`ruled`、`appealed` 状态；`rejected`、`corrected`、`closed` 返回 `case_closed`。
- 证据 id 在案件内唯一；重复返回 `duplicate_evidence`。
- 证据类型限定为 `authority_event`、`ledger`、`witness`、`chat`、`document`。
- 证据时间不得早于立案时间；超过立案后 7 天（`EVIDENCE_WINDOW_SECONDS = 604800`）返回 `evidence_expired`。窗口边界本身仍受理。
- 证据按时间非递减追加；乱序提交返回 `time_regression`。

### 裁定与更正

- 裁定只能从 `accepted` 进入，结果限定为 `upheld`、`dismissed`、`warning`、`compensation`，理由不得为空白。
- 裁定写入 `ruling`，并追加 `rule` 审计；重复裁定返回 `invalid_status`。
- 申诉只能在 `ruled` 后提出一次；重复申诉返回 `already_appealed`。
- 更正允许在 `ruled` 或 `appealed` 后执行，追加 `corrections` 与 `correct` 审计，不修改 `ruling` 和 `appeals`。重复更正返回 `already_corrected`。
- 结案只允许从 `corrected` 进入，追加 `close` 审计；重复结案返回 `already_closed`。
- 时间倒序的管理动作返回 `time_regression`，不会写入任何记录。

### 上限

- 案件 `MAX_CASES = 256`；每案权威事件 `MAX_EVENTS = 32`；每案证据 `MAX_EVIDENCE = 64`；每角色花名册 `MAX_AUTHORITY = 32`。
- 申诉与更正各最多 1 条，审计最多 4 条（受理、裁定、更正、结案）。
- 理由最长 256 字符，证据来源最长 128 字符；id 沿用 `OwnerIds` 的格式与长度限制。
- 超限写入返回 `capacity`、`invalid_events` 或 `invalid_evidence`，不会产生非法文档。

### 严格校验

`valid()` 除键集、枚举、时间、id 和上限外，还校验状态与历史的对应关系：

- `filed` 不得有裁定、申诉、更正或审计。
- `accepted`/`rejected` 必须有且只有对应的受理/驳回审计。
- `ruled` 及之后必须有裁定，且审计顺序为 `accept`、`rule`。
- `appealed` 必须有 1 条申诉；`corrected`/`closed` 必须各有 1 条更正。
- `closed` 额外要求 `close` 审计，且时间不早于更正。
- 审计中的行为者必须在花名册中；裁定人与裁定审计、更正人与更正审计必须一致。
- 删除受理审计、伪造裁定人、篡改状态或加入窗口外证据都会使文档失效。

## 验证

实际运行命令：

```sh
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 120 /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot --headless --path Game --script "$PWD/tests/dispute_state_test.gd"
```

原始末行：

```text
DISPUTE_STATE_TEST checks=183 failures=0
```

覆盖：立案/重复/无事件、受理权限与越权拒绝、驳回、证据窗口与状态限制、AI 建议被拒且文档深度不变、裁定→申诉→更正保留历史、结案、非法文档拒绝、案件/证据/事件上限，以及写时复制契约（输入不变、连续变更基于返回候选、失败不返回候选）。

## 未覆盖

- 外部权威事件的存在性与内容核验（需要事件日志切片）。
- 真实处罚、资产扣减、补偿分录、权属更正事件和封禁/恢复备份。
- 游戏官府与服务器管理员的独立凭据、管理操作独立日志通道。
- 网络身份绑定、命令重放、并发写入和权威时钟。
- 存档读写、界面、通知和申诉时限升级。
- 多管理员合议、回避、利益冲突和跨世界案件。
- 上述事项完成前，M12-04 不能标记完成。

## 关联

- [M12 计划](PLAN.md) 的 M12-04 段（本记录不修改计划，登记由主会话完成）。
- [领土政治、私兵、有限 PvP 与官府执法](../../systems/politics-conflict-law.md)。
- [RECORD-02 · 参与制度](RECORD-02-participation.md) 与 [ADR-025](../../decisions/ADR-025-conflict-participation.md)。
- 实现：[`Game/world/dispute_state.gd`](../../../../Game/world/dispute_state.gd)；测试：[`tests/dispute_state_test.gd`](../../../../tests/dispute_state_test.gd)。
