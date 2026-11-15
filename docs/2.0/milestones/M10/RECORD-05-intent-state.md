# M10-03 · 意图执行账本（最小切片）

执行日期：2026-11-15。状态：切片完成，不表示 M10-03 或 M10 验收完成。前置：[M10 PLAN](PLAN.md)、[M10-03 意图与预算校验](RECORD-04-intent-rules.md)。

## 问题

RECORD-04 只提供 `plan`/`validate`：意图可以通过执行前校验，但没有任何地方记录“这个意图已经消费过”，也没有任何地方回答“居民现在是否还在冷却”。执行层如果自己临时维护这两件事，重复 id 和冷却就会散落在调用方，重启后也无法恢复。

本切片冻结自主行动的第二层：一个纯规则的意图执行账本，明确冷却判定、成功消费的记账语义和有界淘汰，并为后续 `HeadlessWorld` 接线提供独立 sidecar。它不接网络、不接 `FarmState`、不写真实市场，也不执行订单。

## 边界

- 新增 `Game/npc/npc_intent_state.gd`、`Game/npc/npc_intent_store.gd` 与 `tests/npc_intent_state_test.gd`。
- 新增 [RECORD-05](RECORD-05-intent-state.md) 本身；只改 [M10 PLAN](PLAN.md) 的“当前进展”一行。
- 未修改 `Game/farm/*`、`Game/world/*`、`Game/ui/*`、`Game/scenes/*`、`Game/ai/*`、其他 `tests/*`、`main.gd`、`.github/workflows`、农场存档格式或 `rules/project-context.md`。
- 无 RNG、无系统时钟、无场景、无网络；`now_utc` 显式传入，同一输入得到同一输出。
- 不读取 `FarmState`，不写市场/银行/农场数据；账本只描述“已消费哪些意图”和“居民何时可再行动”。
- 本切片不接入主循环，也不被 `HeadlessWorld` 调用；接线留给后续切片。

## 文档形状

```text
{
  until_utc: float >= 0,                  # 居民下次可行动时刻；0 表示可用
  intents: {                              # 已消费意图 id -> 消费时刻
    "intent_<fnv1a>": float >= 0,
  },
}
```

与 `npc_intent.gd` 只读上下文的 `cooldowns` 同形，调用方可以直接把账本投影进去，不需要转换字段。JSON 数字统一按 float 归一。

字段约束：

- 文档恰好两个键：`until_utc`、`intents`；未知键一律拒绝，避免旧权威静默丢掉未来字段。
- `until_utc` 与每条消费时刻都在 `[0, 2^53-1]` 内且有限。
- 意图 id 是非空字符串，长度不超过 128。
- 记录数不超过 256。
- 不变式：每条消费时刻不大于 `until_utc`。账本不会记录“冷却结束前就消费”的历史，`valid()` 强制该约束。

## 规则

### valid

严格校验形状、键集、时间范围、id 形状、记录上限和上述不变式。空账本 `{until_utc: 0.0, intents: {}}` 合法。

### cooling

`cooling(state, now_utc)` 返回 `{ok, reason, cooling, until_utc}`。`cooling` 为真表示 `now_utc < until_utc`。文档或时间不合法时失败关闭（`ok:false`、`cooling:true`），调用方必须先看 `ok`。

### record

`record(state, intent_id, at_utc, until_utc)` 返回 `{ok, reason, state}`，其中 `state` 是候选文档，输入不被修改。按顺序拒绝：

1. 文档不合法 -> `invalid_state`。
2. `at_utc` 或新的 `until_utc` 不合法 -> `invalid_time`。
3. id 非字符串、为空或超长 -> `invalid_intent`。
4. `at_utc < state.until_utc`（居民仍在冷却）-> `cooldown`。
5. 新 `until_utc < at_utc`，或新 `until_utc < state.until_utc`（冷却倒退）-> `invalid_cooldown`。
6. id 已存在 -> `duplicate_intent`（重复消费不幂等接受，由调用方显式处理）。

成功时把 id 与 `at_utc` 写入候选文档，并把 `until_utc` 推进到传入值。

### 有界淘汰

记录上限 256。写入后若超过上限，按消费时刻淘汰最旧一条；消费时刻相同时按 id 升序淘汰。由于第 4、5 条约束保证新消费时刻不小于原 `until_utc`，而 `valid()` 保证历史时刻不大于 `until_utc`，新记录始终是最新的，不会被本次淘汰。淘汰结果与字典遍历顺序无关。

### 具名原因

