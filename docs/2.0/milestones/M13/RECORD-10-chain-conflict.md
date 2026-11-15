# M13-01 · 参与/交战/公共项目整合链路证据

日期：2026-11-16。状态：**本机无头链路已执行并通过，未验收 M13-01**。本记录只报告 `tests/chain_conflict_integration_test.gd` 的完整运行，不表示 M13-01 或 M13 完成；网络、Windows、UI、真实驻留与失败恢复压力均未覆盖。

范围：在单个真实 `HeadlessWorld` 中，以固定种子、固定逻辑时钟、固定命令序列串起 `chain_integration_test.gd` 未覆盖的参与制度、交战、公共基金与公共项目链路：

1. 两个真实玩家开户（各 120 COIN 发行）；
2. 真实播种/收获 34 格青菜，真实招募两支民兵（A 12 人、B 10 人），现金与粮草真实离袋；
3. 房主声明 `limited` 参与制度（区域、半开窗口、损失预算），双方同意后在合法窗口交战：真实现金转移、单位减员、战利品与 `destroyed` 守恒；
4. 组织、公共基金、成员真实现金缴入、公共项目登记/承诺、用基金真实建成并支出；
5. 现金变化逐笔追溯账本分录或权威 `outcome`，`total_cash == issued`；
6. 重启后参与/交战/单位/基金/公共项目文档和现金余额保留，同 `command_id` 重放交战与 build 不二次发放战利品、不二次支出；
7. 拒绝路径与一次注入的农场保存失败均零字节变化。

纯规则夹具：无 UI、无渲染、无网络、无系统时钟；存档写入 `.local/` 下的隔离目录。本轮只新增 `tests/chain_conflict_integration_test.gd` 与本记录，未修改任何生产文件、既有测试、`rules/` 或 workflow，未提交、未推送。

前置：[M13 PLAN](PLAN.md)（M13-01）、[跨系统链 RECORD-05](RECORD-05-chain.md)、[ADR-023 地籍](../../decisions/ADR-023-land-cadastre.md)、M12 参与制度/交战权威测试 `tests/conflict_authority_test.gd`、M8-04a 公共项目权威测试 `tests/public_works_authority_test.gd`。

## 结论

1. **整条链路在本机无头运行中通过：`checks=512 failures=0`，连续两次一致。** 开户 → 播种/收获 → 招募 → `limited` 制度 → 双方同意 → 一次合法交战 → 组织/基金/缴入 → 项目登记/承诺 → 真实建成支出，每一环都断言上一环资产的落点。
2. **交战是真实结算，不是夹具改写**：兵力取 A 单位真实 12 人；损失被声明的 8 点窗口预算截断；先取现金 8 COIN，战利品 4 COIN 回到 A；A 支付 12 份粮草；A 单位从 12 人减到 4 人，B 的防守单位保持 10 人。`destroyed = 12 + 8 − 4 = 16`，交战前后双方现金+粮草合计从 208 降到 192，差额正好 16。
3. **公共项目真实支出**：组织账户先由 A/B 各缴入 60 COIN（基金余额 120），build 后组织账户归零、`@world` 增加 120、基金 `balance=0 / spent=120`、项目 `built`，`built_utc` 等于权威支出时刻 `START+11000`。
4. **现金守恒与可追溯性成立**：全程 `total_cash == issued`，双分录每次对账通过；发行仅 240（两次开户），无销毁；9 条账本分录覆盖 2 次开户、2 次招募付款、1 次交战取现、1 次战利品、2 次基金缴入和 1 次项目支出，事件 id 与金额逐笔断言。招募的粮草成本同时记录在真实单位文档 `commands[unit_id].result.cost`。
5. **重启保留全部文档与余额**：真实 `save()` 后同目录、同 world id、同房主重开为 `loaded`；参与制度通过 `Participation.valid()`，交战上下文通过 `ConflictSettlement.valid_context()`，公共项目通过 `PublicWorks.valid()`；双方角色/损失、目标预算、减员后的单位、基金余额/支出/缴入累计、项目状态与现金余额全部保留。
6. **跨重启重放幂等**：内存结果窗口已丢失的情况下，同 `command_id`、同参数的 engage 与 build 分别返回 `duplicate=true`，四个世界文档逐字节不变，现金/单位/基金 history 全部不变；战利品和支出都不会第二次发生。
7. **拒绝零半提交**：区域外/无粮草的交战、非所有者单位、重复 build 均被具名拒绝且所有文件与现金逐字节不变；注入农场保存失败后，缴入返回 `save_io`，农场合账本/基金文档/文件均未改变。
8. **未发现需要修复的生产缺陷**。唯一影响覆盖面的限制是经济规模与“先扣现金再扣物资”的固定顺序共同导致本切片的单次交战无法同时触发防守方物资损失并保留足够的玩家现金完成 120 COIN 公共项目（见“未覆盖项”），这是夹具取舍，不是计算错误。

