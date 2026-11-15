# M8-04 · 公共项目登记地块选择（切片）

执行日期：2026-11-16。状态：切片完成，不表示 M8-04 或 M8 验收完成。前置：[M8 PLAN](PLAN.md)、[RECORD-10 · 公共项目接入世界权威](RECORD-10-public-works-authority.md)、[RECORD-12 · 公共项目面板](RECORD-12-public-works-panel.md)、[RECORD-13 · 公共项目建成视觉](RECORD-13-public-works-visual.md)。

## 问题

公共项目面板登记表单只接受手输 `ParcelId` 文本，而世界权威摘要已经带有地籍视图（`territory.parcels` 的 `id` 与 `slot`），建成视觉也按同一个 `parcel_id` 映射宅基 slot。玩家需要记住并准确输入地块 id 才能把项目绑定到已有地籍，容易拼错或绑到不存在的地块。本切片只补登记行的地块选择入口，不引入三维地图选点。

## 边界

- 修改：
  - `Game/ui/public_works_panel.gd`（`set_parcels`、`ParcelChoice` 下拉、选择写回文本框）；
  - `Game/scenes/main.gd`（`_parcel_ids()`，打开与刷新时把地籍 id 交给面板）；
  - `tests/public_works_panel_test.gd`（选项、写回、清空与请求载荷）。
- 新增：本记录。
- 未修改：`.github/`、PLAN、`rules/`、世界权威/存储/协议文件、建成视觉脚本、项目文档格式、RPC 频道。
- 请求形状不变：`open` 仍发送 `{command_id, project_id, kind, parcel_id}`，`parcel_id` 仍是从 `ParcelId` 文本框读出的字符串。

## 面板行为

- 登记行在类型下拉之后新增 `OptionButton`，节点名 `ParcelChoice`。
- `set_parcels(parcels: Array)`：
  - 每项转字符串并去掉首尾空白；空串跳过；
  - 去重后按 id 升序排序；
  - 第一项固定为“不绑定”（元数据空串），其后每项文本就是地块 id，元数据也是该 id。
- 选择某项时把对应元数据写入既有 `ParcelId` 文本框；选择“不绑定”把文本清空。
- 重建选项不清空玩家已手输的文本；若文本正好等于某个选项 id，则自动选中该项，否则回到“不绑定”。
- 空数组（单机、未连接或摘要没有地籍）只留下“不绑定”，文本框仍可手输。
- 表单校验与请求路径完全复用原有实现：请求仍取 `_open_parcel.text.strip_edges()`，面板不判断地块是否存在、归属或状态。

## 接线

- `main.gd` 新增 `_parcel_ids()`：从 `remote.member.state.territory.parcels` 逐行取 `id`；缺少 `id` 时用 `TerritoryState.slot_parcel_id(slot)` 反查；去重后返回。
- `_open_public_works()` 在 `open_panel()` 之前调用 `set_parcels(_parcel_ids())`，面板打开时选项已就绪。
- `_public_works_refresh()` 同样在刷新世界视图前重新读取地籍，摘要更新后选项跟着更新。
- `remote == null` 或没有地籍摘要时 `_parcel_ids()` 返回空数组，面板仍允许手输，不虚构本地地块。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
cd /Volumes/Disk-1tb/yipiantian
for f in Game/ui/public_works_panel.gd Game/scenes/main.gd \
  tests/public_works_panel_test.gd; do
  "$GODOT" --headless --path Game --check-only --script "$PWD/$f"
done
perl -e 'alarm shift; exec @ARGV' 420 "$GODOT" --headless --path Game \
  --script "$PWD/tests/public_works_panel_test.gd"
perl -e 'alarm shift; exec @ARGV' 420 "$GODOT" --headless --path Game \
  --script "$PWD/tests/public_works_view_test.gd"
```

三个文件 `--check-only` 均退出 0。

原始末行：

```text
PUBLIC_WORKS_PANEL_TEST checks=80 failures=0
```

回归原始末行：

```text
PUBLIC_WORKS_VIEW_TEST checks=25 failures=0
```

## 覆盖

| 用例 | 检查 |
|---|---|
| 选项生成 | 登记行存在 `ParcelChoice`；输入含重复、空串与首尾空白时，选项去重且按 id 升序，首项为“不绑定” |
| 选择写回 | 选择 `parcel_02` 后 `ParcelId` 文本等于 `parcel_02` |
| 不绑定 | 选择“不绑定”清空 `ParcelId` 文本 |
| 重建选项 | 手输 `parcel_02` 后重建选项，文本保留且选中匹配项 |
| 空地籍 | `set_parcels([])` 只剩“不绑定” |
| 请求载荷 | 通过选择写入的地块 id 仍以文本值进入 `open` 请求的 `parcel_id`；手输的非选项文本也照常发送并去空白 |

## 未覆盖

- 三维地图选点：未接入视口拾取、地图高亮或点击地块自动填表；选择范围仅限权威摘要已有的地籍 id。
- 真实网络 UI 联调：只运行面板与场景的既有测试，未启动真实 WSS 服务端手动点选地块登记。
- TCC/真实窗口：未在真实窗口中点按下拉验证布局与弹出位置。
- Windows 实机与 CI：按本任务边界没有修改 `.github/`，本切片的测试仍只在 macOS 本机运行。
- 未做窄屏、手柄或读屏下的下拉可用性验证。

## 关联

- 阶段计划：[M8 PLAN](PLAN.md)。
- 面板切片：[RECORD-12 · 公共项目面板](RECORD-12-public-works-panel.md)。
- 建成视觉：[RECORD-13 · 公共项目建成视觉](RECORD-13-public-works-visual.md)。
- 同型地籍读取：`Game/scenes/main.gd` 的 `_parcel_views()`、`Game/world/territory_state.gd` 的 `slot_parcel_id()`。
