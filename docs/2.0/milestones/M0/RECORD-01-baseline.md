# M0-01 · 记录行为与数据基线

状态：已执行，未验收。范围仅限只读调查与隔离夹具；未修改产品代码，未运行游戏 UI，未编辑 M0-03/04 记录与 `world_package.gd`。

## 方法与范围

- 阅读当前实现：`Game/farm/farm_state.gd`、`farm_store.gd`、`farm_command.gd`、`world_command_entry.gd`、`decoration_state.gd`、`animal_companions.gd`、`neighbor_catalog.gd`、`kitchen.gd`、`garden_memories.gd`、`crop_catalog.gd`、`Game/scenes/main.gd`、`Game/scenes/decoration_layout.gd`、`Game/layout/*`、相关测试。
- 不启动游戏窗口；调用链由代码与无头测试交叉确认。
- v27 字段来自实际序列化输出（`FarmStore.save`）和校验函数，不依据历史文档补字段。
- 夹具由真实 `FarmStore` 写入生成，正常/边界样本均通过当前校验器；损坏样本由正常样本派生，未知版本仅改 `version`。
- 需注意：`Game/farm/world_package.gd` 属于 M0-03，本文只记录其边界之外的事实；v27 落盘路径与 2.0 世界包信封不是同一格式。

## 真实调用链

### 播种

1. UI 选择种子后 `main._field_menu_action("sow", crop)` 只调用 `_select_crop(crop)`，不立即播种。
2. 点击田格进入 `main._apply_tool()`；`candidate := farm_state.copy()`。
3. `candidate.sow(field_id, cell_id, selected_crop, now)` → `FarmState._act("sow", ...)`：先 `_settle_data` 推进时间，再校验 `ground == "ready"`、支持类型（`luffa` 只能上架，其余只能地面）、格为空，然后写 `crop_id`。
4. `main` 先把结果 `farm_state.accept(candidate)` 放入内存，再 `store.save_state(farm_state, decoration_state)`；写失败时内存结果保留并锁输入，重试只保存当前快照。
5. 新档初始作物由 `FarmState._init`/`_set_initial_crop` 写入 `field_03`/`field_04` 的 `greens`、`field_05`/`field_06` 的 `radish`（均为 `cell_06`）。

### 浇水

1. 同一 `main._apply_tool()` 路径，`selected_tool == "water"`。
2. `candidate.water(...)` → `_act`：先结算时间；拒绝已成熟、已浇过或空格。
3. 一次浇水把 `growth_seconds` 增加 `duration_seconds * water_progress`（`water_progress` 为 0.12..0.30，按作物不同），并置 `watered = true`；每次种植只生效一次。
4. 保存路径与播种相同。

### 收获

1. `main._apply_tool()` 对 `harvest` 构造 `FarmCommand.make(_new_command_id(), field_id, selected_cell, now)`。
2. `farm_commands.execute(farm_state, command)`：校验命令；同一批内重复 ID 直接返回已记录结果且不产生候选；否则 `state.copy()` 后调用 `candidate.harvest(...)`。
3. `_act("harvest")`：结算时间，要求 `growth_seconds >= duration`，`harvested[crop]++`、`inventory[crop]++`，用 `_empty_cell(last_settled)` 清空格子。
4. `main` 先 `farm_state.accept(candidate)`，再 `store.save_state`；只有保存成功后 `farm_commands.commit(command, result)`。保存失败时收获结果留在内存，命令不记录为已提交。
5. 无场景入口 `world_command_entry.gd` 走同一 `FarmState`/`FarmStore`/`FarmCommand`，先保存后 `commit`。

### 库存

- 唯一权威是 `farm.inventory`；`farm.harvested` 是累计收获，不是当前库存。
- 增加：`harvest`（`harvested` 与 `inventory` 同时 +1）。
- 减少：`share_basket`（按菜篮数量）、`kitchen_action` 的 `start`（每种菜 −1）、`animal_action` 的 `feed`（每种食物 −1）。
- 仅增加 `inventory` 而不增加 `harvested`：`claim_gift`。
- HUD 通过 `FarmState.hud_state()` 读取两者副本；没有独立库存存档字段。

### 布局与小院

