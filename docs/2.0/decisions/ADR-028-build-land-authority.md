# ADR-028 · 建造与拆除的地籍权限入口

- 状态：裁决完成并已实现（2026-11-15，含三项产品取舍拍板）；证据见文末。
- 关联：[ADR-023 地籍与建筑归属分离](ADR-023-land-cadastre.md)、[ADR-006 住宅首版](ADR-006-housing-slice.md)、[ADR-024 公共基金](ADR-024-public-funds.md)、[ADR-025 冲突参与](ADR-025-conflict-participation.md)、[RISKS R24](RISKS.md)、[M11 RECORD-02 地籍权威](../milestones/M11/RECORD-02-cadastre-authority.md)、[M13 RECORD-05 跨系统链路](../milestones/M13/RECORD-05-chain.md)。
- 范围：只决定建造/拆除如何查询并使用地籍权限；不改动 `Game/farm/*`、`Game/world/*` 的现有代码，不改变农场格式 27，不决定地籍的客户端入口、通行判定或公共项目。

> 行号取自 2026-11-15 当前工作树（HEAD `e327ccc`，`Game/world/world_host.gd` 仍有未提交的并行改动）。并行任务使行号可能继续偏移；复核时以函数名和提交后的实际文件为准。

## 背景

RISKS R24 记录：地籍权限未进入建造/拆除入口，`FarmState.build` 不查询 `may_build`，土地主张与建筑归属可互相矛盾。M13-01 链路记录已经确认：生产代码没有任何 `may_build`/`may_trespass` 调用，只有测试在查询权限；链路夹具因此没有执行建造命令，避免把“查询”当作“已强制”。

ADR-023 已经决定地籍与建筑分离：地籍只记录土地，`build` 只记录建筑，转让不搬房；并明确“土地权限进入建造命令入口的决定仍待完成”。M11 RECORD-02 完成了地籍 sidecar、权威加载/保存和成员 claim/transfer/release，但“建造/通行判定与客户端入口未接”。本 ADR 只补建造/拆除的这一半。

## 现状核验：链路与断点

### 1. 建造/拆除的权威链路

| 环节 | 位置（当前工作树） | 行为 |
|---|---|---|
| 客户端提交 | `Game/scenes/main.gd:723-737` | `_send_build`/`_send_demolish` 用 `FarmCommand.make_build/make_demolish` 生成命令并交给 `remote.submit`。宅基面板 `_open_homes`（`main.gd:705-711`）需要 `remote`；单机没有建造入口。 |
| 成员/身份门 | `Game/world/world_host.gd:499-579` | `execute_for_member` 从连接解析 `actor`；`BUILD`/`DEMOLISH` 与 `set_theft` 一起在 `:530-538` 只允许具名 member，访客 `forbidden`、匿名 `no_player`。 |
| 命令执行 | `Game/world/headless_world.gd:141-203` | 时间上下界在 `:150-156`；`commands.execute` 在 `:157`；新提交返回候选后在 `:171` 取候选，`settle_economy` 在 `:175`，`store.save_state(candidate, decorations)` 在 `:186`，成功后 `farm.accept(candidate)` 在 `:191`。 |
| 规则分派 | `Game/farm/farm_command.gd:94-99` | `BUILD` 调 `state.build(command.slot_id, command.blueprint, float(command.at_utc), actor)`；`DEMOLISH` 调 `state.demolish(...)`。 |
| 建筑规则 | `Game/farm/farm_state.gd:703-727` | `build` 只校验时间、玩家、槽位、蓝图与占用；成功后写入 `_data.buildings[slot_id] = {blueprint, owner, started_utc, done_utc}`（`:721-726`）。 |
| 拆除规则 | `Game/farm/farm_state.gd:730-744` | `demolish` 只校验时间、玩家、槽位、存在性与 `record.owner == actor`；没有建筑时 `empty`，非房主 `not_owner`。 |

这条链路里没有地籍文档、没有 `may_build`、没有地块 id。`HeadlessWorld` 已经加载并保存地籍（`:79-93`、`:405-408`），成员土地命令也已存在（`:422-461`、`world_host.gd:587-...`），但建造命令完全看不到它。

### 2. `may_build` / `may_trespass` 的现有语义

`Game/world/territory_state.gd:302-311` 与 `:317-326` 是纯查询：

| 地块状态 | `may_build` | `may_trespass` | 依据 |
|---|---|---|---|
| `claimed` | 仅 `owner == actor` | 仅 `owner == actor` | ADR-023 §3 |
| `public` | 任何合法玩家 | 任何合法玩家 | ADR-023 §3 |
| `unclaimed` | 拒绝 | 任何合法玩家 | ADR-023 §3 |
| 未知地块/非法 actor | 拒绝 | 拒绝 | 同上 |

`public`/`@world`/空串/非玩家 id 都不是合法 actor；`claimed` 的 `owner` 必须是合法玩家。`may_build`/`may_trespass` 不读 `FarmState`，也不读写磁盘。当前生产代码没有调用者；只有 `tests/chain_integration_test.gd:619-664` 与 `tests/territory_test.gd:195-222` 查询它们。

