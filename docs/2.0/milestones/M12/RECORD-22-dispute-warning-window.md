# RECORD-22 · 纠纷警告期限与到期纯规则切片

状态：切片完成，未验收；只表示 M12-04 中“警告裁定带期限、可按时刻派生
生效/到期/未开始”的纯规则部分，不表示 M12-04 已完成。
日期：2026-11-16。

## 问题

[RECORD-20](RECORD-20-dispute-enforcement.md) 已让 `compensation` 裁定真实
转账，但同为裁定结果的 `warning` 仍只是 `ruling.outcome` 的语义记录：没有
期限，也没有任何函数能回答“这条警告在某个时刻是否仍生效”。“未覆盖”一节
明确写着警告期限未实现。本切片补齐可纯规则完成的部分：

- 给警告裁定一个明确的持续期限；
- 提供纯规则查询，判断某条警告在给定时刻是仍生效、已到期还是未开始；
- 到期只改变派生可见状态，不删除案件、裁定、证据或审计历史。

## 边界

- 只改 `Game/world/dispute_state.gd` 与 `tests/dispute_state_test.gd`；没有
  修改权威侧（`headless_world.gd`、`world_host.gd`、`disputes_store.gd`）、
  场景、界面、`.github/` 或 `rules/`。
- 不做封禁、解封、恢复备份、权属更正、执行预算消耗，也不把警告接到权威、
  RPC、视图或面板；这些都需要接权威，属后续切片。
- 不新增文档字段：`state` 仍严格两键，案件仍严格十一键，`valid()` 的键集和
  归一化路径完全不变，旧文档无需迁移。
- 结案、更正和申诉都不撤销警告，也不缩短期限；它们只追加历史，原裁定结果
  和裁定时刻保持不变。

## 决定

### 期限与常量

```gdscript
const WARNING_WINDOW_SECONDS: float = 2592000.0  # 30 天
```

理由：30 天与项目现有最长合同期限一致（借款和保险都用 7/14/30 天，最长
30 天），给被警告方一个完整、可预期的改正窗口；它比 7 天证据窗口更长，因为
警告约束的是后续行为而不是举证期限。警告不再叠加第二个期限概念，避免把
“多久内再犯会升级”这种尚未定义的处罚规则提前写进文档。

### 半开区间

警告从裁定时刻 `ruling.at_utc` 起算，到 `ruling.at_utc +
WARNING_WINDOW_SECONDS` 为止，按 `[起算, 到期)` 判定：

| 查询时刻 | 派生状态 |
|---|---|
| `< 起算` | `not_started` |
| `>= 起算` 且 `< 到期` | `active` |
| `>= 到期` | `expired` |

恰好等于到期时刻即为 `expired`，与证据窗口既有的“边界外一秒拒绝、边界内
一秒接受”保持一致的可测边界语义。

### 派生而不落盘

期限完全由不可变的 `ruling.at_utc` 和常量派生，因此不写入 `cases`：

- 不新增字段，就不必改键集校验、`normalize()` 或存储信封；
- 同一文档在不同时刻查询得到不同结果，但文档本身逐字节不变；
- 到期不会触发任何写入，也不会误删案件与审计历史；
- 重放同一查询是幂等的，序列化往返后结论相同。

### 查询接口

```gdscript
Disputes.warning_state(state, case_id, at_utc) -> Dictionary
```

成功返回：

```json
{
  "ok": true, "reason": "", "case_id": "...", "status": "active",
  "starts_utc": 1800000002.0, "expires_utc": 1802592002.0
}
```

失败返回 `{ok: false, reason, case_id}`，且绝不带 `status`：

| 输入 | 具名原因 |
|---|---|
| 文档未通过完整 `valid()` | `invalid_state` |
| 案件 id 非法 | `invalid_case` |
| 查询时刻非法、负数、非有限 | `invalid_time` |
| 案件不存在 | `missing_case` |
| 案件无裁定或裁定不是 `warning` | `no_warning` |

