# M12-02 · 参与制度面板界面（切片）

执行日期：2026-11-16。状态：切片完成，不表示 M12-02 或 M12 验收完成。前置：[M12 PLAN](PLAN.md)、[RECORD-02 · 参与制度](RECORD-02-participation.md)、[RECORD-09 · 参与制度接入世界权威](RECORD-09-participation-authority.md)、[RECORD-10 · 参与制度真实网络测试](RECORD-10-participation-network.md)。

## 问题

参与制度权威已经有 RPC 17/18 和只读视图，但没有可见入口：玩家只能靠日志或手写请求声明制度、同意参与或退战，也看不到权威拒绝原因。界面若自行判断房主身份、角色或上限，会与权威产生第二套事实。

## 边界

- 新增 `Game/ui/participation_panel.gd` 与 `tests/participation_panel_test.gd`。
- 修改 `Game/scenes/farm_hud.gd`（“参战”入口）与 `Game/scenes/main.gd`（打开面板、转发请求、连接答复、Esc/右键归属）。
- 未修改 `Game/world/*`、`Game/conflict/*`、`Game/farm/*`、RPC 频道、协议、存档、CI 或规则文档。
- 面板不判断房主身份、风险声明、角色、退战延迟或损失上限；所有裁决仍由权威给出。面板只用视图里的 `host` 与调用方提供的当前玩家 id 决定显示哪一组操作。

## 字段

面板持有的就是权威的只读参与视图：

```text
{available, host, sequence, now_utc,
 regime{tier, revision, declaration_id, declared_by, declared_utc, effective_utc,
        higher_risk, area_ids, window_ids, loss_cap, offline_loss_cap},
 areas[{id, min_x, min_z, max_x, max_z}],
 windows[{id, start_utc, end_utc}],
 participants[{participant, attacker, defender, consent_revision, consent_utc,
               withdraw_utc, withdraw_effective_utc}],
 losses[{target, window_id, amount}]}
```

- “当前制度”：`limited` 显示“有限冲突：第 N 版｜声明 id｜在线上限｜离线上限｜生效时间”；空制度或 `peace` 显示“和平：当前不开放交战。”。
- “房主”：显示 `host`，本地玩家是房主时追加“（你）”；无房主显示“未登记”。
- 风险区域、时间窗口、参与者与损失累计各成一组，空组显示“还没有…。”。
- 参与者在退战登记后显示“退战登记 <UTC>，生效 <UTC>”，延迟信息来自权威视图，不由界面推算。

## 动作映射

| 界面操作 | action | args |
|---|---|---|
| 刷新 | `state` | 无（request id 固定为 `participation-state`） |
| 声明制度 | `regime` | `{command_id, declaration{tier, declaration_id, effective_utc, higher_risk, areas, windows, loss_cap, offline_loss_cap}}` |
| 同意参与 | `declare` | `{command_id, role: "attacker" 或 "defender"}` |
| 申请退战 | `withdraw` | `{command_id}` |

- 请求 id 形如 `participation-<action>-<ticks_usec>-<counter>`，同时作为载荷里的 `command_id`；`main.gd` 在缺省时补发命令 id。
- 房主声明区只在 `available` 且 `host == self_id` 时出现；玩家操作区只在 `available` 且 `host != self_id` 时出现；没有玩家身份时两区都不出现。
- 声明 `peace` 时忽略区域、窗口与上限输入，发送空范围、空窗口和 0 上限；声明 `limited` 时按固定格式解析：
  - 区域：`区域 id,min_x,min_z,max_x,max_z`，多条以分号或换行分隔；
  - 窗口：`窗口 id,start_utc,end_utc`；
  - 生效时间：UTC 秒，留空取本地当前时间；声明 id、正整数上限、`offline <= online` 等格式错误在发请求前提示。
- 退战不可撤销且延迟生效，点击只打开确认框；取消不发请求，确认后才发 `withdraw`。
- 面板不缓存待确认状态、不本地改写参与者或损失；下一次权威答复整份替换视图。

## 错误展示

