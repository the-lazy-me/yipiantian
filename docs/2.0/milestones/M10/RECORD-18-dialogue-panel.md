# M10-04 · 居民对话面板

执行日期：2026-11-16。状态：切片完成，未验收；只表示 M10-04 的对话界面部分，不表示
M10-04 或 M10 已完成。前置：[M10 PLAN](PLAN.md)、[居民确定性对话规则](RECORD-16-resident-dialogue.md)、
[居民对话接入权威与网络](RECORD-17-resident-dialogue-authority.md)、[居民只读面板](RECORD-14-resident-panel.md)、
[M12 纠纷面板](../M12/RECORD-18-dispute-panel.md)（二次确认与拒绝文案的写法参考）。

## 问题

RECORD-17 已把对话接入权威：`dialogues_view()` 下发本人行与本人最近回复，RPC 29/30
执行 `state`/`say`。但客户端没有任何界面，`reply_kind` 也没有中文正文——RECORD-16/17
都把“模板 id 到中文正文的映射”明确留给 UI。玩家既看不到冷却与今日剩余点数，也无法
把七类固定话语变成一次请求。

本切片只补界面：新增对话面板，把权威视图摆出来，并把点按变成一次 `say` 意图。规则、
视图形状、RPC、隐私分级和存档格式都不改。

## 边界

- 新增 `Game/ui/dialogue_panel.gd`、`tests/dialogue_panel_test.gd` 与本记录。
- 未修改 `Game/scenes/main.gd`、`Game/world/**`、`Game/farm/**`、`Game/npc/**`、
  `.github/workflows/rule-tests.yml`、`rules/`、任何 `PLAN.md`。
  - 主场景接线（底栏入口、实例化、`dialogue_result` 转发、断线清空、Esc/右键归属）
    由并行任务统一处理，因此本切片只交付可挂载的面板与测试。
  - 面板类测试预加载共享主题字体，属 `scene_tests` 组；登记由主会话统一完成。
- 面板不派生人格、不预测回复、不计算关系增量、不写任何文档；冷却、日上限、邀约
  门限与拒绝原因都由权威决定。

## 面板

`Game/ui/dialogue_panel.gd`，沿用 `resident_panel.gd` / `resolutions_panel.gd` 的模板：
全屏遮罩 + 居中 `PanelContainer`、`FarmTheme` 主题、Esc 关闭并归还焦点。

公开接口：`open_panel(view)`、`close_panel()`、`show_unavailable(reason)`、
`show_status(text)`、`apply_result(payload)`、`is_open()`、`is_popup_open()`；
信号 `dialogue_intent(action, args)`、`refresh_requested`、`closed`。

自上而下：

1. 标题行：标题、`Refresh`、`Close`。
2. `DialogueStatus`：`对话已启用｜N 位居民`；不可用时按原因显示
   `世界尚未打开` / `居民对话尚未启用` / `尚未加入这个世界`，其他原因原样显示。
3. `DialogueList`：每个权威行一条 `Dialogue_<npc id>`：
   `显示名（id）｜最近对话 UTC N / 未记录｜今日剩余 R / L｜可以对话 / 冷却中，还需约 N 秒 / 暂不可对话`。
   `今日剩余 = daily_limit - daily_affinity` 是唯一一处显示换算，取的是权威发来的
   两个数，不做本地规则回放；冷却文案取行内 `cooldown_remaining`。
4. `RecentSection` / `RecentList`：本人最近的回复行，逐条显示
   `居民名｜中文回复｜UTC N`；为空时显示 `还没有对话记录。`。
5. `ActionSection`：`TargetSelect`（选项来自权威行，默认第一行）、`ActionHint`、
   `CategoryButtons` 网格与七个固定按钮。
6. `Status`：拒绝原因、重复提示与成功回复。

### 七类固定选项

按钮节点名 `Say_<category>`，文字与键都直接跟随 `NpcDialogue.CATEGORIES`：

