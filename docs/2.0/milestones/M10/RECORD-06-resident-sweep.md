# M10-03 · 居民意图接入世界权威（可玩切片）

执行日期：2026-11-15。状态：切片完成，不表示 M10-03 或 M10 验收完成。前置：[M10 PLAN](PLAN.md)、[M10-02 居民名册](RECORD-02-roster.md)、[M10-03 意图与预算校验](RECORD-04-intent-rules.md)、[M10-03 意图执行账本](RECORD-05-intent-state.md)。

## 问题

RECORD-04 提供了 `plan`/`validate`，RECORD-05 提供了单居民消费账本与 sidecar，但两者都没有接进世界权威：没有地方把居民现金、口袋、公开卖单和冷却投影成上下文，也没有地方在真实市场上下单、撮合并把成功消费写回持久账本。验收判据“阿舟用真实预算完成一次采购；重复或过期意图不会重复成交；重启后仍拒绝已消费意图”仍然没有可运行证据。

本切片完成 M10-03 的第一个可玩切片：`HeadlessWorld` 在显式启用后用真实经济账户与真实市场卖单结算名册三人；默认关闭，既有世界与全部测试行为不变。

## 边界

- 新增 `Game/npc/npc_resident_ledger.gd`、`Game/npc/npc_resident_ledger_store.gd`、`tests/npc_resident_sweep_test.gd` 与本记录。
- 修改 `Game/world/headless_world.gd`：新增 `residents_enabled`、居民账本与 store、`enable_residents()`、`settle_residents()`，并让启用后的 `settle_economy_now()` 把居民结算并入同一候选与同一次保存。
- 未修改 `Game/npc/npc_intent.gd`、`Game/npc/npc_intent_state.gd`、`Game/npc/npc_intent_store.gd`、`Game/farm/*`、其他 `Game/world/*`、`Game/ui/*`、`Game/scenes/*`、农场格式 27 或任何规则/规划文档。
- 无新依赖、无 RNG、无系统时钟读取；`at_utc` 由调用方显式传入。
- 不接服务器主循环、网络、模型或 UI；名册居民不参与社交、拜访或对话。

## 启用方式

```gdscript
var world := HeadlessWorld.new()
world.open(directory, now_utc)
world.enable_residents()                 # 只置本会话标志，不写盘
world.settle_residents(now_utc)          # 或启用后由 settle_economy_now() 并入
```

- `residents_enabled` 默认为 `false`。未启用时 `settle_residents()` 返回
  `{ok:true, reason:"disabled", changed:false}`，`settle_economy_now()` 保持
  原有逐字节行为。
- `enable_residents()` 不持久化开关：重启后必须由调用方再次启用。持久状态只有
  已消费意图账本，它在成功消费后写盘。

## 账本形状

`npc_residents.json` 的信封为 `{version: 1, state: {...}}`，状态文档：

```text
{
  residents: {
    "<npc id>": {
      until_utc: float >= 0,
      intents: { "<intent id>": float >= 0 },
    },
  },
}
```

- 文档恰好一个键 `residents`；居民表最多 16 人，且 id 必须来自 M10-02 名册
  （`npc_lin_shen`、`npc_xu_bo`、`npc_a_zhou`）。
- 每位居民的子文档交给 `npc_intent_state.gd` 的严格 `valid()`：恰好
  `until_utc`/`intents` 两键、时间在 `[0, 2^53-1]`、id 非空且不超过 128 字符、
  最多 256 条、每条消费时刻不大于 `until_utc`。不存在条目的居民按空账本处理。
- `record()` 返回候选文档且不修改输入；`cooling()` 只读，返回与单居民账本同形
  的 `{ok, reason, cooling, until_utc}`。
- sidecar 文件名 `npc_residents.json`，暂存文件 `npc_residents.pending.json`；
  64 KiB 上限、写入 pending 后读回比对再 rename、缺失返回空账本、损坏返回
  `corrupt`、版本不支持返回 `unsupported`，绝不覆盖已有文档。

## 事务顺序

`settle_residents(at_utc)` 与启用后的 `settle_economy_now(at_utc)` 共用
`_apply_residents()`：

1. 在 `farm.copy()` 候选上工作，活状态不变。
2. 按名册顺序对三名居民：
   1. 经济账户不存在时以固定命令 id `npc-open-<id>` 开户；已开通或已领赠款
      视为可继续。
   2. 从候选农场投影本人现金、口袋货物、公开开放卖单（`side=sell`、
      `status=open`、`remaining>0`）和居民账本中的本人子文档。
   3. `NpcIntent.plan(context, at_utc)`；无供给、无事可做、冷却或无现金只登记
      具名原因。
   4. `NpcIntent.validate(intent, context, at_utc)`；过期、已消费、预算不足等
      同样只登记原因。
   5. 在 `candidate.copy()` 子候选上以 `intent.id` 作为市场命令 id 调用
      `market_place_order`，随后 `market_match`。任一失败则整笔子候选丢弃。
   6. 全部成功后接受子候选，并把 `intent.id -> at_utc`、`until_utc =
      at_utc + 300` 写入账本候选。
