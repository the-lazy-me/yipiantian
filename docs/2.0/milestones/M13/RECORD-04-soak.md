# M13-02 · 长期模拟证据（规则夹具）

日期：2026-11-15。状态：**本机无头模拟已执行，未验收**。本记录只报告 `tests/long_soak_test.gd` 的一次完整运行，不表示 M13-02 或 M13 完成；真实驻留、Windows 与能耗均未覆盖。

范围：纯规则夹具，固定种子与固定 UTC 起点，无 UI、无渲染、无网络、无系统时钟；存档通过真实 `FarmStore` 写入隔离目录。本轮只新增 `tests/long_soak_test.gd` 与本记录，未修改任何既有代码、测试、`rules/` 或 workflow，未提交、未推送、未 stash。

前置：[M13 PLAN](PLAN.md)、[M8-05 金融压力模拟](../M8/RECORD-05-stress.md)（到期/交付时间戳记录扫描时刻的既有结论）、[M6 自然集成](../M6/RECORD-06-nature-integration.md)（固定种子与 6 小时天气块）。

## 结论

1. **一年离线结算，一次推进与逐日推进逐字节一致**。作物场景 365 天、1460 个完整天气块，两条路径的完整 `snapshot()` 相等（`raw_equal=yes`）：播种 100、成熟 100、收获 100（含构造函数自带的 4 株初始作物），湿度全部在 `[0,1]`，所有格子逐字段相等。经济场景中原始快照不同，但差异只有 M8-05 已记录的观察时刻字段（`closed_utc` / `delivered_utc` / `at_utc` 与滚动报价序号），经济投影、余额、作物与商品完全一致。
2. **一年脚本化经济循环的现金、商品与分录守恒**。3 个账户各 120 + 银行 2000 + 商人 600，开局共发行 2960 COIN；全年 156 笔成交各燃烧 1、12 次运费各燃烧 2，共烧毁 180，最终 `issued == total_cash == 2780`。365 天里每天断言 `total_cash == issued`，每周断言 `issuance - burn == issued`、`bank.cash == capital - outstanding + fees`、双分录对账与商品守恒；经对账通过，无负余额，无未解释发行。
3. **各表与命令窗口都在界内，归档计数单调**。真实世界一年后的峰值：订单 256（上限）、shipment 12/256、delivery 8/256、losses 4/256、分录 512（上限）、经济命令窗口 64（上限）；`archived_orders` 797 单调递增且不超过订单序号。
4. **一次存档在一年内未触限，但同一脚本化世界的延长运行会在第 630 天超过 `FarmStore.MAX_BYTES`，重试无法保存**。这是本轮发现的真实问题：一年文档 469,212 字节（占上限 89.5%，余量 55,076），第 600 天 517,655 字节仍可保存与重载，第 630 天 525,221 字节保存失败（`verify_farm.pending.json`），重试仍失败，30 天进度未落盘；磁盘上的旧主件仍可加载。探针世界为补足流动性用真实规则贷款（主循环不借这些），因此不能与主世界同日逐字比较；容量结论取自探针自己的保存序列。**同日后已修复并复跑，见「存档上限修复」一节。**
5. **各表单表上限都成立，但合起来不等于文档上限**。按各表行数上限填满（订单 256 行另加商人 bid/ask 两行，最小合法行形状）得到 983,223 字节，是 524,288 上限的 1.87 倍；八张表每张单独都远小于上限。该构造本身不是合法状态（258 行订单超过 `Market.MAX_ORDERS`），只是容量测量。
6. **静态内存采样未显示随操作量加速的泄漏特征**。基线 31,079.4 KB，峰值增量 4,474.2 KB（第 365 天）；增长集中在前 150 天（+4,270.6 KB），之后是每日约 1 KB 的缓慢上升（第 150→365 天共 +203.6 KB）；14 次采样中对象数恒为 1520、资源数恒为 33。这只是本机引擎静态内存的观测，不是进程驻留内存，也不能外推到其他平台。

