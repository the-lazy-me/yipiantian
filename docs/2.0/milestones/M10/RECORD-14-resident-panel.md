# RECORD-14 · 居民只读面板与主场景接线

状态：切片完成，未验收；只表示 M10-04 的居民只读面板与场景入口部分，不表示
M10-04 或 M10 已完成。
日期：2026-11-16。

## 问题

[RECORD-13](RECORD-13-resident-view.md) 已把居民状态投影为权威视图并通过
RPC 25/26 下发，但游戏里没有任何入口：玩家看不到三名居民的名称、角色、人格、
公开关系、记忆规模、已消费意图与真实购买。本切片解决：

- 面板放在哪、显示哪些字段、按什么顺序；
- 权威不可用（未启用 / 世界未打开）时如何明确呈现；
- 打开、刷新与答复如何接线，Esc 与右键归谁；
- 单机、断线、重连时如何避免把旧视图当成当前事实；
- 只读面板如何证明没有写路径。

## 边界

- 新增 `Game/ui/resident_panel.gd`、`tests/resident_panel_test.gd`、
  `tests/resident_panel_network_test.gd` 与本记录。
- 修改 `Game/scenes/farm_hud.gd` 的“居民”入口与信号，以及
  `Game/scenes/main.gd` 的实例化、打开、刷新、答复和输入归属。
- 未修改 `Game/world/*`、`Game/ui/dispute_panel.gd`、`.github/`、`PLAN.md`、
  `rules/`、农场存档格式、经济规则、`settle_residents()` 或社交规则。
- 面板没有动作、没有编辑控件、不派生人格或关系、不排序、不写文档。

## 面板

`Game/ui/resident_panel.gd`：

- 公开接口：`open_panel(view)`、`close_panel()`、`show_unavailable(reason)`、
  `is_open()`、`is_popup_open()`（恒为 false）、`apply_result(payload)`；
  信号 `refresh_requested`、`close_requested`。
- `view` 与 `residents` 保存最近一次权威视图和行；`apply_result` 只在
  `payload.state` 是字典时整份替换，没有 `state` 的拒绝答复不改动视图。
- 可用时按权威数组顺序渲染，不排序、不补行：
  - `Name_<id>`：显示名、角色中文与角色代号；
  - `Traits_<id>`：`NpcPersonality.TRAITS` 顺序的五维读数；
  - `Relation_<id>_<peer>`：另外两名居民的显示名、affinity、动作数、赠礼数
    与最近时刻，顺序取权威数组；
  - `Memory_<id>`：记忆条数与最近 `last_memory_utc`；
  - `Intent_<id>`：`intents_consumed`；
  - `Purchase_<id>`：`last_purchase` 的商品名（目录缺失时回退代号）与时刻，
    空对象显示“暂无成交记录”。
- `available=false` 时：`reason=disabled` 显示“居民未启用”，`not_open` 或
  缺失原因显示“世界尚未打开”，列表隐藏且不渲染任何居民行。
- Esc 仅在面板打开时关闭面板并归还焦点；刷新、收起的节点名分别为 `Refresh`、
  `Close`，无下拉或确认框。

## 场景接线

- `farm_hud.gd`：工具栏新增“居民”按钮（节点名 `Residents`），点击发出
  `residents_requested`。
- `main.gd`：
  - 创建 `ResidentPanel` 并挂在 HUD 下，连接 `refresh_requested`、
    `close_requested` 与 `residents_requested`；
  - 打开时先显示最后确认的视图，再经
    `remote.request_residents("resident-state", "state")` 请求新视图；
  - `residents_result` 用 lambda 转给 `apply_result(payload)`，整份刷新；
  - 单机、首次请求失败、`lost` 和 `reconnecting` 时调用
    `show_unavailable("not_open")`，清空旧名册并标明世界未打开；重连完成后
    玩家可再次刷新，不保留断线前的列表；
  - `_input` 中在纠纷面板之后新增居民面板分支：Esc 或右键关闭，世界相机
    不接收面板背后的输入。

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian && \
perl -e 'alarm shift; exec @ARGV' 180 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/resident_panel_test.gd"
```

原始末行：

```text
RESIDENT_PANEL_TEST checks=43 failures=0
```

```sh
cd /Volumes/Disk-1tb/yipiantian && \
perl -e 'alarm shift; exec @ARGV' 420 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/resident_panel_network_test.gd"
```

原始末行：

```text
RESIDENT_PANEL_NETWORK_TEST checks=66 failures=0
```

回归原始末行：

```text
DISPUTE_PANEL_TEST checks=98 failures=0
DISPUTE_PANELS_NETWORK_TEST checks=199 failures=0
```

`main.gd` 另以 `--check-only --script res://scenes/main.gd` 做过解析检查，无
脚本错误。

