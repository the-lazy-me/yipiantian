# M13-11 · 长期模拟切片

状态：已执行（2026-11-16），未验收。范围：纯规则夹具 `tests/long_simulation_test.gd`，在 3 个独立构造的世界实例中各跑 60 个逻辑日，逐日检查现金守恒、对账、数量非负、重放不二次结算、单位上限、交战损失上限、事件表有界、世界隔离与固定输入确定性。不涉及 UI、网络、真实墙钟驻留、存档格式或生产代码修改。

前置：[M13-02 PLAN](PLAN.md)、[M8-05 压力模拟](../M8/RECORD-05-stress.md)、[M13-10 整合链路](RECORD-10-chain-conflict.md)。

## 模拟设计

- 引擎：Godot 4.7.2.stable，Apple Silicon macOS，无头隔离进程。
- 固定逻辑时钟 `START = 1800028800`；每个世界先推进到 `START + 1d`，使权威时间戳完全来自逻辑时钟，而不是单调会话时钟。
- 世界实例：
  - `alpha`：seed 42001，world id `long-alpha`。
  - `beta`：seed 42002，world id `long-beta`；市场售价、物流日、公建日不同。
  - `alpha_replay`：与 `alpha` 完全相同的 seed、world id 与日程，独立目录，用于确定性复跑。
- 每个世界独立目录 `.local/verification/long-simulation-<pid>-<usec>/world-<name>/`；固定 seed 在开世界前写入 `NatureStore`。
- 每日流程：
  1. 作物生长与收获：A 3 格、B 2 格、C 1 格青菜；当天收获后播种次日份。
  2. 市场：A/B 各挂 1 格卖单，B 另挂 1 格不交叉买单（次日到期）；每 10 天 B 真实买入 1 格；共 123 笔成交。
  3. 物流：第 7 天（`beta` 第 17 天）A 发运 1 格，推进 6 小时后到达，产生 1 条交付事件。
  4. 银行：A 第 1 天借 300、7 天期，第 8 天进入 `overdue`；B 第 2 天借 100、第 6 天还本付息 105。
  5. 单位：B 招募 1 人守卫长期存活；C 招募 1 人民兵，第 4 天因断粮逃散并退出名册。每日补给结算在同一逻辑秒调用两次，第二次必须为 `settled_this_tick` 且扣粮为 0。
  6. 参与/交战：第 1、11、21、31、41、51 天轮换 `limited` 制度窗口并重新同意；第 5、11、21、31、41、51 天各完成一次合法交战，共 6 次，每次损失 4，累计 24。
  7. 组织/基金/公共项目：A 创建组织、B 加入，两人各缴入 60，登记道路项目、承诺 120 并通过组织基金建成；`alpha` 第 16 天、`beta` 第 26 天完成。
  8. 每日末再次执行经济扫描，第二次必须无新增工作；市场事件与交战事件各重放一次同一命令 id，必须为 `duplicate` 且不再结算。
- 性能取舍：逐格作物收获/播种直接调用 `FarmState` 的规则入口（与 M8-05 同法），不经过每格一次 v27 存盘的 `HeadlessWorld.execute`；世界权威仍负责所有市场、贷款、单位、参与、交战、组织、基金与公共项目操作，且下一次权威命令会持久化整份活农场。按格提交的作物链路已由 M13-01 整合夹具覆盖。首版按格走权威命令耗时 90 秒，超出 60 秒预算，故采用此取舍。

## 覆盖与断言

每个世界 60 个逻辑日，逐日实际比较：

1. `total_cash == issued`；`issuance - burned == issued`；账户 + 商人 + 托管 + 银行 == `total_cash`；`bank.cash == capital - outstanding + fees`。
2. 账户现金、厨房库存、累计产出、订单/成交/发货/交付/损失数量无负值。
3. 同一市场事件与同一交战命令重放不二次成交/扣款；同一逻辑秒重复经济扫描不产生第二次到期、交付或过期；重复补给结算不二次扣粮。
4. 单位人数在 `UnitState.MAX_PEOPLE_PER_UNIT` 内、名册不超过 `MAX_UNITS`、欠供天数有界。
5. 每次交战损失不超过参与制度窗口上限（本例 4），目标累计损失不超过权威固定上限 100（本例累计 24）。
6. 事件表与内存窗口按既有容量常数有界：账本 `MAX_ENTRIES=512`、订单 256、成交 512、发货/交付/损失 256、参与交战 1024、命令结果 64、冲突已消费 1024、目标 256、单位命令 256、基金历史 256 等。
7. `beta` 运行前后 `alpha` 的活状态指纹与目录文件摘要不变；`alpha_replay` 与 `alpha` 指纹一致。

