# RECORD-18 · 纠纷面板切片

状态：切片完成，未验收；只表示 M12-04 的界面接入部分，不表示 M12-04 已完成。
日期：2026-11-16。

## 问题

[RECORD-17](RECORD-17-dispute-authority.md) 已把纠纷规则接到 `HeadlessWorld`、
`disputes.json`、RPC 23/24 与 `WorldClient.request_dispute()/dispute_result`，
但没有界面。本切片增加只读案件展示与当事人/管理员操作入口，解决：

- 普通玩家如何看到与自己相关的案件、公开状态与权威时钟；
- 管理员如何看到全部案件和权威花名册；
- 立案、证据、申诉、受理、驳回、裁定、更正、结案如何只成为权威请求；
- 裁定、更正、结案如何避免误触；
- 答复到达后如何整份替换视图，并显示权威拒绝文案；
- 面板与 HUD、Esc、右键、刷新和关闭如何归属。

## 边界

- 面板不判断管理员身份、案件状态、证据窗口、申诉资格或裁定结果；全部由
  `disputes.json` 花名册与 `DisputeState` 规则决定。
- 面板不本地放行、改写、删除或补全案件，不乐观更新，不合并增量。
- `advisor` 复选框只改变发给权威的 `decision.advisor/authority` 两个标志。
  面板不本地拦截，也不自行显示 `advisory_only`；拒绝文案由权威答复给出。
- 未实现通知、案件详情分页、证据文件上传、申诉时限、多人合议或回避。
- 本切片未修改世界权威、存储、RPC 或网络测试。

## 实现

### 面板：`Game/ui/dispute_panel.gd`

- 信号：`dispute_action(action, args)`、`refresh_requested`、`closed`。
- 视图字段与权威 `disputes_view()` 一致：
  `{available, now_utc, viewer, is_authority, authority_roles, cases, public}`。
- 只读区：
  - 状态行显示可用性、权威 UTC 与视角（管理员/玩家/访客）；
  - 管理员显示权威花名册（admin/arbiter）；
  - `cases` 整份渲染，每行含案件编号、立案人、被举报人、状态、证据数、
    裁定摘要（outcome/by/at_utc/reason 或“未裁定”）、申诉数、更正数、
    审计数与每条审计条目；
  - `public` 单独渲染，只含编号、状态与立案 UTC。
- 普通玩家区：立案（case_id/against/event_ids）、提交证据
  （case_id/evidence_id/kind/source）、申诉（case_id/reason）。
- 管理员区仅在 `is_authority` 为真时可见：受理、驳回、裁定
  （case_id/outcome/reason/advisor）、更正、结案。
- 裁定、更正、结案点击后先弹 `ConfirmationDialog`；取消不发请求。
- 每个动作的请求 id 同时写入载荷 `command_id`；面板只构造
  `{command_id, ...}`，由 `main.gd` 转给 `WorldClient.request_dispute()`。
- 证据的 `submitted_by`/`at_utc` 不由面板发送；确认框关闭、面板收起时清空待发动作。
- `is_popup_open()` 覆盖确认框与两个下拉；首个 Esc 交给弹层，第二个关闭面板。

### 入口与接线

- `Game/scenes/farm_hud.gd`：新增 `dispute_requested` 信号与“纠纷”按钮
  （节点名 `Dispute`），始终可见；单机打开由场景说明需要共享世界。
- `Game/scenes/main.gd`：
  - 创建 `DisputePanel`（节点名 `Dispute`），连接动作、刷新、关闭；
  - `_open_dispute()` 先摆出上次已知视图，再请求 `"dispute-state"`；
  - `_dispute_refresh()` 请求权威状态；
  - `_dispute_action()` 以载荷里的 `command_id` 作为请求 id 转发；
  - `remote.dispute_result` 连接到 `dispute_panel.apply_result`；
  - `_input()` 增加面板归属：确认框/下拉占用首个 Esc，之后 Esc 或右键关闭，
    面板可见时世界镜头不接收输入。
- 单机（`remote == null`）不虚构本地案件，状态行提示“纠纷需要进入共享世界”。

## 覆盖矩阵

| 要求 | 测试证据 |
|---|---|
| 只读状态、案件编号、双方、状态、证据数、裁定、申诉/更正计数、审计 | `A case row shows...`、`The ruling summary...`、`Every audit entry...` |
| 普通玩家只显示权威下发的相关案件 | 视图只含两案；`All authoritative related cases are kept` |
| 公开状态行单独显示 | `The public status rows are rendered separately`、`A public row shows only...` |
| 管理员花名册与全部案件 | `The administrator sees the authoritative roster`、`The administrator sees every case in the view` |
| 普通玩家看不到管理员区/按钮 | `The administrator section is hidden...`、`Administrator actions are not offered...` |
| 立案请求字段 | `The filing request carries...` |
| 证据请求字段且不含提交人/时间 | `The panel does not claim an evidence author or time` |
| 申诉请求字段 | `An appeal forwards the case and trimmed reason` |
| 受理/驳回转发 | `Accept forwards the trimmed case id`、`Reject forwards a reject intent` |
| 裁定确认与取消不发送 | `Ruling opens a confirmation...`、`Cancelling the ruling confirmation sends no request` |
| 裁定 decision 字段 | `An unchecked advisor box sends an authority decision`、`The selected outcome...` |
| advisor 原样转发 | `The advisor flag is forwarded for the authority to judge`、`An advisory_only refusal...` |
| 更正/结案确认与字段 | `Correcting only opens a confirmation`、`Confirming forwards only the closing case id` |
| 请求 id 即 command_id | `The filing request id doubles as the command id` |
| `apply_result` 整份覆盖 | `The reply's state replaces the case list`、`A case missing from the reply is not kept locally` |
| 拒绝文案与 reason 回退 | `A refused reply shows the authority's reason text`、`...shows the authority reason code` |
| duplicate 与成功提示 | `A duplicate reply is reported`、`A successful filing is reported` |
| 刷新/关闭信号与 Esc 归属 | `Refreshing asks the caller...`、`Esc closes the dispute panel`、`Closing returns keyboard focus...` |

## 验证

实际运行命令：

```sh
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 300 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/dispute_panel_test.gd"
```

原始末行：

```text
DISPUTE_PANEL_TEST checks=92 failures=0
```

解析检查（`--check-only --script`，无输出错误）覆盖
`Game/ui/dispute_panel.gd`、`Game/scenes/farm_hud.gd`、`Game/scenes/main.gd`、
`tests/dispute_panel_test.gd`。

回归：

```text
PARTICIPATION_PANEL_TEST checks=69 failures=0
CONFLICT_PANEL_TEST checks=74 failures=0
```

测试分类说明：面板 preload `FarmTheme`，后者 preload 艺术字体
`res://art/ui/fonts/汇文明朝体.ttf`，因此 `dispute_panel_test` 与现有
`participation_panel_test`、`conflict_panel_test` 同属 scene_tests 类型；本任务
不允许修改 `.github/`，未把新测试加入 CI 列表。

## 未覆盖

- 真实 WSS 下从面板点击到权威答复的端到端 UI 链路；后端 RPC 23/24 已由
  `dispute_network_test` 覆盖，但本切片没有 UI 联调测试。
- TCC 权限弹窗、真实鼠标点按与真实窗口焦点；测试使用 `SceneTree` 直接构造视图
  与 `push_input`。
- Windows 未验证；本切片只在 macOS 无头 Godot 上运行。
- 真实管理员花名册变更、证据文件上传、通知与申诉时限。
- `compensation` 裁定结果只是语义记录；权威当前不执行资产补偿、封禁或恢复备份。
