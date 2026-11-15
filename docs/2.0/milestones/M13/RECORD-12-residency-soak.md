# M13-02 · 真实驻留切片（墙钟驻留、文件与内存曲线）

日期：2026-11-16。状态：**本机无头墙钟驻留已执行，未验收 M13-02**。本记录只报告 `tests/residency_soak_test.gd` 的两个运行（CI 默认 30 秒与本机 600 秒），不表示 M13-02 或 M13 完成；Windows、能耗、真实玩家与图形客户端均未覆盖。

范围：在真实 `HeadlessWorld` + `enable_residents()` 上按墙钟循环推进并结算，每轮推进 1 逻辑小时，周期性采样引擎静态内存、世界目录文件与账本，检查现金守恒、对账、各表容量、文件/内存不随运行时长无界增长、重放同一逻辑时刻无变化、尾段重启一致。纯规则夹具：无 UI、无渲染、无网络；存档写在 `.local/` 隔离目录。本轮只新增 `tests/residency_soak_test.gd` 与本记录，**未修改任何生产文件**，未提交、未推送。

前置：[M13 PLAN](PLAN.md)（M13-02）、[RECORD-04 · 长期模拟](RECORD-04-soak.md)（固定步数、一年逻辑时长、静态内存采样）、[RECORD-11 · 多世界长期模拟](RECORD-11-long-simulation.md)（3 世界 60 逻辑日）、M10-05 `tests/resident_long_run_test.gd`（居民 60 逻辑日）。

## 结论

1. **两个时长都通过，且不变量在同一逻辑时长下稳定**：30 秒 `checks=4314 failures=0`（117 tick，117 逻辑小时）；600 秒 `checks=80993 failures=0`（2337 tick，2337 逻辑小时）。每个 tick 都断言 `total_cash == issued`、双分录对账、居民意图/记忆/关系/赠礼/邀约/对话表容量；每个采样点再校验经济、市场、账本、自然、地籍、参与、单位、基金、公共项目、组织、争端与居民 sidecar 的结构。
2. **现金恒等在整个驻留期成立**：商人开业发行 600；三名居民首次采购时各开户赠款 120，毛发行 960；10 笔成交各燃烧 1，共 10；600 秒结束 `issued = 950 = total_cash`。持有方：居民账户 14+7+18 = 39、商人 571、托管 340，合计 950；账本余额表 `issuance = -960`、`burn = 10` 与 `issued` 一致。
3. **文件曲线有界并明确收敛**：600 秒里世界目录总字节从 210,528 涨到 603,176，前 1/3 峰值 599,370、后 1/3 峰值 603,494，**后段仅增加 4,124 字节**（容差 256 KiB）。增量几乎全部来自 `farm.json` 的流水：账本分录到 `MAX_ENTRIES=512` 后按既有 checkpoint 规则驱逐并封顶（133 KB，占 farm.json 一半），订单/成交表在居民购买节奏下保持十几到二十几行。`residents.json` 到 55,724 字节后在 137.4 秒停止变化，之后 462 秒一动不动；`npc_residents.json` 恒为 687 字节。
4. **内存曲线不是无界增长，但本切片只能证明“有界且收敛”，不能证明绝对不泄漏**：600 秒里引擎静态内存 38.7 → 40.9 MiB，前 1/3 峰值 42,345,490、后 1/3 峰值 42,891,806，**后段仅增加 546,316 字节**（容差 8 MiB）。增长由 **5 个离散台阶**构成：tick 16/24/32/40（开局前 10 秒）四步共约 1.6 MB，tick 840（215.5 秒）一步 543,828 字节；此后 373.8 秒的 183 个样本里静态内存完全不变（291 个相邻增量中 258 个为 0）。对象数全程恒为 1581，资源数恒为 68——没有对象泄漏特征。tick 840 在三次独立 600 秒运行中位置完全相同，且 840 逻辑小时 = 35 逻辑日 = 5 个 7 日季节边界，因此这一步按逻辑时间而不是墙钟时长定位；具体分配点仍无法从本切片归因。
5. **发现并修正了一个测量方法缺陷（夹具自身，不是产品）**：首版把样本存进 `Array[Dictionary]`，每个样本让引擎静态内存稳定增加 1,172 字节（292 个样本、291 个相邻增量全部正好 +1,172，无一个为 0），第一/第三段对比时会把它误判成“产品持续增长”。改为预分配 `PackedInt64Array`（`MAX_SAMPLES × 12` 个整数，最多 320 条）后，600 秒运行的相邻采样增量中 258/291 为 0，5 个台阶之外不再有任何逐样本增长；同一世界前/后 1/3 的静态内存最大差从 779,056 降到 546,316 字节，中位数差从 811,784 降到 577,172 字节。这正符合任务要求：先确认增长是否由测量本身造成，再判断产品。
6. **确定性、重放与重启成立**：尾段同一逻辑时刻再调用一次 `settle_economy_now` 返回 `changed=false` 且所有文档指纹不变；真实 `save()` 后同目录、同 world id、同房主重开为 `loaded`，指纹与在线状态一致（600 秒 `1df610175e58356d`）；重启后再扫一次同一时刻仍 `changed=false`。
7. **没有发现破坏不变量或守恒的生产缺陷**；但观察到一处长期行为问题：邀约表在约 22 逻辑日后被 64 条已过期行填满，此后再也不能发起邀约（见“发现”第 5 条）。它不影响守恒、对账、结构校验或内存有界性，因此本切片按任务边界只记录、不修改生产代码。