结构校验器（`Economy.valid`、`Participation.valid`、`ConflictSettlement.valid_context`、`UnitState.valid`、`PublicWorks.valid`）在第 5、15、30、45、60 天执行。

## 实际原始输出

本机无头运行（三次独立进程结果一致）：

```text
MEASURE world=alpha days=60 cash_issued=2835 final_total=2835 events=643 fingerprint=3558f8208e38e0f0
DETAIL world=alpha trades=123 engagements=6 conflict_loss=24 deliveries=1 losses=0 built=1 ledger=512 issuance=2960 burned=125
MEASURE world=beta days=60 cash_issued=2835 final_total=2835 events=643 fingerprint=fdbe0c7ef062c918
DETAIL world=beta trades=123 engagements=6 conflict_loss=24 deliveries=1 losses=0 built=1 ledger=512 issuance=2960 burned=125
MEASURE world=alpha_replay days=60 cash_issued=2835 final_total=2835 events=643 fingerprint=3558f8208e38e0f0
DETAIL world=alpha_replay trades=123 engagements=6 conflict_loss=24 deliveries=1 losses=0 built=1 ledger=512 issuance=2960 burned=125
DETERMINISM alpha=3558f8208e38e0f0 replay=3558f8208e38e0f0 equal=true
ISOLATION alpha=3558f8208e38e0f0 beta=fdbe0c7ef062c918 alpha_unchanged=true
ELAPSED_MS=39721
LONG_SIMULATION_TEST checks=11650 failures=0
```

解释：毛发行 2960 = 3 × 120 开户赠款 + 2000 银行资本 + 600 商人预算；销毁 125 = 123 笔成交手续费 + 2 笔运费；`2960 - 125 = 2835`。两个不同 seed 的世界现金数值相同是因为日程相同、只有自然 seed 不同；指纹差异来自 `nature` 等状态。

## 发现

1. **未发现生产不变量破坏**。60 天 × 3 个世界实例的 11650 项检查全部通过；未修改生产代码。
2. **账本到达容量上限后按既有 checkpoint 规则压缩**。第 60 天 `MAX_ENTRIES=512` 已满，`Economy.reconcile()` 仍逐日通过，`issuance - burned == issued` 与四类现金持有方对账成立。这是既有的有界审计窗口，不是无界增长；若未来要求 512 条以上的逐笔长期审计，需要产品层决定如何归档，而不是扩大内存表。
3. **确定性可跨进程复现**。`alpha` 在三次独立进程中均得到 `3558f8208e38e0f0`；同进程内的独立目录复跑也一致。`beta` 指纹为 `fdbe0c7ef062c918`，与 `alpha` 不同。
4. **世界隔离成立**。`beta` 全部运行结束后，`alpha` 的活状态指纹与目录文件摘要均未变化。
5. **交易损失表为空是设计输入，不是失败**。本切片只发运 `safe` 货物；申报风险运输及其损失分支由 M8-05 覆盖。

## 未覆盖

- 真实墙钟长时驻留（本切片只有逻辑时钟，没有数小时/数天的真实进程驻留、睡眠唤醒、系统压力或内存 RSS 曲线）。
- Windows 实机、CI、真实文件系统断电/崩溃窗口；仅本机 macOS 无头进程。
- UI、渲染、输入、窗口生命周期与能耗。
- 网络多客户端、真实 WSS 传输、并发写与重连。
- 作物逐格操作经权威命令提交；该链路由 M13-01 整合夹具覆盖，本切片为控制时长改为直接规则调用。
- 60 天切片不等于多年模拟；天气极端值、保险赔付（尚未实现）、多商品市场和更复杂社会关系的长期组合未穷举。

## 复现

```bash
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
cd /Volumes/Disk-1tb/yipiantian
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/long_simulation_test.gd"
```

产物只写入 `.local/verification/`。本机耗时约 39 秒，满足 60 秒预算。
