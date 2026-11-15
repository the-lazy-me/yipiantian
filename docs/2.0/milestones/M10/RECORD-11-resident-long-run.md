# M10-05 · 居民长期行为评估（规则长跑切片）

执行日期：2026-11-16。状态：切片完成，不表示 M10-05 或 M10 验收完成。前置：[M10 PLAN](PLAN.md)、[居民采购接入世界权威](RECORD-06-resident-sweep.md)、[居民自发社交](RECORD-08-social.md)、[社交与邀约写入记忆](RECORD-10-social-memory.md)。

## 问题

M10-05 要求“无人观看、稀少交易、关系冲突与模型停用对照，测循环、成本与人格稳定性”，验收判据是“无无限自聊和无限交易；成本与记忆规模受限”。此前记录分别冻结了采购、意图账本、社交和记忆适配层，但没有任何一次跨 60 个逻辑日的运行把真实世界经济与这些规则模块放在一起，验证冷却、容量与守恒在长期循环里仍然成立。

本切片只新增一个无头长跑夹具，不修改生产代码：在启用居民的真实 `HeadlessWorld` 中跑 60 个逻辑日，模型关闭，全部决策来自既有规则。社交与记忆模块目前尚未接入权威，因此测试从权威状态投影最小只读上下文，再调用它们的纯规则入口；写入只落在测试持有的文档里。

## 边界

- 新增 `tests/resident_long_run_test.gd` 与本记录。
- 未修改 `Game/`、`PLAN.md`、`rules/`、`.github/`、农场存档格式或任何规则文档。
- 无模型、无网络、无 UI、无场景、无 Windows 路径；游戏时间只来自测试显式传入的逻辑时钟。
- 测试目录与全部产物写在 `.local/verification/resident-long-run-*`。
- 社交/记忆文档不是生产存档：权威目前没有对应 store，记录不把它们说成已持久化。
- 调用方投影有两项显式约定：每对关系达到 `MAX_ACTS_PER_PEER` 后不再进入规则选择；每天每位居民最多一次赠礼、最多 4 次社交尝试。它们都是测试侧的当前上限，不改变规则模块。

## 每日流程

1. `advance_to(now)` 推进天气、作物与市场/经济扫描（订单过期、商人报价维护、撮合、交割、贷款到期）。
2. 启用居民后调用 `settle_residents(now)`：真实开户、现金、口袋、公开卖单、`plan`/`validate`、下单与撮合全部走既有权威路径。
3. 同一逻辑时刻再扫一次，验证冷却/账本阻止第二次成交。
4. 从权威状态投影每名居民的人格、关系、动作冷却与已消费 act id；调用 `NpcSocial.plan`/`validate`/`apply`，再把已发生动作交给 `NpcSocialMemory.apply` 写入本人记忆。
5. 把一条已提交世界事件投影交给 `NpcMemoryFeed.apply`，随后用同一事件 id 重放验证去重。
6. 每天检查守恒、账本/冷却、记忆容量、社交上限、各文档 `valid()` 与既有事件表容量常数。

## 覆盖矩阵

| 验收点 | 检查 |
|---|---|
| 现金守恒 | 每天与最终 `total_cash == issued`；复式账 `economy_reconcile()` 通过；商品总量保持 120 |
| 采购预算 | 每位居民当日现金变化恰好等于开户赠款减去本人意图总额；现金非负；从不超预算 |
| 不重复成交 | 全局 intent id 唯一；同一时刻重复扫描 `changed=false`；重建已消费 intent 再 `validate` 返回 `duplicate_intent` |
| 意图账本 | `ResidentLedger.valid()` 每天通过；每人 intents 数等于实际购买次数且不超过 256；消费时刻不晚于 `until_utc` |
| 冷却与失败等待 | `until_utc` 不超过“本次购买 + 300 秒”；每次扫描至多 3 名居民各产生一个终态；失败有具名原因；同一居民不会同时“买入”和“失败” |
| 记忆上限 | 每位居民 entries 不超过 64；`dropped` 单调不减；60 天内实际触发淘汰 |
| 事件去重 | 社交 act id 与每日世界事件 id 重放均返回 duplicate，记忆文档逐字节不变 |
| 公共账本隔离 | 社交动作与记忆写入前后，居民意图账本与世界经济快照 JSON 完全相同 |
| 社交有界 | 无自我关系；动作对象不等于发起人；每对关系动作不超过 16、赠礼不超过 8；每人每天赠礼不超过 1、动作不超过 4；总动作/赠礼不超过固定上限 |
| 文档有效 | 60 天后 `Economy.valid`、`Market.valid`、`ResidentLedger.valid`、`Memory.validate_document`、`NpcSocial.valid` 全部通过；每天亦检查记忆/社交/意图 |
| 确定性 | 相同 seed、相同命令序列、相同逻辑时钟的两个独立目录运行得到同一指纹 |
| 容量常数 | 市场订单/成交/物流/损耗、复式账条目、已提交命令结果分别受 `Market.MAX_*`、`Ledger.MAX_ENTRIES`、固定 64 窗口约束 |

