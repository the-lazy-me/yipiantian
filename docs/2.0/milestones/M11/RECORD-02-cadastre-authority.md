# M11-02 · 地籍接入世界权威

执行日期：2026-11-15。状态：切片完成，不表示 M11-02 或 M11 验收完成。前置：[M11-01 地籍切片](RECORD-01-cadastre.md)、[ADR-023 · 地籍与建筑归属分离](../../decisions/ADR-023-land-cadastre.md)。

> 本记录沿用任务分配中的 M11-02 编号，范围是“把不重叠地籍规则接进世界权威”。[M11 PLAN](PLAN.md) 中 M11-02 的“建立组织”不在本记录范围内。

## 问题

M11-01 只完成了纯地籍规则：`TerritoryState` 能校验不重叠地块、执行 claim/transfer/release，并给出 `may_build`/`may_trespass`，但没有任何权威加载、持久化或成员命令入口。ADR-023 明确要求接线切片先决定三件事：地籍文档放在哪里、世界初始地块如何生成、土地权限如何进入命令入口。本切片决定前两件并接上成员命令；第三件（建造/通行判定）仍未接入。

## 边界与决定

### 1. 地籍是独立 sidecar，不进入 v27 农场文档

新增 `Game/world/territory_store.gd` 与 `territory.json`（`territory.pending.json` 为暂存文件）：

```text
{ "version": 1, "state": territory }
```

`territory` 的形状沿用 M11-01：

```text
{ world_id, sequence, parcels: { parcel_id: parcel }, command_results }
```

- 沿用 `nature_store` / `social_store` 的原子写：写 pending、回读比对、`rename` 替换主文件；读回先跑 `TerritoryState.valid()`，再 `normalize()` 还原 JSON 数字类型。
- 没有新增农场顶层键，没有改 `FarmStore.VERSION`、`V27Importer.KNOWN_FARM_KEYS` 或任何 v27 存档键。接入点不需要修改农场存档格式。
- 已有但损坏、版本不支持或属于另一个世界的地籍文档会让权威拒绝启动，而不是被默认布局覆盖；这避免静默丢掉土地记录。

### 2. 权威加载与保存由 `HeadlessWorld` 承担

- `HeadlessWorld.open(save_directory, now_utc, world_identity = "")` 在打开农场/自然文档后加载地籍。
- 传入显式 `world_identity` 时必须与文档的 `world_id` 一致，否则返回 `territory_world_mismatch`。
- 未传身份时采用文档已有的 `world_id`；全新目录使用 `"world"`。这让旧的 headless 调用方（测试、单机会话）无需知道世界 id，也不会因世界 id 不同而无法重开。
- 每个被接受的 land 命令先写候选文档，写成功后才替换内存中的权威文档；失败或重放不写文件。
- `HeadlessWorld.save()` 只在文档已加载或已修改时重写地籍。未被触碰的默认布局是确定性的，不必落盘。
- `WorldHost.configure()` 把自己的 `world_identity` 传给 `HeadlessWorld.open()`，因此共享世界的成员命令和重启读取同一份地籍。

### 3. 默认地籍：六个不重叠的 8×8 地块

`TerritoryState.default_state(world_id)` 生成 3×2 网格的 `parcel_01`…`parcel_06`，坐标为 `0..7`、`8..15`、`16..23`（包含端点，相邻不算重叠）。

这是接线用的确定性占位：现有农场世界没有把地图坐标接到地籍矩形，先给权威一组可主张的土地，才能验证命令、持久化和重启不变量。真实地图、用途和公共地块的产生方式仍未定义。

### 4. 成员命令通过连接身份执行

`WorldHost.territory_for_member(peer_id, action, args)` 是权威命令入口：

