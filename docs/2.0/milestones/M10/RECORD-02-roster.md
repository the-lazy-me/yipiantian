# M10-02 · 居民名册

状态：切片实现（2026-11-15），未验收。范围：林婶、许伯、阿舟的稳定 `npc_id`、显示名、由 `npc_id + 世界种子` 派生的五维人格、初始居民关系与初始记忆，以及到 M10-01 人格/记忆公共入口的接线。不包含 M10-03 自主行动、真实资源/预算、日程、模型调用、对话、存档接线、网络同步或场景/UI。

权威设计：[ADR-021](../../decisions/ADR-021-npc-memory.md)（人格与记忆规则）、[AI 系统](../../06-AI-SYSTEM.md)；上层计划：[M10 PLAN](PLAN.md)。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/npc/npc_roster.gd` | 新增。三人确定性名册；人格委托 `NpcPersonality.traits()`，初始记忆委托 `NpcMemory.create()` / `remember()`；不实现第二套派生或淘汰。 |
| `tests/npc_roster_test.gd` | 新增。91 项无头检查；只读内存，不触碰农场状态、场景、模型、磁盘或网络。 |
| `docs/2.0/milestones/M10/RECORD-02-roster.md` | 本记录。 |

未修改 `Game/npc/npc_personality.gd`、`Game/npc/npc_memory.gd`、`Game/farm/*`、`Game/world/*`、`Game/ai/*`、`Game/scenes/*`、`Game/ui/*`、`FarmState`、规则文件或决策索引。农场存档格式不变，无新增顶层键。

## 规则与数值

```text
名册版本            schema = 1
居民                npc_lin_shen / npc_xu_bo / npc_a_zhou
显示名              林婶 / 许伯 / 阿舟
居所                柳岸 / 竹汀 / 渡口
人格维度            diligence / warmth / suspicion / curiosity / generosity
人格来源            Personality.traits(npc_id, world_seed)
人格范围            0..100 整数
初始关系            三人两两互记为 neighbor
初始记忆            每人 1 条 observation，显著性 10
初始记忆时间        固定 0.0（纪元），使初始化不读取时钟
记忆容量与淘汰      完全沿用 M10-01（每位居民 64 条）
```

名册是派生数据：同一 `world_id + world_seed` 重复构造得到完全相同的文档。不同种子只改变人格，稳定 id、显示名、居所和基线关系保持不变；所有派生值仍落在 0..100。`build()` 复用 M10-01 记忆文档的世界 id 规则，避免名册接受一个记忆层会拒绝的世界 id。

## 名册形状

```json
{
  "schema": 1,
  "world_id": "world-a",
  "world_seed": 7,
  "npcs": {
    "npc_lin_shen": {
      "display_name": "林婶",
      "home": "柳岸",
      "traits": {
        "diligence": 42,
        "warmth": 71,
        "suspicion": 18,
        "curiosity": 55,
        "generosity": 63
      },
      "relations": {
        "npc_xu_bo": "neighbor",
        "npc_a_zhou": "neighbor"
      }
    }
  }
}
```

名册字段固定为 `schema` / `world_id` / `world_seed` / `npcs`；居民字段固定为 `display_name` / `home` / `traits` / `relations`。人格值以上只是形状示例，不是固定断言。

## 接口

```text
Roster.build(world_id, world_seed)       # {ok, reason, roster}
Roster.initial_memory(world_id)          # {ok, reason, document}
Roster.initialize(world_id, world_seed)  # {ok, reason, roster, memory}
```

- `build()` 对每个稳定 id 调用 `Personality.traits()`；非法世界 id 返回 `invalid_world_id`，非法种子返回 `invalid_seed`，两者都不返回部分名册。
- `initial_memory()` 建立 M10-01 空记忆文档后，对每位居民调用一次 `Memory.remember()` 写入基线 observation；重复使用同一 id 会被 M10-01 以 `duplicate` 拒绝。
- `initialize()` 把两半一起构造，保证它们指向同一个世界；任一失败都返回空名册与空记忆，不返回半成品。
- 返回的名册是调用方可安全修改的副本；修改不会污染常量表或后续构造。

## 初始关系与初始记忆

- 三人的既有故事表明他们已经是邻里、会互相请客；名册把这一身份事实记为两两 `neighbor`，不引入任意信任分或数值关系。
- 玩家与居民的关系仍由既有 `Game/farm/neighbor_catalog.gd` 的愿望/回礼状态和 M5 社交文档承担；名册不读取、不复制也不改写这些状态，避免出现第二套权威。
- 初始记忆只写一条 authored observation，内容是既有身份与邻里关系，不伪造交易、承诺或账本事实。基线时间固定为 `0.0`，因此初始化不依赖调用方时钟；检索时按 M10-01 的衰减规则排序。
- 模型不能写入名册或初始记忆。未来模型建议仍须先经规则层接受为世界事件，再由事件调用方调用 `Memory.remember()`。

## 持久化取舍

名册不持久化。它完全由 `world_id + world_seed + 稳定 id` 重建，保存一份副本只会引入与派生结果漂移的风险；本切片因此不新增 store、存档键或迁移。初始记忆本身是普通 M10-01 文档，测试已通过既有 `Memory.to_json()` / `from_json()` 验证往返一致；是否、何时把它接入 `FarmState` 或世界迁移，留到真正需要持久化 NPC 状态的切片决定。

## 测试

无头运行（本机）：

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/npc_roster_test.gd"
```

结果：

```text
NPC_ROSTER_TEST checks=91 failures=0
```

覆盖：

- 三人存在、稳定 id、显示名、居所与两两邻居关系；
- 人格恰为五维、经 M10-01 公共入口派生、范围 0..100、描述可生成；
- 同一世界种子重复构造完全一致；返回名册被修改后不影响后续构造；
- 不同种子至少改变一个维度且不越界；不同世界 id 在相同种子下不改变人格；
- 世界 id、种子和初始记忆的错误输入被具名拒绝且不返回半成品；
- 初始记忆每人一条、字段固定、通过 M10-01 严格校验、可通过 `retrieve()` 取回、重复 id 被判 `duplicate`；
- 初始记忆的 JSON 往返一致；
- 名册不携带 farm/economy/cash/ledger、库存或预算字段，也不复制玩家关系。

同时复跑 M10-01 回归：

```text
NPC_MEMORY_TEST checks=202 failures=0
```

## 未覆盖与 M10-03 边界

- **未做 M10-03 自主行动**：名册只提供身份、偏好、基线关系和初始记忆，不提供目标选择、资源预算、库存、日程、行动合法性、冷却或失败等待。阿舟要用真实预算采购，至少需要把名册接到 `FarmState` / 市场 / 账本，并在规则层新增目标与状态校验；这些会改动 `Game/farm/*`、`Game/world/*` 或主循环，超出本切片的文件边界。
- 未把名册或初始记忆接入 `FarmState`、世界快照、迁移包或网络消息。
- 未实现模型读取名册、生成对话、主观评价/传闻/承诺分层，也未实现记忆压缩或删除。
- 未实现 NPC 资源、日程、拜访、交易、关系变化与冷却。
- 未实现场景/UI 展示、Windows 实机与 CI 门禁登记；测试尚未加入 `.github/workflows`。
