# M13-01 · 跨系统整合链路证据（规则夹具）

日期：2026-11-15。状态：**本机无头链路已执行并通过，未验收 M13-01**。本记录只报告 `tests/chain_integration_test.gd` 的一次完整运行，不表示 M13-01 或 M13 完成；治理/冲突链路中的建造强制、Windows、网络与真实驻留均未覆盖。

范围：一条固定种子、固定逻辑时钟、固定交易序列的端到端链路，覆盖现有规则边界（天气、生长、灾害、收获、市场、撮合、运输风险、银行、贷款、地籍）。纯规则夹具，无 UI、无渲染、无网络、无系统时钟；存档通过真实 `FarmStore` / `NatureStore` / `TerritoryStore` 写入隔离目录。本轮只新增 `tests/chain_integration_test.gd` 与本记录，未修改任何既有代码、测试、`rules/` 或 workflow，未提交、未推送、未 stash。

前置：[M13 PLAN](PLAN.md)（M13-01）、[ADR-023 地籍](../../decisions/ADR-023-land-cadastre.md)、[M11 RECORD-02 地籍权威](../M11/RECORD-02-cadastre-authority.md)、[M6 自然集成](../M6/RECORD-06-nature-integration.md)、[M7 RECORD-03 撮合](../M7/RECORD-03-matching.md)、[M7 RECORD-04 物流](../M7/RECORD-04-logistics.md)、[M8 RECORD-03a 运输损失](../M8/RECORD-03a-transport-loss.md)、[M8-05 金融压力](../M8/RECORD-05-stress.md)。

## 结论

1. **整条链路在本机无头运行中通过：`checks=509 failures=0`。** 播种 → 生长（晴天正常速率、旱地半速、雨天全速、一次干旱与一次风暴）→ 收获进本人 bag → 农田市场卖单 → 与另一账户撮合成交（1 COIN 手续费销毁）→ 两次声明风险发货（一次到达、一次损失）→ 银行开户/借款/还款/逾期 → 地籍主张、转移与建造权限查询；每一环都断言上一环资产的落点。
2. **商品守恒在每个阶段成立**：`produced + merchant grant == bags + merchant stock + sell escrow + transit + lost`。期末 `6 + 120 = 126`，右侧为 bag 5（A 3 + B 2）+ 商人库存 96 + 卖单托管 24（商人卖价挂单 4×6）+ 在途 0 + 损失 1。逐商品检查：青菜 26=26，其余五种 20=20。
3. **现金守恒在每个阶段成立**：`total_cash == issued`，双分录每次对账通过（12 个检查点）。总发行 2840（2×120 开户 + 600 商人预算 + 2000 银行资本），销毁 5（成交 1 + 两次运费 2+2），净发行与期末总现金均为 2835：账户 430（A 122 + B 308）+ 商人 260 + 托管 340 + 银行 1805。银行恒等式 `2000 − 200 未偿本金 + 5 已收费用 = 1805` 成立。
4. **运输风险按持久化字段确定性结算**：序号 1、青菜 1 格、`chain_a`、农田市场→港口市场、出发 `START+262600` 的掷值为 830（≥250）→ 到达；序号 2、出发 `START+264000` 的掷值为 244（<250）→ 损失。损失事件写入 `loss_1`，含 `shipment_id`、`victim`、`quantity=1`、`unit_value=6`、`value=6` 与 `depart..arrive` 的风险窗口；货物不回流到任何账户。
5. **重复命令 id 不产生第二条记录**：播种、收获、买单、损失发货、借款、还款六个已提交 id 重放均为 `duplicate`，完整 `snapshot()` 逐字段不变；成交、发货、交付、损失、贷款、订单、分录、净发行、事件序号与命令窗口计数全部不变。地籍主张重放同样幂等，地籍文档逐字段不变。
6. **存档 → 重开保留全部关键链路**：真实 `save()` 后在同一目录以同一 world id 重开得到 `loaded`，完整 farm/decorations 快照逐字段相同；两袋、两账户现金、成交、到达/损失、贷款偿还/逾期、商人/银行现金、两块地籍与账本对账全部保留；重开后再次重放仍为 `duplicate` 且状态不变。
7. **未发现规则计算错误**。天气、湿度、生长、灾害、掷值、成交价格/费用/退款、贷款费用与银行余额均与本记录事先写下的固定夹具完全一致。