## 环境与基线

| 项 | 值 |
|---|---|
| 引擎 | `Godot 4.7.2.stable.official.ed1daf0bf`（本机 `/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app`） |
| 仓库 HEAD | `b5430f5d13f9f99e098d355f53614176b5c3fca9`（运行前后一致） |
| 工作树 | 并行任务仍在改 `Game/farm/`、`Game/world/`、多个 `tests/` 与 `rules/project-context.md`；本轮未触碰这些文件，改动只有新增的两个文件。HEAD 在任务期间因并行提交从 `f411fd7` 前进到 `b5430f5`，最终干净运行在 `b5430f5` 上，运行前后 HEAD 不变 |
| 种子 / 起点 | `SEED = 424242`，`START = 1800000000.0`（UTC） |
| 时间步长 | 每天 86400 秒；天气块 21600 秒（每天 4 块）；季节 7 天 |
| 存档上限 | `FarmStore.MAX_BYTES = 524288`，`VERSION = 27` |
| 预算 | 夹具自检 300 秒；外部 `alarm 420`；实测整轮 119.9 秒（`user 118.1`、`sys 0.5`） |
| 产物 | `.local/verification/long-soak-<pid>-<usec>/`（`results.json` + 两个隔离存档目录） |

运行命令：

```bash
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 420 \
  "$GODOT" --headless --path Game --script "$PWD/tests/long_soak_test.gd"
```

同一夹具在 4 次独立进程中运行，检查数、字节数、越界日与内存增量完全一致；基线随进程路径有 3.8 KB 差异（31,075.6 与 31,079.4 KB），属观测噪声。夹具开发早期曾把容量探针世界的样本混入同一条内存序列（35 个样本），已改为只采样主循环世界，本节数据来自修正后的 14 个样本；那是夹具自身的缺陷，不涉及产品代码。

## 夹具与场景参数

| 场景 | 参数与动作 | 主要断言 |
|---|---|---|
| 作物离线一年 | 两块独立农场同时播种全部可用格子（96 格 + 4 株初始作物）；一块一次 `settle(day 365)`，一块每日 `settle`；同一 `Nature(424242)` | 1460 个完整天气块、1461 个触及块（起点落在块内，末尾一块未走完）、三种天气（clear 476 / cloudy 484 / rain 501）、四季、28 个灾害块；`planted == mature == harvested == 100`；完整快照与每格生长/湿度逐字相等；湿度 `[0,1]` |
| 经济离线一年 | A/B 各 120、银行 2000、商人 600；B 种 8 格青菜；B 挂 2 格卖单（第 2 天到期）、A 挂 2 格买单（第 3 天到期）、B 发 3 格运费、A 借 7 天 50；一次推进 vs 逐日推进 | 两条路径贷款都转为逾期、两单都到期、1 次交付；A 可用余额 170、B 袋中 8 格；经济投影逐字相等；原始快照被断言为不同，差异仅观察时刻字段；重复扫描不产生第二次到期/逾期 |
| 脚本化经济循环 365 天 | 3 账户 + 银行 + 商人；每天检查并收获 `field_01`–`field_03` 各 2 格成熟青菜、空出的 ready 格子补种；每天到期扫描、1 笔卖出与 1 笔买入挂单；每周 3 组买卖成交（共 156 笔）；每月放款与发货（13 笔贷款、12 笔运费，其中 4 笔走声明风险损失分支）；每 30 天真实存档 + 重载 | 每天 `total_cash == issued`；每周双分录对账、商品守恒、各表上限、归档计数单调、命令窗口上限；每次存档后读回文本逐字相等并 `restore_snapshot` |
| 存档容量探针 | 另建一个同样的脚本化世界，从第 1 天按同一每日脚本跑到第 630 天，每 30 天真实存档；探针模式用真实规则贷款补足流动性（否则脚本化交易本身持续净流出，测到的是流动性墙而不是容量） | 记录首次失败日、字节数、失败原因、磁盘上旧件是否可加载、重试结果、未落盘天数 |
| 表饱和尺寸 | 在内存中把订单 256 行（另加商人的 bid/ask 两行，共 258）、成交 512、shipment 256、delivery 256、loss 256、分录 512、两个命令窗口各 64（512 字节负载）全部填满，序列化后测尺寸 | 每张表单独是否小于上限（是）；合计是否小于上限（否，记录差值） |