| 场景 | reason |
|---|---|
| 文档形状/字段/不变式不合法 | `invalid_state` |
| 时间不合法 | `invalid_time` |
| id 不合法 | `invalid_intent` |
| 居民仍在冷却 | `cooldown` |
| 新冷却时刻早于本次消费或倒退 | `invalid_cooldown` |
| 同一 id 已消费 | `duplicate_intent` |

## 持久化

`npc_intent_store.gd` 是与 `territory_store.gd` 同风格的 sidecar：

- 文件 `npc_intents.json`，暂存文件 `npc_intents.pending.json`，信封 `{version: 1, state: {...}}`。
- 保存前用与加载相同的 `valid()` 校验；写入 pending 后读回比对，一致才重命名为主文档。
- 缺失文件返回 `{ok:true, kind:"missing", state: 空账本}`；已存在但损坏返回 `corrupt`，版本不匹配返回 `unsupported`，绝不覆盖。
- 其他具名失败：`unsafe_path`、`invalid_state`、`create_directory`、`io`、`verify`、`too_large`、`replace_main`。
- 农场存档 v27 未改动。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/npc/npc_intent_state.gd` | 新增纯规则账本：严格校验、冷却判定、消费记账、有界淘汰 |
| `Game/npc/npc_intent_store.gd` | 新增 sidecar：版本信封、原子写、损坏/版本拒绝、缺失返回空账本 |
| `tests/npc_intent_state_test.gd` | 新增无头夹具，88 项检查 |
| `docs/2.0/milestones/M10/RECORD-05-intent-state.md` | 本记录 |
| `docs/2.0/milestones/M10/PLAN.md` | 只更新“当前进展”一行 |

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian && \
perl -e 'alarm shift; exec @ARGV' 120 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/npc_intent_state_test.gd"
```

原始末行：

```text
NPC_INTENT_STATE_TEST checks=88 failures=0
```

覆盖矩阵：

| 用例 | 检查 |
|---|---|
| 空文档 | 空账本合法、冷却时刻为 0、无历史、整数时间字段合法 |
| 非法形状 | null/数组、缺键/多键、负或非有限或非数字时间、非字典 intents、负或非数字消费时刻、非字符串/空/超长 id、消费晚于冷却、超过 256 条 |
| 记账 | 合法消费、候选文档合法、id 与消费时刻写入、冷却推进、输入不变 |
| 冷却 | 冷却前可用、冷却中拦截、边界放行、非法时间/文档失败关闭 |
| 拒绝 | 重复 id、冷却中记录、冷却时刻早于消费、冷却倒退、空/非字符串 id、负时间、非法文档 |
| 累积 | 第二次消费保留第一条并推进冷却 |
| 有界 | 连续 256 条成功、满额仍合法、第 257 条淘汰最旧且保留新记录、只淘汰一条、同一时刻按 id 升序淘汰 |
| 只读 | record/cooling 不修改输入；候选文档与输入深拷贝隔离 |
| 存取 | 缺失返回空账本、保存成功、主文件写入、pending 不残留、重开后文档一致、float 归一、原子替换、非法文档拒绝且不落盘 |
| 损坏 | 损坏 JSON、不支持版本、缺版本、状态非法、状态非字典、空文件、超字节上限均具名拒绝；损坏文件不被覆盖 |
| 原子写失败 | pending 路径被占住时返回 `io` 且不产生主文档；恢复后重试成功并可重新加载 |

## 未覆盖

- 权威接线：没有 `HeadlessWorld` 加载、`WorldHost` 命令入口、客户端 RPC、权限门或成员/访客角色判断。
- 真实执行：不扣现金、不冻结余额、不占卖单剩余、不发货、不记账；账本记录“校验通过并已消费”，不等于订单成交。失败/重试/并发抢单仍由执行层处理。
- 多居民：文档只有一个 `until_utc`，因此一份文档只描述一个居民；名册多居民时的分文件或分区留给接线切片。
- 世界隔离：sidecar 没有 `world_id` 字段，任何形状合法的文档都会加载；接线时依赖目录隔离或扩展信封。
- 淘汰策略：固定按消费时刻，不区分居民、商品或意图类型；没有 TTL 清理（历史只随上限淘汰）。
- 跨重启恢复：只验证了存取往返，没有验证接线后“重启仍拦住重复 id”的端到端路径。
- UI、可玩性观察与 Windows/CI：未覆盖。

## 关联

- 阶段计划：[M10 PLAN](PLAN.md)。
- 前置规则：[M10-03 意图与预算校验](RECORD-04-intent-rules.md)。
- 持久化参照：`Game/world/territory_store.gd`；校验风格参照 `Game/world/player_binding_state.gd`。
