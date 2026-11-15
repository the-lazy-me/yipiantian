# M10-04 · 居民自发社交（纯规则切片）

执行日期：2026-11-15。状态：切片完成，不表示 M10-04 或 M10 验收完成。前置：[M10 PLAN](PLAN.md)、[M10-02 居民名册](RECORD-02-roster.md)、[M10-03 意图与预算校验](RECORD-04-intent-rules.md)、[M10-04 居民角色权限](RECORD-07-resident-roles.md)。

## 问题

M10-04 要求“扩展角色与社会事件”，验收判据是“NPC 邀约可拒绝，模型不凭叙述改变权属”。此前切片已经有人格、名册、记忆和角色权限，但居民还没有任何“可以主动做哪种社交动作、对谁做、多久能做一次”的规则；也没有一份可复现的关系文档来记录亲密度和赠礼次数。

本切片冻结自发社交的第一层：从只读上下文确定性地选择一个固定动作与对象，在执行前复校验，并生成写时复制的关系文档候选。它不调用模型、不接网络、不改存档、不改 UI，也不真正赠礼、扣款或改变任何权属。

## 边界

- 新增 `Game/npc/npc_social.gd`、`tests/npc_social_test.gd` 与 [RECORD-08](RECORD-08-social.md) 本身。
- 未修改 `PLAN.md`、`rules/project-context.md`、`.github/workflows`、`Game/farm/*`、`Game/world/*`、`Game/ui/*`、`Game/scenes/*`、`Game/ai/*`、`WorldHost`、`HeadlessWorld`、`main.gd`、其他 `tests/*` 或农场存档格式。
- 纯静态规则：无 RNG、无系统时钟、无磁盘、无场景、无网络；`plan` / `validate` / `apply` 都显式接收 `now_utc`，同一输入得到同一输出。
- 不读取 `FarmState`，不写市场、银行、账户或账本；社交文档只记录关系、动作时刻与赠礼次数。
- 动作只会改变关系文档中的 `affinity`、时刻和计数，不授予财产、权属、账户或命令权限；`claim_from_narrative()` 永远返回 `not_authority`。
- 不接模型、UI、`WorldHost` 或真实赠礼扣款；赠礼只是文档中的一次意图记录。

## 动作目录

动作来自固定枚举，不接受自由文本作为权威内容：

| 动作 | 含义 | 固定冷却 | affinity 增量 |
|---|---|---|---|
| `greet` | 打招呼 | 300 秒 | +1 |
| `gift` | 赠送口头礼物/小额赠礼意图 | 1800 秒 | +4 |
| `invite` | 邀请来访 | 3600 秒 | +2 |
| `apologize` | 道歉 | 1800 秒 | +5 |

`apply` 把 affinity 结果夹在 `-100..100`。赠礼以固定 1 份计量，每对关系最多 `MAX_GIFTS_PER_PEER = 8` 次；本切片不记录金额、不扣款、不执行真实赠送。

## 上下文契约

调用方从权威状态投影出最小只读上下文，未知键一律拒绝：

```text
{
  resident: {
    id: OwnerIds.valid,
    traits: {diligence, warmth, suspicion, curiosity, generosity},  # 恰好五维，0..100
    relations: {
      peer_id: {
        affinity: int -100..100,
        last_utc: float >= 0,      # 最近一次对该对象的社交
        gifts: int 0..8,           # 已赠礼次数
        acts: int 0..16,           # 已记录动作数
      },
    },                             # 最多 32 位对象
  },
  cooldowns: {
    actions: {kind: float >= 0},   # 动作种类 -> 最近执行时刻
    acts: {act_id: float >= 0},    # 已消费 act id -> 执行时刻
  },
  limits: {
    gift_remaining: int >= 0,      # 可赠礼余额上限（剩余份数）
  },
}
```

人格与关系只影响选择，不被本模块改写；上下文在本切片不被持久化。

## 关系文档形状

```text
{
  "relations": {
    "<npc_id>": {
      "<peer_id>": {
        "affinity": 0,                    # -100..100 整数
        "last_utc": 0.0,                  # 最近社交时刻
        "acts": {"social_123": 0.0},      # act id -> 执行时刻
        "gifts_utc": [0.0],               # 赠礼时刻，非降序
      },
    },
  },
  "actions": {
    "<npc_id>": {"greet": 0.0},           # 动作种类 -> 最近执行时刻
  },
}
```