说明：饱和探针使用最小合法行形状，只测表边界，不是玩法证据；其合计因此是真实行形状的下界。该构造也**不是一个合法状态**（258 行订单已超过 `Market.MAX_ORDERS`），`Market.valid` 会拒绝它，所以探针只测尺寸、不把结果当作存档可接受的证据。

## 实际原始输出

```text
SOAK crop_offline days=365 completed_blocks=1460 touched_blocks=1461 kinds={"clear":476,"cloudy":484,"rain":501} seasons=4 disasters=28 planted=100 mature=100 harvested=100 one_shot_ms=302 daily_ms=403 raw_equal=yes moisture_equal=yes
SOAK economy_offline days=365 projection_equal=yes raw_equal=no difference=closed_utc/delivered_utc/delivery_at_utc+rolling_quote_sequence issued=2838 total_cash=2838 loan=overdue delivered=1
SOAK document bytes total=469212 headroom=55076 decorations=439 economy=280357 orders=78442 ledger_entries=132090 trades=48193
SOAK economy_loop days=365 trades=156 loans=13 shipments=12 orders_max=256 archived_orders=797 shipments_max=12 deliveries_max=8 losses=4 ledger_entries_max=512 command_window_max=64 json_max_bytes=469233 json_final_bytes=469212 cash_conserved=yes reconcile=yes
SOAK capacity_probe ran_days=630 last_saved_day=600 last_saved_bytes=517655 store_limit=524288 first_failed_day=630 first_failed_bytes=525221 reason=verify_farm.pending.json on_disk_bytes=517655 on_disk_loadable=true retry_ok=false pending_bytes=525221 live_bytes_over_limit=true lost_days=30
SOAK saturated_tables orders=258 trades=512 shipments=256 deliveries=256 losses=256 ledger_entries=512 json_bytes=983223 headroom=-458935 store_limit=524288
SOAK saturated_parts {"deliveries":53693,"economy_window":40321,"farm_window":46977,"ledger_entries":133201,"losses":70589,"orders":74717,"shipments":87081,"trades":147133}
SOAK saturated_single_fits {"deliveries":true,"economy_window":true,"farm_window":true,"ledger_entries":true,"losses":true,"orders":true,"shipments":true,"trades":true}
SOAK saturated_aggregate_fits=no bytes=983223 limit=524288 over_by=458935
SOAK memory baseline_kb=31079.4 peak_delta_kb=4474.2 final_delta_kb=4474.2 samples=14 interval_days=30 metric=engine_static_memory scope=this_machine_only
LONG_SOAK_TEST checks=11839 failures=0 days=365 peak_delta_kb=4474.2
```

标准错误只有两条，且都是容量探针预期的失败路径，不是夹具错误：

```text
WARNING: FARM_STORE stage=verify_farm.pending.json error=1
     at: push_warning (core/variant/variant_utility.cpp:1033)
```

## 守恒与有界性