| category | 按钮文字 | reply_kind |
|---|---|---|
| `greet` | 问候 | `reply_greet_warm` / `_neutral` / `_guarded` |
| `ask_work` | 问农事 | `reply_work_recorded` / `_unrecorded` |
| `ask_market` | 问行情 | `reply_market_recorded` / `_unrecorded` |
| `apologize` | 道歉 | `reply_apology_accepted` / `_withheld` |
| `thank` | 道谢 | `reply_thanks_warm` / `_neutral` |
| `invite` | 邀约 | `reply_invite_consider` |
| `farewell` | 告别 | `reply_farewell` |

一次点按只发一个意图：

```text
dialogue_intent("say", {
  "command_id": "dialogue-<category>-<ticks>-<n>",
  "npc_id": "<选中居民>",
  "category": "<七类之一>",
})
```

`command_id` 同时用作请求 id；面板不发 `actor`、`viewer`、`visible`、`now_utc`、
关系或时间。面板不追加、也不清除任何本地行；下一次答复整份替换视图。

### 禁用与原因

`available=false` 时行动区隐藏、选择器禁用。可用时按选中行决定：

- `ready=false` 或 `cooldown_remaining > 0`：七个按钮全部禁用，`ActionHint` 显示
  `这位居民刚和你聊过，还需要等 N 秒。`
- `daily_affinity >= daily_limit`：全部禁用，提示 `今日对话点数已用完，明天再来吧。`
- 权威行缺少事实（如 `daily_limit=0`）：保守禁用，提示 `这位居民现在不能对话。`
- 其余：按钮可用。

按钮禁用只是显示性判断；`_say()` 仍会再检查一次选中行，程序化 `pressed.emit()` 或
残留焦点圈不会把冷却中的行变成意图。真正能否成交、关系增量与记忆写入仍由权威裁决。

### reply_kind 与拒绝原因中文表

这是 RECORD-17 明确未覆盖的部分：

- `REPLY_LABELS` 覆盖 `NpcDialogue.REPLY_KINDS` 的全部 13 个模板 id，正文使用
  面向玩家的短句，不复述内部协议。未知 `reply_kind` 原样显示。
- `REASON_LABELS` 覆盖权威 `_dialogue_reason_text()` 的全部具名原因以及
  `save_resident_state_*` 前缀；答复带 `reason_text` 时优先使用权威原文，缺失时
  才回落到本表，仍未知则原样显示机器串。
- `duplicate=true` 显示 `这次对话已经记录过了。`；成功但没有 `reply_kind`（例如
  只有视图）显示 `对话已记录。`。

文案用字避开了当前字体子集缺失的字（`寒`、`暄`、`笑`），例如
`他回应得温和，和你多聊了几句。`、`他摆摆手，说心意收下了。`。

## 验证

窗口运行（不加 `--headless`，面板会挂载共享主题）：

```sh
cd /Volumes/Disk-1tb/yipiantian && \
perl -e 'alarm shift; exec @ARGV' 180 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --path Game --audio-driver Dummy --script "$PWD/tests/dialogue_panel_test.gd"
```

原始末行：

```text
DIALOGUE_PANEL_TEST checks=67 failures=0
```

字体：

```sh
cd /Volumes/Disk-1tb/yipiantian && \
perl -e 'alarm shift; exec @ARGV' 300 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/font_coverage_test.gd"
```

本切片新增的中文全部落在当前子集内：对 `Game/ui/dialogue_panel.gd` 单独做的
284 个非 ASCII 码位检查为 `failures=0`。`FONT_COVERAGE_TEST` 在本次工作树中报
`checks=1278 failures=5 missing=5`（`千`、`币`、`献`、`益`、`贡`），来源是并行任务
未跟踪的 `Game/world/resolution_effects.gd`（`git ls-files` 为空），与本切片无关；
该文件补齐用字或字体子集后应恢复 `0`。

