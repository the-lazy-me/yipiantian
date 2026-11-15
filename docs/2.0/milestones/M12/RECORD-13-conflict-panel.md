# M12-03 · 交战面板界面（切片）

执行日期：2026-11-16。状态：切片完成，不表示 M12-03 或 M12 验收完成。前置：[M12 PLAN](PLAN.md)、[RECORD-03 · 交战与转移](RECORD-03-settlement.md)、[RECORD-07 · 单位交战损失桥接](RECORD-07-unit-conflict.md)、[RECORD-11 · 参与制度面板](RECORD-11-participation-panel.md)、[RECORD-12 · 交战权威接入](RECORD-12-conflict-authority.md)。

## 问题

交战权威已经有 RPC 19/20、`WorldClient.request_conflict()` 和只读视图，但没有可见入口：玩家看不到目标损失预算与近期结果，也无法在界面里提交一次交战。界面若自行判断参与同意、单位归属、损失上限或资产，会与权威产生第二套事实。

## 边界

- 新增 `Game/ui/conflict_panel.gd` 与 `tests/conflict_panel_test.gd`。
- 修改 `Game/scenes/farm_hud.gd`（“交战”入口）与 `Game/scenes/main.gd`（打开面板、转发请求、连接答复、制度表头来源、Esc/右键归属）。
- 未修改 `Game/world/*`、`Game/conflict/*`、`Game/farm/*`、RPC 频道、协议、存档、CI 或规则文档。
- 面板不判断参与同意、单位归属、损失上限或资产；所有裁决仍由权威给出。面板不计算战利品，也不显示未经权威下发的 outcome。

## 字段

面板持有的就是权威的只读交战视图：

```text
{sequence,
 targets[{key, target, parcel_id, lost, cap}],
 recent[{command_id, attacker, defender, parcel_id, troops, losses,
         taken_cash, taken_supplies, spoils_cash, spoils_supplies,
         destroyed, supply_cost, at_utc, defender_online,
         target_lost_after, target_cap, window_id}]}
```

- 目标按 `key` 排序；行显示 key、防守者、地块（空为“未绑定”）与累计损失/上限。
- 近期结果按 `command_id` 排序；只渲染该行实际存在的字段，缺少战报字段时显示更短的行，不补造 outcome。空列表显示“还没有交战结果。”。
- 交战视图本身不下发制度与房主。主场景把参与制度视图交给 `set_participation()`，表头据此显示“有限冲突：第 N 版｜在线上限｜离线上限”或“和平：当前不开放交战。”；没有参与视图时显示“当前制度未载入。”，房主显示“未登记”。
- 面板打开时会顺带请求一次权威参与制度状态，并在 `participation_result` 到达时更新表头，避免制度在打开后过期。

## 动作映射

| 界面操作 | action | args |
|---|---|---|
| 刷新 | `state` | 无（request id 固定为 `conflict-state`） |
| 交战 | `engage` | `{command_id, defender, attacker_units[], defender_units[], x, z, target_parcel?}` |

- 请求 id 形如 `conflict-engage-<ticks_usec>-<counter>`，同时作为载荷里的 `command_id`；`main.gd` 在缺省时补发命令 id。
- 单位 id 按逗号拆分并保留输入顺序，空段或空列表在本地拒绝；单位是否存在、归属谁、是否已同意参与由权威裁决。
- `x` / `z` 只校验整数格式，不做世界范围或越界判断。
- `target_parcel` 留空时不出现在请求载荷里；非空时去掉首尾空白原样发送。
- 交战不可撤销，点击只打开确认框（提示双方损失与战利品会立即结算）；取消不发请求，确认后才发 `engage`。面板只缓存本次待确认载荷，权威答复整份替换视图。

## 错误展示

