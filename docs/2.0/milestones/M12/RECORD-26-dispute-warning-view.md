# RECORD-26 · 纠纷警告期限接入视图与面板切片

状态：切片完成，未验收；只表示 M12-04 中“警告裁定的派生期限随权威视图下发，
当事人在面板看见警告窗口”的切片，不表示 M12-04 已完成。
日期：2026-11-16。

## 问题

[RECORD-22](RECORD-22-dispute-warning-window.md) 已实现纯规则
`Disputes.warning_state()`，但该函数只被测试调用：`HeadlessWorld.disputes_view()`
不下发警告状态，`WorldHost` 的 RPC 23/24 答复里没有它，`DisputePanel` 也不
显示。于是玩家即使收到警告裁定，也看不到警告何时生效、何时到期。本切片
把已存在的派生规则接到权威视图和界面：

- 权威视图给相关成员与管理员下发当刻警告状态；
- 面板在案件行显示“警告 生效中/已到期/未开始｜UTC 起 至 止”；
- 公开状态行仍只有案件号、状态与立案时间，不含警告细节。

## 边界

- 只改 `Game/world/headless_world.gd`、`Game/ui/dispute_panel.gd`、
  `tests/dispute_authority_test.gd`、`tests/dispute_panel_test.gd`；`disputes.json`
  格式、RPC 编号、`.github/` 与 `rules/` 均不变。
- 不新增存储字段，不迁移旧档；警告状态每次由裁定时刻与常量重新派生。
- 不实现封禁、警告撤销或提前解除、期限内再犯升级，也不改变裁定的执行方式。
- 面板仍不自行计算 30 天窗口；它只渲染权威给的 `warning`。

## 实现

### 权威视图：`HeadlessWorld.disputes_view()`

对管理员与案件相关成员可见的完整案件行，构造副本后调用
`Disputes.warning_state(disputes, case_id, authority_now_utc())`；只有
`ok` 为真时才写入 `full["warning"]`。因此：

- 非警告裁定、未裁定案件的完整行没有 `warning` 键；
- 公开行（`public`）结构不变，匿名或无关玩家拿不到警告状态；
- `now_utc` 与派生用的时钟是同一个 `authority_now_utc()`，客户端看到的状态
  与同一答复里的时间一致。

`world_host.gd` 的 RPC 23/24 原样转发 `disputes_view()`，无需额外改动。

### 面板：`Game/ui/dispute_panel.gd`

`_case_text()` 在证据/裁定摘要行之后、审计行之前追加：

```text
警告 生效中｜UTC 1500 至 2593500
```

`status` 经 `_warning_text()` 映射为“生效中 / 已到期 / 未开始”，未知值原样
显示。没有 `warning` 键或 `ok=false` 时不输出该行。面板不缓存、不推断期限。

## 验证

实际运行（macOS 无头 Godot 4.7.2）：

```sh
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 180 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/<test>.gd"
```

| 测试 | 结果 |
|---|---|
| `dispute_authority_test` | `checks=188 failures=0` |
| `dispute_panel_test` | `checks=100 failures=0` |
| `dispute_state_test` | `checks=244 failures=0` |
| `font_coverage_test` | `checks=1272 failures=0 missing=0` |

新增断言：

- 立案 → 受理 → 警告裁定后，立案人与被警告方都在案件行看到 `warning.ok`；
- 状态为 `active`，`expires_utc - starts_utc` 精确等于
  `Disputes.WARNING_WINDOW_SECONDS`；
- 无关玩家的公开行没有 `warning`；没有警告裁定的案件行没有该键；
- 面板夹具的 `warning` 渲染为“警告 生效中｜UTC 1500 至 2593500”，无警告
  案件不渲染警告行。

## 未覆盖

- 警告提前撤销、期限内再犯的升级后果、警告与封禁换算；这些处罚策略尚未
  定义。
- 警告到期时的主动推送或提醒；客户端只在刷新/收到新答复时看到新状态。
- 真实网络下面板跨天观察状态从 `active` 变 `expired`；本切片用受控时钟在
  权威测试里验证。
- Windows、真实鼠标点按与 TCC 权限弹窗。

## 关联

- [M12 计划](PLAN.md) 的 M12-04 段。
- [RECORD-22 · 纠纷警告期限](RECORD-22-dispute-warning-window.md)。
- [RECORD-17 · 执法闭环接入世界权威](RECORD-17-dispute-authority.md)。
- [RECORD-18 · 纠纷面板](RECORD-18-dispute-panel.md)。
- 实现：`Game/world/headless_world.gd`、`Game/ui/dispute_panel.gd`。
- 测试：`tests/dispute_authority_test.gd`、`tests/dispute_panel_test.gd`。
