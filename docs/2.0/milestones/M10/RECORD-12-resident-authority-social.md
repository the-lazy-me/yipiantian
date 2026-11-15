# M10-04 · 居民社交与记忆接入世界权威（持久化切片）

执行日期：2026-11-16。状态：切片完成，不表示 M10-04 或 M10 验收完成。前置：[M10 PLAN](PLAN.md)、[居民采购接入世界权威](RECORD-06-resident-sweep.md)、[居民自发社交](RECORD-08-social.md)、[社交与邀约写入记忆](RECORD-10-social-memory.md)、[居民长期行为评估](RECORD-11-resident-long-run.md)。

## 问题

RECORD-06 已让启用了居民的权威用真实经济账户与公开卖单完成采购，RECORD-08 提供了确定性的社交规则，RECORD-10 能把已发生的社交动作写成有界记忆，但三者没有在权威里接起来：社交关系与记忆只存在于测试持有的文档，权威没有对应的 sidecar，重启后既恢复不了关系也恢复不了冷却；长期评估因此无法说明“重启后的关系、记忆与冷却仍然生效”。

本切片把社交与记忆接入 `HeadlessWorld`：新增 world 级 sidecar `residents.json`，在启用居民时于同一轮结算里对真实关系文档执行 `plan`/`validate`/`apply`，并把已发生动作写入本人记忆。它仍然不执行真实赠礼、不移动任何现金、货物、账户或权属，也不接模型、网络或 UI。

## 边界

- 新增 `Game/world/residents_store.gd`、`tests/resident_authority_social_test.gd` 与本记录。
- 修改 `Game/world/headless_world.gd`：新增社交/记忆文档与 store、`open()` 加载、`settle_residents()` 与启用后的 `settle_economy_now()` 的社交阶段与保存顺序。
- 未修改 `Game/npc/npc_social.gd`、`npc_social_memory.gd`、`npc_memory.gd`、`npc_roster.gd`、`npc_personality.gd`、`Game/farm/*`、`Game/ui/*`、`Game/scenes/*`、`Game/ai/*`、`WorldHost`、网络命令、农场存档格式 27、`PLAN.md`、`rules/` 或 `.github/`。
- 默认关闭：只有显式调用 `enable_residents()`（部署权威用 `--residents`）才产生社交动作与 sidecar 写入；未启用时只读取现有文档，不创建 `residents.json`。
- 无新依赖、无 RNG、无系统时钟读取；时间来自调用方显式传入的 `at_utc`，人格仍由既有 `NpcPersonality` 从世界种子派生。

## Sidecar 形状

文件 `residents.json`，暂存文件 `residents.pending.json`；信封：

```text
{
  "version": 1,
  "world_id": "<world id>",
  "social": {relations: {...}, actions: {...}},   # 既有 NpcSocial 文档
  "memories": {schema: 1, world_id: "<world id>", npcs: {...}},  # 既有 NpcMemory 文档
}
```

- 信封恰好四个键；`social` 交给 `NpcSocial.valid()`，`memories` 交给 `NpcMemory.validate_document()`，且记忆文档的 `world_id` 必须等于信封 `world_id`。
- 容量沿用既有规则：社交最多 16 名发起者 × 32 个对象、每对 16 条动作 / 8 次赠礼；记忆每位居民 64 条。文档最多 256 KiB。
- 缺失文件是合法初始文档：名册三人两两建立 affinity 0 的关系行，记忆为空。它不会在加载时写盘。
- 存在但非 JSON、形状不合法、超出容量或版本不是 1 时返回 `corrupt` / `unsupported`；信封 `world_id` 与权威世界不一致时返回 `world_mismatch`。权威用 `load_resident_state_<kind>` 拒绝启动，绝不覆盖已有文档。
- 保存先写 pending、读回逐字节比对、再 rename 为主文档；调用方无法写入下一次加载会拒绝的文档。

## 权威接线

`open()` 在居民意图账本之后加载该 sidecar；失败让启动失败。`settle_residents(at_utc)` 在启用时，经济阶段之后执行社交阶段：

1. 对每名名册居民，从真实关系文档投影人格、对象关系、已消费 act id、动作种类冷却与赠礼余额。
2. 同一权威时刻已经有该居民动作时整名跳过；滚动 24 小时内动作达到 4 次或赠礼达到 1 次时不再产生新动作。计数来自已保存的动作/赠礼时刻，因此重启后仍生效。
3. `NpcSocial.plan` -> `validate` -> `apply`；关系候选和 `NpcSocialMemory.apply` 产生的本人记忆候选都成功后才同时接受，任一失败不留下半条动作。
4. 重复扫描由“同一时刻”守卫、动作冷却与 `duplicate_intent` 共同拦住；同一 act id 重放不会二次增加关系或写第二行记忆。