### 3. 断点

1. `FarmCommand._apply` 在 `Game/farm/farm_command.gd:94-99` 直接把 `slot_id` 交给 `FarmState.build/demolish`，没有地块参数，也没有可注入的地籍视图。
2. `HeadlessWorld.execute` 在 `Game/world/headless_world.gd:157-191` 只操作农场候选与农场存档，地籍文档在同一会话里存在但未被读取。
3. `FarmState.build` 的准入只回答“槽位空不空、蓝图存不存在”，不回答“这块地是不是你的、能不能建”；`demolish` 只回答“房主是不是你”。
4. `WorldHost.execute_for_member` 的权限门只回答成员/访客，不回答土地权利。
5. `HeadlessWorld.state_snapshot()`（`:502-510`）只含 `now_utc/farm/decorations/nature`，地籍不在快照里；这不影响本 ADR 的建造强制，但说明客户端目前拿不到地籍状态，接入客户端主张入口需要另案。

## 决定

### 1. 强制点：权威命令事务，而不是 `FarmState.build`

**决定：在 `HeadlessWorld.execute` 的建造事务里查询地籍；`FarmState.build` 继续是纯建筑规则，不 import 地籍。**

理由：

- `FarmState` 是建筑生命周期与存档形状的所有者，地籍是世界级土地文档；把 `TerritoryState` 塞进 `FarmState` 会让农场存档依赖 sidecar，违背 ADR-023 的分离，也会把地籍的加载/保存顺序带进规则层。
- 生产路径唯一：客户端 `main.gd` → `WorldHost.execute_for_member` → `HeadlessWorld.execute` → `FarmCommand.execute` → `FarmState.build`。单机没有建造入口（`main.gd:706-711` 要求 `remote`），所以不存在第二条生产路径。
- 直接 `FarmState.build` 的调用只出现在规则测试（如 `tests/building_test.gd`）。这些测试测的是“建筑规则本身”，不是“权威入口是否允许建造”。本 ADR 要求新增权威入口测试，并把“生产代码没有绕过 `HeadlessWorld.execute` 的建造调用”作为验收项，而不是在 `FarmState` 里复制一份地籍检查。
- 如果未来出现单机建造，它必须走同一权威入口（或显式决定单机不接入地籍），不能直接调用 `FarmState.build` 绕过。

具体位置：`HeadlessWorld.execute` 在 `commands.execute` 返回非重放候选之后、`store.save_state` 之前执行门禁。这样：

- 重放路径在 `headless_world.gd:160-170` 已经提前返回，不会因为后来土地易主而把已提交的建造重放判成 `not_parcel_owner`；
- `FarmState.build` 已有的 `invalid_time`、`invalid_player`、`invalid_slot`、`invalid_blueprint`、`occupied` 仍在门禁之前，保持现有原因优先级；
- 门禁失败时候选被丢弃，不落盘、不 `farm.accept`、不广播。

### 2. slot→parcel 的最小映射：固定矩形 + 序数约定

**决定：采用“固定矩形地块 + 槽位序数约定”，不新增持久化字段，不改 `territory.json` 形状。**

现有事实：

- `Game/farm/building_catalog.gd:8` 固定 `SLOTS = ["yard_a", "yard_b", "yard_c", "yard_d", "yard_e", "yard_f"]`，顺序是现有 UI/场景的显示顺序。
- `Game/world/territory_state.gd:82-102` 的 `default_state()` 按同一顺序生成 `parcel_01`…`parcel_06`，矩形为包含端点的 8×8 网格：

| 槽位 | 地块 | 固定矩形 `(min_x,min_z,max_x,max_z)` |
|---|---|---|
| `yard_a` / 甲号宅基 | `parcel_01` | `(0,0,7,7)` |
| `yard_b` / 乙号宅基 | `parcel_02` | `(8,0,15,7)` |
| `yard_c` / 丙号宅基 | `parcel_03` | `(16,0,23,7)` |
| `yard_d` / 丁号宅基 | `parcel_04` | `(0,8,7,15)` |
| `yard_e` / 戊号宅基 | `parcel_05` | `(8,8,15,15)` |
| `yard_f` / 己号宅基 | `parcel_06` | `(16,8,23,15)` |

最小映射：`SLOTS[i] ↔ parcel_%02d(i+1)`。实现上增加一个纯函数，例如 `TerritoryState.slot_parcel_id(slot_id)`，由 `BuildingCatalog.SLOTS.find(slot_id)` 得到序号；未知槽位返回空串（`FarmState` 会先返回 `invalid_slot`），目标地块不存在则门禁返回 `slot_unmapped`。`TerritoryState` 只 preload 纯数据目录 `BuildingCatalog`，不读 `FarmState`。

为什么按 `slot_id` 而不是按矩形做点在多边形内：

