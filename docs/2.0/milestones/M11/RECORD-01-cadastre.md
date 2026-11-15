# M11-01 · 土地与地籍（最小切片）

执行日期：2026-11-15。状态：切片完成，不表示 M11-01 或 M11 验收完成。前置：[M11 PLAN](PLAN.md)、M5 建设权限。

## 问题

M11-01 要求区域边界、权利人、用途、通行权与有限租赁，并保证购买/交换不会双重归属或封死唯一公共通路。首版还没有任何土地权威数据：建筑由 `FarmState.build` 记录槽位、施工时间和建造者，但“这块地是谁的、别人能不能建/能不能过”没有规则。

本次只建立可以独立验证的地籍纯规则，不接入农场文档、存档、网络和 UI。范围刻意小于 M11-01 的完整验收：租赁、用途、公共通路连通性、购买/交换价格与住宅蓝图连接都留给后续切片。

## 边界

- 新增 `Game/world/territory_state.gd` 与 `tests/territory_test.gd`，不修改 `Game/farm/*`、`Game/scenes/*`、`Game/ui/*`、其它 `Game/world/*` 或任何流程／规则文件。
- 不读取 `FarmState`，不新增农场顶层键，不改变保存格式；`territory` 子文档将来放在哪一层由接线切片决定。
- 无 RNG、无系统时钟、无磁盘、无场景、无网络。所有命令显式传入 `at_utc`，同一输入得到同一输出。
- 不改变现有 `build`/`demolish` 的建筑归属规则；本模块只记录土地。

## 实现

### 文档形状

```text
territory = {
  world_id: String,
  sequence: int,
  parcels: { parcel_id: parcel },
  command_results: { command_id: { payload: String, result: result } },
}

parcel = {
  id, rect: {min_x, min_z, max_x, max_z},
  owner, status, claimed_utc, claim_id,
}
```

- `rect` 使用包含端点的整数格坐标，四个键必须齐全；`min_x <= max_x`、`min_z <= max_z`，坐标在 `0..4096`。两个矩形只要在任一轴上的闭区间相交就算重叠，包含端点相邻（例如 `0..3` 与 `4..8`）不重叠。
- `status` 只有 `unclaimed`、`claimed`、`public`：
  - `unclaimed`：`owner` 为空串，`claimed_utc = 0`，`claim_id` 为空。
  - `claimed`：`owner` 是合法玩家 id，`claim_id` 是合法命令 id。
  - `public`：`owner` 固定为 `public`，`claimed_utc = 0`，`claim_id` 为空。
- 地块表以 id 为键；行内 `id` 必须与键一致，因此键级重复不可能存在，行内 id 与键不符会被拒绝。最多 256 块地，命令窗口最多 64 条结果。

### 命令

- `claim(state, world_id, parcel_id, owner, command_id, at_utc)`
  - 只接受 `unclaimed` 地块和合法玩家 id（不能是 `public`、`@world`、空串或非法字符）。
  - 成功写入 owner/status/claimed_utc/claim_id；同一命令 id 且参数一致时回放首次结果（`duplicate=true`），同一 id 换参数返回 `command_conflict`，不同 id 再主张返回 `already_claimed`。
  - 未知地块 `unknown_parcel`；`public` 地块 `already_public`；世界 id 与文档不一致 `wrong_world`。
  - 仍会检查目标矩形不与其它地块重叠，重叠的畸形声明返回 `overlapping_parcels`，不会写入。
- `transfer(state, parcel_id, from, to, command_id, at_utc)`
  - 只有当前 owner 本人可以发起，接收者必须是另一个合法玩家；`from != to`。
  - 转让只改土地行：owner、claimed_utc、claim_id。不会拆建、迁移或改变 `FarmState` 里的建筑；建筑归属继续由现有 `build`/`demolish` 规则决定。
  - 非 owner `not_owner`，未主张/已放弃 `not_owned`，时间早于上次土地动作 `time_regression`。
- `release(state, parcel_id, actor, command_id, at_utc)`
  - 只有 owner 本人可以放弃；成功后回到 `unclaimed` 并清除 owner、claimed_utc、claim_id。
  - 非 owner `not_owner`，非 claimed 状态 `not_owned`。

### 权限

纯函数，不读 `FarmState`：

| 状态 | `may_build` | `may_trespass` |
|---|---|---|
| `claimed` | 仅 owner | 仅 owner |
| `public` | 任何合法玩家 | 任何合法玩家 |
| `unclaimed` | 拒绝 | 任何合法玩家 |

`unclaimed` 的“不能建、可以通过”是本切片的明确默认，理由见 [ADR-023](../../decisions/ADR-023-land-cadastre.md)。非法 actor（空串、`public`、`@world`、非字符串等）和未知地块一律返回 false。

### 确定性与幂等