1. 入口为 `main._begin_courtyard_edit`、`_begin_construction`（`island_builder`）以及装饰布局的 `change_requested`。
2. `main._apply_courtyard` / `_apply_construction` / `_apply_fields` / `_apply_trellis` / `_apply_bridge` / `_apply_flock` / `_apply_building` / `_apply_land` / `_apply_plants` / `_apply_routes` 最终都调用 `FarmState.apply_layout(snapshot, now)`。
3. `apply_layout`：`CourtyardPlan.from_snapshot` 校验后重建 `fields`（保留旧格，新增空格）、拒绝移除有作物的格、调用 `Companions.include_flocks`、布局实际变化时记录 `memories.marks.arrange`、结算时间；成功后 `main` 先 `farm_state.accept(candidate)` 再 `store.save_state`，最后重建场景。
4. `courtyard_edit_session._check` 与各预览器只做预览/准入，不写权威状态。
5. 田块增删、格子行列、棚架、桥、建筑、岸线、水草、道路/围栏分别映射到 `farm.layout` 的不同子对象（见下表）。

### 邻居

1. 收获书/邻居页发出 `_exchange(id, visit, basket, gift)`。
2. `candidate.share_basket(id, round, basket)` 校验邻居、轮次、未挂起、作物类别、数量与库存，扣库存并置 `pending = true`。
3. `candidate.claim_gift(id, round, crop)` 要求同轮且 `pending`，校验礼物作物，`inventory[crop]++`，`pending = false`，`round++`，`last_gift = crop`。
4. `main._exchange` 先 `farm_state.accept(candidate)` 再 `store.save_state`；写失败不发布草稿、不扣菜。
5. 邻居故事/愿望由 `neighbor_catalog.gd`、`neighbor_stories.gd` 从 `neighbors[id].round` 派生，没有独立故事存档。

### 装饰

1. `decoration_layout.confirm_preview()` / `remove_selected()` 在候选 `DecorationState` 上调用 `place_at`/`place`/`remove`，发出 `change_requested`。
2. `main._change_decoration(candidate)` 校验 `Kitchen.placement_valid`（晒架任务需要晒架已放置），复制 `FarmState`；装饰快照变化时写 `memories.marks.arrange`；然后 `store.save(candidate_farm.snapshot(), replacement.snapshot())`（注意这里走 `save()` 全量校验，而不是 `save_state`）。
3. 保存成功后 `decoration_state = replacement` 并接受显示；失败保留旧状态。

### 其他已存档状态

- 厨房：`main._kitchen_action` → `candidate.kitchen_action(...)` → `Kitchen.act`，成功后 `decorations.unlock(candidate.harvested, candidate.kitchen)`，再 `save_state` 并接受。
- 动物：`main._animal_action` → `candidate.animal_action(...)` → `Companions.act`（`revision` 必须匹配），保存成功后接受。
- 回忆/相册：`garden_album.observe()` 写 `dawn`/`dusk`/`company`；`main._change_decoration` 与 `apply_layout` 写 `arrange`；照片 `add`/`rename`/`remove` 走 `FarmState.photo_action`；均以 `store.save` 提交。
- 季节：`main._change_season` → `FarmState.set_season`，保存后应用表现。

## v27 字段映射

### 顶层封套

落盘文件为 `farm.json`（另有 `farm.backup.json`、`farm.pending.json`、`farm.backup.pending.json` 作为恢复/写入中间件；它们不是字段映射的一部分，但被 `FarmStore` 用于恢复和版本否决）。

| JSON 路径 | 类型 / 范围 / 单位 / 时间语义 | 归属与权威 | 变更入口 | 相关测试 |
|---|---|---|---|---|
| `version` | 整数，当前必须等于 `27`；整数校验不接受小数 | `FarmStore.VERSION` | `_save_validated` 写入；`_read_document` 读取并区分 `unsupported` | `tests/farm_store_test.gd` |
| `farm` | 对象，必须恰好 9 个键；`FarmState._valid_snapshot` 整树校验 | `FarmState._data` | 全部 `FarmState` 变更方法 + `accept`；`FarmStore.save_state` | `tests/farm_state_test.gd`、`tests/farm_store_test.gd` |
| `decorations` | 对象，必须恰好 6 个物品键 | `DecorationState._items` | `unlock`/`place`/`place_at`/`remove`；`main._change_decoration` | `tests/decoration_state_test.gd`、`tests/free_decoration_test.gd` |

