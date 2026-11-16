# M11-01 · 地籍连通性接入世界权威（只读）

执行日期：2026-11-16。状态：切片完成，不表示 M11-01 或 M11 验收完成。前置：[M11 PLAN](PLAN.md)、[RECORD-10 · 地籍转让与通行判定](RECORD-10-territory-transfer.md)、[RECORD-15 · 地籍连通性与唯一公共通路检查](RECORD-15-territory-paths.md)、[ADR-023](../../decisions/ADR-023-land-cadastre.md)、[ADR-028](../../decisions/ADR-028-build-land-authority.md)。

## 问题

RECORD-15 交付了纯规则 `TerritoryPaths.build_view()` / `check_blocking()`，但只在 `tests/territory_paths_test.gd` 里被调用，`Game/` 内零引用。规则能算“封掉这块地会不会切断公共入口到宅基的唯一通路”，世界却无法回答这个问题，也没有人决定宅基名单与公共入口从哪里来。RECORD-15 的“未覆盖”把这三件事列为接线前的必答项。

本切片只补**只读**的一半（缺口 G10 的前半）：把 `check_blocking()` 接成权威动作，仍然不让 claim/transfer/build 因阻断而失败。

## 边界

- 修改 `Game/world/headless_world.gd`：新增 `public_entrance_parcel()`、`built_homestead_parcels()`、`check_territory_blocking()` 与私有失败构造器。
- 修改 `Game/world/world_host.gd`：在既有 `territory` RPC（频道 9/10）的 `territory_for_member()` 里增加动作名 `blocking`；答复封装在既有六键上多一个 `blocking` 键，与 `can_pass` 多一个 `passable` 同构。**协议编号、频道数量、载荷上限、令牌桶均未改**。
- 新增 `tests/territory_blocking_authority_test.gd`。
- **未改** `Game/world/world_member.gd`、`Game/world/world_client.gd`、`Game/world/territory_paths.gd`、`Game/world/territory_state.gd`、`Game/farm/**`、`Game/scenes/**`、`Game/ui/**`、`.github/workflows/rule-tests.yml`、`rules/`。不写 ADR：这是 RECORD-15 已记录设计的实现，不是新的长期决策。

## 决定与实现

### 1. 公共入口 = 已建成且绑定地块的 `village_square`

`public_entrance_parcel()` 遍历 `public_works.projects`，只接受 `kind == village_square` 且 `status == built` 的项目行，取其非空 `parcel_id`。没有这样的项目时返回空串，动作以具名 `no_entrance` 拒绝，不猜入口。

理由：

- 广场是当前目录里唯一真正“公共集散地”的项目类型；`public_well` 与 `road_segment` 是设施与路面，作为唯一入口 origin 会把“有路”误读成“有村口”。
- 建成是事实，不是承诺：`funded` 只说明钱够了，项目行还没 `built_utc`，把未建成项目当入口会让寻路结果随一次支出跳变。
- 不猜是硬要求：没有入口时返回 `no_entrance` 比随便挑 `parcel_01` 更诚实，也让运营者知道要先建广场。

**取舍一：只取一个入口。** `build_view()` 的视图只有单一 `entrance`。多个已建成广场同时存在时，按 `parcel_id` 字典序取最小者。理由是当前地籍是 6 块固定布局，多入口需要多源连通性（每个入口都要能到达宅基），那是新的规则形状，不能在本只读切片里悄悄叠加。

**取舍二：不把地籍里不存在的地块过滤掉。** 若广场绑定了一个地籍没有的 `parcel_id`，`public_entrance_parcel()` 仍返回该 id，`build_view()` 会返回具名 `unknown_entrance`。这样运营者能区分“还没建广场”（`no_entrance`）与“广场绑定错了地块”（`unknown_entrance`），而不是把配置错误伪装成正常状态。

### 2. 宅基名单 = 农场已建成建筑，按 ADR-028 序号映射到地块

`built_homestead_parcels()` 读取 `farm.buildings_at(now_utc)`：

- 只取 `state == "done"`（`now_utc >= done_utc`）；施工中的建筑还不是可到达的宅基。
- 槽位 → 地块复用 `TerritoryState.slot_parcel_id()`（`Buildings.SLOTS[i] ↔ parcel_%02d(i+1)`），不另建映射表。
- 结果与 `territory.parcels` 求交；地籍里没有的槽位被跳过（房子存在但无地可路由）。
- 结果排序去重。