## 环境与基线

| 项 | 值 |
|---|---|
| 引擎 | `Godot 4.7.2.stable.official.ed1daf0bf`（本机 `/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app`） |
| 机器 | Apple M4 Pro，24 GiB，macOS 27.0.1 arm64；无头、无渲染 |
| 仓库工作树 | 运行期间并行代理仍在改 `Game/world/`（居民对话权威切片）、`Game/ui/` 与多个测试；本轮未触碰这些文件。600 秒运行前后 `headless_world.gd`（`00af68b6…`）/ `residents_store.gd`（`e2236932…`）的 sha256 校验一致，运行窗口内无生产文件变化；本记录的数据对应这两个哈希。运行结束后并行代理继续编辑 `headless_world.gd`，夹具在最新树上仍通过 `--check-only`，但未重跑长驻留 |
| 种子 / 起点 | `SEED = 42017`（开世界前写入 `NatureStore`），`START = 1800028800`（UTC） |
| 世界身份 | world id `residency-soak`，房主 `soak_host` |
| 逻辑步长 | 每 tick `advance_to(now + 3600)`，即 1 逻辑小时 |
| 墙钟节奏 | 每 tick 目标 250 ms（`--tick-ms`，约束 200–500）；落后时借用下一轮，不累积 |
| 采样节奏 | 30 秒运行每 4 tick 一次（29 个样本）；600 秒运行每 8 tick 一次（292 个样本）；上限 `MAX_SAMPLES=320` |
| 存档上限 | `FarmStore.MAX_BYTES = 2097152`，`VERSION = 27`；`residents.json` 262,144；`npc_residents.json` 65,536 |
| 预算 | 夹具自身无固定超时；外部 `alarm`：30 秒运行 200 秒、600 秒运行 780 秒。CI 的单夹具看门狗是 180 秒，因此 **CI 只应跑 30 秒默认值** |

运行命令：

```bash
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
cd /Volumes/Disk-1tb/yipiantian
# CI 默认（30 秒）
perl -e 'alarm shift; exec @ARGV' 200 "$GODOT" --headless --path Game \
  --script "$PWD/tests/residency_soak_test.gd"
# 本机长驻留（10 分钟）
perl -e 'alarm shift; exec @ARGV' 780 "$GODOT" --headless --path Game \
  --script "$PWD/tests/residency_soak_test.gd" -- --soak-seconds=600
```

## 夹具设计

每个 tick：`advance_to(now + 1h)` → 有变化时 `save()`（与 `world_server` 同策略，只在作物字段或经济事件变化时写盘）→ `settle_economy_now(now)` → 同一时刻第二次扫掠必须 `changed=false` → 按节奏采样。

采样字段（12 个整数）：tick、elapsed_ms、静态内存、动态内存（Godot 4.7.2 无 `OS.get_dynamic_memory_usage()`，记 `-1`，不编造）、`OBJECT_COUNT`、`OBJECT_RESOURCE_COUNT`、世界目录总字节、`farm.json`、`residents.json`、`npc_residents.json`、`issued`、`total_cash`。样本先写入预分配缓冲，结束时一次性写成 `samples.json`，不产生逐 tick 日志。