顶层多余键会被 `data.size() != 3` 拒绝为 `corrupt`；`farm` 内多余键会被 `data.size() != 9` 拒绝。

### `farm` 对象

| JSON 路径 | 类型 / 范围 / 单位 / 时间语义 | 归属与权威 | 变更入口 | 相关测试 |
|---|---|---|---|---|
| `season` | 字符串枚举 `daily` / `drying` / `after_rain`；默认 `daily` | `FarmState.set_season`；`season_catalog.valid` | `FarmState.set_season` ← `main._change_season` | `tests/season_scene_test.gd`；`tests/farm_state_test.gd`（非法季节拒绝） |
| `harvested.<crop_id>` | 13 个作物键，各为整数 0..`9007199254740991`（2^53−1）；累计收获篮数 | `FarmState.harvest` | `_act("harvest")` +1；无其他写入 | `tests/farm_state_test.gd`、`tests/farm_command_test.gd`、`tests/neighbor_state_test.gd` |
| `inventory.<crop_id>` | 13 个作物键，各为整数 0..2^53−1；当前可用篮数 | `FarmState` | 收获 +1；`share_basket`、厨房 `start`、动物 `feed` 扣减；`claim_gift` +1 | `tests/neighbor_state_test.gd`、`tests/kitchen_state_test.gd`、`tests/animal_companions_test.gd` |
| `neighbors.willow/ bamboo/ferry.round` | 整数 0..2147483646；已完成拜访轮次/故事索引；不是时间戳 | `FarmState.claim_gift` | `claim_gift` +1；`share_basket` 只校验不递增 | `tests/neighbor_state_test.gd` |
| `neighbors.<id>.pending` | 布尔；菜篮已交付、礼物待领取 | `FarmState.share_basket` / `claim_gift` | `share_basket` 置 true；`claim_gift` 置 false | `tests/neighbor_state_test.gd` |
| `neighbors.<id>.last_gift` | 字符串；`""` 或该邻居 `gifts` 中的作物 ID；`round == 0` 时必须为 `""` | `FarmState.claim_gift` | 领取礼物时写入 | `tests/neighbor_state_test.gd` |
| `animals.<animal_id>.name` | 字符串，1..12 字符，首尾无空白，不含控制字符；默认 7 只固定名字 | `FarmState.animal_action`；`animal_companions.valid_name` | `Companions.act("name")` | `tests/animal_companions_test.gd` |
| `animals.<animal_id>.preference` | 整数 −1..3；−1 表示“随它喜欢” | 同上；`valid` | `Companions.act("preference")` | `tests/animal_companions_test.gd` |
| `animals.<animal_id>.visits` | 整数 0..2147483646；互动次数 | 同上 | `act("feed")`/`act("call")` +1 | `tests/animal_companions_test.gd` |
| `animals.<animal_id>.shared` | 整数 0..2147483646；投喂次数，必须 ≤ `visits` | 同上 | `act("feed")` +1 | `tests/animal_companions_test.gd` |
| `animals.<animal_id>.revision` | 整数 0..2147483646；乐观并发版本，必须 ≥ `visits` | 同上 | 每次成功 `act` +1；调用方必须传入当前值 | `tests/animal_companions_test.gd`、`tests/farm_state_test.gd` |
| `kitchen.revision` | 整数 0..2147483646；厨房事务版本 | `Kitchen.act` | 每次成功动作 +1 | `tests/kitchen_state_test.gd` |
| `kitchen.jobs.<station>` | `stove`/`jar`/`rack`/`garden_rack` 之一；空对象或 `{recipe, crop, start_utc, finish_utc}` | `Kitchen.act` | `start` 写入；`collect` 清空 | `tests/kitchen_state_test.gd` |
| `kitchen.jobs.<station>.start_utc` / `finish_utc` | 浮点，Unix 纪元 UTC 秒；`finish_utc − start_utc` 必须约等于配方秒数（`is_equal_approx`；20/25/35/45/60/90） | `Kitchen.RECIPES` + `Kitchen.act` | `start` | `tests/kitchen_state_test.gd`、`tests/farm_store_test.gd` |
| `kitchen.jobs.<station>.recipe` / `crop` | 字符串；`crop` 必须属于该配方的作物组 | 同上 | `start` | `tests/kitchen_state_test.gd` |
| `kitchen.stock.<recipe>` | 6 个配方键，各为整数 0..2147483646；成品数量 | `Kitchen.act` | `collect` +1；`share` −1 | `tests/kitchen_state_test.gd` |
| `kitchen.records.<recipe>.made` | 整数 0..2147483646；累计做成数；必须等于 `shared + stock[recipe]` | `Kitchen.act` | `collect` +1 | `tests/kitchen_state_test.gd` |
| `kitchen.records.<recipe>.shared` | 整数 0..2147483646；累计送出数 | 同上 | `share` +1 | `tests/kitchen_state_test.gd` |
| `kitchen.records.<recipe>.last_crop` | 字符串；`made == 0` 时 `""`，否则必须是该配方接受的作物 | 同上 | `collect` 写入 | `tests/kitchen_state_test.gd` |
| `kitchen.records.<recipe>.last_to` | 字符串；`shared == 0` 时 `""`，否则必须是邻居 ID | 同上 | `share` 写入 | `tests/kitchen_state_test.gd` |
| `kitchen.display` | 字符串；`""` 或某个 `stock > 0` 的配方 | 同上 | `collect` 设为成品；`display` 切换；`share` 清空 | `tests/kitchen_state_test.gd` |
| `memories.marks.dawn/dusk/company/arrange` | 可选键；值均为浮点 Unix UTC 秒，0..253402300799；只记录一次 | `Memories.mark`；`garden_memories.valid` | `observe`（dawn/dusk/company）、`apply_layout`/`_change_decoration`（arrange） | `tests/garden_memories_test.gd` |
| `memories.photos` | 数组 ≤256；每项恰 3 键 `{id, title, utc}` | `Memories.photo_action` | `add`/`rename`/`remove` ← `garden_album` | `tests/garden_memories_test.gd` |
| `memories.photos[].id` | 32 个小写十六进制字符；数组内唯一 | 同上 | `add` | 同上 |
| `memories.photos[].title` | 1..40 字符，不含控制字符 | 同上 | `add`/`rename` | 同上 |
| `memories.photos[].utc` | 浮点 Unix UTC 秒，0..253402300799 | 同上 | `add` | 同上 |
| `fields.<field_id>.cells.<cell_id>.crop_id` | 字符串；`""` 或作物 ID；`luffa` 只能在 `trellis`，其他只能在 6 块地面田 | `FarmState` | `_act("sow")`；收获清空 | `tests/farm_state_test.gd`、`tests/trellis_planting_state_test.gd` |
| `fields.<field_id>.cells.<cell_id>.growth_seconds` | 浮点秒，≥0；种有作物时 ≤ 作物 `duration_seconds`（青菜 1800、萝卜 5400 等） | `FarmState._settle_data` / `_act` | `settle` 累加真实流逝；`water` 加一次奖励；收获/播种重置 | `tests/farm_state_test.gd`、`tests/headless_world_test.gd` |
| `fields...<cell>.last_settled_utc_seconds` | 浮点 Unix UTC 秒，有限且 ≥0；**该格最近一次逻辑结算时间**，空地与成熟地也更新 | `FarmState._settle_data` | `settle`/任何 `_act`/`apply_layout` | `tests/farm_store_test.gd`、`tests/farm_state_test.gd` |
| `fields...<cell>.watered` | 布尔；空地为 false；为 true 时必须 `growth_seconds >= duration * water_progress` | `FarmState._act("water")` | 浇水置 true；新种植由 `_empty_cell` 置 false | `tests/farm_state_test.gd`、`tests/trellis_planting_state_test.gd` |
| `fields...<cell>.ground` | 枚举 `ready` / `rough` / `weedy`；非 `ready` 时不得有作物；`trellis` 的格必须为 `ready` | `FarmState.tidy` / `sow` | `weed`：`weedy → rough`；`till`：`rough → ready`；初始 `field_06` 的 `cell_11`/`cell_12` 为 `rough`，`cell_13..16` 为 `weedy` | `tests/ground_tending_test.gd`、`tests/farm_state_test.gd` |

