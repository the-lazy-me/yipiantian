# M10-04 · 对话面板主场景入口

执行日期：2026-11-16。状态：切片完成，未验收；只表示 M10-04 的对话面板接线部分，
不表示 M10-04 或 M10 已完成。前置：[M10 PLAN](PLAN.md)、
[居民确定性对话规则](RECORD-16-resident-dialogue.md)、
[居民对话接入权威与网络](RECORD-17-resident-dialogue-authority.md)、
[对话面板](RECORD-18-dialogue-panel.md)、[居民只读面板](RECORD-14-resident-panel.md)。

## 问题

RECORD-18 交付了 `Game/ui/dialogue_panel.gd` 与面板测试，并在“未覆盖”里明确记下：
没有底栏入口、没有 `main.gd` 实例化、没有 `dialogue_result` 转发、没有断线清空与
Esc/右键归属。RECORD-17 的 RPC 29/30 因此已经可达，但玩家在游戏里没有任何入口能
触发它。本切片只补这条入口与场景接线，规则、视图形状、RPC 与存档格式都不改。

## 边界

- 改动 `Game/scenes/farm_hud.gd`、`Game/scenes/main.gd`、`Game/ui/dialogue_panel.gd`
  （两处最小显示修正），新增 `tests/dialogue_entry_scene_test.gd` 与本记录；在
  `tests/dialogue_panel_test.gd` 补一条 `state` 读答复的断言。
- 未修改 `Game/world/**`、`Game/farm/**`、`Game/npc/**`、`.github/**`、`rules/`、
  任何 `PLAN.md`（多代理并行改动同一工作树，这些路径不属于本切片）。
- 面板仍然只显示、只转发；冷却、日上限、邀约门限、拒绝原因与关系增量都由权威裁决。

## 入口位置与底栏宽度取舍

底栏此前已因入口过多修过一次（`f477734`）：16 个入口在 1600 逻辑宽度下需要
1824 px。`debug_time_preview_test` 在 1600 与 960 两种尺寸下断言每个可见按钮都在
视口内且互不重叠，所以“再加一个入口”必须先算宽度。

实测当前工作树（`--audio-driver Dummy`，1600×900）：

| 情形 | 可见入口 | 底栏末端 | 视口内上限 |
|---|---|---|---|
| 单机（新增「对话」前） | 16 | 1558 px | 1576 px |
| 共享世界（新增「对话」前） | 16 | 1522 px | 1576 px |
| 共享世界（新增「对话」后，未调宽） | 17 | **1606 px（溢出）** | 1576 px |
| 调整后（单机 18 / 共享 17） | 17–18 | 1466 px | 1576 px |

也就是说，共享世界在加「对话」后只差约 54 px。两个可选方案：

1. 把「对话」塞进已有面板（例如居民面板加标签页）。这会改变 RECORD-14 的只读
   面板契约，且让一个只读名册携带写动作，职责混杂。
2. 保持「对话」为独立入口，把 14 个两字入口的横向内边距从主题默认 18 px 收到
   10 px。两字标签实测 40 px，10 px 内边距的最小宽度是 62 px，色泽、边框、圆角
   与按压态都仍是共享 `FarmTheme.framed_paper` 的同一块淡彩面，没有新建控件样式。

选择 2。理由：对话与居民是两个不同的权威视图（一个只读名册、一个转发 `say`），
合到一个面板会把“只读”契约变复杂；收内边距只改宽度，不改交互语义、命中区或
配色。调整后共享世界 17 个可见入口、单机 18 个入口的末端都是 1466 px，两种模式
都在 1576 px 内，且新增入口仍是纯文字、不占图标槽。

实现方式：`farm_hud.gd` 新增 `_text_entry()`，对 normal/hover/pressed/hover_pressed/
disabled 五个状态都覆盖 `content_margin_left/right = 10`（只改 `normal` 会被
`hover` 的 18 px 撑回去）；`TEXT_ENTRY_WIDTH` 62、`TEXT_ENTRY_INSET` 10 写成常量并
注释了测量依据。

「对话」入口常驻底栏（与居民、决议一致），单机点击由场景标明世界未打开，不虚构
本地对话。这一点与居民/决议的既有约定相同，因此没有在 `set_world_mode` 里额外
隐藏它。

## 场景接线（`main.gd`）

与 `resident_panel` 同等级，逐项对齐：

| 项 | 实现 |
|---|---|
| 实例化 | `DialoguePanel.new()`，`name = "Dialogue"`，挂到 `hud` 这一 CanvasLayer 下（盖住底栏） |
| 刷新 | `refresh_requested → _dialogue_refresh()`，发一次 `request_dialogue("dialogue-state", "state")` |
| 意图 | `dialogue_intent(action, args) → _dialogue_intent()`，命令 id 同时作请求 id；未连上时面板显示“还没有连上世界，这句话没有发出去。” |
| 答复 | `remote.dialogue_result → dialogue_panel.apply_result(payload)`，整份替换视图 |
| 打开 | `_open_dialogue()`：取消工具、收起时间预览、取消自由视角手势、关闭世界输入，先摆上次确认的视图再请求 |
| 断线 | `_on_remote_lost()` 与 `_on_remote_reconnecting()` 都 `show_unavailable("not_open")`，保留面板让玩家看到原因 |
| Esc/右键 | 在 `_input()` 的帧断链里排在居民面板之后、市场之前；`is_popup_open()` 为真时第一次 Esc 只收目标下拉 |

