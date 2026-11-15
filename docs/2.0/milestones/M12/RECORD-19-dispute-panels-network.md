# RECORD-19 · 纠纷面板真实网络联调切片

状态：切片完成，未验收；只表示 M12-04 的面板到真实权威端到端联调，不表示
M12-04 已完成。
日期：2026-11-16。

## 问题

[RECORD-17](RECORD-17-dispute-authority.md) 已覆盖 `disputes.json` 与 RPC 23/24，
[RECORD-18](RECORD-18-dispute-panel.md) 已用桩远程覆盖面板行为，但“面板点击 →
真实 `WorldClient` → 真实 `world_server.gd` → 权威文档 → 面板整份刷新”的链路
没有验证。本切片只新增一个真实网络 UI 联调测试，解决：

- 房主/管理员与普通成员的面板是否按权威 `is_authority` 显示不同区域；
- 立案、证据、申诉、受理、裁定、申诉后更正、结案是否能完全从面板发起并落到
  `disputes.json`；
- 拒绝路径（非管理员受理/裁定、访客写入、`advisor` 建议）是否原样显示权威
  文案，且不产生本地放行或文档写入；
- 确认框取消、发送前、刷新和关闭时，面板视图与权威文档是否都不被本地改写；
- 原裁定、申诉与审计在更正和结案后是否保留。

## 边界

- 只新增 `tests/dispute_panels_network_test.gd` 与本记录；没有修改 `Game/`、
  `.github/`、PLAN 或 `rules/`。
- 测试不判断业务规则：管理员身份、案件状态、证据窗口、申诉资格与
  `advisory_only` 全部由真实权威答复决定；测试只核对面板与文档。
- 仍然不执行真实处罚、资产扣减、补偿分录、封禁或恢复备份；`outcome` 只是
  可审计的语义记录。
- 不核验外部权威事件是否真实存在；`event_ids` 仍只做格式、非空与唯一校验。
- 不覆盖多管理员并发、真实鼠标点按、TCC 权限、Windows 或跨机网络。

## 实现

### 测试：`tests/dispute_panels_network_test.gd`

按 `Game/scenes/main.gd` 的接线构造一个真实 `DisputePanel`：

- 挂到 `root`，连接 `dispute_action`、`refresh_requested`、`closed`；
- `client.dispute_result` 连接到面板 `apply_result`，同时记录每个答复；
- 动作转发使用面板生成的 `command_id` 作为请求 id；
- 刷新请求 `"dispute-state"`；
- 打开面板与 `main.gd` 一致：先摆出上次视图，再请求权威状态。

真实权威以 `--host-player=PLAYER_A` 启动，回环 WSS，RPC 23/24；三个连接依次
打开（同一进程只允许一个 `/root/WorldSession`）：

1. **房主 A**：`dispute-state` 返回 `is_authority=true`，花名册 `admin` 含 A；
   面板显示 `AuthorityStatus` 管理员视角、权威 UTC、`AuthorityRoster`、
   `AdminSection`，且案件/公开列表为空。
2. **成员 B**：`is_authority=false`，`AdminSection` 与花名册隐藏，当事人区可见，
   管理员按钮不可见；通过面板立案 → 提交证据，检查回复、面板整份视图与
   `disputes.json`（含权威改写 `submitted_by` 与 `at_utc`）。
3. **房主 A**：通过面板受理 → 裁定（先取消确认框再确认）；取消不发请求、不写
   文档；裁定后检查原裁定、审计 `[accept, rule]` 与落盘。
4. **成员 B**：通过面板申诉，检查原裁定保留、申诉行与状态；再触发隐藏的
   受理/裁定按钮，权威返回 `forbidden`，面板原样显示 `reason_text`，视图与
   文档字节不变。
5. **房主 A**：取消更正/结案确认框各一次；确认更正 → 结案，检查原裁定、
   申诉、更正与审计 `[accept, rule, correct, close]` 全保留并落盘；勾选
   `RuleAdvisor` 后提交，权威返回 `advisory_only`，面板原样显示文案，文档
   字节不变；刷新与关闭面板不再写文档。
6. **访客**：可读公开状态行、无私有案件行；立案与证据均被 `forbidden` 拒绝，
   文案原样显示；刷新与关闭不写文档。

视图比较忽略权威派生字段 `now_utc`（它随权威时钟推进），其余字段与顺序保持
一致；`disputes.json` 没有派生时钟字段，直接逐字节比较。

## 覆盖矩阵

