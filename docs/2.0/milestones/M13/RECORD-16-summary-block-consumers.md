# M13-16 · 打开面板先消费摘要只读块

日期：2026-11-16。状态：**本机切片完成，未验收**。范围：让单位、组织、公共基金与
公共项目四个面板在打开时，先用 `remote.member.state` 里对应的摘要块作为初始视图，
再照常发 `state` 请求刷新。目标只是“打开面板时立刻有内容、少一次空屏”，不省掉
`state` 请求，权威答复到达后仍整份替换。

前置：[M13-15 · 摘要默认携带四个只读块](RECORD-15-default-summary-room-views.md)、
[ADR-027 · 摘要可见性](../../decisions/ADR-027-summary-visibility.md)。

## 边界

- 修改 `Game/scenes/main.gd`：四个 `_open_*` 面板入口改用摘要块；新增
  `_summary_room_rows()` 读取与回退。
- 新增 `Game/scenes/summary_block.gd`：纯静态函数 `summary_block()`，可被无美术的
  规则测试直接 preload。
- 新增 `tests/summary_block_test.gd`，并登记进 `.github/workflows/rule-tests.yml`
  的纯规则数组（未动 `scene_tests`）。
- 未修改 `Game/ui/**`：面板继续只接受整份视图，不感知摘要。
- 未修改 `Game/world/world_projection.gd`、`world_host.gd`、`headless_world.gd`、
  协议字段或字体文件。
- 未新增说明性 UI 文案。

## 行为

`SummaryBlock.summary_block(summary, key, array_key)` 从摘要里取一块：

- `summary` 不是字典、块缺失、块不是字典、数组键缺失或不是数组时返回空数组，
  不抛错。
- 只保留字典行，返回深拷贝；行顺序保持摘要里的原有顺序（不再排序）。
- 摘要的块形状与权威 `state` 视图相同。

四个面板的打开路径：

| 面板 | 摘要块 | 数组键 | 回退 |
|---|---|---|---|
| 组织 | `organizations` | `organizations` | `governance_panel.organizations` |
| 单位 | `units` | `units` | `unit_panel.units` |
| 基金 | `funds` | `funds` | `fund_panel.funds` |
| 公共项目 | `public_works` | `projects` | `public_works_panel.projects` |

回退规则：`remote` 或 `remote.member` 为空、摘要块为空（缺块、空数组或预算裁剪在
当前规则下形状相同）时，退回面板上次已知的行，不把空块当成权威宣告房间为空，也不
显示额外文案。随后仍按原路径发 `state` 请求；答复照旧整份替换。

公共项目还会用同一份初始视图刷新场景建成物，打开时标记与列表一致。

## 验证

新测试：

```text
SUMMARY_BLOCK_TEST checks=18 failures=0
```

覆盖：正常块、`public_works.projects` 键映射、缺块、块形状不对、空数组、数组键
缺失/类型不对、非字典行被跳过、非字典摘要、null 摘要、行顺序保持、数组与行（含
嵌套贡献者列表）深拷贝。

回归：

```text
FARM_INTERACTION_TEST checks=81 failures=0
M4_CLIENT_SCENE_TEST checks=42 failures=0
FONT_COVERAGE_TEST checks=1272 failures=0 missing=0
```

`M4_CLIENT_SCENE_TEST` 在窗口模式运行（`--audio-driver Dummy`，不加 `--headless`）。
首次运行时并行 Godot 进程较多，等待 authority 就绪超时（`checks=3 failures=1`），
清理残留服务进程后重跑通过；此后未再出现。

## 未覆盖

1. **真实网络端到端。** 没有真实 WSS 会话验证“摘要块先显示、state 答复后替换”的
   时序；只验证了取块函数与本地场景回归。
2. **摘要块被 16 KiB 额度裁剪时的界面差异。** 空块与空房间按设计不可区分，面板会
   先显示上次已知行；没有只读标记说明“摘要被裁剪”。
3. **Windows。** 只在 macOS 本机运行。

## 关联

- [M13 PLAN](PLAN.md) M13-01 跨系统整合。
- 摘要块的产生与裁剪：[M13-15](RECORD-15-default-summary-room-views.md)。