采样时的结构校验：`Economy.valid`、`Market.valid`、`Ledger.valid`、自然快照可恢复、`TerritoryState.valid`、`Participation.valid`、`UnitState.valid`、`PublicFund.valid`、`PublicWorks.valid`、`Organization.valid`、`Disputes.valid`；每个 tick 的居民容量：意图 ≤ 256/人、记忆 ≤ 64/人、每对关系动作 ≤ 16、赠礼 ≤ 8、邀约 ≤ 64、对话玩家 ≤ 64，并调用各自的 `valid()`。

曲线判据：样本按时间三等分，比较前 1/3 与后 1/3 的**最大值**，绝对容差——文件 256 KiB、静态内存 8 MiB、对象数 64。中位数一并打印但不作为门禁：30 秒运行的后 1/3 仍处在前 10 秒的开局填装之后，中位数门禁会几乎没有余量，且与宿主快慢耦合，属噪声。这不是放宽断言——真正的无界增长会先抬高后段最大值，且两个时长用的是同一判据。

## 实际原始输出

### 默认 30 秒（CI 形状）

```text
SOAK ticks=117 sample_every=4 samples=29 logical_step=3600
CURVE files_max_first=501758 files_max_last=566513 files_median_first=333566 files_median_last=564707 mem_max_first=42037970 mem_max_last=42214518 objects_first=1581 objects_last=1581 samples=29
FINAL now_utc=1800450000 cash_issued=950 final_total=950 logical_hours=117.0
RESTART fingerprint=f48aa10df4319fb3 reopened=f48aa10df4319fb3 equal=true changed=false
MEASURE seconds=30.2 samples=29 mem_first=38.6 mem_last=40.3 mem_peak=40.3 files_first=172746 files_last=566513 cash_issued=950 final_total=950
ELAPSED_MS=30189 soak_seconds=30 tick_ms=250 logical_step=3600
RESIDENCY_SOAK_TEST checks=4314 failures=0
```

日志中 `FARM_SAVE stage=complete version=27` 共 139 行，是每次真实写盘（农场与经济变化时）的既有日志；没有 `SCRIPT ERROR`、`WARNING` 或其他错误。

在并行代理把 `headless_world.gd` 改到 `2dcde101…` 之后重跑默认 30 秒，结果一致：`checks=4314 failures=0`、指纹仍为 `f48aa10df4319fb3`、文件峰值 501,758 → 566,513、静态内存 38.6 → 40.3 MiB。600 秒数据仍对应 `00af68b6…`。

### 本机 600 秒（10 分钟）

```text
SOAK ticks=2337 sample_every=8 samples=292 logical_step=3600
CURVE files_max_first=599370 files_max_last=603494 files_median_first=591457 files_median_last=603282 mem_max_first=42345490 mem_max_last=42891806 objects_first=1581 objects_last=1581 samples=292
FINAL now_utc=1808442000 cash_issued=950 final_total=950 logical_hours=2337.0
RESTART fingerprint=1df610175e58356d reopened=1df610175e58356d equal=true changed=false
MEASURE seconds=600.1 samples=292 mem_first=38.7 mem_last=40.9 mem_peak=40.9 files_first=210528 files_last=603176 cash_issued=950 final_total=950
ELAPSED_MS=600146 soak_seconds=600 tick_ms=250 logical_step=3600
RESIDENCY_SOAK_TEST checks=80993 failures=0
```

日志中 `FARM_SAVE stage=complete version=27` 共 2,438 行；无错误。

## 文件曲线

600 秒运行的采样时间线（每 20 个样本取一行；`files` 为世界目录总字节）：

| 墙钟 ms | tick | files | farm.json | residents.json | 静态内存 MiB |
|---|---|---|---|---|---|
| 1,833 | 8 | 210,528 | 104,427 | 6,047 | 38.68 |
| 42,947 | 168 | 576,020 | 271,338 | 32,586 | 40.29 |
| 83,993 | 328 | 588,294 | 271,444 | 44,648 | 40.34 |
| 125,052 | 488 | 596,309 | 271,126 | 53,299 | 40.37 |
| 166,160 | 648 | 599,370 | 271,444 | 55,724 | 40.38 |
| 207,276 | 808 | 599,370 | 271,444 | 55,724 | 40.38 |
| 248,384 | 968 | 603,176 | 273,506 | 55,724 | 40.90 |
| 289,468 | 1,128 | 602,858 | 273,188 | 55,724 | 40.90 |
| 330,565 | 1,288 | 603,494 | 273,506 | 55,724 | 40.90 |
| 371,607 | 1,448 | 603,070 | 273,400 | 55,724 | 40.90 |
| 412,647 | 1,608 | 603,494 | 273,506 | 55,724 | 40.90 |
| 453,795 | 1,768 | 603,070 | 273,294 | 55,724 | 40.90 |
| 494,882 | 1,928 | 603,388 | 273,506 | 55,724 | 40.90 |
| 535,907 | 2,088 | 603,070 | 273,294 | 55,724 | 40.90 |
| 577,035 | 2,248 | 603,282 | 273,400 | 55,724 | 40.90 |