## 链路与检查矩阵

| # | 链路 | 关键断言 | 检查 |
|---|---|---|---|
| 0 | 启动 | 固定种子被采用；world id、房主、逻辑时钟、6 块地、默认和平制度有效；零发行、空单位名册 | 13 |
| 1 | 开户/收获/招募 | A/B 各 120；34 格青菜真实成熟并进入各自 bag；`harvested=34`；A 12 人/B 10 人真实招募；现金 96/100、`@world` 44、粮草 12/0；单位文档成本 24+12 / 20+10 | 316 |
| 2 | 参与制度 | 房主声明 limited、声明的区域/半开窗口/8 点预算、`higher_risk`；推进到生效时刻；A 攻击方/B 防守方同意绑定当前 revision | 16 |
| 3 | 交战 | 区域外拒绝、非本人单位拒绝均零字节；真实结算 troops=12、losses=8、taken_cash=8、spoils_cash=4、supply_cost=12、destroyed=16；A 单位 12→4；`total_cash==issued` | 36 |
| 4 | 基金/公共项目 | 组织创建/加入；基金开立；A/B 各缴入 60 真实现金；项目登记、承诺 120 达 `funded`；build 真实支出 120；基金 history 1 行；项目 `built` | 48 |
| 5 | 可追溯性 | 9 条分录逐事件断言；发行 240、销毁 0、净发行 240；`accounts+merchant+escrow+bank == total`；期末 A 40/B 32/`@world` 168 | 23 |
| 6 | 重启 | `save()`→同目录重开 `loaded`；参与/交战/单位/基金/项目文档与余额保留；engage/build 重放 `duplicate` 且文件/现金不变 | 41 |
| 7 | 拒绝 | 无粮草交战、非所有者单位、重复 build 具名拒绝；注入农场保存失败返回 `save_io`；全部零字节、零现金变化 | 19 |
| | **合计** | | **512** |

## 固定夹具

| 项 | 值 |
|---|---|
| 引擎 | `Godot 4.7.2.stable.official.ed1daf0bf` |
| 仓库 HEAD | `3865557453f7353b78514180451d4bcf8b8c9ffd`（`test: 三面板真实网络联调`）；运行前后 HEAD 不变 |
| 工作树 | 运行前后 `git status --short` 只有本记录与 `tests/chain_conflict_integration_test.gd` 两个未跟踪文件；未修改任何已跟踪文件 |
| 种子 / 起点 | `SEED = 101507`，`START = 1800014400.0`（UTC） |
| 逻辑时刻 | 收获 `START+7200`；参与制度生效/交战 `START+11000`；窗口 `[START, START+86400)` |
| 世界 / 房主 | `chain-conflict-world` / `chain_a` |
| 地块 | `area_a`：`x,z ∈ [0,5]`；交战点 `(2,2)` |
| 损失预算 | `loss_cap=8`、`offline_loss_cap=4`；目标预算常量 100 |
| 作物 | 青菜 1800 秒；A 24 格、B 10 格，共 34 格 |
| 单位 | 民兵：现金 2/人、粮草 1/人；A 12 人（24 COIN + 12 粮草），B 10 人（20 COIN + 10 粮草） |
| 交战 | troops 12；losses 8；taken_cash 8；taken_supplies 0；spoils_cash 4；spoils_supplies 0；supply_cost 12；destroyed 16 |
| 公共项目 | `road_segment` 固定成本 120；组织 `guild_works`；基金 `fund_guild_works`；账户 `org_guild_works` |
| 缴入 | A 60 + B 60 = 120；期末缴入累计 60/60 |

## 守恒结论

现金（每个阶段都检查 `total_cash == issued`，期初发行 240、销毁 0）：

```text
开户        A 120 + B 120                                   = 240
招募        A 96  + B 100 + @world 44                       = 240
交战        A 100 + B 92  + @world 48                       = 240
缴入        A 40  + B 32  + org 120 + @world 48             = 240
建成        A 40  + B 32  + org 0   + @world 168            = 240
```

交战 resource 守恒（双方现金+粮草，不含系统账户）：

```text
before  A cash 96 + supplies 12 + B cash 100 + supplies 0 = 208
after   A cash 100 + supplies 0 + B cash 92 + supplies 0  = 192
reduce  208 - 192 = 16 = outcome.destroyed
        destroyed = supply_cost 12 + losses 8 - spoils 4
```