`fields` 的键集合只有当次布局的 `Plan.fields` 加一个固定键 `trellis`，即默认 7 个；每个地面田默认 4×4=16 格，格子 ID 形如 `cell_01`..`cell_16`。`trellis` 的格子 ID/数量由 `layout/trellis_slots.gd` 按棚架尺寸派生，形如 `left_-2`..`right_2`（默认 10 个），并非固定 16 格。格子对象必须恰好 5 个键。

### `farm.layout` 对象

`layout` 必须恰好 7 个键：`shore`、`terrain`、`fields`、`fence_style`、`construction`、`plants`、`routes`。

| JSON 路径 | 类型 / 范围 / 单位 / 时间语义 | 归属与权威 | 变更入口 | 相关测试 |
|---|---|---|---|---|
| `layout.shore` | 2 个浮点，各 0..8；西/南岸扩展米数 | `CourtyardPlan.snapshot`/`from_snapshot` | `expand_shore`（经 `apply_layout` 提交） | `tests/island_construction_test.gd` |
| `layout.terrain` | 2 个浮点：地面高度 0.08..0.38、岸宽 0.8..1.2 | 同上 | `set_terrain`（经 `apply_layout`） | 同上 |
| `layout.fence_style` | 枚举 `bamboo` / `crossed` / `picket` | 同上 | 小院编辑器/`apply_layout` | `tests/garden_memories_test.gd`、`tests/courtyard_editor_test.gd` |
| `layout.fields` | 数组 1..12；每项恰 8 键 | `CourtyardPlan.fields` | 田块编辑器 → `apply_layout` | `tests/island_fields_test.gd`、`tests/variable_fields_test.gd` |
| `layout.fields[].id` | 字符串 `field_NN`（2..6 位数字后缀，规范为 `%02d`），数组内唯一 | 同上 | 同上 | 同上 |
| `layout.fields[].position` | 3 个浮点世界坐标；x/z 绝对值 ≤30；y 必须等于地形高度 + 0.07（±0.001） | 同上 | 同上 | `tests/farm_grid_layout_test.gd` |
| `layout.fields[].yaw` | 浮点度，±180 | 同上 | 同上 | — |
| `layout.fields[].size` | 2 个浮点，米；派生格宽 `(size−(0.20,0.29))/(columns,rows)` 必须在 0.5999..1.2001 / 0.4399..1.0001 之间 | 同上 | 同上 | `tests/island_fields_test.gd` |
| `layout.fields[].columns` / `rows` | 整数 2..8 | 同上 | 同上 | 同上 |
| `layout.fields[].cells` | 字符串数组，数量必须 `columns*rows`；ID 唯一且形如 `cell_NN`；全局总格数 ≤384 | 同上 | 同上 | `tests/farm_store_test.gd`（384 边界） |
| `layout.fields[].seed` | 整数 0..2147483647；地块视觉随机种子 | 同上 | 同上 | — |
| `layout.construction` | 对象，恰 6 键 | `island_construction.valid` | `apply_construction` ← `apply_layout` | `tests/island_construction_test.gd` |
| `construction.land` / `east_land` | 数组 ≤256 个笔刷块；每块 4 个数 `[x,y,w,h]` 或 5 个数 `[... , -1]`（5 个表示擦除） | 同上 | 岸线画笔 | `tests/island_brush_test.gd`、`tests/multi_island_land_test.gd` |
| — 笔刷约束 | x/y 绝对值 ≤30；w/h 为 0.5 的整数倍（`CELL=0.5`）且 0.5..5；全部数值按 0.5 网格对齐（容差 0.0001） | 同上 | — | 同上 |
| `construction.trellis` | `[]` 或 6 个数：宽 2..6、高 0.8..2、深 1.6..3、x/z 绝对值 ≤24、偏航 [−180, 180) | 同上 | 棚架编辑器 | `tests/trellis_layout_test.gd` |
| `construction.bridge` | `[]` 或 6/7 个数：两端 x1,z1,x2,z2；宽 0.8..1.8；样式 `0`（平桥）/`1`（拱桥）；可选栏杆高 0.35..1.2；两端距离 2..9；x/z ≤24 | 同上 | 桥编辑器 | `tests/bridge_layout_test.gd` |
| `construction.flocks.duck/goose/hen.count` | 整数：鸭 0..12、鹅 0..8、鸡 0..8 | `flock_layout.valid` | 动物区域编辑器 | `tests/flock_layout_test.gd`、`tests/flocks_test.gd` |
| `construction.flocks.<kind>.area` | `[]` 或 4 个数 `[x,y,w,h]`：x/y 绝对值 ≤24，w/h 2..12，且 `w*h >= count * 每只需求面积`（鸭 3、鹅 4、鸡 1.5） | 同上 | 同上 | 同上 |
| `construction.buildings.house` / `kitchen` | `[]` 或 3 个数 `[x,z,yaw]`：x/z 绝对值 ≤24，yaw [−180, 180)；空数组表示使用作者默认位置 | `building_layout.valid` | 建筑编辑器 | `tests/building_layout_test.gd` |
| `layout.plants` | 数组 ≤160；每项 3 键 `{id, kind, pose}` | `plantings.valid` | 水草编辑器 | `tests/plantings_test.gd`、`tests/plant_layout_test.gd` |
| `layout.plants[].id` | 整数 1..2147483647，数组内唯一 | 同上 | 同上 | 同上 |
| `layout.plants[].kind` | 枚举 `lotus` / `reed` / `cattail` / `trapa` | 同上 | 同上 | 同上 |
| `layout.plants[].pose` | 4 个数 `[x, y, yaw, scale]`：x/y 绝对值 ≤30，yaw [0, 360)，scale 0.8..1.2；恢复时按 4 位小数规范化、yaw 取模 360 | 同上 | 同上 | 同上 |
| `layout.routes` | 数组 ≤64；每项 4 键 `{id, kind, points, openings}` | `player_routes.valid` | 道路/围栏编辑器 | `tests/player_routes_test.gd`、`tests/route_layout_test.gd` |
| `layout.routes[].id` | 整数 1..2147483647，数组内唯一 | 同上 | 同上 | 同上 |
| `layout.routes[].kind` | 枚举 `road` / `fence`；`road` 的 `openings` 必须为空 | 同上 | 同上 | 同上 |
| `layout.routes[].points` | 2..64 个 `[x,y]`，坐标绝对值 ≤30，必须吸附到小岛网格；相邻点距离 ≥0.49；全部线路总长 ≤256 | 同上 | 同上 | 同上 |
| `layout.routes[].openings` | ≤32 个 `[x,y]`，必须落在对应线上（距离 ≤0.005） | 同上 | 同上 | 同上 |

