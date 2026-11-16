# RECORD-28 · 治理解散态与纠纷警告行窗口截图

状态：切片完成，未验收；只表示 M12-04 中“治理面板已解散态/负责人解散确认”
和“纠纷面板警告行”的真实窗口渲染证据，不表示 M12-04 已完成。
日期：2026-11-16。

## 问题

[RECORD-26](RECORD-26-dispute-warning-view.md) 已让权威视图下发 `warning` 并在
`DisputePanel._case_text()` 追加“警告 生效中/已到期/未开始｜UTC 起 至 止”，
但验证只有 headless 字符串断言；组织解散入口与关闭态也没有窗口截图。
本切片补两张画面的真实渲染证据，并核对文字裁切、按钮重叠和确认框文案：

- 治理面板：关闭组织的“已解散”行与全部写按钮禁用态；
- 治理面板：未关闭组织的负责人视图、“解散组织”按钮和确认框弹出态；
- 纠纷面板：带 `warning` 的案件行与无 `warning` 的对照行。

## 边界

- 新增 `tests/dispute_governance_visual_test.gd`；产物只写
  `.local/verification/dispute-governance-visual/`。
- 修复 `Game/ui/governance_panel.gd` 中确认框的可见缺陷（见下）；未改
  `Game/art/ui/fonts/汇文明朝体.ttf`，未改文案表意，未新增业务字段或逻辑。
- 不接真实网络，不改变警告期限规则、组织解散权威流程或确认框行为。

## 实现

测试用与 `governance_panel_test.gd`、`dispute_panel_test.gd` 相同的权威视图
夹具实例化两个真实面板，在非 headless 窗口中按固定尺寸截图：

- 窗口与 `canvas_items` 内容缩放尺寸都设为 1600×1000；项目拉伸基尺寸是
  1600×900，只改 `root.size` 时 `get_texture()` 仍是 1600×900，所以测试同时
  设置 `root.content_scale_size`。
- `root.gui_embed_subwindows = true`，让 `ConfirmationDialog` 出现在窗口纹理里。
- 每张图保存后断言 `save_png()` 成功且图片至少 1600×1000；测试末行沿用
  `CHECKS/FAILURES` 汇总并 `quit`。
- 治理夹具：`river` 为 `status: "closed"`、`closed_utc`，ALICE 为负责人；
  再以未关闭的同一视图渲染负责人解散入口。纠纷夹具：`case_corrected` 带
  `warning = {ok: true, status: "active", starts_utc: 1500, expires_utc: 2593500}`，
  `case_filed` 无 `warning`，与 RECORD-26 的期限一致。

## 产品代码最小修复

首轮截图发现治理面板的确认框使用引擎默认深色背景与英文标题
“Please Confirm...”；嵌入窗口继承了面板的深墨字色，正文在深底上几乎不可读。
根因是 `ConfirmationDialog` 没有覆盖 `AcceptDialog` 的默认 `panel` 样式，而
控件字体颜色由所属淡彩主题继承。最小修复只改确认框创建处：

- 标题改为“解散组织”；
- `panel` 与 `embedded_border` 使用与面板相同的淡彩纸底；
- `title_color` 使用共享墨色。

修复后正文“确定解散这个组织吗？解散不可撤销，组织资金会退还给缴入的成员。”
完整可读，确认/取消按钮清晰。标题区仍与面板同纸色，没有额外描边或独立色块，
但不再出现深浅冲突或英文标题。

## 验证

实际运行（macOS，Godot 4.7.2，非 headless，`--audio-driver Dummy`）：

```sh
cd /Volumes/Disk-1tb/yipiantian && \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --path Game --audio-driver Dummy \
  --script "$PWD/tests/dispute_governance_visual_test.gd"
```

末行：

```text
DISPUTE_GOVERNANCE_VISUAL_TEST checks=25 failures=0 \
dir=/Volumes/Disk-1tb/yipiantian/Game/../.local/verification/dispute-governance-visual
```

关联 headless 检查：

| 测试 | 结果 |
|---|---|
| `governance_panel_test` | `checks=56 failures=0` |
| `dispute_panel_test` | `checks=100 failures=0` |
| `font_coverage_test` | `checks=1272 failures=0 missing=0` |

逐张结论（PNG 均为 1600×1000）：

1. `01-governance-closed.png`：`河岸合作社 · 3 人 · 负责人 · 已解散` 完整
   显示；`加入/退出/任命干事/交接负责人/解散组织` 全部为禁用样式；成员列表与
   底部管理行都在面板内，无裁切或重叠。
2. `02-governance-leader-dissolve.png`：未关闭视图不再显示“已解散”，
   `解散组织` 按钮可用；与相邻按钮无重叠。
3. `03-governance-dissolve-confirm.png`：中文标题与整句确认文案完整可读，
   `取消/解散` 两个按钮清晰；修复前的问题与根因见上一节。
4. `04-dispute-warning.png`：案件行完整显示
   `警告 生效中｜UTC 1500 至 2593500`；同屏的 `case_filed` 没有警告行；长
   player id 在面板宽度内换行，不溢出。立案/证据/申诉表单在滚动区内继续向下
   延伸（右侧滚动条可见），不是被裁切丢失。
5. `05-dispute-no-warning.png`：只保留 `case_filed` 时没有“警告”行，与第 4 张
   的带警告案件形成对照。
6. `06-dispute-confirm.png`：管理员视图点“结案”后，确认框显示中文标题
   “确认操作”和完整文案“确定结案吗？结案后不再受理证据或更正。”，纸色底上
   正文与按钮清晰；与第 3 张治理确认框一致。

## 增补：纠纷确认框主题化

初版记录把 `DisputeConfirm` 留作未覆盖，但截图同时证明它沿用了引擎默认对话框
背景，和治理确认框是同一处缺陷。随后按同一方式补了 6 行：中文标题“确认操作”、
`panel`/`embedded_border` 使用面板纸色、`title_color` 使用共享文字色；测试新增
第 6 张截图与三条断言（案件编号输入、结案按钮、确认框标题与文案）。重跑末行为
`checks=25 failures=0`，`governance_panel_test 56/0`、`dispute_panel_test 100/0`、
`font_coverage_test 1272/0 missing=0`。

## 未覆盖

- 真实网络下警告跨天从 `active` 变 `expired`、组织解散/退款后的整份视图刷新。
  RECORD-26/RECORD-20 的 headless 与网络断言仍负责这些链路，本切片不重复。
- Windows、真实鼠标点按、TCC 权限弹窗与 DPI 缩放。
- 确认框标题区没有独立着色条；底层文字可能在标题行透出，但不遮挡标题、正文或
  按钮。

## 关联

- [M12 计划](PLAN.md) 的 M12-04 段。
- [RECORD-20 · 纠纷执行与事件核验](RECORD-20-dispute-enforcement.md)：
  本切片不重新验证补偿转账，只补画面证据。
- [RECORD-26 · 纠纷警告期限接入视图](RECORD-26-dispute-warning-view.md)：
  本切片补齐其“未覆盖”中的面板实际渲染观察，不覆盖网络与跨天状态。
- 实现：`Game/ui/governance_panel.gd`、`Game/ui/dispute_panel.gd`、
  `tests/dispute_governance_visual_test.gd`。
- 产物：`.local/verification/dispute-governance-visual/*.png`。