| 恒等式 / 边界 | 一年实测 | 结论 |
|---|---|---|
| `total_cash == issued` | 循环：开局 2960，全年燃烧 180 后终值 2780；离线场景 2838 | 逐日与逐周成立 |
| `issuance - burn == issued` | 每周由 `Economy.reconcile` 返回 | 成立 |
| `bank.cash == capital - outstanding + fees` | 每周与两个离线路径 | 成立 |
| 双分录对账（含被驱逐分录的检查点） | 每周，共 52 次 | 通过 |
| 商品：袋 + 商人库存 + 卖单预留 + 在途 + 损失 == 收获 + 商人授予 20 | 每周，青菜 | 成立 |
| 订单 / shipment / delivery / loss | 256 / 12 / 8 / 4（上限 256 / 256 / 256 / 256） | 界内 |
| 分录 | 512（上限 512，驱逐按检查点对账） | 界内 |
| 命令窗口 | 经济 64（上限 64）；农场 0（本夹具未走农场命令通道，故未压到上限） | 经济界内；农场窗口只在饱和探针中测得 64 行、46,977 字节 |
| 归档计数 | `archived_orders` 797，shipment/delivery/loss 计数单调 | 单调且不超过各自序号 |
| 存档字节 | 一年峰值 469,233（89.5%），第 630 天越过上限 | 一年内界内，之后**不成立** |

到期/交付时间戳的差异是已知且被显式断言的：一次推进把 `closed_utc` 记为第 365 天、逐日推进记为第 2 天；交付同理（第 365 天 vs 第 1 天）。夹具因此比较“经济投影”（去掉这些观察时刻字段、滚动报价行、`market.sequence`、分录与成交），并断言原始快照不同。若未来要求崩溃后逐字重放同一快照，需要为到期/交付记录真实到期时刻，或让扫描不写入随观察时刻变化的字段——这是 M8-05 已登记的待决设计，不是本轮新问题。

## 内存采样

采样点：第 0 天与每 30 天，外加第 365 天，共 14 次；指标为 `OS.get_static_memory_usage()` 与 `Performance.MEMORY_STATIC`（两者在本机完全相等），同时记录 `OBJECT_COUNT` 与 `OBJECT_RESOURCE_COUNT`。

| 天 | 静态内存 KB | 相对基线 KB | 对象 | 资源 |
|---|---|---|---|---|
| 0 | 31079.4 | 0.0 | 1520 | 33 |
| 30 | 32461.2 | 1381.8 | 1520 | 33 |
| 60 | 34351.5 | 3272.1 | 1520 | 33 |
| 90 | 34496.7 | 3417.3 | 1520 | 33 |
| 120 | 34527.9 | 3448.5 | 1520 | 33 |
| 150 | 35350.0 | 4270.6 | 1520 | 33 |
| 180 | 35377.3 | 4297.9 | 1520 | 33 |
| 210 | 35412.7 | 4333.3 | 1520 | 33 |
| 240 | 35435.0 | 4355.7 | 1520 | 33 |
| 270 | 35461.2 | 4381.9 | 1520 | 33 |
| 300 | 35487.9 | 4408.6 | 1520 | 33 |
| 330 | 35518.8 | 4439.4 | 1520 | 33 |
| 360 | 35547.4 | 4468.1 | 1520 | 33 |
| 365 | 35553.5 | 4474.2 | 1520 | 33 |

趋势：前五个 30 天区间（第 0→150 天）的增量分别为 1381.8 / 1890.3 / 145.2 / 31.1 / 822.1 KB，之后稳定在每 30 天 22–36 KB；第 150 天到第 365 天共 215 天增加 203.6 KB（平均 0.95 KB/天），第 240 天到第 365 天共 125 天只增加 118.5 KB。对象与资源计数全程不变，30 天增量没有随天数加速（第 150 天后稳定在 22–36 KB/30 天），也没有回落；这只说明本机 365 天内没有对象泄漏特征，不足以判定不存在缓慢增长。

边界：这只是本机 macOS 进程内引擎静态内存的采样，**不是真实驻留内存（RSS）**，不能作为绝对占用、Windows 表现或能耗结论；采样间隔 30 天，短于该间隔的峰值与回收不会出现在数据里。容量探针的第二个世界未采样，避免把两个世界混进同一条趋势。

## 发现的问题