## 链路与检查矩阵

| # | 链路 | 关键断言 | 上一环资产去向 | 检查 |
|---|---|---|---|---|
| 0 | 启动 | 固定种子被农场采用；世界 id、逻辑时钟、首个 6 小时天气块、无灾害、两袋与共享库存为空、零发行 | 夹具：`nature.json` 先写入种子 | 14 |
| 1 | 播种与生长 | 6 格青菜 + 1 格胡萝卜；晴/湿速率 1.0；7199/7200 秒成熟边界；干旱块（cloudy+drought 3）后湿度 0.1875；旱地 cloudy 半速（3600 秒→1800 生长秒）；雨天在旱土上仍为 1.0；雨块湿度 0.4375→0.6875 | 种下作物写入各自格子并由 A 拥有 | 89 |
| 2 | 收获 | 6 次收获均为 `greens`×1；全部进入 **A 自己的 bag**，共享库存为 0；`harvested[greens]=6`；格清空但保留 0.6875 湿度；B 袋仍为 0 | bag 6 格（商品守恒 6=6） | 44 |
| 3 | 账户与商人 | A/B 各得 120；商人预算 600、每商品授予 20、12 条滚动报价、bid 5/ask 7、库存 16/商品、现金 260 + 托管 340 = 600 | 发行 840，现金 840 | 45 |
| 4 | 撮合成交 | A 卖 2@6（离袋）；B 买 2@7；成交价 6、名义 12、费 1、卖家得 11、买家退 2；A 现金 131、B 108、B 袋 2；双方订单 filled；销毁 1 | 2 格从 A 袋进入 B 袋；1 COIN 离开发行 | 43 |
| 5 | 发货 | 声明风险；序号 1 掷值 830 到达（+1 回 A 袋）；序号 2 掷值 244 损失（`loss_1`，不入账）；每次运费 2 销毁；到达/损失行与风险窗口 | 在途 1 → 0；损失 1 格；A 袋 4→3→4→3 | 95 |
| 6 | 银行与贷款 | 银行资本 2000；A 借 100（费 5）并还 105 → repaid；B 借 200（费 10）保持 open；A 现金 227→122，B 308；银行 1900→2005→1805 | 现金从账户进入银行并回流 | 54 |
| 7 | 风暴与逾期 | 风暴块（cloudy+storm 1）可见，湿度 0.8125 wet；务必在到期前仍为 open；到 `START+869400` 结算恰有 1 笔逾期；逾期不动现金；储备报告 1 逾期/1 已还/资产 200；账本各类行数正确 | 贷款状态 open→overdue；现金不变 | 36 |
| 8 | 地籍 | 默认 6 块全 unclaimed；未主张地不可建造但可通行；A 主张 `parcel_01` 后可建造/通行，B 不可；A 不可在 B 的 `parcel_02` 建造/通行；B 转移给 A 后权限互换 | 地籍主张/转移持久化到 `territory.json` | 25 |
| 9 | 重放 | 6 个命令 id + 地籍主张重放均为 duplicate；快照逐字段不变；所有表与发行/序号计数不变 | 无第二次成交/发货/损失/贷款/分录 | 28 |
| 10 | 重启 | `save()` → 同目录重开为 loaded；farm/decorations 快照逐字段相同；bag、现金、成交、到达/损失、贷款、商人/银行、地籍全部保留；重开后重放仍幂等；重启后现金/商品守恒 | 全部资产从磁盘恢复 | 36 |
| | **合计** | | | **509** |

## 固定夹具

