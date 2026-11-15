# M8-04 · 公共项目建成视觉（切片）

执行日期：2026-11-16。状态：切片完成，不表示 M8-04 或 M8 验收完成。前置：[M8 PLAN](PLAN.md)、[RECORD-10 · 公共项目接入世界权威](RECORD-10-public-works-authority.md)、[RECORD-11 · 公共项目真实网络测试](RECORD-11-public-works-network.md)、[RECORD-12 · 公共项目面板](RECORD-12-public-works-panel.md)。

## 问题

公共项目权威、网络与面板都已完成，`public_works.json` 里的项目和面板行都能看到，但世界场景没有任何可见物：建成只改变文档状态，玩家在共享世界里仍看不到广场、公井或石板路。本切片只解决“建成后世界里有可见物”，不引入外部美术资产、不做地图选点或点击交互。

## 边界

- 新增：
  - `Game/scenes/environment/public_works_view.gd`
  - `tests/public_works_view_test.gd`
  - 本记录。
- 修改：`Game/scenes/main.gd`（预加载与变量、`_adopt_remote()` 创建视图、公开项目答复接线、打开/刷新同步、断线清空）。
- 未修改：`.github/`、PLAN、`rules/`、`farm_hud.gd`、世界权威/存储/协议文件、项目文档格式、`main.tscn`。
- 未新增 GLB、Blender 资产、贴图或字体依赖；标记全部由 `CylinderMesh` / `BoxMesh` 与 `StandardMaterial3D` 在运行时生成。

## 位置映射

- 复用既有契约，不复制坐标表：
  - `TerritoryState.parcel_slot_id(parcel_id)` 把地籍地块解析为 `yard_a`…`yard_f`；
  - `HousingLayout.slot_pose(slot_id)` 给出世界 XZ 与 yaw，与宅基地渲染完全同一张表。
- `PublicWorksView.placement_for(parcel_id)` 是静态函数，返回 `{slot_id, position, yaw}` 或 `{}`；空地块、未知地块（如 `parcel_99`）、把 slot id 当地块 id 传入都返回空，调用方跳过。
- 视图的地面高度由 `main.gd` 用与 `housing_view.gd` 相同的
  `courtyard_plan.ground_height + courtyard_plan.anchors.east_bank.y` 提供，标记局部原点贴地，网格在原点之上。
- 多个项目绑定同一地块时各自生成标记，位置相同、节点名按 `project_id` 区分，不互相覆盖，也不静默挪位。

## 可见物

| kind | 程序化形状 | 说明 |
|---|---|---|
| `village_square` | 低矮圆柱圆盘，半径 0.50 m、高 0.10 m | 石色铺面，明显低于房屋 |
| `public_well` | 开口圆柱井台，半径 0.18 m、高 0.36 m，顶部无盖 | 内部加一片深色小圆盘表示井口 |
| `road_segment` | 长方体石板，0.26 × 0.06 × 1.10 m | 窄、长、薄，沿 z 延伸 |

- 共享石色材质取 `Game/ui/ui_tokens.gd` 的 `EDGE`，井口深色取 `INK`，粗糙度为 1.0；所有标记共用这两个材质实例。
- 只显示 `status == "built"`、`kind` 属于三类、`project_id` 非空且 `parcel_id` 可解析的行。`unbuilt`、`funded`、未知 kind、空项目 id、格式错误行、空/未知地块都跳过。
- 不读取项目行的 `funded`/`pledged`/`built_utc` 来改变几何；这些仍由面板展示。

## 刷新与生命周期

- `PublicWorksView.refresh(source)` 接受权威 `{projects: [...]}` 或行数组，按 `project_id` 建立整份替换集合：
  - 消失或不再满足条件的项目立即 `remove_child` + `queue_free`；
  - 同一项目类型/地块/slot 不变时保留原节点，重复刷新不叠加、不重建；
  - 类型或地块变化时重建该项目的标记。
