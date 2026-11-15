# M5-04 · 住宅三维呈现（切片）

执行日期：2026-11-15。状态：切片完成，不表示 M5 或 M5-04 验收完成。前置：[RECORD-06 · 住宅首版](RECORD-06-housing.md)。

## 问题

RECORD-06 已让住宅进入权威状态和“宅基”面板，但场景里没有房子：建成与施工中只能从面板得知。本次把 `Game/scenes/procedural_lab/house_kit.gd` 接入共享世界的农场场景，只做呈现，不改建筑规则、farm 文档或网络消息。

## 边界

- 只在共享世界（`main.gd` 的 `_adopt_remote`）创建住宅视图；单机/本地模式不生成任何宅基。
- 数据仍来自 `FarmState.buildings_at(now_utc)`；视图不判定权限、占用或工期。
- 不新增网络消息。建造/拆除在权威回执或邻居广播已应用的同一处刷新；施工完成由已有每秒结算调用 `buildings_at` 后自然切到建成形态。
- 不新增美术文件；施工形态只用程序化石块与木构架，建成形态复用 house_kit。

## 实现

### 固定槽位布局

`Game/scenes/environment/housing_layout.gd`：

- 顺序直接取 `building_catalog.gd` 的 `SLOTS`（`yard_a`…`yard_f`），不另建一份槽位表。
- 槽位按目录顺序映射到桥对岸（院落东岸）的固定坐标表：`yard_a`…`yard_f` 依次为 `(15.58,-2.52)`、`(11.08,-2.28)`、`(15.58,-1.02)`、`(11.04,-3.74)`、`(13.72,-2.94)`、`(11.08,-5.04)`。全部为常量，不含时钟或随机源。
- 这里不是规则网格：东岸已种有杨柳、竹丛、芦苇、菊花、岸石与桥东石路，规则网格在可读尺寸下放不下。坐标表按实测低层轮廓逐槽避让，最近间距 0.23 m。
- 蓝图参数：小屋 2 开间、工坊 3 开间、凉亭 2 开间；深度、层高、屋面坡度、门廊与门位各不相同，因此不同蓝图的 `dimensions()` 必然不同。
- 种子：`world:<world_id>/slot:<slot_id>/blueprint:<blueprint_id>`。同一世界、槽位和蓝图在读档、两个客户端或重建场景后都得到同一 joinery 与瓦片随机色；不含时间。
- 统一 `PRESENTATION_SCALE=0.19`。当前院落没有为住宅预留空地，六个完整比例的房屋放不下；0.19 是在不移动既有景物的前提下，使最大蓝图（工坊）的包围盒与低层景物保持可测间距的呈现比例。它是呈现参数，不改变蓝图之间的尺寸比例。

### 视图

`Game/scenes/environment/housing_view.gd`：

- `refresh(buildings, world_id)` 遍历槽位目录：空槽或未知蓝图移除节点；`state=done` 用 `house_builder`（默认 `HouseKit.build`）生成房屋；其余状态生成“地基 + 四角木柱 + 檐梁”的未完工形态。
- 每个槽位节点记录 `blueprint/state/seed/width/depth/height` 元数据。刷新按 `blueprint|state|seed` 比较，未变化不重建；拆除立即从父节点移除。
- `house_builder` 可替换，使无美术的 CI 也能验证视图结构；真实几何由 `component_house_test.gd` 在美术环境覆盖。

### 接线

`Game/scenes/main.gd`：

- `_adopt_remote()` 创建 `YardHomes`，地面高度取东岸 `ground_height + anchors.east_bank.y`。
- `_refresh_homes_scene()` 从 `farm_state.buildings_at(remote.world_time())` 和 `remote.grant.world_id` 派生视图。
- 调用点：每秒 `settle_farm()`（施工完成）、`refresh_farm()`（权威摘要/初始接管）、`_apply_remote_command()` 的 `build`/`demolish` 分支（自己的回执与邻居广播都会经过）。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 90 "$GODOT" --headless --path Game \
  --script "$PWD/tests/housing_view_test.gd"
perl -e 'alarm shift; exec @ARGV' 90 "$GODOT" --headless --path Game \
  --script "$PWD/tests/build_panel_test.gd"
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --path Game --audio-driver Dummy \
  --script "$PWD/tests/m4_client_scene_test.gd"
# 需要渲染窗口；本机无头模式会退化为 dummy 渲染，MultiMesh 实例变换读回恒为单位阵。
perl -e 'alarm shift; exec @ARGV' 420 "$GODOT" --path Game --audio-driver Dummy \
  --script "$PWD/tests/component_house_test.gd"
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --path Game --audio-driver Dummy \
  --script "$PWD/tests/procedural_lab_scene_test.gd"