`_dialogue_intent` 不做任何本地校验或回放：访问角色不足时由权威回 `forbidden`，
面板显示权威 `reason_text` 原文（实测“当前身份不能执行这个操作。”）。

## 面板的两处最小修正

窗口截图暴露了两个 RECORD-18 未覆盖的显示问题，都在面板内修：

1. **`state` 读答复被当成一次对话。** 共享世界首次打开面板时只发 `state` 请求，
   答复 `{ok: true, action: "state", reply_kind: ""}`；`apply_result` 原先把它
   当成“成功但没有 reply_kind”，显示“对话已记录。”。现在先判断
   `action == "state"` 直接返回，只替换视图、不写状态行。`dialogue_panel_test`
   补一条断言。
2. **不可用时空留“居民”小标题。** 标题是列表的同级节点，`available=false` 时只
   隐藏了列表本体。现在标题与列表一起隐藏（`_resident_heading`），断线截图里只
   剩“世界尚未打开”。

两处都不改动视图形状、信号或规则。

## 验证

窗口运行（不加 `--headless`，因为需要真实绘制帧截图）：

```sh
cd /Volumes/Disk-1tb/yipiantian && \
perl -e 'alarm shift; exec @ARGV' 240 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --path Game --audio-driver Dummy --script "$PWD/tests/dialogue_entry_scene_test.gd"
```

末行：

```text
DIALOGUE_ENTRY_TEST checks=24 failures=0 evidence=.local/verification/dialogue-entry-584865
```

证据 PNG（同一目录）：`panel.png`（打开后权威行与七类按钮）、`refusal.png`
（访客点按后权威原文）、`disconnected.png`（断线后清空并显示“世界尚未打开”）。

无头回归：

```text
DIALOGUE_PANEL_TEST checks=68 failures=0
M4_CLIENT_SCENE_TEST checks=42 failures=0
RESIDENT_PANEL_TEST checks=45 failures=0
FONT_COVERAGE_TEST checks=1272 failures=0 missing=0
FARM_INTERACTION_TEST checks=81 failures=0
SETTINGS_TOOLBAR_TEST failures=0
```

`SETTINGS_TOOLBAR_TEST` 在窗口模式（`--audio-driver Dummy`）下跑，因为它断言
`root.mode` 与截图；末行 `failures=0`，工具栏 18 个入口在 1600 与 960 都几何可用。

覆盖矩阵：

| 用例 | 检查 |
|---|---|
| 入口可见 | 共享世界底栏有 `Dialogue` 且文字为“对话”；无图标，与其它世界入口一致 |
| 底栏宽度 | 17 个可见入口全部在视口内且不重叠（1600×900） |
| 真实点按 | 鼠标点按底栏入口打开面板，`state` 经 RPC 29/30 返回权威视图；3 行居民、状态行“对话已启用｜3 位居民” |
| 权威拒绝 | 访客点按 `Say_greet`，权威回 `forbidden`；面板状态行显示原文“当前身份不能执行这个操作。” |
| 拒绝不改视图 | 拒绝后居民行与点按前逐项相同（JSON 比较），不伪造回复 |
| `state` 不写状态 | `action == "state"` 的答复不产生“对话已记录。” |
| Esc 归属 | 对话打开时一次 Esc 只关对话，世界工具仍在；不关居民面板 |
| 反向归属 | 居民面板打开时 Esc 只关它，对话保持关闭 |
| 断线 | 服务端停止后 `reconnecting`，面板清空且显示“世界尚未打开” |

## 未覆盖

- **真实多人联调**：测试用访客角色证明“写入被拒绝”的路径，但没有两个真实成员
  互相观察关系变化、冷却与今日剩余在联机下逐秒推进的端到端断言；`say` 的成功路径
  由 `resident_dialogue_network_test`（RECORD-17）覆盖，未与面板联合验证。
- **Windows**：只在 macOS 窗口模式运行，未覆盖 Windows 实机、字体回退与 DPI。
- **`daily_limit` 为 0 的权威**：面板会保守禁用按钮，但本测试未构造这种视图。
- **视觉验收**：只核对了三张截图在 1600×900 下的可读性与底栏不溢出，未做大屏、
  高 DPI、夜间或减少动效偏好下的截图。
- **CI 登记**：新测试放在 `scene_tests` 组（需要真实绘制与本地 WSS），未改
  `.github/workflows/rule-tests.yml`；登记由主会话统一处理。

## 关联

- [M10 PLAN](PLAN.md)
- [居民确定性对话规则](RECORD-16-resident-dialogue.md)
- [居民对话接入世界权威与网络](RECORD-17-resident-dialogue-authority.md)
- [对话面板](RECORD-18-dialogue-panel.md)
- [居民只读面板](RECORD-14-resident-panel.md)