## 测量

```text
MEASURE residents=3 days=60 trades=10 intents=10 memories=192 social=96 cash_issued=950 final_total=950 fingerprint=39ab8f57a70577a6
DETAIL run=run-a trades=10 intents=10 actions=96 gifts=28 feed=180 memories=192 dropped=87 orders=22 ledger=512 fingerprint=39ab8f57a70577a6
DETAIL run=run-b trades=10 intents=10 actions=96 gifts=28 feed=180 memories=192 dropped=87 orders=22 ledger=512 fingerprint=39ab8f57a70577a6
DETERMINISM first=39ab8f57a70577a6 second=39ab8f57a70577a6 equal=true
ELAPSED_MS=12066
```

- 三人各获得 120 COIN 开户赠款，商会开市另发行 600 COIN；交易手续费按既有规则燃烧，60 天后净发行与总现金同为 950。
- 60 天只有 10 笔居民采购：现金耗尽后规则返回 `no_cash`，没有任何无限交易；10 个 intent 各成交一次。
- 记忆活条目为 3 × 64 = 192，累计淘汰 87 条，说明有界淘汰真实发生；每日世界事件共写入 180 行。
- 社交动作 96 次、赠礼 28 次；达到每对 16 条动作上限后计划返回 `nothing_to_do`，没有自我社交或超额赠礼。
- 市场订单 22 条、复式账条目 512 条，均不超过各自既有常数；其中 512 恰好达到 `Ledger.MAX_ENTRIES`，之后由既有淘汰规则保持有界。
- 两次独立运行指纹相同，运行耗时约 12.1 秒，低于 60 秒预算。另起一个 Godot 进程复跑，得到同一指纹、同一 `checks=13494 failures=0`，耗时 12101 ms。

## 原始末行

```text
ELAPSED_MS=12066
RESIDENT_LONG_RUN_TEST checks=13494 failures=0
```

运行命令：

```sh
cd /Volumes/Disk-1tb/yipiantian && \
perl -e 'alarm shift; exec @ARGV' 150 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/resident_long_run_test.gd"
```

## 发现与取舍

- 未发现真实不变量破坏：现金/商品守恒、账本、冷却、容量与确定性在 60 天双跑中全部成立。
- 规则模块之间有一个值得记录的交互：`NpcSocial.plan` 的赠礼/邀请/招呼对象选择只按亲和度与最近时刻，不检查每对 16 条动作上限；若把满额对象继续投影进去，`validate` 会以 `over_capacity` 拒绝计划结果。测试调用方因此只投影“仍有动作余量”的对象，满额对象不再进入选择；这属于调用方状态投影，不是对规则模块的修改。
- 社交与记忆仍由测试驱动，权威没有订阅对应事件；因此“私人对话不改变公开账本”是由适配层只写测试文档保证的，而不是生产权威的接线证据。
- 宏观上 60 天交易稀少且在第 3 天左右因预算耗尽停止，符合 M10-05 “稀少交易”的对照语境；测试没有通过额外注资制造高频交易，因为那会偏离当前规则能产生的真实行为。

## 未覆盖

- **模型启用**：全程关闭模型；没有提示词、自然语言生成、人格化文案或模型对决策的参与。
- **真实 UI**：没有居民状态面板、采购日志、社交/记忆展示或玩家可操作入口。
- **Windows**：只在 macOS 无头模式运行，未验证 Windows 路径、文件系统或实机。
- **真实墙钟驻留**：所有时间都是显式逻辑时钟；没有观察真实时间下的长时间运行、离线结算或进程重启。
- **权威接线**：社交、记忆、邀约、角色权限未接入 `HeadlessWorld`/`WorldHost`；测试通过投影调用纯规则，未验证生产事件订阅。
- **持久化**：记忆与关系文档没有 store，未验证跨重启恢复、损坏恢复或多世界隔离；居民意图账本与农场仍按既有 sidecar 规则。
- **其他社会行为**：未覆盖邀约接受/拒绝/撤回、角色权限矩阵、真实赠礼扣款、冲突、传闻与关系衰减。
- **并发与网络**：单权威、单线程；未覆盖多权威并发、客户端命令或网络分区。

## 关联

- [M10 PLAN](PLAN.md)
- [居民采购接入世界权威](RECORD-06-resident-sweep.md)
- [居民自发社交](RECORD-08-social.md)
- [社交与邀约结果写入记忆](RECORD-10-social-memory.md)
- [世界事件到居民记忆](RECORD-03-memory-feed.md)
- [长期规则模拟](../M13/RECORD-11-long-simulation.md)
