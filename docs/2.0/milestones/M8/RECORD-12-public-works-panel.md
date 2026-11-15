# M8-04 · 公共项目面板（切片）

执行日期：2026-11-16。状态：切片完成，不表示 M8-04 或 M8 验收完成。前置：[M8 PLAN](PLAN.md)、[RECORD-10 · 公共项目接入世界权威](RECORD-10-public-works-authority.md)、[RECORD-11 · 公共项目真实网络测试](RECORD-11-public-works-network.md)。

## 问题

公共项目权威已有 RPC 21/22 与只读视图，但没有玩家入口：项目只能通过 `WorldClient.request_public_works()` 从代码登记、承诺、退回或建成，玩家也看不到已承诺金额、固定成本覆盖和建成状态。本切片补上单机可测的公共项目面板与 HUD 接线，所有权限、余额与足额判断仍由权威裁决。

## 边界

- 新增 `Game/ui/public_works_panel.gd`、`tests/public_works_panel_test.gd` 与本记录。
- 修改 `Game/scenes/farm_hud.gd`（“公建”入口与 `public_works_requested` 信号）、`Game/scenes/main.gd`（实例化面板、打开/刷新/动作/关闭与 Esc/右键归属）。
- 未修改 `Game/world/*`、`Game/farm/*`、`world_server.gd`、农场格式（仍 27）、`PROTOCOL_VERSION`（仍 1）或 RPC 频道。
- 面板不复制权威规则：不判断成员资格、组织权限、基金 keeper、余额、项目是否存在或是否足额，也不在本地推导固定成本。

## 面板行为

- 视图行来自权威答复的 `state.projects`：`{project_id, kind, parcel_id, funded, pledged, status, built_utc}`，按 `project_id` 排序。
- 项目行显示：
  - 项目 id；
  - 类型文案：`village_square` → 村口广场、`public_well` → 公井、`road_segment` → 石板路；未知类型原样显示；
  - 地块；空串显示“未绑定”；
  - 已承诺 `pledged`；
  - 固定成本覆盖 `funded`（不显示本地推导的成本分母）；
  - 状态：`unbuilt` → 未建、`funded` → 已足额、`built` → 已建成；未知状态原样显示；
  - `built_utc > 0` 时显示“建成 <UTC 秒>”；状态为已建成但时间为 0 时显示“建成时间未记录”。
- 空视图显示“还没有公共项目。”，不虚构本地项目。
- `parcel_id` 只使用文本框，不接地图地块选择器。

## 动作映射

| 界面操作 | action | args |
|---|---|---|
| 刷新 | `state` | 无（request id 固定为 `public-works-state`） |
| 登记项目 | `open` | `{command_id, project_id, kind, parcel_id}` |
| 承诺 | `pledge` | `{command_id, project_id, amount}` |
| 退回 | `release` | `{command_id, project_id, amount}` |
| 用基金建成 | `build` | `{command_id, project_id, fund_id}` |

- 请求 id 形如 `public-works-<action>-<ticks_usec>-<counter>`，同时作为载荷里的 `command_id`；`main.gd` 在缺省时补发命令 id。
- 字段格式在面板内只做最小校验：项目 id、基金 id 不能为空，金额必须是正整数；类型由下拉框提供。项目是否存在、承诺是否超限、能否退回、基金余额与支出权全部交给权威。
- `build` 不发送金额；固定成本由权威目录决定，面板不复制价目表。
- 面板不做声明式权限判断：房主与普通成员看到同一组操作入口，由权威返回拒绝原因。

## 错误展示

- `apply_result(request_id, payload)` 先用 `payload.state` 整份覆盖视图，再显示结果。
- 失败时取 `reason_text`，为空则取 `reason`；两者都为空时显示“公共项目操作被拒绝。”。面板不改写原始原因码。
- `duplicate` 显示“这条公共项目操作已经执行过。”；成功的 `build` 显示“公共项目已建成。”；其他成功答复清空状态行。
- 单机或未连接时由主场景显示“公共项目需要进入共享世界。”或“还没有连上世界，公共项目没有刷新。”，不虚构本地项目。