- 根键恰好 `relations` / `actions`；关系行恰好 `affinity` / `last_utc` / `acts` / `gifts_utc`。
- 上限：`MAX_RESIDENTS = 16` 名发起者 × 每位 `MAX_PEERS = 32` 个对象；每对关系最多 `MAX_ACTS_PER_PEER = 16` 条动作、`MAX_GIFTS_PER_PEER = 8` 次赠礼。
- `affinity` 必须是 `-100..100` 的整数；JSON 往返中的整值 float 也接受。
- 所有时刻有限、非负且不超过安全整数；每条动作/赠礼时刻不晚于该关系的 `last_utc`，赠礼时刻必须非降序。
- `actions` 的每个发起者必须已有关系行，动作种类必须来自固定目录，动作时刻不晚于该居民任一关系的最近社交时刻。
- 未知键、越界、超限、非整数 affinity、超长或非字符串 act id 一律拒绝。

## 规则

### plan

1. 校验时间与上下文；没有对象返回 `nothing_to_do`。
2. 按固定优先级选择：`apologize` -> `gift` -> `invite` -> `greet`。
3. `apologize`：存在 affinity `<= 0` 的对象时，选择 affinity 最低者。
4. `gift`：可赠礼余额大于 0、generosity `>= 50`、且存在 affinity `< 80` 且未达赠礼上限的对象时，选择 affinity 最低者。
5. `invite`：warmth `>= 50` 或 curiosity `>= 50`，且存在 affinity `>= 20` 的对象时，选择 affinity 最高者。
6. `greet`：选择 `last_utc` 最久远者。
7. 同值按 peer id 升序打破平局；对象字典顺序不影响结果。
8. 没有可用动作返回具名 `nothing_to_do`；不产生随机。

动作形状固定为：

```text
{id: "social_<fnv1a>", kind, from, to, expires_utc}
```

id 由 `FNV-1a(["npc_social_v1", from, to, kind, 过期毫秒])` 确定性派生；有效期是规划时刻加 120 秒。

### validate

按顺序拒绝：时间/上下文、动作形状、确定性 id、动作种类、发起者、对象、过期、已消费 id、动作冷却、动作数/赠礼数上限、赠礼余额。成功只返回 `{ok: true, reason: ""}`，不修改输入。

### apply

按顺序拒绝：时间、文档、动作形状、对象、过期、重复 id、动作冷却、动作数/赠礼数/居民数/对象数上限。成功时深拷贝输入并：

1. 把 affinity 增加固定增量，结果夹在 `-100..100`；
2. 把 `last_utc` 推进到 `max(原值, now_utc)`；
3. 写入 act id、动作种类最近时刻和赠礼时刻；
4. 再次用 `valid()` 检查候选文档。

失败只返回 `{ok: false, reason}`，不带候选文档，也不修改输入。同一 act id 重放返回 `duplicate_intent`，不重复增加关系。

### 具名原因

| 场景 | reason |
|---|---|
| 规划无可用动作 | `nothing_to_do` |
| 时间不合法 | `invalid_time` |
| 上下文形状/字段不合法 | `invalid_context`、`invalid_resident`、`invalid_traits`、`invalid_relations`、`invalid_cooldowns`、`invalid_limits` |
| 动作形状/字段不合法 | `invalid_act`、`invalid_act_id`、`invalid_kind`、`invalid_from`、`invalid_target`、`invalid_expiry` |
| 动作已过期 | `expired` |
| 同一 act id 已消费 | `duplicate_intent` |
| 动作冷却未结束 | `cooldown` |
| 动作/居民/对象数达到上限 | `over_capacity` |
| 赠礼次数达到上限 | `gift_cap` |
| 可赠礼余额不足 | `insufficient_gift` |
| 关系文档不合法 | `invalid_document` |
| 候选文档未通过不变式 | `invalid_state` |
| 叙事声称权属/授权 | `not_authority` |

## 叙事与权限边界