解释：

- **前 10 秒的线性增长不是泄漏**，是真实状态填装：`farm.json` 每 tick 约 +41 KB，直到账本分录达到 `MAX_ENTRIES=512`（约 tick 40 / 第 40 逻辑小时）；随后进入驱逐-封顶阶段，`farm.json` 在 271–274 KB 之间小幅振荡（订单、成交、托管行在居民购买节奏下进出）。
- **`residents.json` 的增长全部发生在前 137.4 秒（536 tick / 536 逻辑小时）**：邀约表从 0 填到 64 行、三名居民记忆从 0 涨到 32/32/28 条、每对关系 16 条动作，之后 462 秒完全静止。这是关系/记忆/邀约表的容量收敛，不是持续写入。64 行邀约全部是 `expired`，最早创建于第 132 逻辑小时、最晚第 532 逻辑小时；`HeadlessWorld` 的裁决只把 pending 转成 expired，不删除历史行，因此邀约表到达 `MAX_INVITATIONS=64` 后新邀约返回 `over_capacity`（NpcInvitation 自己的上限是 128，信封上限更严）。这是既有设计，不是本切片引入的行为；本切片只证明它在长驻留中保持有界。
- **后 1/3 只增加 4,124 字节**（599,370 → 603,494），容差 256 KiB 约 65 倍余量；`farm.json` 后段变化 2,062 字节，全部来自流动中的订单/成交行。

30 秒运行同样收敛：`files` 从 172,746 到 566,513，其中前 10 秒占主要增量，最后 10 秒只在 554–567 KB 间因订单行进出而小幅波动。

## 内存曲线

| 墙钟 | 事件 | 静态内存 |
|---|---|---|
| 1,833 ms（tick 8） | 首个样本 | 40,558,674（38.68 MiB） |
| 3,931 ms（tick 16） | +487,092 | 41,045,766 |
| 5,984 ms（tick 24） | +610,024 | 41,655,790 |
| 8,041 ms（tick 32） | +260,704 | 41,916,494 |
| 10,112 ms（tick 40） | +243,296 | 42,159,790（开局填装合计 +1,601,116） |
| 12,171–45,004 ms | 每 tick +17 KB，共约 +120 KB | 与逻辑时间同增的零散分配 |
| 215,494 ms（tick 840） | +543,828 | 42,889,378 |
| 225,801 ms 之后 | 无变化 | 42,891,806 保持到结束（373.8 秒，183 个样本） |

三次 600 秒运行的对比（本记录这一份，加上修正前带 Dictionary 样本的一份与本记录定稿前的同夹具一份）中，tick 16/24/32/40/840 的五个台阶位置一致，大小相差不超过约 1.5 KB。tick 840 = 35 逻辑日 = 5 个 7 日季节边界，因此该台阶按**逻辑时间**定位，不是墙钟时长。