覆盖矩阵：

| 用例 | 检查 |
|---|---|
| 空视图 | 面板打开后显示“世界尚未打开”，列表隐藏且无居民行 |
| 未启用 | `reason=disabled` 显示“居民未启用”，无居民行 |
| 世界未打开 | `reason=not_open` 显示“世界尚未打开” |
| 顺序 | fixture 故意使用非 `NpcRoster.IDS` 顺序，面板逐项保留，不排序 |
| 行内容 | 显示名、角色、五维人格、两条关系、记忆、意图与购买文本齐全 |
| 购买 | 已知商品显示目录名与代号；无成交显示“暂无成交记录” |
| 刷新 | 一次 `pressed` 只发出一次 `resident-state` / `state` 请求 |
| 只读 | 无 LineEdit/TextEdit/SpinBox/CheckBox/OptionButton，无动作信号，仅刷新与关闭 |
| 整份替换 | 第二次答复移除的居民不再保留，列表不叠加 |
| 拒绝答复 | 没有 `state` 的答复保留上一份已确认视图 |
| 畸形行 | 非字典行被跳过，面板不崩溃 |
| Esc/焦点 | 隐藏时忽略 Esc；打开后焦点在面板内；Esc 关闭一次并归还焦点 |
| 网络启用 | 真实 `world_server.gd --residents` + WSS 25/26 + 真实面板；成员真实开市后三名居民完成购买 |
| 网络行内容 | 面板保持 `NpcRoster.IDS` 顺序；名称、角色、五人格、两两关系、记忆、意图、购买均来自权威答复 |
| 网络刷新 | 一次刷新只产生一个答复，无额外请求；视图与直接读取一致 |
| 只读网络 | 连续刷新前后 `residents.json` 逐字节一致 |
| 断线 | 停止真实权威后客户端收到 `reconnecting`；面板清空并显示“世界尚未打开”，列表禁用 |
| 网络未启用 | 同一目录不带 `--residents` 重启：`available=false`、`reason=disabled`，面板显示“居民未启用”，sidecar 逐字节不变 |

## 未覆盖

- **模型对话**：没有提示词、生成、语音或自由文本；面板只显示权威数值与计数。
- **真实赠礼**：赠礼仍只写关系与记忆，视图只显示赠礼次数，面板没有赠礼入口。
- **TCC 真实点按**：输入验证使用无头 `push_input` 与真实网络请求，没有通过
  macOS 辅助功能或真实鼠标点击按钮；未覆盖窗口焦点、全屏或桌面壁纸切换后的
  点按路径。
- **Windows**：只在 macOS 无头模式与 loopback WSS 上验证，未覆盖 Windows
  路径、文件系统或实机。
- **完整场景运行**：`main.gd` 只做解析检查，网络测试按同样的接线方式挂载
  真实面板，但未启动完整游戏场景逐项点按。
- **视觉验收**：没有截图或人工视觉检查；面板沿用现有纸质主题，未新增专有
  图标或动效。
- **记忆正文与历史**：不展示记忆条目、摘要、检索或完整购买流水；订单归档后
  `last_purchase` 为空。

## 关联

- [M10 PLAN](PLAN.md)
- [居民只读视图接入世界权威](RECORD-13-resident-view.md)
- [居民社交与记忆接入世界权威](RECORD-12-resident-authority-social.md)
- [居民采购接入世界权威](RECORD-06-resident-sweep.md)
- [纠纷面板](../M12/RECORD-18-dispute-panel.md)
- [纠纷面板真实网络联调](../M12/RECORD-19-dispute-panels-network.md)