覆盖矩阵：

| 用例 | 检查 |
|---|---|
| 隐藏起点 | 面板初始隐藏；隐藏时忽略 Esc、不抢 HUD 焦点 |
| 空/不可用视图 | 空视图与 `not_open` 显示“世界尚未打开”；`disabled`、`not_a_member` 各有独立文案；列表、行动区与选择器不可用 |
| 顺序与行内容 | 故意使用非 `NpcRoster.IDS` 顺序，行逐项保留；显示名、id、最近对话、今日剩余、冷却状态齐全；冷却行显示“还需约 120 秒” |
| 七类选项 | 恰好七个按钮，文字与 `NpcDialogue.CATEGORIES` 一一对应 |
| 目标选择 | 默认第一行；切换只改请求对象；整份替换后仍保留同一居民 |
| 禁用与原因 | 冷却行禁用并写明剩余秒数；日额度用尽禁用并写明原因；权威日切归零后恢复；程序化点按在禁用行不发意图 |
| 意图形状 | 一次点按恰好一个 `say`；`request_id == command_id`；携带 `npc_id` 与 `category`；不含 `actor`/`viewer`/`visible`/`now_utc`；点按前后视图不变 |
| 七类转发 | 每个类别各转发一次且类别正确 |
| reply_kind 文案 | 映射覆盖全部 `REPLY_KINDS`；两个不同模板显示各自正文；未知 kind 原样显示 |
| recent | 逐条显示居民、中文回复与时刻；未知 kind 原样；后续答复为空时清空不合并 |
| 拒绝 | 优先显示权威 `reason_text`；缺失时用中文原因表；未知原因原样；拒绝不改动视图；`duplicate` 有独立文案 |
| 整份替换 | 答复 `state` 移除的居民不再保留 |
| 刷新 | 一次刷新只发一个 `dialogue-state` / `state` 请求 |
| 畸形数据 | 非字典行、无 id 行、空对象与畸形 `recent` 均跳过，裸居民行仍渲染 |
| Esc/焦点 | 打开后焦点在面板内；Esc 关闭一次并归还焦点；关闭后 Esc 被忽略 |

## 未覆盖

- **主场景接线**：没有底栏入口、`main.gd` 实例化、`dialogue_result` 转发、断线
  清空与右键归属；本切片只交付面板与测试，需由接线切片补齐。
- **真实网络 UI 联调**：后端 RPC 29/30 已由 `resident_dialogue_network_test`
  覆盖，但没有“真实面板 → WSS → 权威 → 面板”的端到端测试。
- **真实点按**：输入验证使用 `SceneTree` 的 `pressed.emit()` 与 `push_input`，
  没有通过 macOS 辅助功能或真实鼠标点击按钮；未覆盖窗口焦点、全屏或桌面壁纸。
- **Windows**：只在 macOS 上运行，未覆盖 Windows 路径、字体与实机。
- **输入就没有自由文本**：面板只有七类固定按钮，没有输入框、模型回复、语音或
  意图分类器；未知模板只按 id 原样显示。
- **关系与点数不作本地预测**：点按后不显示“预计 +1”或关系预览；实际增量只在
  最近视图或成功答复中由权威返回。
- **视觉验收**：没有截图或人工视觉检查；面板沿用现有纸质主题与共享字体。
- **`dialogue_result` 语义**：面板接受 `{ok, reason, reason_text, duplicate,
  reply_kind, state}`；未验证权威在异常答复里省略 `state` 时的全部组合。

## 关联

- [M10 PLAN](PLAN.md)
- [居民确定性对话规则](RECORD-16-resident-dialogue.md)
- [居民对话接入世界权威与网络](RECORD-17-resident-dialogue-authority.md)
- [居民只读面板](RECORD-14-resident-panel.md)
- [纠纷面板](../M12/RECORD-18-dispute-panel.md)
- [规则决议面板](../M11/RECORD-13-resolutions-panel.md)
