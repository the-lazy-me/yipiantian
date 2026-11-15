# M11-01 · 地籍连通性与唯一公共通路检查

执行日期：2026-11-16。状态：切片完成，不表示 M11-01 或 M11 验收完成。前置：[M11 地籍规则](RECORD-01-cadastre.md)、[地籍接入权威](RECORD-02-cadastre-authority.md)、[地籍转让与通行判定](RECORD-10-territory-transfer.md)、[ADR-023](../../decisions/ADR-023-land-cadastre.md)。

## 问题

M11-01 的交付要求是“购买/交换不会双重归属或封死唯一公共通路”。此前已有 `TerritoryState.can_pass()`，但它只回答“能不能跨过这一块地”，无法回答两件验收真正需要的事：

1. 从公共入口到某处宅基是否存在一条可通路径；
2. 把某块地变成不可通行后，是否还有宅基失去唯一入口（即这块地是不是割点）。

[RECORD-10](RECORD-10-territory-transfer.md) 的未覆盖项明确写了“无连通性寻路”。本切片只补这一缺口，仍不接入权威、网络、存档与界面。

## 决定与实现

### 1. 输入是地籍视图，不是地籍文档本身

新增纯规则模块 `Game/world/territory_paths.gd`。`build_view(state, options)` 从一个地籍形状的文档（只要求 `parcels` 字典，行内含 `id`/`rect`/`owner`/`status`）派生只读路由视图：

```text
view = {
  ok, reason, entrance,
  homesteads: [parcel_id, ...],       # 已建成宅基，排序去重
  nodes: {
    parcel_id: {
      neighbors: [parcel_id, ...],    # 按 id 排序
      passable: bool,                 # 匿名/指定玩家的通行判定
    }
  }
}
```

- **相邻关系由矩形边界派生**：把每个矩形四边的单位格边界线编码成整数，两个矩形登记同一段边界即相邻。只在角点相接不算相邻——走路不能穿过一个点。这样不需要地籍文档新增邻接字段，也不改变 `territory_state.gd` 的任何形状。
- 调用方显式传入 `entrance`（公共入口）与 `homesteads`（已建成宅基）。规则不读 `FarmState`，宅基名单由接线层从真实建筑派生。
- `options` 键集合精确为 `entrance`/`homesteads`/`passable`/`actor`，未知键拒绝；缺失 `entrance` 返回 `missing_entrance`。

### 2. 通行权沿用 `can_pass` 语义

- `passable` 字段在 `actor` 缺省时表示“匿名公共行人”：只有 `public` 与 `unclaimed` 地块可通行。这与 `TerritoryState.can_pass(state, id, 合法玩家)` 对一名不拥有任何地块的玩家完全一致，因此没有另起一套规则。
- 传入 `actor` 时直接调用 `TerritoryState.can_pass()`，本人地块可通行，他人 `claimed` 地块不可通行。
- `passable` 列表沿用 RECORD-10 的外部放行语义（例如已建成公共项目绑定的地块），只对所有人放行通行，不改变地籍文档。
- **取舍：**本切片没有实现“所有权要求通行许可”的社交逻辑。[politics-conflict-law.md](../../systems/politics-conflict-law.md) 所说的“通行权与相邻土地所有权分开”在规则上仍只有“本人/公共/无主/外部放行”四种来源；尚未有地役权、协议或决议产生的通行权。`can_pass` 语义变了时必须同步本模块，二者不能各自维护一套权限表。

### 3. 终点宅基豁免（只对终点生效）

`path(view, start, goal, blocked = [])` 用排序 BFS 给出确定性最短路：