赠礼仍只是关系与记忆中的一次动作：不扣现金、不检查或移动库存、不写账户、不改变权属。

## 事务顺序

`settle_residents()` 与启用后的 `settle_economy_now()` 共用 `_apply_residents()`，顺序为：

1. 在 `farm.copy()` 候选上完成经济开户/下单/撮合，并生成居民账本候选。
2. 在同一轮里生成社交与记忆候选；不修改活文档。
3. 确保自然种子、保存农场候选。
4. 保存居民意图账本（若有变化），成功后才更新内存账本。
5. 保存 `residents.json`（社交或记忆有变化时），成功后才更新内存关系/记忆。
6. `farm.accept(candidate)` 并广播一次。

任一 sidecar 写失败时农场已经落盘，因此接受同一农场候选并广播，避免“磁盘领先、内存落后”；账本或关系文档留待后续结算补记。关系与记忆在同一个 `residents.json` 原子替换里，不会出现只保存其中一半的状态。

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian && \
perl -e 'alarm shift; exec @ARGV' 180 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/resident_authority_social_test.gd"
```

原始末行：

```text
RESIDENT_AUTHORITY_SOCIAL_TEST checks=136 failures=0
```

回归原始末行：

```text
NPC_RESIDENT_SWEEP_TEST checks=98 failures=0
ELAPSED_MS=13397
RESIDENT_LONG_RUN_TEST checks=13494 failures=0
```

覆盖矩阵：

| 用例 | 检查 |
|---|---|
| 默认关闭 | 不写 `residents.json` / `npc_residents.json`；`settle_residents` 返回 `disabled`；缺失文档初始化为名册相邻关系与空记忆 |
| 启用后一次扫描 | 三名居民真实开户与采购；每人至少一次道歉并写入本人记忆；关系 affinity 为正；关系与记忆文档通过严格 `valid()` |
| 关系/记忆对应 | 每名居民的动作数等于其记忆行数；记忆摘要包含“道了歉”；sidecar 信封只有 version/world_id/social/memories，不含现金、货物、账户、权属字段 |
| 同一时刻重放 | 同一时刻第二次扫描 `changed=false`、无第二次成交、无第二个社交动作；关系、记忆、现金、货物、成交全部不动 |
| 同一 act id 重放 | `NpcSocial.validate` 返回 `duplicate_intent`；`apply` 不重复改关系；`NpcSocialMemory.apply` 返回 duplicate 且记忆逐字节不变 |
| 资产隔离 | 无公开卖单的世界里社交仍发生；后续社交扫描不改变现金、口袋、成交与商品总量；双分录与 `total_cash == issued` 仍成立 |
| 重启 | 关系与记忆逐字节恢复；居民开关回到关闭；同一时刻扫描不重复动作/成交；道歉冷却时刻仍在；`plan` 不再选择道歉；act id 重放仍为 duplicate |
| 每日上限 | 滚动 24 小时内每位居民动作不超过 4；达到上限后继续扫描不再记录动作 |
| 世界隔离 | 异世界信封返回 `load_resident_state_world_mismatch`，且原文件不被覆盖 |
| 损坏/超限 | 非 JSON 返回 `load_resident_state_corrupt`；版本 2 返回 `load_resident_state_unsupported`；17 名发起者的关系表超容量返回 `load_resident_state_corrupt` |
| 既有回归 | 居民采购切片与 60 逻辑日长期评估的检查数、成交数、守恒与确定性指纹不变 |

## 未覆盖

- **真实赠礼**：赠礼仍不扣现金、不检查库存、不移动物品、不记账；只写关系与记忆。
- **模型**：没有提示词、自然语言生成或模型参与决策；动作仍来自固定规则与固定优先级。
- **网络与 UI**：没有客户端 RPC、命令频道、摘要投影、居民状态面板或社交/记忆展示；启用方式仍只有启动参数 `--residents`。
- **Windows**：只在 macOS 无头模式验证，未覆盖 Windows 路径、文件系统或实机。
- **写失败恢复演练**：实现了 pending+回读+rename 与“接受农场、保留旧关系文档”的具名失败路径，但本切片没有注入磁盘写失败来演练该分支。
- **其他社会行为**：未接邀约接受/拒绝/撤回、角色权限、冲突、传闻或关系衰减；关系只按固定增量变化。
- **真实墙钟与多权威**：时间为显式逻辑时钟，未验证真实时间驻留、离线结算或多权威并发。

## 关联

- [M10 PLAN](PLAN.md)
- [居民采购接入世界权威](RECORD-06-resident-sweep.md)
- [居民自发社交](RECORD-08-social.md)
- [社交与邀约结果写入记忆](RECORD-10-social-memory.md)
- [居民长期行为评估](RECORD-11-resident-long-run.md)
- [世界事件到居民记忆](RECORD-03-memory-feed.md)
- [居民名册与人格](RECORD-02-roster.md)