| 项 | 值 |
|---|---|
| 引擎 | `Godot 4.7.2.stable.official.ed1daf0bf`（本机 `/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app`） |
| 仓库 HEAD | 最终运行在 `0066b2efd138a8af5d704dd2af4a413079166ab8`，运行前后 HEAD 不变；任务开始时为 `f411fd7`，期间并行提交先后推进到 `7b28af0`、`04f44a7`、`0066b2e`，每一 HEAD 上的复跑结果一致 |
| 工作树 | 并行任务仍在改 `Game/farm/farm_state.gd`（最终运行时仍为修改状态）；本轮未触碰这些文件，改动只有新增的两个文件。夹具按当时的实际 API 编写，在同一工作树上连续复跑结果一致 |
| 种子 / 起点 | `SEED = 101507`，`START = 1800014400.0`（UTC），首块 `83334` |
| 天气块 | 21600 秒；起点 `clear`，湿度 0.5 |
| 干旱 | 块 `83335`（相对 6h），`drought` 严重度 3；块完成后湿度 0.1875 |
| 风暴 | 块 `83365`（相对 186h），`storm` 严重度 1；块完成后湿度 0.8125 |
| 作物 | 青菜 1800 秒、胡萝卜 7200 秒；`YOUNG_PROGRESS=0.35` |
| 商人报价 | 青菜 base 6 → bid 5 / ask 7；每商品授予 20、挂单 4、预算 600 |
| 成交 | A 卖 2@6、B 买 2@7；maker 价 6；名义 12；费 1；卖家 11；买家退 2 |
| 发货 1 | 相对 262600 出发，到达 263200；掷值 `830` ≥ 250 → 到达；运费 2 |
| 发货 2 | 相对 264000 出发，到达 264600；掷值 `244` < 250 → 损失 `loss_1`；运费 2 |
| 贷款 | 期限 604800；A 100（费 5）即还；B 200（费 10）在相对 869400 逾期 |
| 端口/位置 | 农田市场 `farm_market` → 港口市场 `harbor_market`；交付 600 秒 |

说明：两个运输掷值依赖 owner id（`chain_a`）与出发时刻，已连同夹具一起冻结；改动其中任一项都会改变确定性结果，测试会因此失败而不是静默漂移。

## 守恒结论

商品（期末，六种商品逐项检查，括号内为青菜）：

```text
produced + granted        6 + 120 = 126   (青菜 6 + 20 = 26)
bags                      A 3 + B 2 = 5   (青菜 5)
merchant stock            16 × 6 = 96     (青菜 16)
sell escrow (open asks)   4 × 6 = 24      (青菜 4)
transit                   0
lost                      1                (青菜 1)
```

现金（期末）：

```text
issuance   120 + 120 + 600 + 2000 = 2840
burned     1 (trade) + 2 + 2 (shipping) = 5
issued     2840 - 5 = 2835

accounts A 122 + B 308 = 430
merchant 260
escrow   340
bank     1805
total    2835
```

银行恒等式：`bank.cash 1805 == capital 2000 − outstanding principal 200 + collected fees 5`。

账本：`open_account` 2、`merchant_budget` 1、`trade` 1、`shipping_fee` 2、`bank_open` 1、`loan_issue` 2、`loan_repay` 1；另有滚动报价的 `escrow_hold`/`escrow_release` 行。每个阶段都验证双分录对账、`issuance − burned == issued` 与各现金持有者之和。

## 实际原始输出

运行命令（仓库根目录）：

```bash
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 420 \
  "$GODOT" --headless --path Game --script "$PWD/tests/chain_integration_test.gd"
```

末行：

```text
CHAIN_INTEGRATION_TEST checks=509 failures=0
```

实测整轮 0.65 秒（`user 0.44`、`sys 0.06`），退出码 0；509 条 `PASS`、0 条 `FAIL`、0 条 `ERROR`。完整输出保存在 `.local/verification/chain_integration_run.log`（已被 `.gitignore` 的 `/.local/` 覆盖）。分阶段检查数：boot 14、sow_grow 89、harvest 44、accounts_merchant 45、trade 43、shipping 95、bank_loans 54、storm_overdue 36、cadastre 25、replays 28、restart 36。