- 对象数（`OBJECT_COUNT`）全程 **1581**，资源数（`OBJECT_RESOURCE_COUNT`）全程 **68**，两个时长相同。世界在开世界后不再创建 Node，因此对象计数不变是预期结果，也是“不是对象泄漏”的独立证据。
- 后 1/3 与前 1/3 的静态内存最大值差 **546,316 字节**（约 521 KiB），远低于 8 MiB 容差。
- 把 600 秒运行的全部增量按来源拆开（三次独立 600 秒运行给出相同台阶）：开局前 15 秒 +1,620,792 字节；与 `residents.json` 行增长同一次采样发生的 +166,024 字节（20 次，每次 5–18 KB，对应居民关系/记忆/邀约行写入）；tick 840 的单次 +543,828 字节；其余为 0。也就是说，除一次固定台阶外，运行中的每一次内存增长都能对上 `residents.json` 的具体写行。
- **tick 840 台阶按逻辑时间定位，不是墙钟**：三次独立 600 秒运行中它都恰好出现在 tick 840（第 215.5/215.6/215.7 秒）；tick 840 = 840 逻辑小时 = 35 逻辑日 = 5 个 7 日季节边界，因此更可能是季节切换路径的一次性分配。其他季节边界（tick 168/336/504）没有同样台阶，说明不是每个季节都分配，本切片也没有内存剖析工具来确认具体来源。30 秒运行（117 tick）不会触及该点。
- 30 秒运行的后段差 176,548 字节，同样只由前 10 秒的开局填装和后段零散分配构成。

**边界**：`OS.get_static_memory_usage()` 是引擎自己的分配器统计，**不是进程 RSS**；它看不到驱动、字体缓存、GPU 与第三方库。开局 1.6 MB 与 tick 840 的 0.5 MB 两个台阶虽能定位到固定逻辑阶段，具体分配对象仍无法从本切片归因；本切片只能说明“在 600 秒、2337 逻辑小时内没有随样本数或墙钟时长持续增长的特征”。

## 幂等、重启与容量

| 检查 | 30 秒 | 600 秒 |
|---|---|---|
| `total_cash == issued` | 每个 tick 通过（950/950） | 每个 tick 通过（950/950） |
| 双分录对账 | 每个 tick 与每个采样点通过 | 同左 |
| 同一逻辑时刻二次扫掠 `changed=false` | 每个 tick 与重启后通过 | 同左 |
| 重启 `loaded` 且指纹相等 | `f48aa10df4319fb3` | `1df610175e58356d` |
| 账本分录 | 512（封顶） | 512（封顶） |
| 订单 / 成交 | 约 22 / 10 | 22 / 10 |
| 邀约 | 3 | 64（`MAX_INVITATIONS`） |
| 记忆条数 | 20 / 20 / 17（上限 64） | 32 / 32 / 28（上限 64） |
| 每对关系动作 | 7–11（上限 16） | 12–16（上限 16） |
| 对话表 | 0 | 0（本切片不触发对话，仅断言容量与结构） |
| 意图账本 | 有效 | 有效（`MAX_RECORDS=256`） |

现金构成（600 秒结束）：居民账户 14 + 7 + 18 = 39，商人 571，托管 340，合计 950 = `issued`；账本余额表另记 `issuance = -960`、`burn = 10`，差额正是 10 笔成交各燃烧的 1 COIN。

## 发现

1. **测量方法会自己制造“泄漏”**（已修正，属夹具）。见结论第 5 条：`Array[Dictionary]` 每样本 +1,172 字节引擎静态内存（前/后 1/3 差 811,784 字节）。修正方法是固定大小 `PackedInt64Array`；修正后同一世界该差降到 577,172 字节，且 258/291 个相邻样本增量为 0。
2. **`advance_to` 每 tick 都会把整份活农场随下一次保存写盘**，因此文件增长是“有界表上限 + 流动行数”的函数，而不是时间本身。账本先到 512 后封顶、邀约先到 64、关系先到 16，都是既有容量常数在驻留期内的正常收敛。若未来要提高这些上限，需要同时重算 `FarmStore.MAX_BYTES`（2 MiB）与 `WorldPackage.MAX_BYTES`（4 MiB），RECORD-04 已登记该依赖。
3. **本切片不触发居民对话**。并行切片正在给 `residents.json` 增加第六键 `dialogues`；本切片在开世界、每个采样点和最终校验中都调用 `ResidentsStore.valid_dialogues()` / `MAX_DIALOGUE_PLAYERS`，但玩家不对话，所以对话表恒为空。对话的写路径与冷却由该切片的夹具覆盖，本切片只证明“空对话表在长驻留中保持合法”。
4. **静态内存的开局台阶与 840 tick 台阶都可定位到固定阶段**。开局 1.6 MB 由前 10 秒的载入/开户/商人开业构成；tick 840 的 0.5 MB 在三次独立 600 秒运行中位置完全相同（tick 840 = 35 逻辑日 = 5 个 7 日季节边界），且运行中其余所有增长都能对上 `residents.json` 的具体写行。这排除了“随样本数或墙钟持续增长”，但没有内存剖析工具，仍不能指出 840 tick 处具体分配的对象。
5. **邀约表填满后，居民在本世界剩余生命里不再能发起邀约**（设计观察，非本轮缺陷）。600 秒运行在第 532 逻辑小时填满 64 行，全部是 `expired`；`_create_invitation` 在 `invitations.size() >= ResidentsStore.MAX_INVITATIONS` 时返回 `over_capacity`，而裁决路径只把 pending 改成 expired、不删除历史行，也没有任何淘汰或压缩。因此约 22 逻辑日后，居民邀约这条社交动作永久失效。它是有界的（不会增长、不破坏守恒、文档仍合法），但与“长期驻留中关系继续演化”的预期不符。是否保留历史行、按时间淘汰最旧行，或改用“每对/每方未决上限”，属于产品决定；本切片按任务边界只记录事实，未修改生产代码。
6. **没有发现生产缺陷，因此没有修改生产文件**。协调要求优先不改 `Game/`；本切片遵守，唯一改动的文件是新增夹具与本记录（以及 PLAN 的链接）。