- `apply_result(request_id, payload)` 先用 `payload.state` 整份覆盖视图，再显示结果。
- 失败时取 `reason_text`，为空则取 `reason`；两者都为空时显示“交战操作被拒绝。”。面板不改写原始原因码，便于定位。
- `duplicate` 显示“这次交战已经结算过。”；成功的 `engage` 显示“交战已结算。”；其他成功答复清空状态行。
- 单机或未连接时由主场景显示“交战需要进入共享世界。”或“还没有连上世界，交战没有刷新。”，不虚构本地战场。

## 接线

- `farm_hud.gd` 新增 `conflict_requested` 与“交战”按钮（节点名 `Conflict`）；入口始终可见，单机点击由主场景说明需要进入共享世界。
- `main.gd` 把面板挂到 HUD 的 `CanvasLayer` 下；打开时先摆出上次视图与参与制度视图，并向权威发 `request_conflict("conflict-state", "state")` 与一次只读参与制度状态请求。
- `conflict_action` 原样转给 `WorldClient.request_conflict`；`remote.conflict_result` 连接到 `apply_result`；面板关闭恢复相机输入与 HUD。
- Esc/右键：确认框先吃掉第一次 Esc；主场景也登记了同一归属，避免相机在面板背后继续处理输入，两条路径最多关闭一次。

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
for f in Game/ui/conflict_panel.gd tests/conflict_panel_test.gd \
  Game/scenes/farm_hud.gd Game/scenes/main.gd; do
  "$GODOT" --headless --path Game --check-only --script "$PWD/$f"
done
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/conflict_panel_test.gd"
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/public_works_panel_test.gd"
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/participation_panel_test.gd"
```

原始末行：

```text
CONFLICT_PANEL_TEST checks=74 failures=0
PUBLIC_WORKS_PANEL_TEST checks=71 failures=0
PARTICIPATION_PANEL_TEST checks=69 failures=0
```

覆盖：

| 用例 | 检查 |
|---|---|
| 可见性 | 初始隐藏；隐藏时不消费 Esc、不抢焦点；打开/关闭信号 |
| 只读视图 | 空视图空列表文案；制度未载入/和平/有限冲突与房主；目标按 key 排序及防守者、地块、损失/上限；近期结果按 command id 排序与已下发字段；空地块“未绑定” |
| engage 映射 | 点击只开确认；取消不发；确认发一次 engage；防守者去空白；单位顺序原样；整数坐标；可选地块发送/留空省略；command id 非空且等于请求 id；不发送 actor/outcome |
| 本地校验 | 空防守者、空/含空段单位列表、空或非整数 x/z 都不打开确认也不发请求 |
| 权威答复 | `state` 整份覆盖；失败显示 `reason_text`，缺失时显示 `reason`；成功“交战已结算。”；duplicate 已结算提示；畸形载荷与行不崩溃 |
| 焦点与关闭 | 确认框吃第一次 Esc；再次 Esc 关闭面板并返回打开者焦点；只关闭一次 |

## 未覆盖

- 真实网络 UI 联调：没有启动真实 server 或在真实窗口里点按；RPC 19/20 的协议路径由 [RECORD-12](RECORD-12-conflict-authority.md) 覆盖，本切片只验证面板与 `WorldClient` 的接线形状。
- 真实画面截图：未验证视觉、遮挡与 DPI 缩放。
- 完整战报：网络答复只含 `state.recent` 摘要，面板按已下发字段展示，不扩展协议。
- 命中、行军、战斗动画、战后历史列表、战利品明细与单位选择器不在本切片内。
- 移动端/窄屏布局、完整键盘导航、Windows 实机未验证。

## 关联

- 权威接入：[RECORD-12 · 交战权威接入](RECORD-12-conflict-authority.md)。
- 规则：[RECORD-03 · 交战与转移](RECORD-03-settlement.md)、[RECORD-07 · 单位交战损失桥接](RECORD-07-unit-conflict.md)。
- 同类面板：[M12-02 · 参与制度面板](RECORD-11-participation-panel.md)、[M12-01 · 单位面板](RECORD-08-unit-panel.md)。
- 阶段计划：[M12 PLAN](PLAN.md)。