## 发现的真实问题

1. **地籍权限尚未进入建造入口（已知缺口，本轮再次确认）**。`FarmState.build` 只校验时间、玩家、槽位、蓝图与占用，不查询 `TerritoryState.may_build`；`ADR-023` 决定 6 与 `M11 RECORD-02` 已记录“土地权限进入建造命令入口的决定仍待完成”。本链路因此只断言权限查询（owner 可建、他人不可建、未主张地不可建但可通行、转移后互换），**没有**把“不可建造”当成已实现的强制；夹具也没有执行任何建造命令，避免把查询用作用例证据。这是 M13-01“治理”环节仍缺的一半。
2. **`advance_to` 本身不落盘，持久化由调用方负责**。`HeadlessWorld.advance_to` 只结算生长与一次经济扫描，不写存档；`world_server.gd` 与 `headless_runner.gd` 在推进后显式调用 `world.save()`。本链路同样在重开前显式 `save()`。这不是缺陷，但属于必须写进调用契约的边界：只推进不保存的世界在崩溃后会丢失这段进度与到达/损失结果。
3. **重放结果不携带市场/贷款计数**。`execute` 对已提交 id 返回 `stage=duplicate`，但不含 `market_expired/matched/delivered/lost/loans_settled`，而新提交结果含这些字段。消费方不能把重放当成“本轮 0 次成交/0 次到达”的证据；本链路只把重放用于幂等断言，不读取这些计数。属于结果形状的不对称，不是计算错误。

## 未验证项

- Windows 实机、网络多客户端/身份解析、UI/场景呈现与能耗。
- 地籍对建造/拆除的强制联动（未实现，见问题 1）。
- 玩家冲突事件（偷取、授权收获、冲突拒绝）未在本链路触发；现有测试已单独覆盖，本链路只走所有者收获。
- 长时间运行的表/文档上限、真实驻留与内存（M13-02 覆盖）。
- 跨版本升级、备份恢复与失败回退（M13-03 覆盖）。
- 固定种子与固定脚本序列之外的分布、边界压力与并发交错。

## 需要登记的内容

1. 在 `docs/2.0/milestones/M13/PLAN.md` 的 M13-01 下登记本记录链接，并明确这是“本机规则链证据，不是阶段验收”。
2. 在 `rules/project-context.md` 的事实记录中新增一条 M13-01 条目（固定种子 101507、检查 509、守恒数字、两掷值、`advance_to` 持久化边界），写法与现有 M6 集成条目一致。
3. 在 `docs/2.0/decisions/RISKS.md`（或 ADR-023 的遗留事项）登记“建造入口未查询地籍”仍为开放缺口；M13-01 的验收要么阻塞于该联动，要么显式排除并保留本记录的问题 1。
4. 在测试入口清单中登记 `tests/chain_integration_test.gd` 的运行命令与预期末行。本记录未改动 `rules/`、workflow 或既有测试。

## 增补：建造的地籍强制已接入（2026-11-16）

问题 1 已不是当前实现状态。ADR-028 把地籍校验放进 `HeadlessWorld.execute()`
的 BUILD 分支：农场规则先接受候选，再按槽位映射调用
`TerritoryState.build_gate()`；未主张地块由首次建造自动主张，他人地块拒绝。
`TERRITORY_BUILD_GATE_TEST 79/0` 覆盖这些拒绝与首次主张。随后加入的公共通路
写入门禁（[M11 RECORD-18](../M11/RECORD-18-territory-blocking-authority.md)
增补）在写盘前再判一次：会切断公共入口到宅基唯一通路的 claim 与首次建造返回
`blocks_public_path`，且不写任何文档。

本记录的夹具仍未执行 BUILD，因此它仍只是地籍**查询**与既有链路的证据，不会
自动变成 M13-01 验收；建造入口的真实网络/UI 路径与 Windows 仍未覆盖。问题 1
与“未覆盖”第 1 项按上述实现更新，不再作为“未实现”缺口。