商品（青菜）：

```text
harvested                 34
recruit consumes          12 (A) + 10 (B) = 22
attack supply cost        12
final bags                0
```

账本（9 条，双分录对账通过）：

| 事件 id | 类型 | 金额 | 方向 |
|---|---|---|---|
| `chain-account-a` / `chain-account-b` | `open_account` | 120 / 120 | 发行 → A/B |
| `unit_pay_chain-a-unit` | `pay` | 24 | A → `@world` |
| `unit_pay_chain-b-unit` | `pay` | 20 | B → `@world` |
| `conflict_take_chain-battle` | `pay` | 8 | B → `@world` |
| `conflict_spoil_chain-battle` | `pay` | 4 | `@world` → A |
| `fund_pay_chain-contribute-a` | `pay` | 60 | A → `org_guild_works` |
| `fund_pay_chain-contribute-b` | `pay` | 60 | B → `org_guild_works` |
| `fund_spend_pw_spend_chain-build` | `pay` | 120 | `org_guild_works` → `@world` |

## 实际原始输出

运行命令（仓库根目录）：

```bash
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 420 \
  "$GODOT" --headless --path Game --script "$PWD/tests/chain_conflict_integration_test.gd"
```

引擎输出末行为（连续两次运行一致；其后的 `real/user/sys` 为外层 `time` 统计）：

```text
CHAIN_CONFLICT_INTEGRATION_TEST checks=512 failures=0
```

实测每轮约 1.07 秒（`user 0.78`、`sys 0.12`），退出码 0；512 条 `PASS`、0 条 `FAIL`、0 条脚本错误。分阶段检查数：boot 13、accounts_harvest_recruit 316、participation 16、engagement 36、public_works 48、traceability 23、restart 41、refusals 19。两次完整输出保存在 `.local/verification/chain_conflict_run_1.log`、`.local/verification/chain_conflict_run_2.log`（已被 `.gitignore` 的 `/.local/` 覆盖）。

## 发现的真实问题

1. **单次交战无法同时覆盖“防守方物资损失”和“成员足额缴入 120 COIN”**（夹具取舍，不是缺陷）。结算固定先扣防守方现金再扣物资；在 2×120 的初始发行、2/人的民兵成本与 120 的公共项目固定成本下，若要让 `taken_supplies > 0`，防守方现金必须低于损失且会被取空，两名玩家剩余现金必然不足 120，公共项目无法由成员真实现金建成。本链路因此让单次交战只触发真实现金损失/战利品，物资侧只覆盖攻击方粮草消耗与 `destroyed` 中的物资项。若以后需要同时覆盖，可增加第二次交战或提高玩家现金来源，但不属于本轮授权范围。
2. **区域外/位置类参与拒绝在权威边界统一映射为 `invalid_participation`**。`ConflictSettlement._map_participation_reason` 只把和平、窗口、同意、预算、重复命令映射为具名外部原因，`area_not_declared` 等回落为 `invalid_participation`。调用方仍能确定性拒绝，但无法仅凭外部 reason 区分“区域外”和“其它参与违规”；本轮只断言拒绝与零字节，不把该措辞当成区域专用原因。
3. **`advance_to` 本身仍不落盘**（与 RECORD-05 一致）。本链路在重启前显式 `save()`；只推进不保存的世界崩溃后会丢失生长/经济进度。

## 未验证项

- Windows 实机、网络多客户端/身份解析、UI/场景呈现与能耗。
- 防守方物资损失与物资战利品分支（原因见“发现的真实问题”1）。
- 其它拒绝路径：和平档、窗口外、退战延迟、目标预算耗尽、离线预算、锁定期、重复/换载荷冲突；这些已有独立测试覆盖，本链路只抽验区域外、非所有者与重复 build。
- 地籍、市场、运输、银行/贷款链路不在本切片；它们由 `tests/chain_integration_test.gd` 覆盖。
- 长时间运行的表/文档上限、真实驻留与内存、跨版本升级与失败回退（M13-02/M13-03 覆盖）。
- 固定种子与固定脚本之外的分布、边界压力与并发交错。

## 需要登记的内容

1. 在 `docs/2.0/milestones/M13/PLAN.md` 的 M13-01 下登记本记录链接，并写明这是“本机规则链证据，不是阶段验收”。
2. 在 `rules/project-context.md` 的 M13-01 条目中补充本切片的固定夹具与检查数（`checks=512`、`destroyed=16`、9 条账本分录、重启/重放幂等）。
3. 在测试入口清单中登记 `tests/chain_conflict_integration_test.gd` 的运行命令与预期末行。本记录未改动 `rules/`、workflow 或既有测试。
