# M10-03 · 居民意图与预算校验（最小切片）

执行日期：2026-11-15。状态：切片完成，不表示 M10-03 或 M10 验收完成。前置：[M10 PLAN](PLAN.md)、[M10-01 人格与有界记忆](RECORD-01-memory.md)、[M10-02 居民名册](RECORD-02-roster.md)、[M10-03 记忆适配层](RECORD-03-memory-feed.md)。

## 问题

M10-03 要求“有限目标选择、状态校验、冷却与失败后等待，先交易再扩展拜访”，验收判据是“阿舟用真实预算采购；重复或过期意图不重复成交”。此前的 M10 切片只有人格、名册和记忆适配，没有任何“居民想做什么、能不能做”的规则。

本切片先冻结自主行动的第一层：从只读上下文生成一个买入意图，并在执行前用同一上下文重新校验。它不调用模型、不接网络、不改存档、不改 UI，也不真正下单或划转现金，目的是让后续“阿舟用真实预算采购”有一个可复测的规则边界。

## 边界

- 新增 `Game/npc/npc_intent.gd` 与 `tests/npc_intent_test.gd`。
- 未修改 `Game/farm/*`、`Game/world/*`、`Game/ui/*`、`Game/scenes/*`、`Game/ai/*`、其他 `tests/*`、`main.gd`、`.github/workflows` 或农场存档格式。
- 无 RNG、无系统时钟、无磁盘、无场景、无网络；所有入口显式接收 `now_utc`，同一输入得到同一输出。
- 不读取 `FarmState`，不写市场/银行/农场数据，不冻结余额、不执行订单、不移动货物。
- 人格与记忆摘要不参与本切片的目标选择，因此没有加入上下文契约；需要它们影响意图时再扩键。

## 上下文契约

调用方从权威状态投影出最小只读上下文。未知键一律拒绝，避免完整存档、命令结果或场景对象混入规则层。

```text
{
  resident: {
    id: String,                         # OwnerIds.valid
    cash: int >= 0,                     # 本人可用现金
    bag: {good_id: int >= 0},           # 仅经济目录商品 -> 本人口袋数量
  },
  market: {
    orders: [                           # 仅公开卖单；调用方已剔除关闭/隐藏行
      { good: good_id, price: int > 0, remaining: int > 0 },
    ],
  },
  cooldowns: {
    until_utc: float >= 0,              # 居民下次可行动时刻；0 表示可用
    intents: { intent_id: float >= 0 }, # 已消费意图 id -> 消费时刻
  },
}
```

`price` 与 `remaining` 来自真实公开卖单；本模块不读取目录基价来编造报价。`bag` 只投影经济目录商品，非目录物品不属于本契约。

## 意图形状

```text
{
  id: "intent_<fnv1a>",
  kind: "buy",
  good: good_id,
  quantity: int > 0,
  price: int > 0,          # 限价上限，取所选公开卖单的当前价格
  reason: "restock",
  expires_utc: float,      # plan 的 now_utc + 120 秒
}
```

- **id 确定性**：`FNV-1a(["npc_intent_v1", 居民 id, 商品 id, 过期毫秒])`。同一输入得到同一 id；不依赖随机数、字典遍历顺序或全局状态。
- **过期边界**：`now_utc >= expires_utc` 即过期，与市场订单的到期判定一致。
- **冷却表**：`cooldowns.intents` 是已消费意图的唯一持久化入口；本模块只读，调用方在订单成功后记录 id。同一 id 再次校验返回 `duplicate_intent`。

## 规则

### plan

1. 校验时间与上下文；居民处于冷却中返回 `cooldown`。
2. 没有公开卖单返回 `no_supply`。
3. 候选 = 卖单商品中本人口袋数量为 0 的商品；没有候选返回 `nothing_needed`。
4. 选择最便宜的候选；同价按商品 id 升序，再按卖单剩余降序，输入顺序不影响结果。
5. 现金低于单价返回 `no_cash`。
6. 数量 = `min(现金 // 单价, 所选卖单剩余, 目录数量上限)`；结果不大于 0 时返回 `no_cash`。
7. 返回意图；不扣现金、不占货、不写冷却表。

### validate

按顺序拒绝：时间/上下文不合法、意图形状/枚举/商品/数量/价格/过期字段不合法、id 与确定性派生不符、已过期、冷却表已消费该 id、居民冷却中、数量 × 限价超过现金、限价内已无该商品供给、数量超过限价内剩余供给。