- 建造命令只有 `slot_id`，没有坐标；用坐标会把“能否建造”取决于尚未接通的 3D 布局、浮点取整和未来地图编辑，结果不可复现。
- 矩形仍是地块的空间范围，供未来的 claim/transfer、通行、租赁和公共通路使用；当前它只作为固定占位数据存在。
- 序数约定是现有两个固定目录之间的确定性契约；不是隐藏的第二份槽位表。

为什么不持久化“slot_id → parcel_id”字段：

- 当前没有创建/编辑地块的命令，地块集合固定为 `default_state` 的六块；序数约定足以确定。
- 持久化字段会改 `PARCEL_KEYS`（`territory_state.gd:59`）或 `STATE_KEYS`（`:58`），把 `TerritoryStore.VERSION` 从 1 升到 2，旧 `territory.json` 会以 `unsupported` 被拒绝（`territory_store.gd:47-48`）。当前早期开发虽不承诺旧存档兼容，但这不是本切片必须支付的成本。
- 触发升级的条件见“复审触发条件”：需要自定义地块、动态创建地块、用途/租赁/组织土地或改变槽位集合时，再持久化映射。

### 3. 拒绝语义

门禁返回稳定的机器原因；`WorldHost` 只负责映射中文文案，规则层不拼文案。

| 场景 | 判据 | 结果 | 机器原因 | 中文文案 |
|---|---|---|---|---|
| 地块属于 actor | `status=claimed` 且 `owner=actor` | 允许 | `""` | — |
| 地块属于他人 | `status=claimed` 且 `owner!=actor` | 拒绝 | `not_parcel_owner` | 这块地不属于你，不能在这里建造。 |
| 公共地块 | `status=public` | 允许（ADR-023 现有语义） | `""` | — |
| 未主张地块 | `status=unclaimed` | 允许，同一事务把该地块主张给 actor | `""` | — |
| 槽位没有对应地块 | 映射目标不存在 | 拒绝 | `slot_unmapped` | 这个宅基还没有对应地块，暂时不能建造。 |
| 地籍未载入 | `territory` 为空/未打开 | 拒绝 | `land_unavailable` | 地籍尚未载入，暂时不能建造。 |
| 地籍在事务中变化 | 提交前 `sequence` 不一致 | 拒绝 | `stale_land` | 土地状态已变化，请重试。 |
| 未知槽位 | `slot_id not in Buildings.SLOTS` | 拒绝（农场原有） | `invalid_slot` | 宅基编号无效。 |
| 非法 actor | 空串/非法玩家 id | 拒绝（农场原有） | `invalid_player` | 玩家身份无效。 |

补充说明：

- **公共地块当前不拒绝。** `may_build` 对 `public` 返回 true（`territory_state.gd:309-310`），这是 ADR-023 已记录的语义；当前没有任何命令会生成 `public` 地块，所以这条路径实际休眠。若产品要求“公共土地不得建私人房屋”，必须新增 `public_build_forbidden` 并修改 ADR-023 的公开表，不在本 ADR 偷偷改。见开放问题 2。
- **未主张地块采用“首次建造即主张”。** 当前没有任何客户端/网络主张入口，严格拒绝会让全新共享世界的六个宅基全部不可建，等于删掉现有的建房流程。因此建造未主张地块时，在同一权威事务内先为该 actor 写入主张，再提交农场；业主与房主从第一条命令起就一致。地块已主张给他人时仍拒绝（`not_parcel_owner`）。主张命令本身仍可由既有 `claim_territory` 单独完成，两条路径幂等。
- **`occupied` 优先于土地原因。** 因为门禁在 `FarmState.build` 之后执行，槽位已有建筑时返回 `occupied`，不会因为地块不是你的而改判 `not_parcel_owner`。这与现有测试 `tests/building_test.gd:124-140` 一致，也避免通过地籍原因泄露“这个槽位是否有人建”。
- `WorldHost._reason_text`（`world_host.gd:1144`）需要新增上述文案；其中 `not_owner` 目前映射为“只能操作自己的订单。”，对拆除是误导，应在同一实现中为 `BUILD`/`DEMOLISH` 的回复改用建筑专用文案（“只有房主能拆除这座建筑。”）或给 `not_owner` 增加按 kind 的上下文映射。

### 4. 拆除：房主优先，不增加地块门禁

**决定：`demolish` 继续只允许建筑 `owner` 拆除，不查询地块状态；地块权利人不能拆除他人的建筑。**

| 场景 | 结果 | 原因 |
|---|---|---|
| 槽位为空/未知槽位 | 拒绝 | `empty` / `invalid_slot`（现有） |
| actor 是建筑 owner | 允许，无论地块是 claimed/public/unclaimed、无论地块 owner 是谁 | 拆除的是 actor 自己的财产 |
| actor 不是建筑 owner，但他是地块 owner | 拒绝 | `not_owner`；地块权利人不能单方面毁坏他人建筑 |
| actor 既不是建筑 owner 也不是地块 owner | 拒绝 | `not_owner` |

理由：