`layout` 对象在磁盘上只保存上述 7 个键；`CourtyardPlan` 运行期的 `rim`、`east_rim`、`paths`、`garden_fences`、`fences`、`props`、`slots`、`anchors`、`angles`、`trees`、`animal_areas`、`site` 等都不进入快照，由布局参数重新派生。`site` 由 `shore` 是否为零决定。

### `decorations` 对象

| JSON 路径 | 类型 / 范围 / 单位 / 时间语义 | 归属与权威 | 变更入口 | 相关测试 |
|---|---|---|---|---|
| `decorations.<item>.unlocked` | 布尔；`pot`/`flowerpot`/`lantern` 需累计收获/品种阈值，`drying_rack` 需分享 1 份成品，`bench`/`tea_table` 初始已解锁 | `DecorationState`；`decoration_catalog.earned` | `unlock`（收获、厨房、加载后补算） | `tests/decoration_state_test.gd`、`tests/decoration_interaction_test.gd` |
| `decorations.<item>.slot_id` | 字符串；`""` 或 `ground_01..04` / `hanging_01..04`；已放置时必须已解锁、类型匹配、旋转被允许且槽位唯一 | 同上 | `place` | `tests/decoration_state_test.gd` |
| `decorations.<item>.quarter_turn` | 整数 0..3；90° 旋转次数；未放置时必须为 0 | 同上 | `place`/`place_at`/`remove` | 同上 |
| `decorations.<item>.position` | `[]` 或 `[x,y]` 世界地面坐标；坐标绝对值 ≤30；恢复时按 4 位小数规范化；非空时必须已解锁、`slot_id==""`、物品类型为 `ground` | 同上 | `place_at`（自由摆放）/`place`/`remove` | `tests/free_decoration_test.gd` |