成功只返回 `{ok: true, reason: ""}`。校验不修改意图或上下文；执行、记账和冷却写入属于调用方。

### 具名原因

| 场景 | reason |
|---|---|
| 居民冷却未结束 | `cooldown` |
| 没有公开卖单 | `no_supply` |
| 卖单商品本人都已有货 | `nothing_needed` |
| 现金不足一份 | `no_cash` |
| 意图已过期 | `expired` |
| 同一 id 已消费 | `duplicate_intent` |
| 上下文/时间/字段不合法 | `invalid_context`、`invalid_time`、`invalid_resident`、`invalid_bag`、`invalid_market`、`invalid_cooldowns`、`invalid_intent`、`invalid_kind`、`invalid_good`、`invalid_quantity`、`invalid_price`、`invalid_expiry`、`invalid_intent_id` |
| 预算不足 | `insufficient_cash` |
| 限价内无供给 / 数量超过剩余 | `price_above_market`、`insufficient_supply` |

## 改动

| 文件 | 内容 |
|---|---|
| `Game/npc/npc_intent.gd` | 新增纯规则模块：上下文校验、买入意图生成、执行前复校验、确定性 id |
| `tests/npc_intent_test.gd` | 新增夹具，49 项无头检查 |
| `docs/2.0/milestones/M10/RECORD-04-intent-rules.md` | 本记录 |

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/npc_intent_test.gd"
```

原始末行：

```text
NPC_INTENT_TEST checks=49 failures=0
```

覆盖矩阵：

| 用例 | 检查 |
|---|---|
| 正常采购 | 有供给与现金时生成买入意图；限价取真实卖单价；数量受现金、卖单剩余约束；多目标选最便宜；同价按商品 id 稳定选择 |
| 无目标 | `no_cash`（零现金与不足一份）、`no_supply`、`nothing_needed` |
| 冷却 | 规划阶段拦截；边界时刻放行；执行前校验同样拦截 |
| 过期 | 过期前一秒通过；到达过期时刻与之后拒绝 |
| 重复 | 冷却表已含同一 id 时 `duplicate_intent` |
| 非法意图 | 零/负/小数/超上限数量、零价格、错误 kind、目录外商品、非法过期时刻、篡改 id、额外键 |
| 预算与市场 | 数量 × 限价超过现金、限价低于全部卖单、数量超过剩余供给、目标已无卖单 |
| 确定性 | 同输入同意图与同 id；卖单顺序变化不改选择；不同时刻不同 id；生成后立即复校验通过 |
| 上下文 | 空上下文、额外键、负现金、目录外口袋商品、零价卖单、负冷却时刻、负规划时刻 |

## 未覆盖

- 模型调用与自然语言：没有提示词、生成、解释或人格化文案；`reason` 只是稳定规则码。
- 网络与权威接线：没有 `HeadlessWorld` 加载、`WorldHost` 命令入口、客户端 RPC、权限门或成员/访客角色判断。
- 存档：意图与冷却表都不进入农场 v27 文档；没有 sidecar、跨重启恢复或损坏恢复。冷却表的持久化位置留给后续切片。
- 真实执行：不扣现金、不冻结余额、不占用卖单剩余、不发货、不记账；`validate` 通过不等于订单成交。价格变动、部分成交和并发抢单仍由后续执行层处理。
- 目标选择：只买一种本人袋中为空的商品；没有多商品篮子、数量需求曲线、人格/记忆权重、关系折扣或卖家选择。意图不绑定具体卖单 id，只以限价和汇总剩余校验。
- 冷却策略：没有按商品或按居民的活动间隔规则；`until_utc` 由调用方决定。
- UI、可玩性观察与 Windows/CI：未覆盖。

## 关联

- 阶段计划：[M10 PLAN](PLAN.md)。
- 前置规则：[M10-01 人格与有界记忆](RECORD-01-memory.md)、[M10-02 居民名册](RECORD-02-roster.md)、[M10-03 记忆适配层](RECORD-03-memory-feed.md)。
- 市场契约：`Game/farm/market_state.gd` 的公开卖单与 `MAX_QUANTITY`/`MAX_PRICE`；商品目录：`Game/farm/economy_catalog.gd`。