**为什么把所有已建成建筑都算宅基：** 当前目录里三个蓝图（`cottage`/`workshop`/`pavilion`）全部是私人计划，`buildings` 表没有“住宅/非住宅”标记。为了区分“住宅”而给农场文档新增一个字段，会牵动 `FarmState._valid_snapshot` 键数、`V27Importer.KNOWN_FARM_KEYS` 与旧存档，收益却只是把工坊排除在联通性保护之外。当前取舍是“任何已建成建筑都值得保一条公共门口”，与 RECORD-15 的终点豁免语义一致；等住宅与工坊在规则上真正分化时再收紧。

### 3. `passable` = `public_works_passable_parcels()`，并与地籍求交

直接复用已有只读收集器（`status == built` 且绑定地块的项目，不含类型过滤），再与 `territory.parcels` 求交。**求交是必须的**：`build_view()` 对 `passable` 里的未知 id 返回 `unknown_passable`，一个过期或错绑的项目就会让整个查询失败；求交后它只是被忽略，不影响其他地块的判定。

### 4. 只读承诺

新动作：

- 不写 `territory.json`、`public_works.json`、`farm.json` 或任何 sidecar；
- 不推进 `territory.sequence`；
- 不改农场或装饰；
- 不做 `authority_now_utc()` 之外的时钟读取，答案只依赖当前文档。`buildings_at(now_utc)` 用的是会话结算时钟，和摘要里的 `buildings` 同一来源。

访客与匿名成员可读，和 `can_pass` 同级：它回答的是“世界现在长什么样”，不回答“你能不能动这块地”。`read_only` 迁移期也照常答复。

### 5. 答复形状

权威层：

```text
{ok, reason, parcel_id, blocking}
```

`blocking` 恒为 `check_blocking()` 的形状（`{ok, reason, parcel, entrance, entrance_reachable, blocked, newly_blocked}`）。视图构建失败时（`not_open`、`invalid_state`、`no_entrance`、`unknown_entrance`、`too_many_*`、`invalid_*`）同一个形状里填写同名的 `reason` 与空结果，调用方不需要处理两种答案。

规则层自己的 `unknown_parcel`（被问的地块不在视图里）直接透出为顶层 `reason`；`check_blocking()` 已经用同样的名字拒绝。

### 6. 网络接线

`territory_for_member()` 的 `blocking` 分支放在 `can_pass` 之后、成员角色门之前，因此访客/匿名可用；写动作仍在其后要求成员 + 非只读 + 具名。`territory_request()` 只在答复里已有 `blocking` 字典时追加该键，其余动作保持既有六键。只读查询**不**触发 `_broadcast_summary()`，因为它不改变世界。

中文拒绝文案只增一条：`no_entrance` → “这个世界还没有建成的公共广场，无法判断公共通路。”其余具名原因复用 `_territory_reason_text()`/`_reason_text()` 既有行。

## 验证

实际运行：

```text
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 240 /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot --headless --path Game --script "$PWD/tests/territory_blocking_authority_test.gd"
```

原始末行：

```text
TERRITORY_BLOCKING_AUTHORITY_TEST checks=99 failures=0
TERRITORY_AUTHORITY_TEST checks=72 failures=0
TERRITORY_BUILD_GATE_TEST checks=79 failures=0
TERRITORY_PATHS_TEST checks=86 failures=0
HEADLESS_WORLD_RUNTIME_TEST checks=83 failures=0
FONT_COVERAGE_TEST checks=1276 failures=0 missing=0
```

覆盖（真实 `HeadlessWorld` + 默认 3×2 地籍，公共项目走真实 `PublicWorksStore` 侧车）：

| 用例 | 检查 |
|---|---|
| 无入口 | 无项目世界返回 `no_entrance`，答案仍带 `blocking` 形状；`public_entrance_parcel()` 为空 |
| 有入口无宅基 | 已建成广场推导出入口；无农场建筑时宅基为空，任何地块的 `newly_blocked` 也为空；阻断入口本身报告入口不可达 |
| 有入口有宅基 | 施工中不算宅基，完工后 `yard_f → parcel_06`；两条通路都通时阻断任一走廊不阻断宅基；`parcel_03` 私有化后下排成为唯一通路，阻断 `parcel_05` 报告 `newly_blocked=["parcel_06"]`；阻断宅基本身不剪掉门口 |
| 具名拒绝 | 未打开世界 `not_open`；只有道路没有广场 → `no_entrance`；已足额未建成广场 → `no_entrance`；地籍外地块 `unknown_parcel`；广场绑定地籍外地块 → `unknown_entrance`；多个广场取最小 id；`passable` 的地籍外 id 被过滤而查询仍成功 |
| 权限 | 成员、具名访客、匿名访客都能读且答案一致；名册外连接 `not_a_member`；迁移只读期仍可读；主机答复与直接权威答复逐项相同；`no_entrance` 带中文文案 |
| 只读与重启 | 连续查询前后 `territory.sequence`、农场快照、目录内所有文件字节完全一致；重开世界后入口、宅基与 `blocking` 答案完全相同，且重开与查询都不写文件 |

