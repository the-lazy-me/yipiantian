# M11-03 · 规则决议界面面板

执行日期：2026-11-16。状态：切片完成，不表示 M11-03 或 M11 验收完成。前置：[M11 PLAN](PLAN.md)、[RECORD-05 · 规则决议](RECORD-05-resolutions.md)、[RECORD-11 · 规则决议 sidecar](RECORD-11-resolutions-store.md)、[RECORD-12 · 规则决议权威与 RPC](RECORD-12-resolutions-authority.md)。

## 问题

RECORD-12 把决议接入了世界权威与 RPC 27/28，但客户端没有任何入口：`resolutions_view()` 的版本差异、决议行、投票窗口和隐私分级都只能通过日志或测试查看。玩家无法提案、表决或推进生命周期，界面层也还没有一个只转发意图、不自行放行规则的面板。

本切片只补界面：新增一个决议面板、底栏入口和场景接线。规则、视图形状、RPC、隐私分级和存档格式都不改。

## 边界

- 新增 `Game/ui/resolutions_panel.gd`、`tests/resolutions_panel_test.gd` 与本记录。
- 修改 `Game/scenes/farm_hud.gd`（底栏「决议」入口与 `resolutions_requested` 信号；复核时一并修好底栏溢出）、`Game/scenes/main.gd`（实例化、打开、刷新、动作转发、`resolutions_result` 接线、断线/重连清空、Esc/右键归属）、`tests/debug_time_preview_test.gd`（图标断言只约束真正带图标的按钮）。
- 未修改 `Game/world/**`、`Game/farm/**`、`.github/`、`rules/`、任何 `PLAN.md`、`docs/2.0/research/LICENSES.md`。
- 面板不本地修改规则版本、状态或票数，不合并增量视图，也不乐观更新。

## 面板形状

沿用 `dispute_panel.gd` / `participation_panel.gd` 的模板：全屏 `Control` 遮罩 + 居中 `PanelContainer`、
`FarmTheme` 主题、`refresh_requested` / `closed` 信号、`present` 之外的 `open_panel(view)` /
`apply_result(request_id, payload)`、Esc/右键关闭并归还焦点、`ConfirmationDialog` 二次确认、
按钮只发 `resolution_action(action, args)`。

自上而下：

1. 标题行：标题、刷新、收起。
2. `RulesVersion`：`规则版本 vN`；`available=false` 时显示「世界尚未打开」或权威给出的原因。
3. `ViewerState`：`成员/访客｜玩家 id`，按视图的 `can_write` 区分；只用来显示，
   不参与授权。
4. `VersionList`：按 `versions` 原样逐行「vN 生效/撤销 · 决议 id」。
5. `ResolutionList`：每行显示 id、类型、标题、提案人、状态、投票窗口、生效时刻、修订号、
   生效/撤销版本；成员视图额外显示赞成/反对人数；相关成员视图显示投票人 id；
   已撤销显示 `ends_utc`（`失效 UTC …`）。
6. `ActionSection`：`ResolutionSelect` 选择决议，`Approve`/`Reject` 表决，
   `Withdraw`/`CloseVote`/`Activate`/`Revoke` 生命周期。
7. `ProposalSection`：`ResolutionId`、`Kind`（选项来自 `ResolutionState.KINDS`）、`Title`、
   `VoteStart`/`VoteEnd`/`EffectiveUtc`，提交前二次确认。
8. `Status`：拒绝原因与成功提示。

## 显示性显隐

按钮是否出现只依据视图：

- 表决：`can_write` 且状态 `proposed`，查看者非空、不是提案人、且不在 `approvers`/`rejecters`。
- 撤案：状态 `proposed` 且查看者是提案人。
- 关闭投票：`can_write` 且状态 `proposed`。
- 生效：`can_write` 且状态 `passed`。
- 撤销：`can_write`、状态 `effective`、查看者在 `approvers`。

`is_member` 保留原义（“已加入”，决定计票人数是否出现），不再决定写入按钮。
这些都只是显示性判断，真正的权限、投票窗口、预告期、计票阈值和生命周期仍由
`ResolutionState` 与权威执行；被拒绝时面板原样显示 `reason_text`（缺失时用 `reason`），
且不改变本地视图。`available=false` 时版本/决议列表显示不可用文案，选择器与全部写入按钮禁用。

## 请求形状

- `propose`：`{"resolution_id", "proposal": {kind, title, vote_start_utc, vote_end_utc, effective_utc}, "command_id"}`。
  时间字段由面板检查为非负数字；窗口顺序与预告期交给权威。
- `vote`：`{"resolution_id", "approve": bool, "command_id"}`。
- `close`/`activate`/`withdraw`/`revoke`：`{"resolution_id", "command_id"}`。
- 面板不发 `actor`/`proposer`/`voter`；`command_id` 由面板生成，`main.gd` 把它同时用作请求 id。

## 场景接线

- `farm_hud.gd` 新增 `resolutions_requested` 与底栏「决议」按钮（`Resolutions`），风格与
  「居民」一致，单机也始终可见。
- `main.gd`：
  - 新增 `resolutions_panel`，挂到 HUD 的 `CanvasLayer` 下；
  - `_open_resolutions()` 先摆出上次视图，单机 `show_unavailable("not_open")`，联机请求 `state`；
  - `_resolutions_refresh()` 请求权威状态；
  - `_resolution_action()` 以载荷里的 `command_id` 作为请求 id 转发；
  - `remote.resolutions_result` 连接到 `apply_result`；
  - `_input()` 增加面板归属：确认框/下拉占用首个 Esc，之后 Esc 或右键关闭，面板可见时世界镜头不接收输入；
  - 断开与重连时清空并标明世界未打开。