## 未覆盖

- **Windows 实机与跨平台文件系统**：只在 macOS 无头运行；Windows 的 rename 替换、路径长度与 CI 均未跑。本夹具没有加入 `.github/workflows/rule-tests.yml`（CI 只跑 30 秒可由后续登记完成，但本轮未改 workflow）。
- **能耗与 CPU/GPU**：无头进程不渲染，不能代表有渲染客户端的帧率或耗电；未测真实驻留 RSS、内存压力或睡眠唤醒。
- **真实玩家与图形客户端**：没有 UI、输入、窗口生命周期；居民动作由权威规则驱动，不是玩家行为。
- **长时间尺度**：600 秒只覆盖 2337 逻辑小时（约 97 逻辑日）；一年、跨季与多年社会关系组合仍由 RECORD-04/11 的逻辑夹具覆盖，但没有真实墙钟驻留。
- **对话写路径**：见发现第 3 条。
- **网络与多客户端**：未接 WSS，单进程权威。
- **保存失败与断电**：本切片只走成功保存路径；写失败注入与崩溃窗口由其他夹具覆盖。

## 需要登记的内容

1. **M13-02 仍未完成**：本记录补上了“真实墙钟驻留 + 文件/引擎内存曲线”的本机证据，但 Windows、能耗与真实玩家仍未覆盖，PLAN 不应据此把 M13-02 标为完成。
2. **CI 登记**：若把 `residency_soak_test` 加入 `rule-tests.yml`，必须用默认 30 秒（本次实测 30.2 秒，加启动约 31 秒，远低于 180 秒看门狗）；不要给 CI 传 `--soak-seconds=600`。本轮未改 workflow。
3. **邀约表填满后长期失效**（发现第 5 条）需要产品决定：保留全部历史行（当前行为，约 22 逻辑日后不再邀约）、按时间淘汰最旧行，还是改成未决上限。本切片未改生产代码，也未增加到夹具断言（当前行为本身是有界的，断言“永远不再邀约”会锁死一个待决设计）。
4. **测量方法修正值得保留**：任何后续内存采样夹具都不应把每样本 Dictionary 计入被测进程的内存曲线；本夹具的固定缓冲写法可作为参照。

## 产物位置

- 夹具：`tests/residency_soak_test.gd`（继承 `SceneTree`；无场景、渲染、UI、网络）。
- 30 秒运行：`.local/verification/residency-soak-1472-486506/`（`world/` + `samples.json`）。
- 600 秒运行：`.local/verification/residency-soak-5384-544372/`（`world/` + `samples.json`；`world/farm.json` 273,188 字节、`residents.json` 55,724 字节、`npc_residents.json` 687 字节）。
- 原始日志：`.local/verification/logs/soak_default_final.log`、`.local/verification/logs/soak_600_final3.log`。
- 采样汇总脚本：`.local/verification/summarize_samples.py`（读取 `samples.json`，输出前/后 1/3 的 min/median/max 与时间线）。
- 600 秒运行前后 `headless_world.gd` 与 `residents_store.gd` 的哈希：`.local/verification/logs/tree_at_run.sha256`（运行后 `sha256sum -c` 通过）。运行结束后并行代理继续编辑 `headless_world.gd`（`2dcde101…`），本记录不覆盖那次改动后的行为。