1. **同一脚本化世界的延长运行会在第 630 天超过存档上限，且重试无法保存**（本轮最重要发现，未修复，需产品决定）。一年 469,212 字节、余量 55,076；第 600 天 517,655 字节仍能保存并重载；第 630 天文档 525,221 字节，`FarmStore` 先写完 `farm.pending.json`，再读回校验时因 `_read_text` 拒绝超过 `MAX_BYTES` 的文件而返回 `verify_farm.pending.json`，重试同样失败（`retry_ok=false`），30 天进度未落盘，同时磁盘上 517,655 字节的旧主件仍可加载（`on_disk_loadable=true`），失败那次写入的 525,221 字节 `farm.pending.json` 留在目录里。按探针自身第 600→630 天的实测增量 7,566 字节（约 252 字节/天），第 600 天剩余的 6,633 字节余量约 26 天用完，因此真实越界点在第 601–630 天之间，第 630 天是首次被 30 天检查点捕获的失败。第 600 天的存档里成交表 255 行（上限 512）、订单表 256 行、分录表 512 行；订单与分录已在上限驱逐，成交与 shipment/delivery/loss 行仍在增长。探针世界用真实规则贷款补足流动性（主世界的脚本化交易持续净流出），因此它比主循环多出贷款分录；这是真实规则路径，不是伪造现金。保存失败目前只表现为一条 `push_warning`，UI 是否呈现不在本夹具范围；本夹具没有发现能让文档自动缩回上限以下的路径。
2. **单表上限之和大于文档上限**。八张表按各自行数上限填满（最小合法行形状）为 983,223 字节，超限 458,935；其中成交 147,133、分录 133,201、shipment 87,081、订单 74,717、losses 70,589、两个命令窗口合计 87,298。也就是说每条“某表不超过 N 行”的断言都成立，但它们合起来可以写出一个 `FarmStore` 读不回来的文档。选用真实行形状只会更大。该构造的 258 行订单超过 `Market.MAX_ORDERS`，仅用于测尺寸。
3. **脚本化交易本身是持续净流出，不能当作平衡性结论**。每周买卖各 2 格、单价 6（成交各烧 1 COIN），每次运费另烧 2 COIN；另有每日挂单/到期扫描，但都不产生收入。所以循环只用于采样守恒与有界性；容量探针延长到 630 天时用真实规则贷款补足流动性，否则测到的是流动性墙而不是容量。这不代表经济平衡、玩家可维生或真实玩家行为。
4. **农场命令窗口未被本夹具覆盖**。夹具直接调用 `FarmState` 公开方法而非命令通道，一年内 `farm_window_max=0`；该窗口的上限只在饱和探针里被填到 64 行验证过形状。若需要真实长跑覆盖，应在下一轮让每日动作走 `commit_command` 路径。

## 存档上限修复（同日）

上面第 1、2 条发现指向同一个设计缺口：文档的界是各表行数上限之和，不是任一单表。按各表上限测得的最小合法行形状合计 983,223 字节，因此 `FarmStore.MAX_BYTES = 524288` 会拒绝一个完全合法、各表都在界内的世界。修复取最小改动：把 `FarmStore.MAX_BYTES` 提到 2 MiB（覆盖实测最坏形状约 2.1 倍），并同步把 `WorldPackage.MAX_BYTES` 从 1 MiB 提到 4 MiB，避免存档能写而导出拒绝。两个常量都带注释说明它们必须一起调整，且依据是实测最坏形状而不是“更保险”。

修复后同一夹具复跑：

```text
SOAK capacity_probe ran_days=1100 last_saved_day=1080 last_saved_bytes=626937 store_limit=2097152 first_failed_day=none
SOAK saturated_tables orders=258 trades=512 shipments=256 deliveries=256 losses=256 ledger_entries=512 json_bytes=983223 headroom=1113929 store_limit=2097152
SOAK saturated_aggregate_fits=yes bytes=983223 limit=2097152 over_by=0
LONG_SOAK_TEST checks=12206 failures=0 days=365 peak_delta_kb=4474.2
```