- 拆除不产生新建筑，也不创建新的土地主张；它只会减少“建筑在别人地上”的存量矛盾，允许房主清理自己的房屋。
- 如果要求地块 owner 同意才能拆，土地转让会把房主的建筑锁死：ADR-023 明确转让不搬房，房主可能既不能用也不能拆。
- 地块 owner 对“不想要的外来建筑”的救济属于租赁/治理/冲突规则（ADR-025 方向），不是私人建造入口的权限。
- 这条规则还允许清理历史遗留的错配建筑（强制执行前已经建在未主张/他人地块上的房子），不需要一次性迁移。

### 5. 竞态与候选快照：校验、提交、失败不落盘

当前竞态事实：

- `HeadlessWorld.execute`（`headless_world.gd:141-203`）没有 `await`/`yield`，RPC 回调在主线程串行执行；两个成员对同一 `slot_id` 的提交不会交错到同一次 `execute` 中间。
- `FarmCommand.execute`（`farm_command.gd:62-74`）从当前农场 state 复制候选，`FarmState.build` 在候选上检查 `_data.buildings.has(slot_id)`；第二条命令看到 `occupied`，不会产生候选。`tests/building_test.gd:143-156` 已在规则层证明“串行化后只有第一条生效”。
- 地籍的 `claim_territory`/`transfer_territory`/`release_territory` 也在同一主线程串行执行（`headless_world.gd:422-461`）；建造与土地命令之间只有调用顺序，没有真正的并行写入。

新校验的合并路径：

1. `HeadlessWorld.execute` 进入时捕获一次 `land_view = territory.duplicate(true)` 与 `land_sequence = int(territory.get("sequence", 0))`。这是本次事务唯一的地籍快照。
2. `commands.execute` 正常生成农场候选；如果是重放（`execution.duplicate` 或 `execution.candidate == null`），直接走现有重放返回，不执行门禁。
3. 对新 `BUILD` 候选，用同一次捕获的 `land_view` 调 `TerritoryState` 的门禁（槽位映射 + `may_build`）。失败：返回具名原因，丢弃候选；`store.save_state` 不会被调用，`farm.accept` 不会执行，`territory_store.save_state` 也不会被调用。
4. 门禁通过后，在 `store.save_state(candidate, decorations)` 之前再次比较 `int(territory.get("sequence", 0)) == land_sequence`；不一致返回 `stale_land`，不落盘、不 `accept`。这条检查在当前单线程实现中不会触发，是为未来引入异步/回调/分片时保留的事务不变量。
5. 门禁放行后，若目标地块未主张，先把隐式主张写入地籍候选并落盘（`territory_store.save_state`），再写农场。两份文件无法原子提交，顺序按“孤儿主张无害、孤儿建筑有害”选择：地籍写失败则整条命令拒绝、农场完全不变；农场写失败则主张保留，玩家重试同一条命令即可继续建房，不会留下“房子在别人地上”。
6. 农场保存成功后才 `farm.accept(candidate)`，地籍候选在保存成功后替换 `territory`。`DEMOLISH` 不跑地籍门禁；仍走现有候选/保存/`accept` 路径，失败同样不落盘。

“同一候选快照”的定义：本次命令的事务快照是 `(land_view, farm candidate, 至多一条隐式主张)`；`land_view` 在入口捕获一次、门禁只读它，`farm candidate` 由 `FarmCommand` 生成并由 `store.save_state` 持久化，隐式主张来自同一份 `land_view` 且是唯一的地籍写入。

失败不落盘的边界：

- 门禁失败：只返回拒绝，候选对象没有进入权威；农场与地籍文件都不变。
- 隐式主张落盘失败：返回 `save_land_*` 的具名原因，农场候选丢弃、农场文件不变；主张命令 id 不进入农场命令窗口，重试可以成功。
- 隐式主张已落盘而农场保存失败：地籍保留该主张（事实正确、可重试），农场不变；这是唯一允许的半提交，方向和后果都在上文说明。
- `store.save_state` 失败：现有路径在 `headless_world.gd:186-190` 返回 `save_*`，不 `accept`；地籍未动。
- `land_sequence` 不一致：在保存前返回；同样不 `accept`。
- 命令 id 不因门禁失败进入农场命令窗口；玩家主张地块后用同一 id 重试可以成功（这是期望行为，不是重放）。

### 6. 不改变农场格式 27

本 ADR 的实现不新增任何农场字段：

- 不改 `FarmStore.VERSION = 27`（`farm_store.gd:6`）与 `{"version": 27, "farm": ..., "decorations": ...}` 文档形状（`:114`）。
- 不改 `FarmState._data` 的顶层键，不改 `buildings` 记录的四字段 `{blueprint, owner, started_utc, done_utc}`；`_valid_buildings`（`farm_state.gd:1512-1529`）与 `_valid_snapshot` 的键数（`:1392-1404`）保持原样。
- 不改 `V27Importer.KNOWN_FARM_KEYS`（`Game/farm/v27_importer.gd:28`）。
- 不改 `territory.json` 形状与 `TerritoryStore.VERSION = 1`（`territory_store.gd:15`）；槽位映射是代码约定，不是新字段。地籍文档仍在首次土地命令时按现有原子写落盘（`headless_world.gd:405-408`、`:453-461`）。
- `HeadlessWorld.state_snapshot()` 不增加 `territory`；本 ADR 不把地籍放进农场快照，也不改网络摘要。

