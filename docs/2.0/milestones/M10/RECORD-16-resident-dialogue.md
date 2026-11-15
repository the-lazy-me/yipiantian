# M10-04 · 居民确定性对话规则（纯规则切片）

执行日期：2026-11-16。状态：切片完成，不表示 M10-04 或 M10 验收完成。前置：[M10 PLAN](PLAN.md)、[居民人格](RECORD-02-roster.md)、[有界记忆](RECORD-01-memory.md)、[自发社交](RECORD-08-social.md)、[邀约规则](RECORD-09-invitations.md)、[AI 系统对话分层](../../06-AI-SYSTEM.md)。

## 问题

`06-AI-SYSTEM.md` 要求端侧小模型只处理“短对话、有限意图选择、记忆摘要”，并且模型建议必须能退回规则行为。M10 已有派生人格、关系文档、固定社交动作、有界记忆和可拒绝邀约，但还没有“玩家说一类话时，居民如何确定性回应”的规则层。若直接接模型，模型会同时决定语气、关系变化和记忆写入，在没有规则兜底时无法验证“不编造资产事实”和“关系有界”。

本切片只冻结最小规则层：把玩家话语归入固定类别，按人格与关系在一小组固定模板中选择回复倾向，输出有界的关系增量、冷却原因和一条只含结构化事实的记忆摘要。它不调用模型，不接权威或 UI，不生成自由文本，也不产生任何资产、价格、商品或权属事实。

## 边界

- 新增 `Game/npc/npc_dialogue.gd`、`tests/npc_dialogue_test.gd`、本记录。
- 未修改任何既有文件；不碰 `Game/world/**`、`Game/farm/**`、`Game/ui/**`、`Game/scenes/**`、`.github/`、`PLAN.md`、`rules/`。
- 纯静态规则：无 RNG、无系统时钟、无磁盘、无场景、无网络；两个入口都显式接收 `now_utc`，同一输入得到同一输出。
- 只读输入：人格（真实 `NpcPersonality` 档案或 `npc_id + world_seed`）、关系投影（与 `NpcSocial.PEER_KEYS` 同形状）、对话状态（类别、最近对话时刻、当日累计、可见事实）。不修改任何输入。
- 输出只有固定模板 id、语气、有界增量、记忆种类/摘要与事实引用；不返回叙事正文。
- 不创建邀约、不执行拜访、不扣款、不移动货物、不改账户或权属；`invite` 只代表口头回应“会考虑”，实际邀约仍走 `npc_invitation.gd`。

## 为什么是这七类

| 类别 | 含义 | 入选理由 |
|---|---|---|
| `greet` | 问候 | 打开对话的最小入口，不需要任何世界事实。 |
| `farewell` | 告别 | 关闭对话，不需要世界事实，关系增量为 0。 |
| `apologize` | 道歉 | 已有同义社交动作，只影响关系，不需要资产叙述。 |
| `thank` | 道谢 | 同上，回应只需固定模板。 |
| `ask_work` | 问农事 | 农事是既有权威状态，可回答“有记录/未记录”，不必编造作物或数量。 |
| `ask_market` | 问行情 | 公开价格是既有可见事实，未传入时用“没有记录”模板。 |
| `invite` | 邀约 | `npc_invitation.gd` 已定义关系/人格门限，这里只决定口头回应。 |

未进入第一批的类别都需要规则层编造事实或承诺：买卖成交、任务派发、天气、私密传闻、他人评价。模型以后可以在这些扩展里提出结构化意图，但仍需先经权威校验。

## 输入契约

关系投影必须与 `NpcSocial.PEER_KEYS` 完全一致（未知键拒绝）：

```text
{
  "affinity": 0,          # -100..100 整数
  "last_utc": 0.0,        # 最近社交时刻，不得晚于 now_utc
  "gifts": 0,             # 0..NpcSocial.MAX_GIFTS_PER_PEER
  "acts": 0,              # 0..NpcSocial.MAX_ACTS_PER_PEER
}
```

对话状态（恰好四个键）：

```text
{
  "category": "greet",        # CATEGORIES 之一
  "last_dialogue_utc": 0.0,   # 0 表示从未对话，否则不得晚于 now_utc
  "daily_affinity": 0,        # 当日已获得的关系增量，0..MAX_DAILY_AFFINITY
  "visible": {                # 可为空；只接受固定键与有界标量
    "market_price": 12,       # 可选，0..MAX_VISIBLE_PRICE
    "work_recorded": true,    # 可选，bool
  },
}
```