| 要求 | 测试证据 |
|---|---|
| A 收到真实 `dispute-state` 且 `is_authority=true` | `The host's panel sees an available dispute authority`、`The host's view reports is_authority=true` |
| A 管理员区与花名册可见 | `The administrator sees the administrator section`、`The administrator sees the authoritative roster` |
| B `is_authority=false` 且管理员区隐藏 | `The member's view reports is_authority=false`、`The member's panel hides the administrator section` |
| B 面板立案并落盘 | `The member's filing sent through the panel lands on the authority`、`The filing is persisted to disputes.json` |
| B 面板提交证据、权威改写提交人与时间 | `The authority records the member as the submitter`、`disputes.json stores the evidence author and authority time` |
| A 面板受理、裁定 | `The administrator's accept ... lands on the authority`、`The administrator's ruling ... lands on the authority` |
| B 面板申诉且原裁定保留 | `The member's appeal ... lands on the authority`、`An appeal preserves the original ruling in the view` |
| A 申诉后更正、结案且历史保留 | `The correction preserves the original ruling`、`The closed case keeps its appeal and correction history` |
| 全量审计落盘 | `disputes.json persists the closed case, ruling and full audit` |
| 面板整份刷新显示权威状态与审计 | `A refresh re-renders the authoritative closed case and audit`、`The reply's state replaces...`（面板单测） |
| B 受理/裁定 `forbidden` 且原样显示 | `The member's accept is refused by the authority`、`The panel shows the accept refusal text verbatim` |
| 访客立案/证据被拒 | `A visitor's filing is refused as forbidden`、`A visitor's evidence is refused as forbidden` |
| `advisor` 返回 `advisory_only` 且字节不变 | `The advisor ruling refusal reason is advisory_only`、`The advisor ruling leaves disputes.json byte-identical` |
| 确认框取消不发送、不写文档 | `Cancelling the ruling confirmation sends nothing`、`A cancelled correction writes no authority document` |
| 发送前视图保持权威最后状态 | `The panel keeps the authority's last state before sending` 系列 |
| 拒绝后视图保持权威最后状态 | `The refused accept leaves the view at the authority's last state` 等 |
| 刷新/关闭不写文档 | `Refreshing the dispute panel writes no authority document`、`Closing the dispute panel writes no authority document` |

## 验证

实际运行命令：

```sh
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 420 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/dispute_panels_network_test.gd"
```

连续两次原始末行：

```text
DISPUTE_PANELS_NETWORK_TEST checks=198 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/dispute-panels-network-391224
DISPUTE_PANELS_NETWORK_TEST checks=198 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/dispute-panels-network-367007
```

两次运行 `exit=0`，日志无 `FAIL`、`SCRIPT ERROR` 或 `ERROR:`；权威日志有
`WORLD_SERVER_READY`/`WORLD_SERVER_STOP`，无 `WORLD_SERVER_ERROR`。

解析检查（`--check-only --script`）无输出错误，覆盖
`tests/dispute_panels_network_test.gd` 及其 preload 的面板、客户端与世界脚本。

### CI 归类

该测试真实挂载 `DisputePanel`，后者 preload `FarmTheme`，而 `FarmTheme` preload
艺术字体 `res://art/ui/fonts/汇文明朝体.ttf`，所以它属于 **scene test**，与
`dispute_panel_test`、`panels_network_integration_test` 同类，需要艺术资源
checkout 才能运行。本任务不允许修改 `.github/`，未把它加入 CI 测试列表；
后续维护 CI 时应加入 `scene_tests` 数组。

## 未覆盖

- 真实 TCC 权限弹窗、真实鼠标点按、真实窗口焦点与输入法；测试直接 `emit`
  按钮信号。
- Windows；只在 macOS 无头 Godot 上运行。
- 多客户端并发写同一案件、两名管理员同时受理/裁定、命令令牌桶限频下的竞争。
- 真实跨机网络、TLS 证书轮换、断线重连期间发起纠纷操作。
- 外部权威事件的存在性与内容核验、真实处罚/补偿/封禁执行。
- 通知、案件分页、证据文件上传、申诉时限与多人合议。

## 关联

- [M12 计划](PLAN.md) 的 M12-04 段（本记录不修改计划）。
- [RECORD-17 · 执法闭环接入世界权威](RECORD-17-dispute-authority.md)。
- [RECORD-18 · 纠纷面板切片](RECORD-18-dispute-panel.md)。
- [RECORD-16 · 三面板网络联调](RECORD-16-panels-network.md)。
- 实现：`Game/ui/dispute_panel.gd`、`Game/world/world_client.gd`、
  `Game/world/world_host.gd`、`Game/world/headless_world.gd`、
  `Game/world/disputes_store.gd`。
- 测试：`tests/dispute_panels_network_test.gd`、
  `tests/dispute_network_test.gd`、`tests/dispute_panel_test.gd`。