字体门禁：新增代码注释与文案未引入子集外汉字（重建后的字集本已覆盖 `无`/`判` 等用字，字体文件未改）。

## 未覆盖

- **写入门禁**：原切片 `claim` / `transfer` / `build` 不调用本动作，阻断结果只是**能问**。已由文末“写入门禁”增补补齐 claim 与首次建造；`transfer` / `release` 不改变匿名行路人的可通行性，不设门禁。
- **几何对齐**：地籍 `rect` 与三维地图/住宅槽位之间仍只有 ADR-028 的序号约定，没有真实坐标对齐。入口与宅基都是 id 级映射，不读地图网格。
- **多入口与多源连通性**：只取最小 id 的单个广场作为 origin；多个公共入口是否都需到达每个宅基尚未决定。
- **住宅与工坊区分**：所有已建成建筑都算宅基（见决定 2）。若产品要求只保护住宅，需要给建筑文档增加住宅标记并处理旧存档。
- **界面**：没有客户端按钮、提示或地籍面板展示；`world_client.gd` 未新增请求方法，只有既有 `territory` 通道能发 `blocking`。
- **地役权/协议通行**：`passable` 仍只有“已建成公共项目 + 公共/无主+ 本人”四种来源，没有租约、通行协议或组织决议产生的通行权。
- **性能**：每次查询重建整张视图（默认 6 块，上限 4096 块 / 65536 段边界）。真实大规模地籍未做基准。
- 只在本机 macOS 无头模式验证；未在 Windows、CI 或真实多人世界里验证本动作的线上答复。

## 增补：写入门禁（2026-11-16）

原“未覆盖”的第一条已补齐。权威在**首次**私有化地块时先判后写：

- `claim_territory()` 在规则接受且不是重放后调用同一份 `_blocking_answer()`；若
  这块地变私有会让某个已建成宅基失去到公共入口的通路（`newly_blocked` 非空），
  返回 `blocks_public_path`，不写 `territory.json`、不推进 `sequence`。
- `execute()` 的 BUILD 门禁在 ADR-028 归属判定之后、自动主张写盘之前做同一判
  定，并把即将建成的宅基（槽位 → 地块）一并纳入保护；拒绝发生在任何文件写入
  之前，返回同一个 `blocks_public_path`。
- 没有建成广场（`no_entrance`）或路由视图无法构建时放行：新世界必须先能建出
  第一个入口；这不是忽略错误，而是没有可判定的公共通路可取。
- `transfer` 不改匿名行路人的可通行性（地块在转让前后都是私有），`release` 只
  增加可通行性，因此都不需要门禁；已私有地块上的建造不改变地块通行性，也不经
  门禁。
- 重放安全：土地命令在 `duplicate` 分支提前返回，农场建造在命令执行器处重放，
  都到不了门禁，因此后来的易主不会改判已提交命令。

测试 `TERRITORY_BLOCKING_AUTHORITY_TEST` 从 99 增至 143 项，新增：无入口世界的
主张与首次建造仍成功（防止自锁）；`parcel_03` 私有化后主张唯一下排走廊被拒且
文件与 `sequence` 不变；在其上首次建造同样被拒且没有工地；同一批里不封路的
`yard_b` 仍提交并自动主张；已提交 claim 在拓扑变化后仍按 `duplicate` 重放；两条
中文文案都含“公共通路”。另补入口选择的分歧：只读路由视图仍取最小 id 的
广场入口并保留 `unknown_entrance` 诊断，写入门禁只从地籍真实存在的地块里选
入口；广场绑定到不存在的地块时门禁不会退化成 `no_entrance` 而放行全部主张。
回归 `TERRITORY_AUTHORITY_TEST 72/0`、
`TERRITORY_BUILD_GATE_TEST 79/0`、`TERRITORY_PATHS_TEST 86/0`、
`CHAIN_INTEGRATION_TEST 509/0`、`CHAIN_CONFLICT_INTEGRATION_TEST 512/0`、
`HEADLESS_WORLD_RUNTIME_TEST 83/0`、`FONT_COVERAGE_TEST 1272/0 missing=0`。

仍未覆盖：多入口、住宅与工坊区分、界面提示、Windows 与真实多人环境；`transfer`
的公共通路语义按当前匿名行路人模型处理，没有按具体玩家角色计算可达性。
