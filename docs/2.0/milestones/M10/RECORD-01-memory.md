# M10-01 · 人格基线与有界居民记忆

状态：切片实现（2026-11-15），未验收。范围：确定性人格基线、每位居民 64 条有界情景记忆、确定性检索、严格 JSON 恢复。不包含真实 NPC 行为、模型接入、对话生成、多人同步、场景/UI 接线。

权威设计：[ADR-021](../../decisions/ADR-021-npc-memory.md)；上层规格：[AI 系统](../../06-AI-SYSTEM.md)、[M10 PLAN](PLAN.md)。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/npc/npc_personality.gd` | 新增。5 维稳定人格（勤勉、温和、多疑、好奇、慷慨），由 `npc_id` + 世界种子经 FNV-1a 确定性派生，无 RNG；提供 `traits`、`valid`、`describe`。 |
| `Game/npc/npc_memory.gd` | 新增。每位居民 64 条有界情景记忆；固定枚举事件类型；容量淘汰与 `dropped`；确定性检索与衰减；整份文档严格校验、JSON 往返与旧档缺省字段读取。 |
| `tests/npc_memory_test.gd` | 新增。202 项无头检查；不触碰农场状态、场景或磁盘。 |
| `docs/2.0/decisions/ADR-021-npc-memory.md` | 本切片的持久裁决。 |
| `docs/2.0/milestones/M10/RECORD-01-memory.md` | 本记录。 |

未修改 `FarmState`、`Game/farm/*`、`Game/world/*`、`Game/scenes/*`、`Game/ui/*`、`Game/ai/*`、`PLAN.md`、规则文件或决策入口 `decisions/README.md`；决策入口由主会话统一登记。农场存档格式不变，无新增农场顶层键。

## 规则与数值

```text
人格维度         diligence / warmth / suspicion / curiosity / generosity
取值范围         0..100 整数
派生输入         ["npc_personality_v1", world_seed, npc_id, trait, index]
散列             FNV-1a（UTF-8 字节，32 位掩码），取模 101

记忆容量         每位居民 64 条
事件类型         trade / gift / conflict / weather / dialogue / observation
参与人           0..4，玩家或 NPC id，去重
摘要             1..200 字符
显著性           1..100 整数
时间             显式注入 now_utc；at_utc 不得晚于 now_utc
状态版本         state_version：0..MAX_SAFE_INTEGER
检索上限         1..64，默认 8
衰减             每满 1 天有效显著性减 1，最低 1；只用于排序
```

## 文档形状

```json
{
  "schema": 1,
  "world_id": "world-a",
  "npcs": {
    "<npc_id>": {
      "dropped": 0,
      "entries": {
        "<memory_id>": {
          "id": "<memory_id>",
          "kind": "trade",
          "participants": ["player_..."],
          "summary": "买了三份种子",
          "salience": 70,
          "at_utc": 1800000000.0,
          "world_id": "world-a",
          "state_version": 42
        }
      }
    }
  }
}
```

记录字段固定为 8 个，文档字段固定为 3 个。未知键在文档、居民行和记录三层都会拒绝，因此农场/经济字段不能混入。

## 接口

```text
Personality.traits(npc_id, world_seed)      # {ok, reason, npc_id, world_seed, traits}
Personality.valid(profile)                  # bool
Personality.describe(profile)               # {ok, reason, text} 中文短句

Memory.create(world_id)                     # {ok, reason, document}
Memory.remember(document, npc_id, event, now_utc)
Memory.retrieve(document, npc_id, options)  # options: now_utc, limit, participant, kind
Memory.effective_salience(entry, now_utc)   # 检索排序用有效显著性
Memory.validate_document(document, now_utc) # {ok, reason}
Memory.valid_document(document, now_utc)    # bool
Memory.from_document(raw, now_utc)          # 旧档缺省字段 + 严格校验
Memory.from_json(text, now_utc)
Memory.to_json(document, now_utc)
```

`remember()` 是纯规则状态变换：只修改传入文档，不读时钟、不落盘、不调模型。同一 id 再次写入返回 `ok=false, reason="duplicate"`，文档不变；同一事件内容换新 id 会存成两条，去重由调用方负责。id 在整个文档内唯一，跨居民复用也返回 `duplicate`。

## 容量与淘汰

- 每次写入后若超过 64 条，按“最低显著性 → 最旧 `at_utc` → id 升序”淘汰一条，循环到 64。
- 高显著性近期事件因此保留；低显著性新事件也可能被立即淘汰，这是有意的容量规则，不额外提升新事件权重。
- `dropped` 每淘汰一条加 1，单调不减；JSON 往返保留。
- 没有删除 API；遗忘只通过淘汰发生。

## 检索与衰减

- 排序键：`max(1, salience - floor(age / 86400))` 降序 → `at_utc` 降序 → id 升序。
- `now_utc` 显式注入；`at_utc > now_utc` 在写入和恢复时都拒绝。
- 衰减只影响排序，不改写记录中的 `salience`、`at_utc` 或任何其他字段；调用方修改返回行也不会回写文档（返回副本）。
- 支持 `participant` 与 `kind` 过滤，二者同时给出时取交集。
- 未记忆任何事件的居民返回空列表而不是错误。

## 恢复与默认值

严格拒绝：未知键、缺必需字段、越界显著性/摘要长度/参与人数、非法枚举、非法 id、重复 id（跨居民）、跨世界记录、未来 `at_utc`、负 `dropped`/`state_version`、超过 64 条的居民行、非固定 schema。

旧档缺省只限以下字段，且缺省值固定：

| 位置 | 缺失字段 | 默认值 |
|---|---|---|
| 文档 | `schema` | `1` |
| 文档 | `npcs` | `{}` |
| 居民行 | `dropped` | `0` |
| 居民行 | `entries` | `{}` |
| 记录 | `world_id` | 文档 `world_id` |
| 记录 | `state_version` | `0` |
| 记录 | `participants` | `[]` |

`summary`、`kind`、`salience`、`at_utc`、`id` 始终必需。JSON 解析后的整数值会归一化为 `int`，`at_utc` 归一化为 `float`。

## 与 AI 的边界

- 记忆是规则文档，不是模型内隐状态；模型不能直接写入、覆盖或删除记忆。
- 模型建议必须先由规则层接受为世界事件，规则事件调用方再显式调用 `remember()` 提交一条记忆。
- `retrieve()` 的结果只是“可见上下文”；模型不得据此虚构成交、权属或承诺，账本与世界事实仍由既有权威规则裁定。
- 本切片不调用模型、不生成对话、不改变世界状态、不新增网络消息或命令。

## 测试

无头运行（本机）：

```text
NPC_MEMORY_TEST checks=202 failures=0
```

覆盖：人格同输入同输出、跨世界/跨 id 差异、非法 id/种子/维度拒绝、中文描述确定性；记忆写入与字段固定、同 id `duplicate`、不同 id 相同内容不合并、跨居民重复 id 拒绝；容量 64、最低显著性/最旧淘汰、`dropped` 单调、高显著性保留；检索排序（衰减、时间、id 平局）、上限、参与者/类型过滤、返回副本、衰减不改原记录、非法选项拒绝；JSON 往返、未知键、重复 id、跨世界、未来时间、负计数、超容量、旧档缺省字段；文档/记录不含 farm/economy 字段。

## 未覆盖

- 真实林婶、许伯、阿舟的行为接线与身份故事校验；
- 规则事件来源与 `remember()` 调用方（市场、赠礼、冲突、天气、对话管线）；
- 模型摘要、模型可见上下文裁剪、模型建议转事件；
- 多人同步、世界迁移携带、隐私导出过滤；
- 场景/UI 展示、Windows 实机与 CI；
- 记忆删除/遗忘请求、主观评价与承诺来源分层（属 M10-02）。