## 输出契约

```text
{
  "ok": true,
  "reason": "",
  "category": "greet",
  "reply_kind": "reply_greet_warm",   # REPLY_KINDS 之一
  "tone": "warm",                     # warm / neutral / guarded
  "affinity_delta": 1,                # 0..MAX_DIALOGUE_DELTA
  "affinity_after": 51,               # 夹在 -100..100
  "daily_affinity_after": 1,          # 夹在 0..MAX_DAILY_AFFINITY
  "capped_reason": "",                # "" / "daily" / "affinity"
  "memory_kind": "dialogue",          # 复用 NpcMemory.KIND_DIALOGUE
  "memory_summary": "玩家向我问候，我作了回应。",
  "cooldown_reason": "",
  "fact_refs": {},                    # 只含本次模板引用的可见事实
}
```

拒绝只返回 `{ok: false, reason, cooldown_reason}`，不携带任何增量、模板或记忆字段。

## 规则表与数值理由

| 类别 | 基础 affinity 增量 | 模板 |
|---|---|---|
| `greet` | +1 | warm / neutral / guarded 三选一 |
| `ask_work` | +1 | 有记录 / 未记录 |
| `ask_market` | +1 | 有记录 / 未记录 |
| `apologize` | +2 | 接受 / 暂不接受 |
| `thank` | +1 | 高慷慨 / 普通 |
| `invite` | +2 | 会考虑（不承诺成行） |
| `farewell` | 0 | 告别 |

- **单次上限 `MAX_DIALOGUE_DELTA = 2`**：一次对话的分量应低于赠礼（4）与社交道歉（5），也低于 `NpcInvitation` 的关系影响，避免聊天成为刷关系的最快路径；`farewell` 固定 0，避免刷告别。
- **对话冷却 `COOLDOWN_SECONDS = 600`**：比社交动作的 `greet` 冷却（300 秒）更慢，因为对话由玩家直接触发、没有居民日程约束；同一居民对同一玩家每 10 分钟最多一次有效对话，冷却中返回 `cooldown` 且无副作用。
- **单日上限 `MAX_DAILY_AFFINITY = 5`**：即每日最多 3 次道歉或 5 次问候；从 0 到 100 仅靠对话需 20 天，关系增长仍以自发社交与赠礼为主。日额度由调用方投影传入，本模块不保存跨日计数，也不读系统时钟。
- **语气阈值**：先判警戒再判温和。`affinity <= -20` 或 `suspicion >= 65` 为 `guarded`；否则 `affinity >= 20` 且 `warmth >= 55` 为 `warm`；其余 `neutral`。这样高多疑的居民不会因高亲和被朗读成热情，人格参与但不越界。
- **道歉是否接受**：`suspicion >= 70` 且 `affinity <= 0` 时暂不接受（`reply_apology_withheld`），否则接受。阈值高于警戒线，表示“道歉能缓和，但多疑者要先观察”。
- **道谢模板**：`generosity >= 60` 用高慷慨模板，否则普通模板。
- **邀约门限**：直接复用 `NpcSocial.INVITE_MIN_AFFINITY = 20`、`INVITE_MIN_WARMTH = 50`、`INVITE_MIN_CURIOSITY = 50`；低于关系返回 `low_affinity`，温和与好奇都不足返回 `not_inclined`，不产生增量或记忆。
- **可见事实上限 `MAX_VISIBLE_PRICE = 1000000`**：只是 UI 展示边界，防止异常数值直接进入摘要；本模块不计算价格，只引用调用方传入的公开值。

## 记忆摘要

摘要只由固定短句与 `visible` 中的标量组成，不读取记忆正文，不拼接玩家原文：

| 类别 | 摘要 |
|---|---|
| `greet` | `玩家向我问候，我作了回应。` |
| `ask_work` 有记录 / 未记录 | `玩家问起农事，我回答有记录。` / `玩家问起农事，我回答没有记录。` |
| `ask_market` 有价格 / 未记录 | `玩家问起行情，我回答最近价格为 N。` / `玩家问起行情，我回答没有记录。` |
| `apologize` 接受 / 暂不接受 | `玩家向我道歉，我接受。` / `玩家向我道歉，我暂未接受。` |
| `thank` | `玩家向我道谢，我作了回应。` |
| `invite` | `玩家邀我做客，我表示会考虑。` |
| `farewell` | `玩家与我道别。` |