- 可通行节点才进入搜索；`claimed` 的他人地块不能作为中途节点。
- **终点如果本身不可通行（例如别人的宅基），只要存在可到达的相邻可通行地块，就算到达**，路径以该宅基结尾。理由：验收问的是“公共路能不能走到宅基门口”，不是“访客能不能穿过宅基”。这个豁免只作用于终点一步，不能让搜索穿过宅基继续前进。
- 起点必须可通行；`blocked` 中的起点或终点直接判为不可达（不是错误）。不可达返回 `ok=true, reachable=false, path=[], distance=-1`；查询本身合法时 `ok` 始终为 `true`，`ok=false` 只表示参数/视图有误。
- 相同输入得到相同路径：邻接列表在构建时排序，BFS 队列按排序顺序展开，平局取较小 id。

### 4. 核心验收：`check_blocking`

`check_blocking(view, parcel_id)` 假设该地块变为不可通行，然后回答“公共入口到每个已建成宅基是否仍然可达”：

```text
{ok, reason, parcel, entrance, entrance_reachable, blocked, newly_blocked}
```

- `blocked`：阻断后不可达的宅基（排序）。阻断前就已不可达的宅基也在这里出现。
- `newly_blocked`：仅列出“本来可达、阻断后不可达”的宅基，也就是这块地真正封死的入口。
- 宅基的“可达”判定与 `path()` 的终点豁免一致：宅基自身被可达，或存在可达的相邻可通行地块（门口）。
- `entrance_reachable` 回答阻断入口本身后是否还能到达入口。阻断入口时，所有宅基按不可达处理。
- 这是本切片的核心价值：购买/交换/建造前调用它，若 `newly_blocked` 非空就说明这次改动会封死唯一公共通路。

### 5. 有界、具名拒绝

- 最多 4096 个地块（`MAX_PARCELS`），最多 65536 段单位边界（`MAX_BOUNDARY_SEGMENTS`）。超限返回 `too_many_parcels` / `too_many_cells`，不启动无界搜索。
- 坐标复用 `TerritoryState` 的 `0..4096` 上限；矩形反向、状态未知、`id` 与键不符、非字典行、非法键、非字符串 `owner` 都返回 `invalid_parcel`。
- 起点/终点/受阻/宅基/入口/放行名单中的非法 id 分别返回 `invalid_start`、`invalid_goal`、`invalid_blocked`、`invalid_homestead`、`invalid_entrance`、`invalid_passable`，不存在的 id 返回对应的 `unknown_*`。
- 所有拒绝与结果都是普通 `Dictionary`，`reason` 是稳定字符串；`path`/`check_blocking` 的数据只读，不改传入的地籍文档。
- **未复用 `TerritoryState.valid()` 的完整校验**：当前地籍最多 256 块且矩形不重叠，视图上限更大，是独立的只读派生层；它只校验本模块真正依赖的字段。重叠矩形（真实地籍不可能出现）会让边界登记产生不可靠的邻接，接线前必须先用地籍 `valid()` 确认文档。

### 6. String 与 StringName 键