因此“农场格式 27”约束通过“把权限状态留在世界地籍、把映射留在代码常量、把建筑记录保持四字段”满足。

### 7. 已知残留

1. **转让后的错配不会因本门禁消失。** A 在自有地块建房后把地块转给 B，建筑 owner 仍是 A、地块 owner 是 B（ADR-023 明确转让不搬房）。本 ADR 只保证“新建时”actor 对地块有建造权；转让后的错配是治理/租赁/更正事件问题。R24 的关闭证据应写成“建造/拆除入口已按地块校验；转让造成的存量错配单列”，不能声称转让也会被强制一致。
2. **历史建筑不迁移。** 强制执行前已经建在未主张或他人地块上的建筑保持原样；房主可拆、不能在不属于自己的地块上重建（`parcel_unclaimed`/`not_parcel_owner`）。不自动替历史建筑补主张，避免在读档时写地籍或猜测权利人。
3. **公共地块的私人建造仍开放。** 见 §3 与开放问题 2；当前没有 `public` 地块生成路径，所以是休眠缺口。
4. **通行判定未接。** `may_trespass` 仍无生产调用者；没有移动/入口权威，不能用它来限制建造。建造门禁只回答“能不能建”，不回答“能不能进”。
5. **客户端仍没有独立主张/转让/释放入口。** 这不阻塞建房：按“首次建造即主张”，未主张宅基照常建造并自动归属。面板只展示归属（§8）；主张、转让与释放仍只能经 `WorldHost.territory_for_member()` 的命令入口发起。

### 8. 地籍可见性（2026-11-15 增补）

权威强制建造门禁后，客户端若看不到归属，就会在别人的地上点“建造”才收到拒绝——这是本次实现引入的可用性缺口。最小补法是只读展示，不新增命令：

1. **摘要携带公开地籍。** `HeadlessWorld.summary()` 增加 `territory`：`{sequence, parcels:[{id, slot, owner, status, claimed_utc, rect}]}`，来源是新的 `territory_display()`；`slot` 由 `TerritoryState.parcel_slot_id()` 反查，客户端因此不需要复制 slot↔parcel 映射。`claim_id` 是内部命令 id，不进入显示文档。
2. **投影白名单。** `WorldProjection._project_territory()` 只放行上述字段，`claim_id` 即使将来重新出现在 `summary()` 也不会过线（ADR-027 §3.2）。
3. **提交后广播。** 首次建造的隐式主张是其他成员无法从命令载荷重建的共享状态变化，因此 `HeadlessWorld` 的变更信号由 `economy_changed` 更名为 `shared_changed`，在经济变化之外也在 `land_claimed` 时发出；`WorldHost` 仍把它接到同一条“按收件人投影的摘要广播”。客户端不本地回放地籍，30 秒 reconcile 只是兜底。
4. **面板只显示，不裁决。** `main.gd::_parcel_views()` 把摘要按槽位映射为“无主（首次建造即归你）/这是你的宅基/宅基属于 <名册显示名>/公共宅基”，并对他人地块给出禁用理由；`build_panel` 在空槽下增加一行地籍说明，他人地块的建造按钮禁用。权威仍是唯一裁决点，面板不因摘要陈旧而改变命令语义。
5. **格式不动。** 农场仍格式 27，`territory.json` 仍 v1，`PROTOCOL_VERSION` 仍 1；新增字段只出现在线上摘要，不进存档。

## 方案对比

| | A：固定矩形 + 序数映射（采纳） | B：在 `territory.json` 持久化 slot→parcel | C：建房时把槽位位置登记为地块 |
|---|---|---|---|
| 映射归属 | `BuildingCatalog.SLOTS` 顺序 + `TerritoryState.default_state` 固定地块；代码契约 | 世界文档（`parcel.slot_id` 或顶层 `build_slots`） | 建造事件创建/占用地块，地块随建筑出现 |
| 文件形状 | 无变化；`territory.json` v1、键集不变 | `PARCEL_KEYS`/`STATE_KEYS` 变化，`TerritoryStore.VERSION` 1→2 | `territory.json` 首次建造时新增地块；仍可能改形状 |
| 旧存档影响 | 无格式影响；行为变化是未主张地块不能再建 | 旧 v1 文档 `load_territory_unsupported`，权威拒绝启动；无迁移器 | 旧世界首次建造写土地；历史建筑仍需另行对账 |
| 写入原子性 | 建造只读地籍，只有农场一次保存 | 同 A | 需要地籍+农场两文件提交与失败回滚，或接受半提交 |
| 同一槽位竞态 | 单线程 + `occupied` 已足够；门禁不增加第二决策点 | 同 A | 首个建造隐式主张；并发下仍需两文件一致性 |
| 无主张时能否建房 | 不能（`parcel_unclaimed`） | 不能 | 能（首个建造成为主张） |
| 与 ADR-023 一致性 | 一致：先主张后建造 | 一致 | 需要修改 ADR-023 的 `unclaimed` 表；理由从“先建先得不可审计”变为“建造即登记” |
| 结论 | **采纳**：当前最小、无格式变化、可独立测试 | 保留为自定义地块/租赁/用途到来时的升级路径 | 不采纳：与 ADR-023 冲突，且引入两文件提交 |

