# M11-02 · 组织治理界面（切片）

执行日期：2026-11-15。状态：UI 切片完成，不表示 M11-02 或 M11 验收完成。前置：[M11 PLAN](PLAN.md)、[RECORD-04 · 组织规则](RECORD-04-organizations.md)、[RECORD-08 · 组织接入世界权威](RECORD-08-organization-authority.md)。

## 问题

RECORD-08 已让世界权威持久化组织、成员与职位，并通过频道 11/12 提供 `organization_request` / `_organization_reply`。但客户端没有任何入口：玩家看不到组织列表、成员职位，也无法创建、加入、退出、任命干事或交接负责人。

本切片只补客户端界面与接线，不改变权威规则、协议、存储或经济。

## 边界

- 新增 `Game/ui/governance_panel.gd`、`tests/governance_panel_test.gd` 与本记录。
- 修改 `Game/scenes/farm_hud.gd`：新增“组织”入口与 `organization_requested` 信号；按钮始终可见，单机点击后由场景说明需要进入共享世界。
- 修改 `Game/scenes/main.gd`：创建面板、打开组织入口、把 `org_action` 转为 `remote.request_organization(...)`、接收 `remote.organization_result` 并刷新面板；Esc/右键关闭面板并入既有模态输入顺序。
- 未修改 `PLAN.md`、`project-context.md`、CI、`WorldHost` / `WorldMember` / `WorldClient`、`organization_state.gd`、其它 UI/测试或存档格式。
- 组织操作不涉及金钱、公共基金、地籍、建造或农场存档。

## 视图契约与信号

面板是纯视图：不读取网络、规则或存档，也不本地修改成员与职位。

```gdscript
present(organizations: Array, my_id: String, can_write: bool, status: String)
```

- `organizations`：权威 `state.organizations` 原样数组，每项 `{id, name, created_utc, members: {player_id: role}, roles}`；`role` 为 `leader` / `officer` / `member`。
- `my_id`：当前连接的玩家 id，用于显示“我的职位”和标记“（我）”。
- `can_write`：场景按连接角色给出；为 `false` 时所有写按钮禁用，`status` 显示原因。
- `status`：权威答复里的 `reason_text`，或场景给出的只读原因；显示在底部状态行。
- 视图整份替换，不合并增量；选中组织按 `id` 与焦点按控件键跨刷新保留。

信号：

| 信号 | 载荷 | 说明 |
|---|---|---|
| `org_action(action, args)` | `create` `{name}`；`join`/`leave` `{org_id}`；`appoint` `{org_id, player_id, role:"officer"}`；`transfer_leadership` `{org_id, player_id}` | 只表达意图，不判断权限、不改本地状态 |
| `refresh_requested` | 无 | 头部“刷新”按钮 |
| `closed` | 无 | “收起”、Esc 或场景关闭后发出 |

`main.gd` 在转发时补 `command_id`；`create` 缺少 `org_id` 时按合法字符集生成 `"org-" + command_id`。

## 界面结构

- 标题“组织”；头部“刷新”“收起”。
- `OrgList`：每个组织一个 `OrgAction_<id>` 按钮，文字为“名称 · N 人 · 我的职位（未加入时写未加入）”；选中状态沿用共享按钮按下样式。
- `MemberList`：选中组织的成员，每行 `Member_<player_id>`，显示玩家 id、职位，自己带“（我）”；无选中组织时提示“先选择一个组织。”
- 创建区：`OrgName` 输入框 + `CreateOrg`。
- 管理区：`JoinOrg`、`LeaveOrg`、`TargetMember`（其他成员）、`AppointOfficer`、`TransferLeadership`。
- 底部 `Status`：权威 `reason_text` 或只读原因。

控件命名便于无头测试：`OrgList`、`OrgAction_<id>`、`Member_<player_id>`、`OrgName`、`CreateOrg`、`JoinOrg`、`LeaveOrg`、`TargetMember`、`AppointOfficer`、`TransferLeadership`、`Refresh`、`Close`、`Status`。

## 交互

- 打开：HUD“组织”入口 → `main.gd` 摆出上次视图；共享世界再发 `state` 请求。单机 `remote == null` 时显示“组织需要进入共享世界。”，不虚构本地组织。
- 刷新：`Refresh` 清空旧状态并发 `refresh_requested`；场景重新请求 `state`。
- 答复：`remote.organization_result` 的 `state.organizations` 整份替换视图，底部显示 `reason_text`；成功且无文案时清空，`duplicate` 时提示已执行。
- 可写性：具名成员（`member`）可写；访客与匿名连接只读，按钮禁用并显示原因。
- 键盘：Tab 在面板内闭环，Esc 先收起打开中的成员下拉，再关闭面板；关闭后焦点回到打开它的 HUD 按钮。面板隐藏时 `visible == false`，`_input` 直接返回，不拦截输入。
- 主题：沿用 `FarmTheme` 字体、墨色、淡彩纸面与按钮状态，不新增独立样式。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/governance_panel_test.gd"
```

原始末行：

```text
GOVERNANCE_PANEL_TEST checks=41 failures=0
```

回归原始末行：

```text
SOCIAL_PANEL_TEST checks=48 failures=0
BUILD_PANEL_TEST checks=39 failures=0
M4_CLIENT_SCENE_TEST checks=42 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/m4-client-scene-322907
```

覆盖：

| 用例 | 检查 |
|---|---|
| 空视图 | 空列表写明没有组织；创建按钮可用，成员动作禁用；无虚构组织行 |
| 渲染 | 名称、成员数、我的职位；多组织；成员与职位；自己带“（我）”；非成员显示未加入 |
| 选择 | 点击切换选中组织；刷新按 id 保留选中 |
| 状态可用 | 非成员只有加入、成员只有退出；有其它成员时任命与交接可用；空名称在本地拒绝 |
| 信号 | 创建只发名称；加入/退出发组织 id；任命发组织、成员与 `officer`；交接发组织与成员 |
| 只读 | 访客视图仍列出组织，所有写按钮禁用，名称不可编辑，状态行显示原因 |
| 键盘 | 打开捕获焦点；列表跟随焦点滚动；刷新恢复同一组织按钮的焦点；Tab 闭环；Esc 关闭并回到打开者 |
| 隐藏 | 隐藏面板不响应 Esc、不夺取焦点 |

## 未覆盖

- 真实点击与截图：本轮只在无头 macOS 上运行面板测试与回归；未在开发预览窗口做真实鼠标点击、布局截图或不同 DPI 检查。真实点击截图受本机 TCC（屏幕录制/辅助功能授权）限制。
- Windows 实机：未在 Windows 运行，也未验证 Windows 下的窗口、焦点和输入路径。
- 权威端到端：面板只验证视图与信号；`request_organization` → 权威 → `organization_result` 的真实网络往返沿用 RECORD-08 的覆盖，本轮未重跑组织权威测试或双端联机。
- 组织显示名：权威视图只带玩家 id，面板按 id 显示成员；没有把世界名册昵称并入组织视图，也没有改协议。
- 解散、公共基金、资产处置、规则决议、税费、预算与案件仍未接入。
- 并发、迁移与双权威写入未覆盖。