- `apply_result(request_id, payload)` 先用 `payload.state` 整份覆盖视图，再显示结果。
- 失败时取 `reason_text`，为空则取 `reason`；两者都为空时显示“参与制度操作被拒绝。”。面板不改写原始原因码，便于定位。
- `duplicate` 显示“这条参与制度操作已经执行过。”；成功的 `withdraw` 显示“退战已登记，延迟结束后才正式退出。”；其他成功答复清空状态行。
- 单机或未连接时由主场景显示“参与制度需要进入共享世界。”或“还没有连上世界，参与制度没有刷新。”，不虚构本地制度。

## 接线

- `farm_hud.gd` 新增 `participation_requested` 与“参战”按钮（节点名 `Participation`）；入口始终可见，单机点击由主场景说明需要进入共享世界。
- `main.gd` 把面板挂到 HUD 的 `CanvasLayer` 下；打开时先摆出上次视图，再用当前 `remote.player_id` 设置 `self_id`，并向权威发 `request_participation("participation-state", "state")`。
- `participation_action` 原样转给 `WorldClient.request_participation`；`remote.participation_result` 连接到 `apply_result`；面板关闭恢复相机输入与 HUD。
- Esc/右键：确认框或下拉先吃掉第一次 Esc；主场景也登记了同一归属，避免相机在面板背后继续处理输入，两条路径最多关闭一次。

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
for f in Game/ui/participation_panel.gd tests/participation_panel_test.gd \
  Game/scenes/farm_hud.gd Game/scenes/main.gd; do
  "$GODOT" --headless --path Game --check-only --script "$PWD/$f"
done
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/participation_panel_test.gd"
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/fund_panel_test.gd"
```

原始末行：

```text
PARTICIPATION_PANEL_TEST checks=67 failures=0
FUND_PANEL_TEST checks=65 failures=0
```

覆盖：

| 用例 | 检查 |
|---|---|
| 可见性 | 初始隐藏；隐藏时不消费 Esc、不抢焦点；打开/关闭信号 |
| 身份分区 | 无身份两区隐藏；房主看到声明区、看不到玩家区；非房主相反 |
| 只读视图 | 空制度显示和平；房主/版本/上限文案；区域、窗口、参与者、损失行；退战延迟来自视图 |
| 声明请求 | peace 空范围与 0 上限；limited 的区域/窗口/上限/生效时间解析；空声明 id、畸形区域、离线超上限、非法时间不发请求 |
| 参与请求 | attacker/defender 角色原样发送；command id 非空 |
| 退战 | 点击只开确认；取消不发；确认发 withdraw 且不带 role |
| 权威答复 | `state` 整份覆盖；成功退战显示延迟提示；失败显示 `reason_text`，缺失时显示 `reason`；duplicate 提示；畸形载荷不崩溃 |
| 焦点与关闭 | 关闭返回打开者焦点；Esc 只关闭一次 |

## 未覆盖

- 真实网络 UI 联调：没有启动真实 server 或在真实窗口里点按；RPC 17/18 的协议路径由 [RECORD-10](RECORD-10-participation-network.md) 覆盖，本切片只验证面板与 `WorldClient` 的接线形状。
- 真实画面截图：当前单显示器环境没有可用的第二屏交付入口，未验证视觉、遮挡与 DPI 缩放。
- 声明制度的实际权威接受：`effective_utc` 留空时优先取视图里的权威时刻 `now_utc`，没有视图时才退回本机时钟；界面不做本地校正，权威拒绝文本原样显示。
- 交战与损失结算、战斗入口、战后历史列表不在本切片内。
- 移动端/窄屏布局、完整键盘导航、Windows 实机未验证。

## 关联

- 权威接入：[RECORD-09 · 参与制度接入世界权威](RECORD-09-participation-authority.md)；网络：[RECORD-10 · 参与制度真实网络测试](RECORD-10-participation-network.md)。
- 纯规则：[RECORD-02 · 参与制度](RECORD-02-participation.md)；裁决 [ADR-025](../../decisions/ADR-025-conflict-participation.md)。
- 同类面板：[M12-01 · 单位面板](RECORD-08-unit-panel.md)、[M11-09 · 组织治理界面](../M11/RECORD-09-governance-panel.md)。
- 阶段计划：[M12 PLAN](PLAN.md)。