## 验证

```text
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 300 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/resolutions_panel_test.gd"
```

原始末行：

```text
RESOLUTIONS_PANEL_TEST checks=85 failures=0
```

底栏修复的验证用真实 `main.tscn` 量测（无头、1600×900 逻辑画布）：

```text
single bar=[P: (24.0, 834.0), S: (1552.0, 49.0)] min=(1516.0, 49.0) bad=0
shared bar=[P: (24.0, 834.0), S: (1552.0, 49.0)] min=(1444.0, 49.0) bad=0
```

`bad` 统计越出可见区或与前一项重叠的可见按钮数。修复前同一探针给出
`BAR [P: (280.0, 834.0), S: (1824.0, 49.0)]`，`设置` 起点 x=1992。

完整的真实窗口一步：

```text
SETTINGS_TOOLBAR_TEST failures=0 output=.../.local/verification/settings-toolbar-338466
FARM_INTERACTION_TEST checks=80 failures=0
```

回归：

```text
DISPUTE_PANEL_TEST checks=98 failures=0
PARTICIPATION_PANEL_TEST checks=69 failures=0
FONT_COVERAGE_TEST checks=1271 failures=0 missing=0
```

字体：`Game/ui/resolutions_panel.gd` 新增的中文文案已包含在当前
`Game/art/ui/fonts/汇文明朝体.ttf`（`python ArtSource/UI/Fonts/subset.py` 重建，
1365 字符 / 2,051,600 字节 / SHA-256
`a7c4d6c34a95884a6a21c611e7f80e340adab3c5862cdacba16603589d381b0c`）中；
`字体来源.txt` 记录的三个数字与重建结果一致，本切片未再改动该文件。字体覆盖测试
`failures=0`。

覆盖矩阵：

| 要求 | 测试证据 |
|---|---|
| 规则版本、成员/访客、刷新与收起 | `The header shows the authoritative rules version`、`The header marks the viewer as a member` |
| 版本差异原样显示 | `Every version row is rendered verbatim and in order` |
| 决议行字段 | `A row shows its id, kind, title, proposer and status`、`...the vote window, effective time, revision and versions` |
| 计票与身份分级 | `A member sees the approval and rejection counts`、`A related member sees the voter ids`、`A non-member sees no vote counts`、`...no voter identities` |
| 已撤销失效时刻 | `A revoked row shows its authoritative end time` |
| 按钮显隐 | `A member who has not voted sees the vote buttons...`、`A non-proposer is not offered withdrawal`、`...offered activating a passed proposal`、`An approving member is offered revocation...`、`A non-member is not offered the vote buttons` |
| 提案请求字段 | `The proposal request carries the trimmed resolution id`、`...selected kind and trimmed title`、`...three UTC times as numbers`、`The panel does not claim a proposer` |
| 表决各一次正确请求 | `Confirming emits one vote intent`、`Reject sends an opposing vote for the same row` |
| 生命周期各一次正确请求 | `Confirming %s forwards the selected row once`（close/activate/withdraw/revoke） |
| 确认框取消不发送 | `Clicking approve alone only opens a confirmation`、`Cancelling the vote confirmation sends no request`、`Cancelling %s sends nothing` |
| 拒绝文案 | `A refused action shows the authority's reason text`、`...shows the authority reason code`、`A refusal with no state leaves the visible resolutions untouched` |
| `available=false` | `An empty view disables the resolution list`、`An unavailable world clears the list and disables the picker` |
| 只读渲染 | `Rendering the view writes nothing`、`Selecting a row sends no request and does not edit the view` |
| Esc 关闭与焦点归还 | `An open vote confirmation reports that it owns Esc`、`Esc closes the resolution panel`、`Closing returns keyboard focus...` |

## 未覆盖

- 真实 WSS 下从面板点击到权威答复的端到端 UI 链路；后端 RPC 27/28 已由
  `resolution_network_test` 覆盖，本切片没有 UI 联调测试。
- 真实鼠标点按、真实窗口焦点和 Windows 实机；测试使用 `SceneTree` 直接构造视图与
  `push_input`。
- 提案表单没有本地预填权威时钟：`now_utc` 只用于展示决策依据，时间字段要求玩家显式填写。
- 底栏宽度：新增「决议」后 1600×900 逻辑画布下有 16 个入口。复核时实测工具条
  `combined_minimum_size` 为 1824 px、起点 x=280，「设置」完全在可见区外，即本次改动前
  底栏就已溢出。已在同一提交修好：13 个纯文字入口的固定宽度由 104 改为 68（两字标签本来
  用不到图标槽），工具条改为左右锚定整宽、居中排布（`offset_left=24`、`offset_right=-24`）。
  实测单机 15 个可见入口 1516 px、联机（多「邻里」「宅基」、少「建设」「菜篮」）1444 px，
  两种模式都完整落在 1552 px 可用宽度内，无按钮越界或相互重叠。
  `tests/debug_time_preview_test.gd` 的 `Toolbar uses left icon and text` 原来要求每个按钮
  都必须有图标，与「世界入口没有对应美术、保持纯文字」的既有实现冲突（改动前就恒失败），
  已改为只对带图标的按钮断言左图标排版。

## 关联

- 阶段计划与验收：[M11 PLAN](PLAN.md)（本记录不修改）。
- 权威与网络：[RECORD-12](RECORD-12-resolutions-authority.md)。
- 面板模板：[M12 RECORD-11 · 参与制度面板](../M12/RECORD-11-participation-panel.md)、
  [M12 RECORD-18 · 纠纷面板](../M12/RECORD-18-dispute-panel.md)。