- 社交动作不修改任何财产、权属、账户或命令权限；候选文档只有关系字段。
- `claim_from_narrative(actor, claimed_action)` 与 M10-04 角色矩阵同一原则：无论叙述声称“我把地送给你”“我授权你付款”，都返回 `ok=false, reason="not_authority", authority=false, proposal_only=true`。
- 叙事只能作为提案；真正的权属和命令仍须走既有权威与角色准入路径。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/npc/npc_social.gd` | 新增纯规则模块：上下文/关系文档严格校验、确定性动作规划、执行前复校验、写时复制的关系写入、叙事不授权入口 |
| `tests/npc_social_test.gd` | 新增无头夹具，121 项检查 |
| `docs/2.0/milestones/M10/RECORD-08-social.md` | 本记录 |

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian && \
perl -e 'alarm shift; exec @ARGV' 180 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/npc_social_test.gd"
```

原始末行：

```text
NPC_SOCIAL_TEST checks=121 failures=0
```

覆盖矩阵：

| 用例 | 检查 |
|---|---|
| 空文档 | 空关系文档合法；null/数组/空字典被拒绝 |
| JSON 往返 | 空文档与含赠礼文档均可解析回合法文档；归一后 JSON 一致 |
| plan 选择 | 负关系道歉、非负关系赠礼、外向缺余额邀请、兜底打招呼；对象按 affinity / last_utc 与 id 稳定选择 |
| 确定性 | 同上下文同动作同 id；对象字典顺序不影响结果；不同时刻不同 id |
| 冷却 | 边界前一秒返回 `nothing_to_do`；边界时刻放行；全部动作冷却中返回 `nothing_to_do` |
| validate | 合法通过；目录外动作、未知/自己对象、错误发起者、过期、重复 id、冷却、动作数上限、赠礼上限、余额不足、篡改 id、额外键、非法时间均具名拒绝 |
| affinity | 上界夹到 100；下界动作后有界恢复；101/-101/非整数拒绝；整值 JSON float 合法 |
| 上限 | 满额动作/赠礼/居民/对象文档合法，写入超限返回 `over_capacity` 或 `gift_cap` |
| apply | 关系增量、时刻、动作 id、动作种类时刻正确；重复重放不重复加关系；冷却边界；赠礼记录；非法文档 |
| 写时复制 | apply 不修改输入；候选与输入深拷贝隔离；失败不带候选文档 |
| 严格 valid | 未知根键/关系行键、缺字段、目录外动作、自我关系、动作晚于最近社交、赠礼乱序、各层超限、非法 id、孤立动作记录均拒绝 |
| 上下文 | 未知键、缺人格维度、人格/关系越界、目录外冷却、负余额、对象超限均具名拒绝 |
| 叙事 | 权属/授权声明永远 `not_authority`，只作为提案；非字符串声明同样不授权 |

## 未覆盖

- **未接模型**：没有提示词、自然语言生成、解释或人格化文案；动作只有固定枚举。
- **未接网络与权威**：没有 `HeadlessWorld`、`WorldHost` 命令入口、客户端 RPC、权限门或成员/访客角色判断。
- **未接存档**：关系文档不进入农场存档或 sidecar，没有跨重启恢复、损坏恢复或世界隔离。
- **未实现拒绝流程**：邀约可以被规则层规划，但没有被邀请方接受/拒绝、过期邀请清理或事件通知；“NPC 邀约可拒绝”仍待后续切片。
- **未实现真实赠礼**：不扣现金、不检查库存、不移动物品、不记账；`gift_remaining` 由调用方投影，本模块不维护余额。
- **未持久化冷却**：动作冷却和已消费 id 只存在于上下文/文档中，由调用方负责在成功后写入；本模块不写 sidecar。
- **未建模关系衰减、冲突或传闻**：affinity 只按固定增量变化，不从记忆/事件推导，也不会自动下降。
- **未接 UI、可玩性观察、Windows 实机或 CI**：测试尚未加入 `.github/workflows`。

## 关联

- 阶段计划：[M10 PLAN](PLAN.md)。
- 前置切片：[M10-02 居民名册](RECORD-02-roster.md)、[M10-03 意图与预算校验](RECORD-04-intent-rules.md)、[M10-03 意图执行账本](RECORD-05-intent-state.md)、[M10-04 居民角色权限](RECORD-07-resident-roles.md)。
- 权威设计：[AI 系统](../../06-AI-SYSTEM.md)。
- 叙事不授权原则：`Game/npc/npc_roles.gd` 的 `claim_from_narrative()`。