- `actor` 只取连接加入时的 `player_id`，请求体不能自带 owner/from；claim 的 owner、transfer 的 from、release 的 actor 都由连接决定。
- 读：`action = "state"` 对所有在册成员开放，包括 visitor 和没有玩家 id 的匿名成员；返回权威地籍的深拷贝。
- 写：只有 `member` 角色可以 claim/transfer/release；visitor 返回 `forbidden`，占位匿名成员返回 `no_player`，迁移中的权威返回 `read_only`。因此“访客只读”由角色门而不是 UI 保证。
- 未在册连接返回 `not_a_member`；未知 action 返回 `unknown_action`。
- 失败原因直接使用纯规则的稳定字符串：`unknown_parcel`、`already_claimed`、`already_public`、`not_owner`、`not_owned`、`same_owner`、`command_conflict`、`invalid_command`、`invalid_owner`、`invalid_time`、`time_regression`、`overlapping_parcels`、`wrong_world`、`invalid_state`。文字说明由地籍专用映射提供，不改变现有经济命令的订单文案。

### 5. 土地时间与幂等回放

- 新命令使用权威世界时钟 `HeadlessWorld.now_utc` 打戳，不信任客户端时间。
- 若命令 id 已在文档中出现，`TerritoryState.recorded_time()` 从地块的 `claim_id`/`claimed_utc`（claim/transfer）或有界命令窗口的 payload（release）取回原始时间。重试因此复用原时间，重启后即使权威时钟更晚也返回 `duplicate`，不会变成 `command_conflict`。
- claim/transfer 的 `claim_id` 是耐久守卫，命令窗口淘汰后仍能识别重放；release 清除 `claim_id`，所以窗口外的 release 重放仍不保证幂等（沿用 M11-01 的已知限制）。
- 地块矩形的不重叠由 `TerritoryState.valid()` 在每次加载和 `claim()` 时检查；重启加载后仍拒绝重叠文档。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/world/territory_state.gd` | 增加 `default_state()` 与 `recorded_time()`；规则本身未改 |
| `Game/world/territory_store.gd` | 新增带版本 sidecar 存储，原子写/校验/损坏拒绝 |
| `Game/world/headless_world.gd` | 加载/保存地籍；claim/transfer/release 命令适配；权威时钟与回放时间 |
| `Game/world/world_host.gd` | 传入世界 id；连接身份与角色门；`territory_for_member()` 与地籍失败文案 |
| `tests/territory_authority_test.gd` | 新增接入夹具 |

未修改 `Game/farm/*`、`main.gd`、`.github/workflows`、`rules/project-context.md`，也未修改 v27 农场存档。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/territory_test.gd"
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/territory_authority_test.gd"
```

原始末行：

```text
TERRITORY_TEST checks=159 failures=0
TERRITORY_AUTHORITY_TEST checks=69 failures=0
```

`territory_authority_test.gd` 覆盖：

| 用例 | 检查 |
|---|---|
| 存储 | 默认地籍有效且六块不重叠；缺失文档返回确定性默认；合法文档原子写入并原样重载；非法候选在落盘前拒绝；未知命令没有记录时间 |
| 身份 | 成员以加入时的 `player_id` 主张，请求体伪造 owner 无效；匿名成员拒绝写；不在册连接拒绝；visitor 读成功、写 `forbidden` |
| 命令 | claim/transfer/release 成功；重复 id 回放；同 id 换人 `command_conflict`；不同 id 再主张 `already_claimed`；未知地块、空命令 id、非法接收者、转给自己、非 owner 转让/放弃、未主张地块转让全部返回稳定原因；release 在窗口内回放 |
| 重启 | claim→落盘→重开：地块、owner、`claim_id` 保留；同一 `claim_id` 在更晚时钟下仍返回 `duplicate` 并复用原土地时间；release 记录在重启后仍可回放；第二次重启后上述结论不变；`valid()` 与手工两两检查均证明不重叠仍成立 |
| 只读 | 迁移中的权威拒绝写但仍可读；visitor 与匿名 visitor 都能读 |
| 损坏 | 损坏文档让权威返回 `load_territory_corrupt` 且原文件不被覆盖；不支持版本返回 `load_territory_unsupported`；另一个世界的文档返回 `territory_world_mismatch`；直接 headless 重开会采用已存 world id |

## 未覆盖

- 客户端与网络传输：没有新增 `WorldMember`/`WorldClient` 请求方法、RPC 或 UI，`territory_for_member()` 目前供权威内部与无传输测试调用。成员要真正远程提交土地命令，还需要一个客户端入口。
- 建造/通行权限：`may_build`/`may_trespass` 尚未接入 `FarmState.build` 或任何建造授权入口；地籍目前不阻止在他人/无主地块上建造。
- 初始地块：`default_state()` 的 3×2 网格是占位，没有和真实地图、字段或建筑槽位对齐；用途、租赁、购买/交换和公共地块的产生方式仍未定义。
- 土地与建筑归属冲突：转让仍不移动、拆除或改写建筑；土地 owner 与建筑 owner 不一致时没有裁决规则。
- 快照/追赶：`HeadlessWorld.state_snapshot()` 仍未包含地籍，事件 tail 也不广播土地命令；掉线成员需要新的读取路径才能恢复地籍。
- 地块数量、坐标上限和默认布局不变时没有迁移；早期开发阶段不承诺旧地籍文档兼容。
- `release` 的窗口外幂等仍未实现。
- 只在本机 macOS 无头模式验证；未在 Windows 实机或 CI 运行，也未做真实网络集成测试。

## 增补：建造自动主张的半提交与 id 复用（2026-11-16）

- BUILD 首次建造会以农场命令 id 自动主张地块，主张先于农场写盘。之前规则命中旧
  命令记录时返回 `duplicate`，执行层却直接视为“已主张”，释放后复用旧 id 建造会
  把房子建到无主地上。现在 duplicate 只有在当前地块仍是
  `status=claimed`、`owner=操作者`、`claim_id=该命令` 时才接受，否则返回
  `claim_command_conflict`，不写农场、不写地籍。
- “地籍已主张、农场未提交”的补完：旧 `at_utc` 的重试原本会被 `time_backwards`
  挡死。现在仅当该 BUILD id 在地籍文档中已有耐久记录
  （`TerritoryState.recorded_time() >= 0`）时跳过时间闸门；随后按当前地块状态
  重新判定，已主张给操作者则直接补写农场。没有地籍记录的旧时间命令仍返回
  `time_backwards`。
- 仍未修复的深窗口：`command_results` 是 64 条 FIFO。记录被后续土地命令淘汰后，
  重放旧 release 可能清掉之后的新主张，重放旧 transfer 可能把地块再次转给旧接收
  人，重放旧 claim 可能重新主张当前空闲地块。payload 相同才 replay 的保护只在
  记录仍在窗口内成立；要彻底消除需给地籍增加持久命令表或拒绝淘汰，属于后续
  存储取舍。

测试 `TERRITORY_BUILD_GATE_TEST` 79→92：释放后复用旧 claim id 建造返回
`claim_command_conflict` 且地籍、农场不变；地籍已有主张而农场缺失时，时钟前移
60 秒后同 id 旧时重试补完建造；无地籍记录的旧时间建造仍 `time_backwards`。
回归 `TERRITORY_AUTHORITY_TEST 72/0`、`TERRITORY_BLOCKING_AUTHORITY_TEST 143/0`、
`TERRITORY_PATHS_TEST 86/0`。

## 关联

- 规则切片：[M11-01 · 土地与地籍](RECORD-01-cadastre.md)。
- 裁决：[ADR-023 · 地籍与建筑归属分离](../../decisions/ADR-023-land-cadastre.md)。
- 阶段计划：[M11 PLAN](PLAN.md)。
- 存储模式参考：`Game/farm/nature_store.gd`、`Game/social/social_store.gd`。
- 权威命令参考：`Game/world/world_host.gd` 的 `execute_for_member()` 与 `_apply_social()`。