3. 整批结束后：确保自然种子已写、保存农场候选；农场保存成功后才保存居民账本
   （仅当本次有新消费），最后 `farm.accept(candidate)`、更新内存账本并在有变化
   时 `shared_changed.emit()`。
4. 账本写失败返回 `save_residents_<kind>`，但此时农场文件已经落盘。权威接受同一
   候选并广播，保持内存与磁盘一致；内存账本仍是旧文档。下一次结算会重新规划同一
   意图，市场命令 id 与该意图相同，重放不产生第二笔成交，账本随后补记。选择
   “接受农场”而不是“拒绝候选”，是因为拒绝会让运行中的世界落后于自己的磁盘，
   而接受最多损失一次账本记账、不会重发财产。
5. `settle_economy_now()` 启用时只做一次农场保存与一次广播；经济扫描与居民
   结算共用同一候选。未启用时保留原来的早退和返回结构。

`execute()` 不运行居民结算，命令路径保持现状。`open()` 读取
`npc_residents.json`：缺失得到空文档；损坏、版本不符等返回
`load_residents_<kind>` 并拒绝启动。

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian && \
perl -e 'alarm shift; exec @ARGV' 180 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/npc_resident_sweep_test.gd"
```

原始末行：

```text
NPC_RESIDENT_SWEEP_TEST checks=98 failures=0
```

回归原始末行：

```text
CHAIN_INTEGRATION_TEST checks=509 failures=0
WORLD_ECONOMY_CLOCK_TEST checks=43 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/world-economy-clock-75900
M4_ECONOMY_COMMANDS_TEST checks=169 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/m4-economy-commands-362504
VILLAGE_BETA_TEST checks=116 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/village-beta-331194
```

覆盖矩阵：

| 用例 | 检查 |
|---|---|
| 默认关闭 | 不开居民账户、不产生货物、不产生交易、`settle_residents` 返回 `disabled`、经济扫描不改变卖单 |
| 启用后采购 | 三人各开真实账户；每人完成一次买入；阿舟现金减少、口袋增加、公开卖单余量减少；市场成交 3 笔；账本记录 intent id 与冷却 |
| 重复扫描 | 同一时刻再扫 `changed=false`、成交/现金/账本/供给全部不动；合并的 `settle_economy_now` 同样不重复买 |
| 过期意图 | 在 `START-1000` 规划、在当前时刻 `validate` 返回 `expired`，且市场无该订单、无新成交 |
| 重启 | sidecar 存在；重开后账本逐字段相同；开关回到关闭；同一 intent id 再校验返回 `duplicate_intent`；成交数不变 |
| 损坏账本 | 非 JSON、版本 2、名册外 id 分别返回 `load_residents_corrupt` / `load_residents_unsupported` / `load_residents_corrupt`；缺失仍可打开为空 |
| 守恒 | 双分录对账通过、`total_cash == issued`、商品总量（商人库存 + 居民口袋 + 开放卖单托管 + 在途）保持 120 |
| 纯规则 | 空文档合法、候选写时复制、冷却边界、重复/名册外拒绝、消费晚于冷却拒绝、未知键拒绝 |

## 未覆盖

- 未接服务器主循环、网络命令、权限、摘要投影或客户端；`world_server` 仍不会
  自动启用居民，也没有面向玩家的开关。
- 未接本地模型或模型调度：意图仍来自固定规则，不使用人格、记忆或对话。
- 未接 UI：没有居民状态、采购日志或错误展示。
- 名册居民不参与社交、拜访、赠礼或组织；本切片只处理采购一条行为。
- 默认关闭是刻意边界：现有单机、共享世界测试与既有世界不因本次改动产生居民
  账户、交易或新广播。
- 只验证购买一条路径；没有卖出、撤单、跨市场物流或风险损失下的居民行为。
- 未验证 Windows、真实长时运行、多权威并发（当前权威单线程、无 await）与
  账本写失败后的磁盘/内存分歧恢复演练。

## 关联

- [M10-02 居民名册](RECORD-02-roster.md)
- [M10-03 意图与预算校验](RECORD-04-intent-rules.md)
- [M10-03 意图执行账本](RECORD-05-intent-state.md)
- [M7-02 市场订单](../M7/RECORD-02-market-orders.md)、[M7-03 撮合与交割](../M7/RECORD-03-matching.md)
- [M7-01 经济初始条件](../M7/RECORD-01-economy-initial.md)、[M8-01 双重记账](../M8/RECORD-01-ledger.md)
- [M4-09 共享世界经济命令](../M4/RECORD-09-economy-commands.md)