## 实施顺序与改动文件

只列建议实现，不在本 ADR 中修改代码。

1. `Game/world/territory_state.gd`
   - preload 纯数据 `res://farm/building_catalog.gd`（不 import `FarmState`）；
   - 新增 `slot_parcel_id(slot_id: String) -> String`（序数映射，未知/越界返回 `""`）；
   - 新增 `build_gate(state: Dictionary, slot_id: String, actor: Variant) -> Dictionary`，返回 `{ok, reason, parcel_id}`；复用 `may_build` 的语义，但区分 `not_parcel_owner`/`parcel_unclaimed`/`slot_unmapped`/`land_unavailable`/`invalid_player`；
   - 不修改 `STATE_KEYS`、`PARCEL_KEYS`、`valid()`、`default_state()` 的文档形状。
2. `Game/world/headless_world.gd`
   - `execute` 入口捕获 `land_view` 与 `land_sequence`；
   - 在 `commands.execute` 的非重放候选之后、`settle_economy`/`store.save_state` 之前，对 `BUILD` 调 `build_gate`；失败返回 `_result(false, reason, false, command.id)`；
   - 在 `store.save_state` 前检查 `territory.sequence` 未变，否则返回 `stale_land`；
   - `DEMOLISH` 不加地籍门禁；建造/拆除都不写 `territory_store`。
3. `Game/world/world_host.gd`
   - `_reason_text` 增加 `not_parcel_owner`、`parcel_unclaimed`、`slot_unmapped`、`land_unavailable`、`stale_land` 的中文文案；
   - 修正 `BUILD`/`DEMOLISH` 的 `not_owner` 文案（建筑语境不要落到“只能操作自己的订单。”）；
   - 角色/身份门保持不变：visitor 仍在 `execute_for_member:530-538` 被 `forbidden`，匿名 `no_player`。
4. 测试（优先扩展现有夹具，不新增测试框架）
   - `tests/territory_test.gd`：映射覆盖六个槽位、一对一、目标地块存在、矩形不重叠；`build_gate` 的 claimed/public/unclaimed/缺失/非法 actor 分支。
   - `tests/territory_authority_test.gd`：通过 `WorldHost.execute_for_member` 执行真实建造；失败不落盘；重放跨土地转让仍 `duplicate`；同槽位两成员只有第一条成功。
   - `tests/chain_integration_test.gd`：更新头部“未覆盖建造强制”的注释；在 phase 8 对 A 主张后的 `parcel_01` 执行一次真实建造，断言建筑 owner、地籍不变、B 在 A 地块建房被 `not_parcel_owner`；失败不改变农场/地籍。
   - `tests/building_test.gd`：预期不改；它测纯建筑规则与规则层串行化。若实现把门禁放进 `FarmCommand` 而不是 `HeadlessWorld`，这个测试需要构造地籍夹具，届时再评估。
5. 文档（实现后，不在本 ADR 中执行）
   - `RISKS.md` R24：写入关闭证据；若接受转让错配为独立缺口，措辞写成“建造/拆除入口已校验，转让造成的存量错配另列”；
   - ADR-023 的“未接线部分”、M11 RECORD-02 的“未覆盖”、M13 RECORD-05 的“问题 1”同步更新；
   - 若客户端仍无主张入口，`docs/2.0/release/player-guide.md` 的宅基段落必须说明“未主张地块不能建造”，否则指南与权威行为不一致。

## 验收标准与测试计划

以下断言在无窗口 headless 中可以执行；具体 `checks` 数在实现后记录，不在本 ADR 编造。

### 1. 映射与规则

- `Buildings.SLOTS.size() == 6`；`slot_parcel_id(SLOTS[i]) == "parcel_%02d" % (i+1)`；六个目标都在 `default_state` 中；六个矩形两两不重叠；映射一对一。
- `build_gate`：claimed owner → `ok`；claimed other → `not_parcel_owner`；public → `ok`；unclaimed → `parcel_unclaimed`；目标缺失 → `slot_unmapped`；空文档 → `land_unavailable`；非法 actor → `invalid_player`；未知槽位不进入门禁（农场 `invalid_slot`）。

### 2. 权威入口与失败不落盘

- A 先 claim `parcel_01`，再通过 `WorldHost.execute_for_member` 建造 `yard_a`：`ok=true`，建筑 owner=A，`territory_view()` 的地块 owner/status/`claim_id`/`sequence` 不变，`farm.json` 与 `territory.json` 的文档键集不变。
- B 在 A 的 `parcel_01` 上建造 `yard_a`（先清空槽位或用另一槽位映射同一地块的夹具）：若槽位被占，返回 `occupied`；若空，返回 `not_parcel_owner`。两种情况下农场快照、地籍视图、两份文件字节都不变。
- 在未主张的 `parcel_02` 上建造 `yard_b`：`parcel_unclaimed`，无写入。
- 通过手动构造/夹具把 `parcel_03` 设为 `public`：建造 `yard_c` 成功，地籍不变（休眠路径）。
- 地籍未载入（空 `territory`）：`land_unavailable`，无写入。

