# M8-04 · 公共基金面板（切片）

执行日期：2026-11-16。状态：切片完成，不表示 M8-04 或 M8 验收完成。前置：[M8 PLAN](PLAN.md)、[RECORD-07 · 公共基金接入世界权威](RECORD-07-public-fund-authority.md)。

## 问题

RECORD-07 之后，基金只能通过 `WorldClient.request_fund()` 从代码发起；玩家看到的是一排 HUD 按钮，没有开立、缴入、支出或换届的入口，也没有任何地方显示权威基金视图。本切片补上单机可测的基金面板与 HUD 接线，让“负责人换人不丢账、越权支出拒绝”可以在界面上走通，并且所有判断仍由权威裁决。

## 边界

- 新增 `Game/ui/fund_panel.gd`、`tests/fund_panel_test.gd` 与本记录。
- 修改 `Game/scenes/farm_hud.gd`（“基金”入口与 `fund_requested` 信号）、`Game/scenes/main.gd`（实例化面板、打开/刷新/动作/关闭与 Esc/右键归属）。
- 未修改 `Game/world/*`、`Game/farm/*`、`world_server.gd`、农场格式（仍 27）、`PROTOCOL_VERSION`（仍 1）或 RPC 频道。
- 面板不复制任何权威规则：不判断成员资格、keeper、余额、组织权限或基金是否存在。

## 面板行为

- 视图行来自权威答复的 `state.funds`：`{fund_id, org_id, keeper, balance, spent, contributors}`，按 `fund_id` 排序；`contributors` 成员也按 id 排序并显示累计。空视图显示“还没有公共基金。”，不虚构本地基金。
- 四个操作区：
  - 开立：组织 id → `open`。
  - 缴入：基金 id 或组织 id + 正整数金额 → `contribute`。
  - 支出：基金 id 或组织 id + 项目 id + 正整数金额 → `spend`。
  - 换届：基金 id 或组织 id + 新负责人 id，先弹 `ConfirmationDialog`，确认后才发 `rotate`。
- 目标文本框以 `fund_` 开头时发 `fund_id`，否则发 `org_id`；权威本来接受两种定位方式，面板只决定用哪个键，不查询基金是否存在。
- 金额只做正整数格式校验；余额、权限、keeper 与项目是否合法全部交给权威，失败时显示权威 `reason_text`（缺失时退回 `reason`），不根据失败金额本地改余额。
- `apply_result` 以权威 `state.funds` 整份覆盖列表；`duplicate` 显示“这条基金操作已经执行过。”。
- 每个请求生成 `fund-<action>-<微秒>-<计数>` 的请求 id，并同时作为载荷 `command_id` 发送，权威重放/重试才认得出同一条命令。
- 打开面板先摆出上次已知视图，再向权威请求 `state`；未联机显示“公共基金需要进入共享世界。”，不生成任何请求。
- Esc 归属：换届确认框吃掉第一次 Esc，第二次关闭面板；面板打开时主场景不再把 Esc/右键交给世界相机。关闭后把焦点还给打开它的 HUD 按钮。

## 接线

- `farm_hud.gd` 新增“基金”按钮（节点名 `Funds`）与 `fund_requested` 信号。
- `main.gd` 预加载 `FundPanel`，实例化后挂在 HUD 这一 `CanvasLayer` 下；连接 `fund_action` / `refresh_requested` / `closed`，并把 `remote.fund_result` 接到 `apply_result`；`_input` 在单位面板之后加入基金面板归属块。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
cd /Volumes/Disk-1tb/yipiantian
perl -e 'alarm shift; exec @ARGV' 120 "$GODOT" --headless --path Game \
  --script "$PWD/tests/fund_panel_test.gd"
```

原始末行：

```text
FUND_PANEL_TEST checks=65 failures=0
```

回归原始末行：

```text
UNIT_PANEL_TEST checks=53 failures=0
GOVERNANCE_PANEL_TEST checks=41 failures=0
```

覆盖：

| 用例 | 检查 |
|---|---|
| 初始状态 | 面板默认隐藏，不消费 Esc，不抢 HUD 按钮焦点 |
| 空视图 | 权威空基金表显示“还没有公共基金。” |
| 渲染 | 两行按 fund id 排序；行内含 fund id、org id、keeper、余额、支出、缴入累计与成员明细；滚动跟随焦点 |
| 刷新 | 刷新按钮只发一个刷新意图 |
| 开立 | 空组织 id 不发请求；有效组织 id 发 `open`，带非空命令 id |
| 缴入 | 基金 id 与组织 id 分别映射到 `fund_id` / `org_id`；0/负数/非数字/空金额不发请求；空目标不发请求；每次点击新命令 id |
| 支出 | 项目 id 去空白；金额与目标正确；负数金额、空项目不发请求 |
| 换届 | 单击只弹确认；取消不发请求；确认发 `rotate` 且带新 keeper；空 keeper 不弹确认；确认框占用第一次 Esc |
| 权威答复 | 成功答复整份替换视图并清空状态；拒绝答复显示权威文案、不改余额；格式错误的行被跳过；空状态清空列表 |
| 关闭 | Esc 关闭面板并发一次 `closed`；关闭后 Esc 被忽略；焦点回到打开按钮 |

## 未覆盖

- 真实点按与截图：受 TCC 限制，未在真实窗口中点击验证布局。
- 真实 server 端到端：面板只经 `WorldClient.request_fund()` 发意图；真实 WSS 基金流程见 [RECORD-09 · 基金网络测试](RECORD-09-public-fund-network.md)（该切片与本文分开记录）。
- 未做窄屏、Windows、手柄或读屏布局验证。
- 面板不展示 `history`、支出项目列表或换届历史；权威视图目前也不下发这些字段。
- 项目 id 只是文本框，不提供已知项目选择；公共项目施工仍未接入（M8-04a）。

## 关联

- 阶段计划：[M8 PLAN](PLAN.md)。
- 权威切片：[RECORD-07 · 公共基金接入世界权威](RECORD-07-public-fund-authority.md)。
- 同型界面参考：[M12-08 单位面板](../M12/RECORD-08-unit-panel.md)、[M11-09 组织治理界面](../M11/RECORD-09-governance-panel.md)。
