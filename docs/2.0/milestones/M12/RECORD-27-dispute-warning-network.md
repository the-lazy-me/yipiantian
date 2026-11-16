# RECORD-27 · 纠纷警告期限真实网络联调切片

状态：切片完成，未验收；只表示 M12-04 的“警告裁定面板 → 真实权威 → `disputes.json`
→ 当事人面板警告窗口”端到端切片，不表示 M12-04 已完成。
日期：2026-11-16。

## 问题

[RECORD-22](RECORD-22-dispute-warning-window.md) 实现了纯规则
`Disputes.warning_state()`，[RECORD-26](RECORD-26-dispute-warning-view.md) 把派生
警告接到 `HeadlessWorld.disputes_view()` 与 `DisputePanel`，但验证只覆盖权威
单元测试和面板夹具：没有用真实 `world_server.gd` + WSS + 真实 `DisputePanel`
验证“管理员经面板裁定警告 → 立案人与被警告方刷新后看见窗口 → 重放与重启保持
派生结论”的完整链路。本切片补上：

- 房主管理员通过真实面板受理并裁定 `warning`，理由随裁定落盘；
- `disputes.json` 只保存裁定与审计，不出现警告期限字段；
- 立案人与被警告方各自重连、刷新，案件行显示“警告 生效中｜UTC 起 至 止”；
- 无关访客只收到公开状态行，面板没有案件行、渲染文本不含“警告”；
- 同一裁定命令重发返回 `duplicate`，`disputes.json` 字节不变、视图警告不变；
- 权威重启后警告仍由落盘裁定派生，文档字节不变、无新字段。

## 边界

- 只新增 `tests/dispute_warning_network_test.gd` 与本记录，并在
  `docs/2.0/milestones/M12/PLAN.md` 的 M12-04 段追加一句；没有修改 `Game/`、
  `.github/` 或 `rules/`。
- 不新增存储字段、不迁移旧档；警告窗口每次由裁定时刻与常量重新派生。
- 不实现警告撤销、提前解除、期限内再犯升级、封禁或其他处罚形式。
- 面板仍不判断权限、案件状态或窗口；每个视图与结果都来自真实权威回复，
  测试只核对面板文本、文档与视图。
- 使用一个房主/管理员、一个立案人、一个被警告方和一个具名访客；同一时刻
  只有一个 `WorldClient` 连接。

## 实现

### 测试：`tests/dispute_warning_network_test.gd`

按 `Game/scenes/main.gd` 的接线挂载真实 `DisputePanel`：`dispute_action` 原样
转发面板生成的 `command_id`，`refresh_requested` 请求 `dispute-state`，
`client.dispute_result` 同时接到面板 `apply_result` 与测试记录。真实权威以
`--host-player=PLAYER_A` 启动，回环 WSS，RPC 23/24。连接依次打开：

1. **被警告方 T**：提交 `account_open` 真事件（`event_warning_network_open_t`），
   现金 120；该事件是后续立案引用的权威事实。
2. **立案人 B**：通过面板立案 `case_warning_network_1`，被举报人 T，引用上述
   真实事件；检查 `filed_by`/`against`/`filed` 落盘。
3. **房主 A**：通过面板受理，选择“警告”结果、填写理由并确认裁定。检查
   `disputes.json` 的 `status=ruled`、`ruling.outcome=warning`、作者与理由；
   检查案件行没有 `warning` 字段；从权威答复取 `warning`，确认 `ok`、
   `active`、窗口长度等于 `Disputes.WARNING_WINDOW_SECONDS`、起点等于落盘
   裁定时刻，面板显示派生窗口。随后重发捕获到的同一 `command_id` 与参数。
4. **立案人 B（重连）**：打开面板刷新，案件行显示“警告 生效中”和与裁定答复
   一致的 UTC 窗口；视图 `warning` 与裁定答复逐键相同。
5. **被警告方 T（重连）**：同样刷新并核对警告窗口。
6. **访客**：视图只有一条公开状态行、无案件行；面板不渲染 `Case_` 标签，
   `CaseList` 与 `PublicList` 的渲染文本都不含“警告”，管理员区隐藏。
7. **房主 A（重启后）**：权威停止并同目录重启（时钟 +3600 秒），检查
   `disputes.json` 字节不变、裁定保留且无 `warning` 字段；重新打开面板后
   `warning` 仍是 `active`，窗口与重启前逐键相同，读取不写文档。

`disputes.json` 的 `state.cases[case_warning_network_1].ruling` 为
`{outcome: warning, by: PLAYER_A, reason: <理由>, at_utc: >0}`；案件行与信封
都没有额外的期限字段。

## 覆盖矩阵

