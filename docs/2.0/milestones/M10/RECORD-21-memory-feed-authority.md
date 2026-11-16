# M10-03 · 已提交命令写入居民记忆

状态：切片实现（2026-11-16），未验收。范围：把已有纯规则 `NpcMemoryFeed` 接到 `HeadlessWorld.execute()` 的权威提交点，让已提交的收获、播种、浇水、赠予和建造命令进入居民有界记忆，并随 `residents.json` 同一次原子保存落盘。不接交易、模型、网络消息或面板。

前置记录：[M10-03 世界事件到记忆的适配层](RECORD-03-memory-feed.md)；[M10-04 社交关系与记忆接入世界权威](RECORD-12-resident-authority-social.md)；上层计划：[M10 PLAN](PLAN.md)。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/world/headless_world.gd` | 在农场提交之后、广播之前，把已提交命令映射成记忆投影并调用 `NpcMemoryFeed.apply()`；只在 `written > 0` 时把记忆候选并入 `residents.json` 保存；成功返回值新增 `memory` 结果字段，默认关闭时返回值不变。 |
| `tests/memory_feed_authority_test.gd` | 新增无头夹具，155 项检查，使用真实 `HeadlessWorld`、真实 `residents.json` sidecar 和保存计数／失败替身。 |
| `.github/workflows/rule-tests.yml` | 在纯规则 `tests=(...)` 组末尾登记新夹具。 |
| `docs/2.0/milestones/M10/RECORD-21-memory-feed-authority.md` | 本记录。 |

未修改 `Game/npc/*`、`Game/world/world_host.gd`、面板、字体、`rules/*` 或其他存档文件。没有新增 sidecar：记忆仍属于 `residents.json` 的 `memories` 键。

## 事件映射

只有命令已经由 `FarmStore.save_state()` 写入、`farm.accept()` 接受之后才进入记忆；`execution.duplicate` 的重放路径在此之前返回，因此同一命令 id 不会再次投影。

| 命令 kind | 记忆 kind | `target` 来源 | 说明 |
|---|---|---|---|
| `harvest` | `harvest` | `command.field_id` | 农事定位符只用于投影，不参与记忆归属。 |
| `sow` | `sow` | `command.field_id` | 同上。 |
| `water` | `water` | `command.field_id` | 同上。 |
| `gift` | `gift` | `command.to_id` | 受赠居民得到高显著度事实行，其余居民得到旁观行；送礼玩家不会成为居民。 |
| `build` | `build` | `command.slot_id` | 宅基槽位是稳定地块字段；首次建造的地籍占地由同一个 build 事件代表。 |
| `territory_claim` | 未单独接入 | — | `FarmCommand.KINDS` 没有独立占地命令；首次 build 的 claim 是同一提交的副作用。若另造同 command id 的事件，派生记忆 id 会与 build 行冲突；若另造事件 id，又违反“id 用 command.id”。因此只保留一条 build 记忆，地籍归属照常写入 `territory.json`。 |
| `theft` | 未接入 | — | `set_theft` 只是玩家的偷取开关，不是一次偷取；真实偷取是 `harvest` 的规则副作用，没有稳定的独立命令或返回字段。 |
| `trade` | 不接 | — | 真实成交由 `settle_economy` 扫描产生，与命令 id 不同源；只接一半会留下语义不完整的记忆。 |
| 其他已提交命令 | 不接 | — | `memory` 返回 `skipped: "unmapped_kind"`，不写盘。 |

`now_utc` 使用 `command.at_utc`，不使用墙钟；这与记忆行的 `at_utc` 语义一致，重放和迁移可由命令时间复现。`actor` 使用 `execute()` 的权威参数；为空时由 `NpcMemoryFeed` 返回 `skipped: "anonymous_actor"`，不重复判定权限。

### 记忆行时刻

记忆文档拒绝任何晚于保存时刻的 `at_utc`（`future_time`）。权威居民结算可能已经把某条记忆写到 `command.at_utc` 之后，玩家时钟本身也允许小幅落后；此时若新行仍用命令时刻，整份 `residents.json` 会因一条行被拒而保存失败，这次命令的记忆静默丢失。

因此 `_remember_committed_command()` 用的保存时刻是 `_memory_event_time()`：取 `command.at_utc` 与文档中已有记忆行最大 `at_utc` 的较大者。新行时刻只会跟着已存在的事实前进，不会凭空超前；正常情况下两者相同。夹具 `_test_memory_clock_after_resident_rows()` 先直接写入一条晚 30 秒的居民行，再提交更早的命令，断言保存成功、`memory.ok=true` 且新行落在已存在的最晚时刻；把该函数改回只取命令时刻会让其中 3 项失败。

## 返回值与失败隔离

已提交命令的返回值新增：

```text
"memory": {ok, written, duplicates, skipped, reason, source_event_id}
```

`source_event_id` 是本次投影使用的命令 id；未映射命令为空。它是本次结果的诊断字段，不写入记忆行（M10-01 的八字段记录不变）。

- 成功且确有新行：`ok=true`，`written` 为本次新增行数。
- 成功但无需写：`ok=true`，`written=0`；未映射命令的 `skipped="unmapped_kind"`，匿名行为 `"anonymous_actor"`，空名册为 `""`。
- 记忆投影或保存失败：`ok=false`，`reason` 为规则原因或 `save_resident_state_<kind>`；`written=0`。

`residents_enabled=false` 时不运行记忆投影、不写 `residents.json`，返回值与改动前一致（没有 `memory` 键）。

落盘顺序：

1. `store.save_state(candidate, decorations)` 保存农场；
2. `farm.accept(candidate)` 接受已提交状态；
3. 在 `resident_memories.duplicate(true)` 候选上运行 `NpcMemoryFeed.apply()`；
4. 仅当 `written > 0` 时调用 `_save_resident_documents()`，由 `memory_changed` 条件并入 `residents.json` 的 `{social, memories, invitations, dialogues}` 原子保存；
5. 保存成功后才更新活文档并继续 `shared_changed.emit()`。

第 3、4 步失败只影响 `memory` 字段：农场的 `ok/stage/reason` 不变，活记忆文档不推进，磁盘上的农场仍是已提交事实。

## 幂等

记忆行 id 由 `NpcMemoryFeed.memory_id(command.id, npc_id)` 派生。同一命令 id 的即时重放由 `execute()` 的 duplicate 路径直接返回，不进入记忆阶段；即使记忆候选里已有同一派生 id，`NpcMemoryFeed.apply()` 也返回 `duplicate` 并让文档逐字节不变。测试确认重放不新增行，也不发起第二次 sidecar 写入。

## 测试

无头运行：

```sh
perl -e 'alarm shift; exec @ARGV' 180 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/memory_feed_authority_test.gd"
```

结果：

```text
MEMORY_FEED_AUTHORITY_TEST checks=155 failures=0
```

覆盖：

- 默认关闭时命令仍提交、无 `memory` 键、不写 `residents.json`；
- 玩家收获/播种/浇水后三名居民各得一条旁观记忆，行 id 来自命令 id，`at_utc` 与 `world_id` 正确；
- 赠予让受赠居民得到 `gift` 高显著度记忆，旁观居民保持低显著度；
- 建造让每名居民得到建造记忆，并确认首次建造的 parcel 归属玩家；
- 被拒规则命令与非法载荷不留下记忆行；
- 同一命令重放不新增行、只有一次 sidecar 写入；
- 记忆落盘后重开世界仍在；
- 保存失败时命令仍 `ok=true`、`stage=committed`，`memory.ok=false` 带原因，农场已落盘而记忆未推进；
- 合法但不映射的命令成功返回 no-op；空名册的 feed 调用不报错。

相关回归（最后一行）：

```text
NPC_MEMORY_FEED_TEST checks=113 failures=0
NPC_MEMORY_TEST checks=202 failures=0
NPC_SOCIAL_MEMORY_TEST checks=145 failures=0
RESIDENT_INVITATION_AUTHORITY_TEST checks=167 failures=0
RESIDENT_AUTHORITY_SOCIAL_TEST checks=139 failures=0
RESIDENT_LONG_RUN_TEST checks=13494 failures=0
HEADLESS_WORLD_RUNTIME_TEST checks=83 failures=0
CONFLICT_AUTHORITY_TEST checks=294 failures=0
FONT_COVERAGE_TEST checks=1272 failures=0 missing=0
```

字体门禁通过：本切片新增的中文注释没有引入缺字，未修改字体文件。

## 未覆盖与限制

- 没有独立的 `territory_claim`、`theft`、`trade` 命令事件；映射和理由见上表。
- 命令 id 沿用 `FarmCommand` 的 128 字符上限，但 `NpcMemoryFeed` 的事件 id 走 `OwnerIds.valid` 的 64 字符上限。超过 64 字符的合法命令 id 会得到 `memory.ok=false`（`invalid_event_id`），命令本身仍提交。
- 记忆行时刻会抬到文档中已有的最晚行，因此命令时间落后时新行的 `at_utc` 可能与命令时刻不同；两者相同是常态，差异只说明权威结算已经写入了更晚的事实。
- 未接模型、网络消息、面板展示或传闻来源分层。