`decorations` 必须恰好包含 `pot`、`flowerpot`、`lantern`、`bench`、`drying_rack`、`tea_table` 6 个键。`slot_id` 与 `position` 互斥：一个已放置物品只能处于槽位模式或自由地面模式之一。

## 派生、临时与忽略字段

- `FarmState.get_cell()` 在快照格子上派生 `id`、`field_id`、`progress`、`remaining_seconds`、`stage`（`empty`/`sprout`/`young`/`mature`），这些**从不写盘**。
- `load_state()` 返回的 `migrated = version < 27`；当前只接受 27，因此正常加载恒为 `false`。`source`/`kind`/`text` 等是读取过程的元数据，不是存档字段。
- `farm.layout` 的运行期几何字段见上一节；它们由 `snapshot()` 的 7 个键重建。
- 存档侧车：`farm.backup.json`（最近一次已提交旧主文件）、`farm.pending.json`、`farm.backup.pending.json` 用于崩溃恢复与版本否决；它们不是独立数据模型，但 `load_state`/`recover` 会验证或拒绝它们。
- v27 中**没有**世界/农场/玩家/设备 ID、金额、事件序号、规则版本等 2.0 封套字段；这些只存在于 `world_package.gd` 的 M0-03 目标格式，不得反推为 v27 字段。
- 时间统一为 Unix 纪元 UTC 浮点秒；代码不读取本地时区参与比较。`last_settled_utc_seconds` 是“该格最近一次逻辑结算”，不是播种/浇水时间。
- 空文件（0 字节）和超过 524288 字节的文件在解析前即为 `corrupt`；读取不产生迁移。

