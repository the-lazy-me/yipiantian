# M12-01 · 单位面板界面（切片）

执行日期：2026-11-15。状态：切片完成，不表示 M12-01 或 M12 验收完成。前置：[M12 PLAN](PLAN.md)、[RECORD-05 · 单位与补给](RECORD-05-units.md)、[RECORD-06 · 单位接入世界权威](RECORD-06-unit-authority.md)。

## 问题

单位权威已经有名册、招募/解散/补给与 RPC 13/14，但没有可见入口：玩家只能靠日志或手写请求操作，无法确认名册里有什么、操作是否被拒。界面不能自己判断权限或资源，否则会与权威产生第二套事实。

## 边界

- 新增 `Game/ui/unit_panel.gd` 与 `tests/unit_panel_test.gd`。
- 修改 `Game/scenes/farm_hud.gd`（“单位”入口）与 `Game/scenes/main.gd`（打开面板、转发请求、连接答复、Esc/右键归属）。
- 未修改 `Game/world/*`、`Game/conflict/*`、`Game/farm/*`、RPC 频道、协议、存档、CI 或规则文档。
- 面板不判断成员身份、现金、粮草、归属或名册上限；所有裁决仍由权威给出。

## 面板

- `open_panel(view)` / `close_panel()` / `is_open()` / `is_popup_open()` / `show_status()` / `apply_result(request_id, payload)`。
- 名册行显示 `id`、`owner`、兵种、人数、装备、驻地与欠供天数，按 id 排序；空视图显示“还没有单位。”。
- 招募区选项来自 `UnitState.CATALOG` / `UnitState.EQUIPMENT` 的键，人数只校验正整数，驻地必填；请求 id 形如 `unit-<action>-<ticks_usec>-<counter>`，同时作为 `command_id`。
- 每行“解散”先弹确认；取消不发请求，确认后才发 `disband`。
- “补给”直接发 `upkeep`。
- `apply_result` 用权威答复里的 `state.units` 整份替换名册；失败只显示 `reason_text` / `reason`，不本地增删单位；`duplicate` 显示“已经执行过”。

## 接线

- `farm_hud.gd` 新增 `unit_requested` 与“单位”按钮（节点名 `Units`）；入口始终可见，单机点击由主场景给出“需要进入共享世界”，不虚构本地名册。
- `main.gd` 把面板挂到 HUD 的 `CanvasLayer` 下以盖住工具栏；打开时先摆出上次视图，再发 `request_unit("unit-state", "state")`；`unit_action` 原样转给 `WorldClient.request_unit`，未连接时显示可见失败。
- `remote.unit_result` 连接到 `apply_result`；面板关闭恢复相机输入与 HUD。
- Esc/右键：面板自己打开时才消费 Esc；确认框或下拉先吃掉第一次 Esc。主场景也登记了同一归属，避免相机在面板背后继续处理输入，两条路径最多关闭一次。

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/unit_panel_test.gd"
```

原始末行：

```text
UNIT_PANEL_TEST checks=53 failures=0
```

回归原始末行：

```text
GOVERNANCE_PANEL_TEST checks=41 failures=0
GAME_MENU_TEST checks=92 failures=0
```

覆盖：

| 用例 | 检查 |
|---|---|
| 可见性 | 初始隐藏；打开/关闭信号；隐藏时不消费 Esc、不抢焦点 |
| 视图 | 空状态；多行按 id 排序；全部字段文案；无效行跳过；视图复制不别名 |
| 招募 | 选项来自规则目录；合法输入生成非空且唯一的 request_id、正确 action/args；非整数/零/空驻地不发请求 |
| 解散 | 点击只开确认；取消不发；确认发 disband 且带目标 unit_id |
| 补给 | 发 upkeep 与 command_id |
| 权威答复 | `state.units` 整份覆盖；失败显示 reason_text；duplicate 提示；不本地增删 |
| 焦点与关闭 | 关闭返回打开者焦点；Esc 只关闭一次 |

## 未覆盖

- 真实点按截图：macOS 截图受 TCC 限制，未在真实窗口验证视觉与遮挡。
- 网络：没有启动真实 server；RPC 13/14 的端到端路径由单独测试覆盖，本切片只验证面板与 `WorldClient` 的接线形状。
- 只读/访客角色：面板不区分角色，写入拒绝由权威以 `reason_text` 显示。
- 名册上限、补给节奏与逃兵提示：只显示权威的 `unfed_days`；没有预测、批量操作或历史。
- 移动端/窄屏布局、键盘完整导航、Objective-C/Windows 实机未验证。
- 单位仍不参与战斗、行军或摘要投影。

## 关联

- 权威接入：[RECORD-06 · 单位接入世界权威](RECORD-06-unit-authority.md)；规则：[RECORD-05 · 单位与补给](RECORD-05-units.md)。
- 同类面板：[M11-09 · 组织治理界面](../M11/RECORD-09-governance-panel.md)。
- 阶段计划：[M12 PLAN](PLAN.md)。
