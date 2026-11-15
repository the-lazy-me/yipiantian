# ADR-023 · 地籍与建筑归属分离

- 状态：采纳（2026-11-15），M11-01 切片实现完成；未验收
- 关联：[M11-01 地籍切片记录](../milestones/M11/RECORD-01-cadastre.md)、[M11 PLAN](../milestones/M11/PLAN.md)、[政治、冲突与法律](../systems/politics-conflict-law.md)

## 背景

M11-01 要求建立地籍：区域边界、权利人、用途、通行权与有限租赁，并保证购买/交换不会让一块地双重归属或封死唯一公共通路。

现有的建筑规则已经把“谁建的”与“建在哪个固定槽位”记在 `FarmState.buildings`：

- `FarmState.build(slot_id, blueprint_id, now_utc, actor)` 记录 `owner=actor`、施工开始/完成时间；槽位来自 `BuildingCatalog.SLOTS`（`yard_a`…`yard_f`）。
- `FarmState.demolish(slot_id, now_utc, actor)` 只允许建筑 owner 拆除。
- `FarmState.set_theft(player_id, enabled)` 只改变玩家自己的被偷设置。

这些规则回答的是“建筑归谁、何时建成”，没有回答“这块地归谁、谁能过、谁能建”。如果直接把土地所有权塞进建筑记录，会带来两个问题：

1. 没有建筑的地块无法表达归属，公共通路也无法表达；
2. 土地转让会被迫同时决定建筑命运，从而把两个不同生命周期、不同审计口径的规则绑死。

## 决定

### 1. 地籍是独立规则文档，建筑归属继续由现有 `build`/`demolish` 决定

新增 `Game/world/territory_state.gd`，保存每个世界的地块表与命令结果。它只记录土地：

```text
parcel = { id, rect, owner, status, claimed_utc, claim_id }
```

土地的 `transfer`/`release` 不会创建、拆除、迁移建筑，也不会改动 `FarmState`。地上建筑的 owner 仍由 `build` 写入、由 `demolish` 校验。这样：

- 没有建筑的地块、公共地块、未主张地块都能被表达；
- 土地与建筑可以分别审计、分别修复；
- 未来若需要“地契与建筑归属必须一致”，应做成显式规则或更正事件，而不是在转让里静默搬房。

### 2. 三种状态与所有权字段严格对应

- `unclaimed`：`owner=""`、`claimed_utc=0`、`claim_id=""`。
- `claimed`：`owner` 是合法玩家 id，`claim_id` 是建立当前土地归属的命令 id。
- `public`：`owner="public"`、`claimed_utc=0`、`claim_id=""`。

`valid()` 拒绝任何“状态说有主/无主，但字段相反”的文档。地块矩形使用包含端点的整数格坐标，最多 256 块，矩形不得重叠；`valid()` 与 `claim()` 都拒绝重叠声明。

### 3. `unclaimed` 的默认权限：不能建造，可以通过

| 状态 | 建造 | 通行 |
|---|---|---|
| `claimed` | 仅 owner | 仅 owner |
| `public` | 任何合法玩家 | 任何合法玩家 |
| `unclaimed` | 拒绝 | 任何合法玩家 |

理由：

- 无主地还没有权利人，允许任何人在上面永久建造会让“先建先得”绕过主张与审计；拒绝建造、保留通行，既不封路也不产生未登记的建筑。
- `public` 是明确登记为公共的地块，建造和通行都开放；真正的公共建筑/公共资金权限留给组织与规则决议切片。
- `claimed` 的通行默认只允许 owner。通行权、地役权和唯一公共通路的连通性尚未实现，后续必须在 M11-01 的完整验收里补上，不能把当前默认当作最终规则。

`may_build`/`may_trespass` 是纯函数，只读地籍文档，不读 `FarmState`。非法 actor（空串、`public`、`@world`、非玩家 id）和未知地块一律拒绝。

### 4. 命令以世界为单位、显式时间、确定性重放

`claim(world_id, parcel_id, owner, command_id, at_utc)`：

- 只接受 `unclaimed` 地块和合法玩家 id；
- 同一命令 id 与参数一致时回放首次结果；同一 id 换参数是 `command_conflict`；不同 id 再主张是 `already_claimed`；未知地块是 `unknown_parcel`；
- 命令 payload 带 `world_id`，世界 id 与文档不一致直接拒绝。两个世界使用同一命令 id 互不影响。

`transfer` 只允许当前 owner 发起，`release` 只允许 owner 放弃。两者都要求 `at_utc` 不早于上次土地动作，失败不写入任何字段。所有函数无 RNG、无系统时钟，同一输入同一输出。

`claim` 与 `transfer` 成功后把命令 id 写入地块的 `claim_id`，因此命令窗口（64 条）淘汰后仍能靠地块行识别重放。`release` 会清除 `claim_id`，所以放弃命令的耐久重放只覆盖窗口内；这条限制在记录里明确保留。

### 5. 严格、定界的文档校验

`valid()` 要求键集合精确、字段类型正确、id 唯一、矩形在 `0..4096` 且不重叠、时间非负且与仍存活命令一致、命令结果与 payload 同世界、数量不超过 256 地块/64 结果。没有旧格式兼容分支，没有迁移器。

### 6. 本切片不接入农场文档

不新增农场顶层键，不改保存格式，不改 `V27Importer.KNOWN_FARM_KEYS` 或快照键数。原因：

- 本切片可以在不碰 `Game/farm/*`、`Game/scenes/*`、`Game/ui/*` 的前提下完整验证规则；
- 子文档位置、世界初始化、恢复顺序、旧世界默认公共地块等接线决定会实质影响存档语义，应由接线切片单独评审；
- 先冻结纯规则，可以避免把“土地规则是否正确”和“存档/网络是否接对”混在一次改动里。

## 为什么不是另一侧

- **不把土地塞进建筑行**：没有建筑的地块和公共通路无法表达；转让会连带决定建筑归属。
- **不把 `unclaimed` 当作可自由建造**：会产生无法审计的占地，且与“先主张、后建造”的权限模型冲突。
- **不让 `transfer` 自动搬房或拆房**：两种归属的生命周期不同，静默副作用会让审计无法解释；冲突应由未来规则显式裁决。
- **不在本切片接网络/UI/存档**：会扩大文件边界，且掩盖纯规则结论；`valid()` 与命令入口应先独立稳定。
- **不使用系统时钟**：离线结算和重放要求显式 `at_utc`；系统时钟会破坏确定性。

## 后果

- 新增 `Game/world/territory_state.gd` 与 `tests/territory_test.gd`，本机结果 `TERRITORY_TEST checks=159 failures=0`。
- `FarmState`、农场存档、网络、UI 均未修改；`territory` 尚未持久化，也尚未参与任何建造/通行判定。
- 已知缺口：土地与建筑 owner 不一致的裁决、公共通路连通性、用途、租赁、购买/交换、公共地块的产生方式、`release` 的窗口外幂等、Windows/CI 证据。
- 后续接线时必须先决定：地籍放在农场快照的哪个子文档、世界初始地块如何生成、土地权限如何进入建造命令入口；这些决定不能靠本 ADR 默认推断。

## 复审触发条件

出现以下任一情况时重开本裁决：接入农场存档或网络命令、需要土地与建筑归属强一致、需要公共通路连通性证明、引入用途/租赁/购买交换、`public` 地块由玩家或组织产生、需要窗口外的 `release` 幂等、或地块数量/坐标上限不再满足真实世界。