```

结果：`HOUSING_VIEW_TEST checks=77 failures=0`；`BUILD_PANEL_TEST checks=17 failures=0`；`M4_CLIENT_SCENE_TEST checks=29 failures=0`（含“权威建造出现未完工宅基”和“拆除后节点消失”两项）；`COMPONENT_HOUSE_TEST failures=[]`；`PROCEDURAL_LAB_SCENE_TEST failures=0`。

CI 证据（规则工作流 run `43670041822`，提交 `af6f463`）：macOS 与 Windows 全部通过；`housing_view_test` 两平台均为 `checks=77 failures=0`（无需 LFS 美术，stub builder），同批 `nature_state_test 136`、`rain_moisture_test 94` 也通过。

新视图测试覆盖：

| 用例 | 检查 |
|---|---|
| 种子确定 | 同一世界/槽位/蓝图重复得到同一 seed 与 plan；换世界、槽位或蓝图都会改变 seed |
| 布局 | 六个槽位按目录顺序取固定坐标表；以最大蓝图的包围盒计算仍互不重叠，四角落均在东岸台地内，实际大小与尺寸元数据一致 |
| 景物避让 | 用 `courtyard_plan.gd` 的确定性位置（杨柳、竹丛、芦苇、菊花/草、岸石、桥东石垫、`GardenPaths` 东端石路、石桥）加实测低层轮廓断言每槽净距 > 0；当前最小 0.135 m，另断言全表最小 > 0.10 m |
| 施工/建成 | `building` 只有 `Foundation`、没有 `House`；`done` 只有 `House`；施工转建成会替换节点 |
| 拆除 | 表里移除槽位后节点立即消失；空表不生成任何宅基；未知蓝图不渲染 |
| 蓝图尺寸 | 小屋/工坊/凉亭的宽、进深或屋脊高不同 |
| 幂等刷新 | 相同状态重复刷新不重建节点、不重复调用房屋生成 |

景物断言的数据来自岛面确定性布置：高度取 1.09 m（0.20 参考比例下的最高屋脊，略低于实际屋脊），只保留该线以下的网格顶点，因此树冠高于屋顶的部分不会误报。轮廓和圆是真实网格的超集，净距为正即证明没有可见穿插；测试本身只 preload GDScript，不依赖 LFS 美术。

离屏自查（窗口渲染，输出在 `.local/verification/housing-3d/`）：`east-bank-wide.png`、`east-bank-close.png`、`east-bank-approach.png`（桥面进院视角）、`east-bank-top.png`、`slot-a.png`…`slot-f.png`、`foundations-close.png`。逐张检查结果：没有竹枝/树冠穿出屋面，完工房屋四角与基座接地，施工地基平板不再压到石垫或岸石，六个槽位之间留有空隙；比例上房屋仍明显小于主屋，与院落的尺度关系一致。

## 景物穿插处理

第一版（2×3 网格、比例 0.34）的离屏自查能看到竹枝穿出屋面、杨柳枝叶压住房屋、施工地基与石垫/岸石交叠。本次按“不改岛面生成规则”的边界重新排布：

- 先读 `island_dressing.gd` / `courtyard_plan.gd` / `courtyard.gd`，确认东岸竹丛、杨柳、芦苇、菊花、岸石、桥东石垫和 `GardenPaths` 的位置都由 `courtyard_plan.gd` 的常量加固定种子生成，没有时间或随机输入。
- 用实际网格顶点逐项测量：低于屋顶的几何才算穿插，树冠高过屋脊不算。以 1.09 m（0.20 参考比例的最高屋脊）为界统计低层轮廓。
- 排布改成固定坐标表并把 `PRESENTATION_SCALE` 收到 0.19。六槽的 `footprint_half_extents()` 与全部低层景物保持至少 0.23 m 实测净距；`GardenPaths`、石垫和岸石全部在净距之外。
- 杨柳的低枝仍跨过两处槽位上方，但进入槽位平面的最低顶点为 1.20 m（世界高度），高于屋脊约 1.14 m（基座 0.11 m + 0.19 比例的 1.03 m），属于“树冠盖过屋顶”而不是穿模。
- 没有隐藏或移动任何既有景物；没有按世界种子让位。坐标和测距不依赖时钟、随机数或场景状态，读档、两个客户端和重建场景得到同一结果。

残余限制：

- 竹丛站在院子中间，从桥面看向东侧房屋时是前景遮挡（正常的深度遮挡，不是相交）；它不属于任何槽位，因此没有按“槽位内植被让位”处理。
- 净距是静态几何加实测轮廓；植物风摆的位移量小于净距，但换美术资产后需要重新测量并更新 `housing_view_test.gd` 的轮廓数据。
- 固定坐标表只保证槽位之间不重叠、四角在台地内，没有院落编辑器级的占地、入口、通行和水陆检查，也未把房屋登记进动物导航/道路障碍。
- 0.19 是当前拥挤院落的占位比例；未来有了真正的宅基用地，应替换 `housing_layout.gd` 的常量而不是改房屋规则。
- 房屋不可移动、迁移或进入；这些仍属于后续院落与住宅切片。
- 本机视觉自查只覆盖东岸固定镜头；未做 Windows 双平台画面对照。

## 关联

- 前置：[RECORD-06 · 住宅首版](RECORD-06-housing.md)。
- 裁决：[ADR-006](../../decisions/ADR-006-housing-slice.md)。