`build_view` 同时接受 String 与 StringName 形式的 `parcels` 键。测试里手写的 `{parcels: {p00: ...}}` 会产生 StringName 键，而 JSON 解析产生 String 键；Godot 把两者视为同一个字典键，所以统一 `str()` 后不会出现重复地块。解析路径永远只有 String 键，这一处理只让手写夹具不因键类型失败。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/world/territory_paths.gd` | 新增纯规则模块：视图构建、确定性 BFS、`check_blocking` |
| `tests/territory_paths_test.gd` | 新增 86 项检查 |
| `docs/2.0/milestones/M11/RECORD-15-territory-paths.md` | 本记录 |

未改 `territory_state.gd`、`headless_world.gd`、`world_host.gd`、`world_client.gd`、`Game/farm/**`、`Game/scenes/**`、`Game/platform/**`、`Game/ui/**`、`.github/`、`rules/`、`PLAN.md`、地籍存储格式。不写任何文件；测试不落盘。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/territory_paths_test.gd"
perl -e 'alarm shift; exec @ARGV' 240 "$GODOT" --headless --path Game \
  --script "$PWD/tests/font_coverage_test.gd"
```

原始末行：

```text
TERRITORY_PATHS_TEST checks=86 failures=0
FONT_COVERAGE_TEST checks=1273 failures=0 missing=0
```

覆盖：

| 用例 | 检查 |
|---|---|
| 视图相邻 | 3×3 网格的边界邻居数（2/4/2）；只在角点相接的两个矩形不相邻且不可达；重复宅基 id 去重 |
| 视图通行 | 公共/无主可通行；匿名行人不穿他人 `claimed`；本人可穿自己地块、不可穿他人；外部放行 id 只放行该地块；无宅基视图合法 |
| 最短路 | 两步到宅基、绕开私有地块的四步路线、路径端点与确定性；重复查询结果相同；外部放行的地块可路由；自身到自身距离 0；不可通行起点不可达；`blocked` 起点/终点判不可达；阻断中途节点切断路线 |
| 封路检查 | 走廊唯一割点切断宅基并记入 `newly_blocked`；阻断宅基不改变门口可达；阻断入口报告入口不可达且全部宅基受阻；菱形双路径的任一单点都不阻断；网格中唯一门口地块被报告、已私有地块不新增阻断；无宅基时为空 |
| 视图校验 | 缺 `parcels`、`parcels` 非字典、未知选项键、缺入口、非法/未知入口、非列表与非法/未知宅基和放行名单、四种非法 actor、未知状态、反向矩形、非法键、行 id 不符、非字典行、StringName 键正常构建 |
| 路径校验 | 空视图、非法/未知起终点、非法/未知受阻 id；错误结果形状固定为空 |
| 封路校验 | 空视图、非法地块、视图外地块；错误结果形状固定为空 |
| 有界 | 4097 个地块返回 `too_many_parcels`；5 个 4097×4097 矩形返回 `too_many_cells` |
| 只读与确定性 | 同一地籍两次构建完全相同；寻路与封路检查后输入文档逐字段不变，地块 owner/status 不变 |

字体门禁：新增注释与文档未引入字体子集之外的汉字。

## 未覆盖

- **权威接线**：没有 `HeadlessWorld`/`WorldHost` 的只读动作，也没有“购买/交换/建造前自动调用 `check_blocking` 并拒绝”的门禁。本切片只提供规则；接入时必须决定宅基名单来源（真实 `buildings`）、公共入口来源、以及拒绝原因如何回传。
- **地役权与协议通行**：只有 `can_pass` 的四种来源。没有租约、通行协议、组织决议或官府裁定产生的通行权；这些需要在 `can_pass` 与本模块同时扩展，不能只在寻路层放行。
- **地图坐标对齐**：视图直接使用地籍矩形，地籍矩形和真实地图/建筑槽位之间的映射仍是 ADR-028 的序号约定，没有几何对齐。公共入口是调用方命名的地块，没有从地图或公共项目自动派生。
- **支付与业务闭环**：`check_blocking` 只是查询，不阻止也不回滚任何 `claim`/`transfer`；将来接入时必须在权威层先判后写，失败不落盘。
- **性能**：BFS 与边界登记按上述上界为 O(边界段 + 地块)，未做真实地图规模基准；当前 6 块默认地籍无需优化。
- **重叠与畸形矩形的容错**：视图只校验本模块依赖的字段，不拒绝重叠矩形；接线前必须确认输入来自 `valid()` 通过的地籍。
- 只在本机 macOS 无头模式验证；未在 Windows、CI 或真实多人世界里验证。

## 关联

- 阶段计划：[M11 PLAN](PLAN.md)。
- 裁决背景：[ADR-023 · 地籍与建筑归属分离](../../decisions/ADR-023-land-cadastre.md)。
- 通行判定来源：[RECORD-10 · 地籍转让与通行判定](RECORD-10-territory-transfer.md)。
- 规范：[政治、冲突与法律](../../systems/politics-conflict-law.md)（“购买一块地不能自动封死他人唯一出入口”）。