- `clear()` 移除全部标记，用于断线。
- `main.gd` 接线：
  - `_adopt_remote()` 在 `housing_view` 之后创建 `PublicWorksScene`，共用地面高度并挂到 `$Environment`；
  - `remote.public_works_result` 改为连接 `_on_public_works_result()`：先交给面板 `apply_result`，再用 `payload.state` 刷新世界视图；
  - 打开面板与面板“刷新”按钮都先用面板已有视图同步世界，再向权威请求新状态；
  - `remote == null` 或 `_on_remote_lost()` 时清空标记，不为未连接状态保留旧建筑。
- 单机模式没有 `public_works_view` 节点（与 `housing_view` 相同，只在 `_adopt_remote()` 创建），不会凭空生成本地公共建筑。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
cd /Volumes/Disk-1tb/yipiantian
for f in Game/scenes/environment/public_works_view.gd \
  tests/public_works_view_test.gd Game/scenes/main.gd; do
  "$GODOT" --headless --path Game --check-only --script "$PWD/$f"
done
perl -e 'alarm shift; exec @ARGV' 420 "$GODOT" --headless --path Game \
  --script "$PWD/tests/public_works_view_test.gd"
```

三个文件 `--check-only` 均退出 0。

原始末行：

```text
PUBLIC_WORKS_VIEW_TEST checks=25 failures=0
```

回归原始末行：

```text
PUBLIC_WORKS_PANEL_TEST checks=71 failures=0
WORLD_SNAPSHOT_TEST checks=33 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/world-snapshot-504144
M4_CLIENT_SCENE_TEST checks=42 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/m4-client-scene-335104
```

三个回归均退出 0。`M4_CLIENT_SCENE_TEST` 退出时仍打印既有的 DummyShader 泄漏提示；该夹具不产生任何公共项目行，本切片的材质未被创建，泄漏与本次改动无关。

## 覆盖

| 用例 | 检查 |
|---|---|
| 位置契约 | `parcel_01` → `yard_a`、`parcel_06` → `yard_f`；位置等于 `HousingLayout.slot_pose`；空地块、未知地块、slot id 当地块 id 均返回空 |
| 三类建成 | 三种 kind 各生成一个以项目 id 命名的节点；广场为低矮圆柱、公井为开口圆柱加深色井口、石板路为窄长薄 BoxMesh |
| 贴地 | 标记位于 `ground_y` 与对应 slot 中心；metadata 记录 project/parcel/slot/kind/signature |
| 同一地块 | 两个项目共用 `parcel_01` 时保留两个独立标记 |
| 跳过 | 非 `built`、未知 kind、空 project id、空/未知 parcel、缺字段行、非对象行都不生成节点；空视图清空 |
| 整份替换 | 同输入重复刷新不叠加且复用节点；移除一行后只保留剩余标记；kind/parcel 变化重建；`clear()` 清空全部 |
| 接线 | `main.gd` 在共享世界创建视图；答复、打开、刷新与断线走同一视图更新/清空路径 |

## 未覆盖

- 真实地图选点：地块仍由 `parcel_id` 文本确定，未接入三维地图点击或视口拾取。
- 美术精修：几何只是可辨识占位（圆盘/井台/石板），没有铺装纹理、井栏细部、道路拼接、施工过程或动画；也未做与既有房屋/植被的避让，公共项目与同一 slot 的房屋可能重叠。
- 真实画面截图：未在真实窗口/TCC 下截图确认亮度、遮挡与昼夜可读性。
- Windows 实机与 CI：`tests/public_works_view_test.gd` 是 scene-free 规则/节点测试，但按本任务边界没有把它加入 `.github/workflows/rule-tests.yml`；当前只在 macOS 本机运行。
- 交互：不做点击、悬停、拆除或面板选点联动。
- 真实网络 UI 联调：只回归既有面板/场景测试，未在此切片重新启动真实 WSS 服务端观察建成物增量出现。

## 关联

- 阶段计划：[M8 PLAN](PLAN.md)。
- 权威切片：[RECORD-10 · 公共项目接入世界权威](RECORD-10-public-works-authority.md)。
- 网络切片：[RECORD-11 · 公共项目真实网络测试](RECORD-11-public-works-network.md)。
- 面板切片：[RECORD-12 · 公共项目面板](RECORD-12-public-works-panel.md)。
- 同型世界视图参考：`Game/scenes/environment/housing_view.gd`、`tests/housing_view_test.gd`。
