# M10-03 · 世界事件到居民记忆的适配层

状态：切片实现（2026-11-15），未验收。范围：把已提交世界事件的最小投影转换成 M10-01 居民记忆，按事实/旁观分层、失败不写、重放幂等、容量沿用 M10-01。不包含主循环接线、网络、模型调用、主观评价与传闻来源分层。

权威设计：[ADR-021](../../decisions/ADR-021-npc-memory.md)（记忆是规则文档，模型不可写）；前置记录：[M10-01 人格与有界记忆](RECORD-01-memory.md)、[M10-02 居民名册](RECORD-02-roster.md)；上层计划：[M10 PLAN](PLAN.md)。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/npc/npc_memory_feed.gd` | 新增。纯适配层：校验事件投影与上下文，按居民派生事实或旁观记忆，只调用 `NpcMemory.remember()` 写入；提供单事件与序列两个入口。 |
| `tests/npc_memory_feed_test.gd` | 新增。113 项无头检查；只读内存，不碰世界、场景、模型、磁盘或网络。 |
| `Game/npc/npc_memory_feed.gd.uid` | Godot 导入生成的脚本 UID。 |
| `docs/2.0/milestones/M10/RECORD-03-memory-feed.md` | 本记录。 |

未修改 `Game/world/*`、`Game/farm/*`、`Game/ui/*`、`Game/scenes/*`、`Game/ai/*`、`Game/npc/npc_memory.gd`、`Game/npc/npc_roster.gd`、`main.gd`、`.github/workflows`、`rules/project-context.md`、决策入口或农场存档格式。没有新顶层键、没有 store、没有网络消息。

## 输入形状

调用方传入已提交事件的最小投影，不传完整命令、库存、账本或场景对象：

```json
{
  "kind": "harvest | sow | water | gift | theft | build | trade | territory_claim",
  "id": "<已提交命令/事件 id>",
  "actor": "<由权威连接解析出的 player/npc id>",
  "target": "<地块/槽位/地块编号，或对手方/受害者 id>",
  "ok": true
}
```

`target` 按事件类型解释：农事与土地事件是定位符（`field_1`、`slot_1`、`parcel_01`），`gift` 是收礼人，`theft` 是受害居民，`trade` 是交易对手方。投影必须只含这 5 个键；未知键拒绝，避免农场、经济或订单字段混入记忆。

上下文 `{now_utc, world_id, roster}`：`now_utc` 由调用方显式注入，`world_id` 必须与记忆文档及名册一致，`roster` 采用 M10-02 `Roster.build()` 形状。

## 事件 → 记忆映射

只有 `ok == true` 且 `actor` 非空的事件写记忆。事实行只给直接涉及的居民；其余在册居民各写一条低显著性 `observation`。

| 事件 kind | 事实主体 | 记忆 kind | 显著性 | 摘要 |
|---|---|---|---|---|
| `harvest` | 行动的居民 | `observation` | 40 | `<名>在田里收获了作物。` |
| `sow` | 行动的居民 | `observation` | 40 | `<名>在田里播下了种子。` |
| `water` | 行动的居民 | `observation` | 40 | `<名>给田里浇了水。` |
| `gift` | 送礼居民 / 收礼居民 | `gift` | 45 / 60 | `<名>把作物送给了<名>。` / `<名>送来了作物。` |
| `theft` | 受害居民 / 动手居民 | `conflict` | 85 / 55 | `<名>拿走了地里的作物。` / `从<名>的地里拿走了作物。` |
| `build` | 行动的居民 | `observation` | 55 | `<名>动工建起了一处建筑。` |
| `trade` | 行动居民 / 在册对手方 | `trade` | 60 / 60 | `与<名>做成了一笔交易。` |
| `territory_claim` | 行动的居民 | `observation` | 70 | `<名>主张了一块土地。` |
| 其余在册居民 | 每位一条 | `observation` | 5 | `看见…` |

- 事实行与旁观行的区分依据是“本人行动、本人收到/失去、本人成交及对手方”，不依据目标地块的所有者推测；事件投影必须由调用方先把受害者/对手方解析成居民 id。
- `gift`、`theft`、`trade` 的 `participants` 是 `[actor, target]`（去重后）；农事、建造、土地事件只含 `[actor]`，定位符不会进参与人列表。
- 名册中的 `display_name` 用于中文摘要；不在名册中的对手方写作“来客”，不会被创建为居民。
- 摘要按 M10-01 上限截断到 200 字符；所有摘要均由规则拼装，没有模型输出。
- 记忆 kind 复用 M10-01 六种枚举；农事/建造/土地是“事实已发生”的 `observation`，没有为此扩展枚举或改 M10-01。

## 幂等、失败与匿名

- **失败不写**：`ok != true` 返回 `{ok: true, skipped: "not_committed"}`，不写任何行。`ok` 非 bool、缺必需键、未知键、非法 kind/id/actor、跨世界或名册世界不符，均返回 `{ok: false, reason}`，文档保持不变（所有校验在第一次写入之前）。
- **重放不重复**：记忆 id 由 `(event id, 居民 id)` 经 FNV-1a 双域散列派生；同一事件重放时 M10-01 返回 `reason="duplicate"`，适配层报告 `duplicates` 并让文档逐字节不变。不同事件内容复用同一 id 仍是同一条记忆；同一内容换新 id 是两条，与 M10-01 的调用方去重约定一致。
- **匿名 actor**：本项目选择“不写”，返回 `skipped: "anonymous_actor"`，连旁观行也不写。理由是无名行动无法归属为某位居民的经历，写成“某人”会在记忆里制造不可核验的人物；若要保留匿名观察，应作为单独的天气/环境事件规则，而不是把匿名玩家伪造成居民。
- **容量与淘汰**：完全沿用 M10-01，每位居民 64 条、最低显著性/最旧/id 升序淘汰、`dropped` 单调。旁观行显著性 5，会最先被淘汰；适配层不新增容量参数、不自己删除。
- **确定性**：不读时钟、不读随机、不遍历 `Dictionary` 的插入顺序来决定语义；居民顺序先按 id 排序，同一输入序列重复处理得到同一文档。

## 接口

```text
MemoryFeed.apply(document, projection, context)        # 单事件
MemoryFeed.apply_sequence(document, events, context)   # 批量，先全量形状校验
MemoryFeed.memory_id(event_id, npc_id)                 # 确定性记忆 id
```

`apply()` 返回：

```text
{ok, reason, event_id, skipped, entries, written, duplicates}
entries[] = {npc_id, memory_id, kind, salience, summary, source_event_id, duplicate}
```

`apply_sequence()` 返回 `{ok, reason, index, results, written, duplicates, skipped}`；任一条事件形状非法时整批不写，并给出第一条非法的下标。注意：批量入口只保证“形状非法不写半批”，不把整批做成事务回滚；若中途 `remember()` 失败（例如文档本身非法），先写的行会保留，调用方应按返回的 `index` 处理。

## 设计取舍

- **适配层不记录来源字段**：M10-01 把记录固定为 8 字段并拒绝未知键，因此来源 event id 不能作为第九字段落盘。适配层把它编码进确定性 memory id，并在返回行中以 `source_event_id` 提供给调用方和测试；没有改 M10-01 的 schema。
- **事件投影只做最小识别**：不接收完整命令、库存、账本或地块所有者表。土地/农事定位符只用于摘要上下文，不参与记忆归属，避免适配层复制 `FarmState` 或地籍的权威。
- **事实/旁观分层放在适配层**：只有适配层知道“谁直接受影响、谁只是看见”，M10-01 只负责存储和淘汰；这样 M10-01 不需要理解事件语义，模型依旧不能写记忆。
- **失败与匿名都不制造记忆**：比“写一条失败观察”更保守；记忆只描述已发生的事实，失败原因仍由世界返回值和日志承担。
- **未接线**：本切片不订阅 `command_committed`、不读事件 tail、不接 `HeadlessWorld`、不落盘；调用方（后续 M10-03）决定何时把已提交事件投影进来。

## 测试

无头运行（本机）：

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/npc_memory_feed_test.gd"
```

结果：

```text
NPC_MEMORY_FEED_TEST checks=113 failures=0
```

覆盖：

- 收获/播种/浇水/赠礼/被盗/建造/成交/土地主张分别落到正确居民，且事实行显著性、kind、摘要、时间、世界字段正确；
- 赠礼收礼方显著性高于送礼方；被盗受害方显著性高于动手方；
- 旁观者只得到显著性 5 的 `observation`，摘要以“看见”开头；玩家行动对所有居民都是旁观；
- 失败事件、非法 `ok`、未知 kind/键、缺 id、非法 id 均不写；匿名与缺省 actor 返回 `skipped` 且文档不变；
- 同一事件重放文档逐字节不变、`duplicates` 计数正确；同内容新 id 写第二条；派生 memory id 稳定且按居民区分；
- 同一事件序列处理两次得到相同文档；批内非法事件整批不写并报告下标；
- 70 条事件后每位居民恰好 64 条、`dropped` 单调、文档仍通过 M10-01 校验；淘汰后重放仍有界；
- JSON 往返、恢复后继续写入与直接写入结果一致；
- 跨世界事件、跨世界名册、非法上下文、未验证文档被拒绝；名册中不存在的居民不产生记忆；
- 存储记录仍只有 8 个 M10-01 字段，没有新增来源或农场字段。

同时复跑前置回归：

```text
NPC_MEMORY_TEST checks=202 failures=0
NPC_ROSTER_TEST checks=91 failures=0
```

## 未覆盖

- 未接入主循环、`HeadlessWorld` 事件 tail、`command_committed` 信号、网络或存档；本切片只是 M10-03 的输入层。
- 未把被偷/成交的对手方从世界状态解析出来；调用方必须提供已解析的居民 id 或玩家 id。
- 未实现主观评价、传闻来源、承诺、模型摘要与上下文裁剪；这些仍按 ADR-021 留在 M10-02 之后。
- 未实现 NPC 自主行动、资源预算、日程、冷却与失败等待（M10-03 主体）。
- 未做场景/UI 展示、Windows 实机与 CI 门禁登记。