### 3. 重放与竞态

- 已提交的 build id：在土地被 claim/transfer 之后再提交同一 id，返回 `duplicate=true`，不重新门禁、不产生第二栋建筑。
- 同一 `slot_id` 两个成员先后提交：第一条成功，第二条 `occupied`；只有一条建筑记录；地籍不变。
- 土地命令与建造命令按任意顺序串行：先 claim 后 build 成功；先 build 后 claim 时 build 得 `parcel_unclaimed`，claim 仍成功。

### 4. 拆除

- 建筑 owner 拆除成功，无论地块是 claimed（本人/他人）、public、unclaimed；地籍不变。
- 地块 owner 不是建筑 owner 时拆除返回 `not_owner`，建筑与地籍不变。
- 历史建筑（未主张地块上）的 owner 可以拆除；拆除后不能在不属于自己的地块上重建（`parcel_unclaimed`）。
- `empty`/`invalid_slot`/`invalid_player`/`invalid_time` 保持现有原因。

### 5. 格式约束

- `FarmStore.VERSION == 27`；`FarmState.snapshot()` 的键集与实现前一致；`buildings` 行仍是四字段；`FarmStore` 写出的 JSON 仍是 `{version, farm, decorations}`。
- `TerritoryStore.VERSION == 1`；`TerritoryState.STATE_KEYS`/`PARCEL_KEYS` 未变；`territory.json` 仍是 `{version:1, state}`。
- `V27Importer.KNOWN_FARM_KEYS` 未变；`HeadlessWorld.state_snapshot()` 未增加 `territory`。

### 6. 回归运行