## 接线

- `farm_hud.gd` 新增 `public_works_requested` 与“公建”按钮（节点名 `PublicWorks`）；入口始终可见，单机点击由主场景说明需要进入共享世界。
- `main.gd` 把面板挂到 HUD 的 `CanvasLayer` 下；打开时先摆出上次视图，再向权威发 `request_public_works("public-works-state", "state")`。
- `public_works_action` 原样转给 `WorldClient.request_public_works`；`remote.public_works_result` 连接到 `apply_result`；面板关闭恢复相机输入与 HUD。
- Esc/右键：类型下拉先吃掉第一次 Esc；主场景也登记了同一归属，避免相机在面板背后继续处理输入，两条路径最多关闭一次。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
cd /Volumes/Disk-1tb/yipiantian
for f in Game/ui/public_works_panel.gd tests/public_works_panel_test.gd \
  Game/scenes/farm_hud.gd Game/scenes/main.gd; do
  "$GODOT" --headless --path Game --check-only --script "$PWD/$f"
done
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/public_works_panel_test.gd"
```

原始末行：

```text
PUBLIC_WORKS_PANEL_TEST checks=71 failures=0
```

四个文件 `--check-only` 均退出 0。

回归原始末行：

```text
FUND_PANEL_TEST checks=65 failures=0
PARTICIPATION_PANEL_TEST checks=69 failures=0
```

覆盖：

| 用例 | 检查 |
|---|---|
| 初始状态 | 面板默认隐藏，不消费 Esc，不抢 HUD 按钮焦点 |
| 空视图 | 权威空项目表显示“还没有公共项目。” |
| 渲染 | 三行按 project id 排序；类型、地块/未绑定、已承诺、固定成本覆盖、未建/已足额/已建成、建成时间均来自权威视图；滚动跟随焦点 |
| 刷新 | 刷新按钮只发一个 `state` 请求 |
| 登记 | 项目 id 与地块去空白，类型选择原样发送；空项目 id 不发请求；请求 id 等于命令 id |
| 承诺 | 项目与正整数金额正确；0/负数/非数字/空金额不发请求；空项目不发请求 |
| 退回 | 项目与金额正确；非正金额不发请求 |
| 建成 | 项目与基金 id 正确，不发送本地推导金额；空基金、空项目不发请求 |
| 权威答复 | 成功答复整份替换视图并移除旧行；拒绝显示 `reason_text`，缺失时显示 `reason`；不改承诺；build 成功提示建成；`duplicate` 提示已执行 |
| 容错 | 无 `state` 的载荷保持原视图；空状态清空列表；格式错误行被跳过；空状态文本清空 |
| 关闭 | 下拉打开时占用 Esc；Esc 关闭面板并发一次 `closed`；关闭后 Esc 被忽略；焦点回到打开按钮 |

## 未覆盖

- 真实点按与截图：受 TCC 限制，未在真实窗口中点击验证布局。
- 真实 server 端到端：面板只经 `WorldClient.request_public_works()` 发意图；真实 WSS 公共项目流程见 [RECORD-11 · 公共项目真实网络测试](RECORD-11-public-works-network.md)。
- 未做窄屏、Windows、手柄或读屏布局验证。
- 未接入地图地块选择、公共建筑三维视觉、项目列表快捷选择或施工过程动画。
- 面板不展示 `PublicWorks.CATALOG` 的成本分母，也不根据 `kind` 推断足额；仅展示权威 `funded` 与 `status`。

## 关联

- 阶段计划：[M8 PLAN](PLAN.md)。
- 权威切片：[RECORD-10 · 公共项目接入世界权威](RECORD-10-public-works-authority.md)。
- 网络切片：[RECORD-11 · 公共项目真实网络测试](RECORD-11-public-works-network.md)。
- 同型界面参考：[RECORD-08 · 公共基金面板](RECORD-08-public-fund-panel.md)、[M12-11 · 参与制度面板](../M12/RECORD-11-participation-panel.md)。