`fact_refs` 只复制本次模板真正引用的字段（`work_recorded` 或 `market_price`），不会把未引用的可见事实带进记忆或 UI。

## 具名原因

| 场景 | reason | cooldown_reason |
|---|---|---|
| 当前时刻非法 | `invalid_time` | `""` |
| 居民 id / 世界种子非法 | `invalid_npc_id` / `invalid_seed` | `""` |
| 人格形状非法 | `invalid_traits` | `""` |
| 关系投影非法 | `invalid_relation` | `""` |
| 对话状态形状非法 | `invalid_speech` / `invalid_category` / `invalid_visible` | `""` |
| 最近对话时刻在未来 | `invalid_time` | `""` |
| 冷却中 | `cooldown` | `cooldown` |
| 关系低于邀约门限 | `low_affinity` | `""` |
| 人格不足以回应邀约 | `not_inclined` | `""` |

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian && \
perl -e 'alarm shift; exec @ARGV' 180 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/npc_dialogue_test.gd"
```

原始末行：

```text
NPC_DIALOGUE_TEST checks=169 failures=0
```

覆盖矩阵：

| 用例 | 检查 |
|---|---|
| 常量与模板 | 七类唯一；每类真实输入产生的 `reply_kind` 都在 `REPLY_KINDS` 内；增量表只含已知类别且不超过单次上限；告别为 0；冷却不短于社交问候 |
| 确定性 | 同输入两次 JSON 逐字节相同；关系字段顺序不影响结果；`npc_id + world_seed` 入口与显式人格入口一致 |
| 上下限与日上限 | 日额度剩余 1 时道歉截断为 1 并报告 `daily`；额度用尽为 0 且仍可对话；接近/到达上界夹紧并报告 `affinity`；下界道歉有界恢复；单次增量不超过 2 |
| 冷却 | 冷却中拒绝且无副作用；边界时刻放行；从未对话不触发；未来时刻拒绝 |
| 人格倾向 | 高温和 + 高关系 = warm；中等人格 = neutral；低关系或高多疑 = guarded；高慷慨道谢 = warm 模板；高多疑 + 低关系暂不接受道歉；人格不改变固定增量 |
| 邀约门限 | 关系低于 20 拒绝；低温和且低好奇拒绝；满足时只回“会考虑”；高好奇可替代温和 |
| 拒绝路径 | 目录外类别、额外/缺失键、日累计越界、关系越界/非整数/缺键/超限、未来关系时刻、非法/无限当前时刻、缺人格维度/越界、非法 id/种子均具名拒绝，且不返回记忆字段 |
| 记忆摘要 | 无农事/行情事实时写“没有记录”；有事实时只引用传入标量；`fact_refs` 只含被引用字段；可见事实未知键、负价、超上限、字符串价、非布尔标记均拒绝 |
| 真实接口对接 | 用 `NpcSocial.apply()` 生成真实关系行，投影为 `PEER_KEYS` 形状后通过 `valid_relation`；社交原始行形状被拒绝；`Personality.traits()` 的真实档案通过 `Personality.valid()` 并可对话；结果沿用 `Social` 的上下界与固定增量 |

## 未覆盖

- **模型**：没有提示词、自然语言生成、意图分类器或模型摘要；类别与模板都是固定枚举。
- **权威与网络**：没有接入 `HeadlessWorld` / `WorldHost`，没有持久化对话状态（`last_dialogue_utc`、`daily_affinity` 由调用方投影并在成功后自行写入），没有 RPC、权限门或世界隔离。
- **UI**：没有对话面板、输入框、模板文案排版；`reply_kind` 到中文正文的映射留给 UI 或后续切片。
- **真实拜访**：`invite` 只产生口头回应，不创建 `NpcInvitation` pending、不移动场景、不生成餐食。
- **关系负向变化**：所有类别增量非负；低关系只改变语气，不会让关系继续恶化。
- **跨日重置**：本模块信任调用方传入的 `daily_affinity`，不判断 UTC 日界，也不保存历史。
- **Windows**：只在 macOS 无头模式验证，未覆盖 Windows 路径或实机。

## 关联

- [M10 PLAN](PLAN.md)
- [有界记忆](RECORD-01-memory.md)
- [居民名册与派生人格](RECORD-02-roster.md)
- [居民自发社交](RECORD-08-social.md)
- [邀约规则](RECORD-09-invitations.md)
- [居民邀约与权威裁决](RECORD-15-resident-invitations.md)
- [AI 系统](../../06-AI-SYSTEM.md)