按影响面运行，不因完整测试集存在就全部执行：

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/territory_test.gd"
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/territory_authority_test.gd"
perl -e 'alarm shift; exec @ARGV' 420 "$GODOT" --headless --path Game \
  --script "$PWD/tests/chain_integration_test.gd"
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/building_test.gd"
```

`HeadlessWorld.execute` 是共享入口，若实现改动该函数的控制流，再补跑 `tests/m4_sync_test.gd` 与 `tests/m4_client_scene_test.gd` 作为命令通道回归；经济/社交命令不走 `BUILD` 分支，不应改变其行为。

## 未验证

- 本 ADR 未实现、未运行任何测试；上述验收项是计划，不是证据。
- 行号来自当前工作树；`world_host.gd` 有并行未提交修改，提交后行号可能变化。
- “RPC 回调在主线程串行、`execute` 无 `await`”来自对当前函数的静态阅读；没有做多线程/压力实测。
- `land_sequence` 守卫在当前单线程下无法自然触发；没有测试 seam 证明它在异步交错时生效，只有代码路径设计。
- 没有真实网络客户端、UI、Windows 或 CI 验证；没有验证 claim 入口缺失时的完整玩家流程（因为该入口尚不存在）。
- 没有验证 `public` 地块的真实生成路径（当前没有生成命令）。
- 没有验证转让、租赁、组织土地、公共项目或冲突（ADR-025）下的建造权限；这些是本 ADR 的复审触发条件。
- 没有量化“一栋建筑一次地籍查询 + 一次字典复制”的性能影响；预计相对存档 JSON 序列化可忽略，但未计时。

## 复审触发条件

出现以下任一情况时重开本裁决：

- 增加客户端/网络的地籍主张入口，或决定“首个建造隐式主张”；
- 开始生成 `public` 地块、公共项目（ADR-024）或组织土地；
- 引入租赁、用途、地役权、公共通路连通性或土地转让时的建筑处置规则；
- `Buildings.SLOTS` 增加、删除或重排，或地块集合不再固定为六块；
- 需要按坐标/矩形而不是 `slot_id` 判断建造位置；
- 引入地块动态创建、地块合并/拆分，或 `TerritoryStore.VERSION` 需要升级；
- 权威入口引入 `await`、线程、分片或异步保存，使 `land_sequence` 守卫需要重新设计；
- 农场格式 27 被替代，或地籍被要求进入农场快照/网络摘要；
- ADR-025 的冲突/占领规则要求在他人 claimed 地块上建造或拆除。

## 拍板结果（2026-11-15）

1. **主张入口：采用“首次建造即主张”。** 不新增主张 RPC 或面板入口；未主张宅基上建房时，在同一事务里先把地块主张给 actor（上文 §3、§5）。理由是最小完整方案：现有建房流程继续可用，业主与房主从第一条命令起一致，且不需要新增网络契约或 UI。独立主张命令（`claim_territory`）保留给后续地籍入口。
2. **公共地块：保持 ADR-023 语义，允许建造。** 不新增 `public_build_forbidden`；当前没有生成 `public` 地块的命令，这条路径休眠。若将来引入公共项目或租赁再重开。
3. **转让造成的“地主≠房主”：按治理缺口接受。** 本 ADR 只保证新建时一致；ADR-023 的“转让不搬房”不变。R24 关闭时必须把这条残留写进风险措辞，不能声称地籍与建筑永远一致。

## 实现证据（2026-11-15）

实现位置：

- `Game/world/territory_state.gd`：`slot_parcel_id()`（`Buildings.SLOTS[i]` ↔ `parcel_%02d(i+1)`）与 `build_gate(state, slot_id, actor)`；返回 `{ok, reason, parcel_id, claim}`，未主张地块返回 `claim=true`。
- `Game/world/headless_world.gd::execute()`：新 `BUILD` 在入口捕获一次 `land_view`/`land_sequence`，农场候选生成后过门禁，未主张地块先写地籍主张（`territory_store.save_state`）再写农场；`DEMOLISH` 与经济/社交路径不变。`world_host.gd` 补齐中文文案，拆除的 `not_owner` 单独显示“只有房主能拆除这座建筑。”。
- `tests/territory_build_gate_test.gd`（新增）：映射、自己地块、他人地块（两份文件字节不变）、未主张隐式主张与重开保持、公共地块、缺失映射、地籍未载入、重放、同槽位 `occupied`，以及**小数时钟**下的隐式主张落盘与重载。

实测（macOS `4.7.2.stable`，`--headless`）：

| 测试 | 末行 |
|---|---|
| `territory_build_gate_test` | `TERRITORY_BUILD_GATE_TEST checks=79 failures=0` |
| `territory_test` | `TERRITORY_TEST checks=159 failures=0` |
| `territory_authority_test` | `TERRITORY_AUTHORITY_TEST checks=69 failures=0` |
| `building_test` | `BUILDING_TEST checks=149 failures=0` |
| `chain_integration_test` | `CHAIN_INTEGRATION_TEST checks=509 failures=0` |
| `m4_join_test` / `m4_reconnect_test` | `M4_JOIN_TEST 56/0`、`M4_RECONNECT_TEST 31/0`（三次连续通过） |
| `m4_sync_test` / `m4_client_scene_test` | `M4_SYNC_TEST 39/0`、`M4_CLIENT_SCENE_TEST 39/0` |

实现中发现并修复一个既有缺陷：地籍把土地动作时间写进命令载荷，JSON 十进制往返会让带亚秒小数的时钟差出最低位，`valid()` 的精确比较随即把合法主张判为 `invalid_state`（`m4_reconnect_test` 的建造因此失败，而整数时钟的夹具一直遮住它）。现在 `claimed_utc` 与载荷时间按 1 ms 容差比较（`LAND_TIME_TOLERANCE`），并由上面“小数时钟”用例固定。

未覆盖：`stale_land`（单线程下无法自然触发）、隐式主张保存失败与“农场保存失败保留主张”的半提交路径（未构造写失败夹具）、`claim_command_conflict` 防御分支；未在 Windows、真实 WSS 多成员会话或客户端 UI 上验证建造与地籍提示。

### 地籍可见性增补（2026-11-15）

实现位置：

- `Game/world/headless_world.gd`：`territory_display()`（按槽位、去掉 `claim_id`）进入 `summary()["territory"]`；信号 `economy_changed` → `shared_changed`，隐式主张成功后随经济变化一起触发摘要广播。
- `Game/world/territory_state.gd`：`parcel_slot_id()` 反查；`Game/world/world_projection.gd`：`_project_territory()` 白名单；`Game/world/world_host.gd`：订阅改名后的信号。
- `Game/scenes/main.gd::_parcel_views()` 与 `Game/ui/build_panel.gd`：归属文案、他人地块禁用建造；`present()` 增加可选 `next_parcels`。

实测（macOS `4.7.2.stable`，`--headless`）：

| 测试 | 末行 |
|---|---|
| `world_projection_test` | `WORLD_PROJECTION_TEST checks=172 failures=0`（新增地籍公开、`claim_id` 不下发） |
| `build_panel_test` | `BUILD_PANEL_TEST checks=33 failures=0`（无主/他人/自己/无地籍四态） |
| `m4_client_scene_test` | `M4_CLIENT_SCENE_TEST checks=42 failures=0`（真实权威首次建造后，本人的摘要把 slot 标为“这是你的宅基”，未动槽位仍可建） |
| `territory_build_gate_test` | `TERRITORY_BUILD_GATE_TEST checks=79 failures=0` |
| `m4_reconnect_test` | `M4_RECONNECT_TEST checks=31 failures=0` |
| `chain_integration_test` | `CHAIN_INTEGRATION_TEST checks=509 failures=0` |
| `world_payload_test` / `world_rate_limit_test` | `67/0`、`21/0` |

未覆盖：多成员同时打开宅基面板时的实时刷新（只验证了提交后摘要送达）、Windows、双显示器实机；主张/转让/释放仍无客户端入口。