| 要求 | 测试证据 |
|---|---|
| 房主管理员经面板受理并裁定 warning（带 reason） | `The administrator accepts the warning case through the panel`、`The administrator's warning rule lands on the authority`、`The panel forwarded the warning outcome and reason`、`The panel reports the recorded warning ruling` |
| 案件经 `disputes.json` 落盘 | `disputes.json persists the warning ruling, its author and reason`、`disputes.json records the ruling time the window derives from`、`disputes.json writes no warning deadline field` |
| 立案人刷新后看见“警告 生效中”与 UTC 窗口 | `The filer sees the ruled case (case_warning_network_1)`、`The filer sees an active warning`、`The filer sees the same derived window as the ruling reply`、`The filer warning matches the authority's ruling reply`、`The filer's panel renders the active warning window` |
| 被警告方刷新后看见“警告 生效中”与 UTC 窗口 | `The warned party sees the ruled case (case_warning_network_1)`、`The warned party sees an active warning`、`The warned party sees the same derived window as the ruling reply`、`The warned party warning matches the authority's ruling reply`、`The warned party's panel renders the active warning window` |
| 窗口由裁定时刻与固定常量派生 | `The authority derives the window from the ruling time and constant`、`The derived warning starts at the persisted ruling time` |
| 无关访客只看到公开行，面板不含“警告” | `The visitor sees only the single public status row`、`The visitor's panel renders no case row`、`The visitor's panel has no warning case label`、`The public row carries no warning detail`、`The visitor's rendered case and public lists contain no warning`、`The visitor's panel hides the administrator section` |
| 同裁定命令重发返回 duplicate | `Resending the same warning ruling returns duplicate`、`The panel reports the duplicate ruling from the authority` |
| 重发后 `disputes.json` 字节不变、视图 warning 不变 | `A duplicate warning ruling leaves disputes.json byte-identical`、`The duplicate reply carries the unchanged warning`、`The duplicate reply writes no new warning field` |
| 权威重启后 warning 仍在、派生自落盘裁定、不写新字段 | `The restart loads disputes.json without rewriting it`、`The warning ruling survives the restart`、`The restarted document still has no warning deadline field`、`The restarted authority derives an active warning from the ruling`、`The restarted warning window is identical to the pre-restart window`、`The restarted panel renders the persisted warning window`、`Reading the warning after the restart writes nothing` |
| 管理员的初次答复也带窗口 | `The ruling reply carries an active warning for the administrator`、`The administrator's panel renders the derived warning window` |

## 验证

实际运行命令（仓库根目录）：

```sh
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 180 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/dispute_warning_network_test.gd"
```

原始末行（连续三次一致，单次约 7 秒）：

```text
DISPUTE_WARNING_NETWORK_TEST checks=102 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/dispute-warning-network-392767
DISPUTE_WARNING_NETWORK_TEST checks=102 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/dispute-warning-network-367135
DISPUTE_WARNING_NETWORK_TEST checks=102 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/dispute-warning-network-404497
```

解析检查：`--headless --path Game --script tests/dispute_warning_network_test.gd
--check-only` 无输出错误。三次运行均无 `FAIL`，权威日志无 `SCRIPT ERROR`。

### CI 归类

该测试真实挂载 `DisputePanel`，后者 preload `FarmTheme`，而 `FarmTheme`
preload 艺术字体，因此属于 scene test，需要艺术资源 check out。测试本身在
macOS 无头 Godot 下直接通过，不需要 `--audio-driver Dummy`。本任务不允许修改
`.github/`，未加入 CI 列表；后续维护时应放入 `scene_tests`。

## 未覆盖

- 警告提前撤销、期限内再犯升级、警告与封禁换算；这些策略尚未定义。
- 警告从 `active` 自然变为 `expired` 的真实网络观察；本切片的重启使用
  受控时钟保持在窗口内，到期判定由 RECORD-22/26 的权威测试覆盖。
- 警告到期时的主动推送或提醒；客户端只在刷新或收到新答复时看到新状态。
- 真实 TCC 权限弹窗、鼠标点按/窗口焦点/输入法；测试直接 `emit` 按钮信号。
- Windows；只在 macOS 无头 Godot 上运行。
- 多管理员、两个客户端同时裁定同一案件或命令令牌桶限频下的竞争。
- 真实跨机网络、TLS 证书轮换、断线重连期间发起裁定。

## 关联

- [M12 计划](PLAN.md) 的 M12-04 段。
- [RECORD-26 · 纠纷警告期限接入视图与面板](RECORD-26-dispute-warning-view.md)。
- [RECORD-22 · 纠纷警告期限](RECORD-22-dispute-warning-window.md)。
- [RECORD-21 · 纠纷补偿面板真实网络联调](RECORD-21-dispute-compensation-network.md)。
- [RECORD-19 · 纠纷面板真实网络联调](RECORD-19-dispute-panels-network.md)。
- 实现：`Game/ui/dispute_panel.gd`、`Game/world/world_client.gd`、
  `Game/world/world_host.gd`、`Game/world/headless_world.gd`、
  `Game/world/dispute_state.gd`、`Game/world/disputes_store.gd`。
- 测试：`tests/dispute_warning_network_test.gd`、
  `tests/dispute_panels_network_test.gd`、`tests/dispute_authority_test.gd`、
  `tests/dispute_panel_test.gd`。