## 夹具清单

目录：`tests/fixtures/v27/`。全部为合成数据，不含用户名、个人路径或真实存档。

| 文件 | 大小 | SHA-256 | 来源与内容 | 预期结果 |
|---|---:|---|---|---|
| `normal.json` | 25828 B | `15e8c556...b6bc0ec` | `FarmStore.save` 生成；含生长中萝卜、收获统计、邻居待领菜篮、厨房成品、动物投喂、`arrange` 回忆、`crossed` 围栏、已放置陶罐 | `ok=true`, `kind=loaded`, `migrated=false` |
| `boundary.json` | 201383 B | `ed895da0...fe4da6b` | `FarmStore.save` 生成；6 块 8×8 田（384 格）、固定小数生长值、最大有限时间戳、所有作物累计/库存为 2^53−1 | `ok=true`, `kind=loaded`；恢复 64 格、最大整数与时间戳 |
| `truncated.json` | 12928 B | `bc88aad0...c4ea8eb` | `normal.json` 字符级截断一半 | `ok=false`, `kind=corrupt`；原字节保留 |
| `corrupt.json` | 9 B | `60498eba...f46faf33` | 非 JSON 文本 | `ok=false`, `kind=corrupt`；原字节保留 |
| `empty.json` | 0 B | `e3b0c442...b855` | 0 字节主文件 | `ok=false`, `kind=corrupt`（不是首次启动） |
| `unknown-version.json` | 26034 B | `8248c044...b23cd4` | `normal.json` 解析后仅把 `version` 改为 `99` | `ok=false`, `kind=unsupported`；原字节保留；随后保存为 `not_loaded` |

完整哈希见本文末。正常/边界夹具均由真实序列化器生成，损坏夹具由正常样本派生，避免手写字段漂移。

## 命令与结果

环境：macOS，Godot 4.7.2-stable，`GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot`。所有命令在仓库根执行，使用 `--headless`，未启动游戏 UI。

生成夹具：

```sh
"$GODOT" --headless --path Game --script "$PWD/tests/make_v27_fixtures.gd"
```