- 命令结果写入有界 `command_results`，超过 64 条时按插入顺序淘汰最旧一条，与规则银行一致。
- `claim`/`transfer` 的 `claim_id` 同时是耐久守卫：命令窗口淘汰后，仍可根据地块行识别同一命令的重放。`release` 清除 `claim_id`，因此放弃命令的重放只在窗口内有效（记录于未覆盖）。
- 每个成功命令只把 `sequence` 加一；失败命令不写结果、不改地块。
- 命令 payload 是 JSON 数组并带 `world_id`。`valid()` 会拒绝属于另一个世界的 payload，同一命令 id 在两个世界文档中互不影响。

### 文档校验

`valid(state)` 严格拒绝：

- 顶层/地块/矩形/结果键集合不精确，缺失或未知键；
- 非法 world id、负数/小数 `sequence`；
- 行内 id 与键不符、重复 `claim_id`；
- 矩形越界、负数、小数、`min > max`、相互重叠；
- 所有权与状态不一致（claimed 无玩家、public 非 public、unclaimed 残留 owner/时间/claim_id）；
- 负数/非有限时间、时间与仍存活命令 payload 不一致、owner 与仍存活命令结果不一致；
- 命令结果超过 64 条、payload 非法 JSON/超长/跨世界/未知类型、结果字段不精确或 `duplicate=true` 被写入；
- 地块超过 256 块；带未知顶层键。

`normalize(state)` 只把 JSON 数字转回 int/float、bool 转回 bool，供往返测试和未来接线使用；不做兼容迁移。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/territory_test.gd"
```

原始末行：

```text
TERRITORY_TEST checks=159 failures=0
```

覆盖：

| 用例 | 检查 |
|---|---|
| 主张 | 合法主张成功；重复命令回放；不同 id 返回 `already_claimed`；未知地块、非法 owner、非法命令 id、负数/非有限时间、错误世界、public 地块、畸形文档全部拒绝且不改状态 |
| 转让 | 非 owner、非法接收者、转给自己、时间倒流、复用他人 claim/transfer 命令 id 全部拒绝；成功转让更新 owner/时间/claim_id；重放幂等；失败不改 owner |
| 放弃 | 非 owner 拒绝；owner 放弃后四个土地字段全部清空；重放幂等；再次放弃返回 `not_owned`；未主张地块不能转让 |
| 权限 | claimed 只允许 owner；public 允许任意合法玩家、拒绝非法 actor；unclaimed 拒绝建造但允许通行；未知地块和畸形文档两者都拒绝 |
| 文档 | JSON 往返仍有效；`normalize` 还原数字类型；逐项拒绝未知键、缺失键、id 不符、矩形越界/反向/小数/重叠、状态与 owner/时间/claim_id 不一致、重复 claim_id、跨世界 payload、坏结果行、超长/非法 payload、超 64 条结果、超 256 块地 |
| 世界隔离 | 两个世界用同一命令 id 和同一地块 id 各自主张；错误世界被拒；重放只影响本世界；把 payload 改成另一世界会让文档失效 |
| 确定性与边界 | 相同输入序列生成完全相同的文档；70 次交替主张/放弃后窗口正好 64 条、`sequence=70`、文档仍有效 |

## 未覆盖

- FarmState 与存档接线：本切片没有把 `territory` 写入农场快照，也没有 `FarmState.claim_land` 等薄封装；接线时需单独决定子文档位置、迁移和键校验。
- 网络权限：没有宿主/客户端命令、成员角色校验、广播或回执；`may_build`/`may_trespass` 只是纯函数，尚未接到建造命令入口。
- UI：没有地籍面板、地块选择、边界可视化或购买/交换界面。
- 建筑归属冲突：土地转让不移动、不拆除、不转移地上建筑；当土地 owner 与建筑 owner 不同、或公共地块上已有私人建筑时，尚无裁决规则。这是后续切片必须显式解决的设计问题，不能在接线时静默选择一个副作用。
- 用途、租赁、通行权、唯一公共通路连通性、购买/交换的双重归属检查：均未实现，不表示 M11-01 验收完成。
- `public` 地块如何由地图/管理员产生、如何证明公共通路不被封死，尚未定义。
- `release` 的耐久幂等只依赖 64 条命令窗口；窗口淘汰后同一命令 id 可能被重新使用，需要后续增加释放命令 id 的持久字段或不可变事件日志。
- 只在本机 macOS 无头模式运行；未在 Windows 实机或 CI 运行，也未做真实存档/网络集成测试。

## 关联

- 阶段计划：[M11 PLAN](PLAN.md)。
- 裁决：[ADR-023 · 地籍与建筑归属分离](../../decisions/ADR-023-land-cadastre.md)。
- 现有建筑规则：`Game/farm/farm_state.gd` 的 `build`/`demolish`；本切片未修改。
- 纯规则写法参考：`Game/farm/loan_state.gd`。