- 容量探针跑到 1100 天仍能保存（第 1080 天 626,937 字节），首次失败日 `none`；原先第 630 天的失败不再出现。
- 表饱和合计 983,223 字节，余量 1,113,929，判定为 `fits=yes`。
- 一年主循环断言与内存采样不变（检查数从 11,839 增到 12,206 是复跑时夹具自身的探针断言变化，守恒结论一致）。
- 存储回归：`FARM_STORE_TEST 119/0`、`WORLD_PACKAGE_TEST 126/0`、`WORLD_TRANSFER_TEST 113/0`、`V27_IMPORTER_TEST 69/0`。

仍未解决的边界：如果某张表的行上限被提高，两个常量必须同步重算；没有自动断言“饱和形状 < 上限”的门禁，只有本夹具的测量。压缩或分表存储仍未实现，也不在当前需求内。

## 未验证项

- **真实驻留**：未测进程 RSS / 内存压力 / 长时间墙钟运行；本记录只有引擎静态内存采样，且仅 365 天、30 天间隔。
- **双平台**：只在 macOS 无头运行；Windows 实机、Windows 文件系统语义（rename 替换、大小写、路径长度）与 CI 上的同一夹具均未跑。
- **能耗**：未测 CPU/GPU 占用、帧率或耗电；无头夹具不能代表有渲染的游戏。
- 网络权威与多世界：未接网络，只有单进程规则状态。
- 存档写入中途崩溃（SIGKILL / 断电）：本轮的失败是文档超限，不是进程被杀；提交边界中断见 [M3-03](../M3/RECORD-03-commit-recovery.md)，两者不互相覆盖。
- 超过 365 天的内存趋势与超过 630 天的文档行为：探针在首次失败即停止，未继续观察交易表达到 512 行后的收敛点。
- 磁盘满、权限拒绝等 OS 级写入错误、UI 对保存失败的提示与玩家恢复路径。

## 需要登记的内容

1. **M13-02 尚未完成**：本轮只有本机规则模拟证据；真实驻留、Windows 与能耗仍需单独执行并在 PLAN 中分别报告。建议在 [M13 PLAN](PLAN.md) 的 M13-02 条目下登记本记录链接。
2. **存档容量问题已按“提高上限”处理**（见「存档上限修复」）：`FarmStore.MAX_BYTES` 2 MiB、`WorldPackage.MAX_BYTES` 4 MiB，依据是实测饱和形状 983,223 字节。压缩/分表与超限前的玩家提示没有实现，仍属后续容量工作需要。
3. **单表上限与文档上限的联合预算**：现在由一个显式常量关系承担（2 MiB 覆盖实测最坏形状），两个常量旁都写了同步要求；没有自动门禁断言，表上限变化时必须重测。
4. **脚本化经济循环不能作为平衡性依据**：它按周固定买卖且持续燃烧费用；若后续要做经济平衡结论，需要单独设计有收入来源的场景。
5. 本夹具尚未加入 `.github/workflows/rule-tests.yml`（本轮不允许改 workflow）。整轮约 120 秒，接近该工作流 180 秒的单夹具看门狗上限；若要纳入 CI，需评估是否提高该夹具的超时或缩减探针天数。

## 产物位置

- 夹具：`tests/long_soak_test.gd`（继承 `SceneTree`，无场景/渲染/UI/网络）。
- 本次运行：`.local/verification/long-soak-51995-312103/`（`results.json`、`economy-world/`、`capacity-world/`）；捕获的完整 stdout/stderr 与运行前后 HEAD 在 `.local/verification/long-soak-final2/`。
- 容量探针的最后一份成功存档 `capacity-world/farm.json`（517,655 字节）保留在运行目录中，可直接复核第 600 天的文档构成与第 630 天的失败复现。