`state` 入口先跑完整 `valid()` 而不是只查局部字段：派生值不能成为绕过文档
校验的旁路，伪造键（例如给案件加一个 `warning_until`）会直接失败关闭。

## 覆盖矩阵

| 要求 | 测试证据 |
|---|---|
| 警告未到期 | `A warning is active at its ruling instant`、`...one second after the ruling`、`...one second before expiry` |
| 恰好到期 | `A warning is expired exactly at the end of the half-open window` |
| 已到期 | `A warning stays expired after the window` |
| 未开始 | `The derived warning has not started before the ruling time` |
| 起止时刻 | `A warning starts at the ruling time and lasts one warning window` |
| 案件关闭后行为 | `A closed case still derives its warning as expired`、`Closing does not shorten the warning window`、`Closing keeps the case and its full audit history`、`Closing keeps the original warning ruling` |
| 非警告裁定 | `A dismissed ruling derives no warning state` |
| 非法输入具名拒绝 | `invalid_state`（伪造键、伪造状态）、`invalid_case`、`invalid_time`（负数、字符串、无穷）、`missing_case`、`no_warning`；均断言不回 `status` |
| 查询不写文档 | `Warning queries leave the document byte-identical`、`Refused warning queries leave the input unchanged` |
| 文档重放幂等 | `Replaying the same warning query is idempotent`、`The replayed warning query keeps the same derived status` |
| 序列化往返稳定 | `The warning document survives JSON encoding`、`The decoded warning document is still valid`、`Reserializing the decoded document is byte-stable`、`The decoded document derives the same warning status`、`The decoded document keeps the warning window bounds` |
| 严格形状不变 | `Warning state is not stored as a new case field`、逐个 `CASE_KEYS` 存在性断言 |

## 验证

实际运行命令（末行即证据）：

```sh
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 180 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/dispute_state_test.gd"
```

```text
DISPUTE_STATE_TEST checks=244 failures=0
```

回归：

```text
DISPUTE_AUTHORITY_TEST checks=179 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/dispute-authority-577006
SIDECAR_STORE_GUARDS_TEST checks=246 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/sidecar-store-guards-299766
```

字体覆盖：本切片新增中文注释没有引入子集外汉字。直接跑
`font_coverage_test` 时报告 4 项缺失（`困`、`池`、`薪`、`难`），全部来自同一
工作区的并行代理正在修改的 `Game/conflict/unit_state.gd`：该文件的 `HEAD`
版本不含这三个字，它们由并行改动新加；本切片两个文件不含这些字（逐字核对）。
为取得不越界的证据，在 `.local/verification/` 放了一个只读探针，扫描 `Game`
文本但排除该并行文件：

```text
FONT_COVERAGE_EXCLUDING_PARALLEL checks=1369 missing=0
```

本切片未改字体文件，也未修改该并行文件。等并行改动补齐字体子集后，
`font_coverage_test` 应恢复全绿。

## 未覆盖

- 封禁、解封、恢复备份、权属更正与执行预算消耗。
- 警告接入权威：本切片时 `HeadlessWorld`/`WorldHost` 尚无 `warning` 查询或
  视图动作；现由 [RECORD-26](RECORD-26-dispute-warning-view.md) 补齐视图与
  面板，RPC、摘要仍不下发警告剩余时间。
- “期限内再次违规的升级后果”“警告撤销或提前解除”“警告与封禁的换算”
  这些处罚策略尚未定义，本切片不发明规则。
- 其他裁定结果（`upheld`、`dismissed`）的期限语义；本切片只处理 `warning`。
- Windows、长时间运行和时钟回拨。

## 关联

- [M12 计划](PLAN.md) 的 M12-04 段（本记录不修改计划）。
- [RECORD-04 · 案件基础](RECORD-04-disputes.md)。
- [RECORD-17 · 执法闭环接入世界权威](RECORD-17-dispute-authority.md)。
- [RECORD-20 · 纠纷事件核验与补偿执行](RECORD-20-dispute-enforcement.md)。
- 实现：`Game/world/dispute_state.gd`。
- 测试：`tests/dispute_state_test.gd`。