结果：退出码 0；输出 `V27_FIXTURE` 六行，`normal.json` 25828 B、`boundary.json` 201383 B、`truncated.json` 12928 B、`corrupt.json` 9 B、`empty.json` 0 B、`unknown-version.json` 26034 B。

新增夹具测试：

```sh
"$GODOT" --headless --path Game --script "$PWD/tests/farm_v27_fixtures_test.gd"
```

结果：`V27_FIXTURES_TEST checks=27 failures=0`，退出码 0。覆盖正常/边界恢复、损坏/截断/空文件拒绝、未知版本区分与字节保留、拒绝后锁写。

既有存储测试：

```sh
"$GODOT" --headless --path Game --script "$PWD/tests/farm_store_test.gd"
```

结果：`FARM_STORE_TEST checks=109 failures=0`，退出码 0。覆盖往返、离线成熟、重复加载不重复发奖、陈旧覆盖、写入失败、损坏恢复、未知版本、384 格边界和布局参数。

## 明确缺口与歧义

1. **动物条目不会随群体数量减少而删除。** `apply_layout` 只调用 `Companions.include_flocks`（只增不删）；`Companions.valid` 允许 7..28 个符合命名规则的 ID，因此减少鸭/鹅/鸡数量后旧条目仍留在 `animals` 中。没有测试断言这一行为；M0-04 迁移时需要决定保留、清理或标记。
2. **`farm.neighbors.round` 与故事章节共用一个索引。** `Neighbors.wish` 先查 `Stories.chapter(id, round)`，超出章节后才按轮次循环；该语义在代码中成立，但没有独立字段记录“已完成故事数”。迁移时应按完整 `round` 保留，不能只保留循环愿望。
3. **`watered` 是“本次种植已享受一次浇水加成”的标记**，不是“今天浇过水”；收获重建空格时才清零。字段名容易误读，文档按实际语义记录。
4. **`last_settled_utc_seconds` 会被空地和成熟地更新**，所以不能当作播种时间或最后一次浇水时间；若 2.0 需要这些事实，必须另设字段，不能从该值反推。
5. **`harvested` 与 `inventory` 不是同一统计。** 只有收获同时增加两者；礼物只加库存，厨房/动物只减库存。任何迁移报告都应分别核对。
6. **没有直接覆盖全部字段持久化的单一测试。** 现有测试按系统分散覆盖（见上表）；`season` 的完整落盘往返主要由 `season_scene_test` 的场景路径覆盖，`layout.fields[].yaw`、`layout.fields[].seed`、`construction.flock.area` 的部分边界值缺少专门断言。
7. **`memories.marks.company` 依赖运行时动物状态**（`garden_album.observe` 检查游动与同伴距离），无头规则测试没有构造该场景；它属于表现触发，不是存档格式缺口。
8. **v27 没有身份、金额或事件日志字段。** 2.0 迁移不能从 v27 推导这些值；`world_package.gd` 的封套字段必须由导入方生成或显式拒绝。
9. **未知版本先于内容校验。** `version != 27` 直接返回 `unsupported`，不会尝试解析 `farm`；因此未知版本夹具的其余内容是否合法不影响结论。反过来说，不能靠修改 `version` 让旧数据“升级”。
10. **未修改产品代码。** 本次只新增 `tests/make_v27_fixtures.gd`、`tests/farm_v27_fixtures_test.gd` 与夹具；`Game/farm/world_package.gd`、M0-03/04 记录、`PLAN.md` 均未改动。

## 夹具完整 SHA-256

```text
ed895da06e0f2ce139fa56215906675b68231132ef88d9ef081c02325fe4da6b  boundary.json
60498ebafa3f473a2a72c1242e8c3202bf50a6d81dfc721958be1550f46faf33  corrupt.json
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  empty.json
15e8c556f726c4f59ef9085cf493dbd99c81ca77ea781efcfc85508efb6bc0ec  normal.json
bc88aad09d1dbd296db18ad6c6fba2c2503dba2b5f103d40d4d97fdb6c4ea8eb  truncated.json
8248c044713bdb8b2c907b3bdf390218cae7ddfa8d428aece948740cc9b23cd4  unknown-version.json
```
