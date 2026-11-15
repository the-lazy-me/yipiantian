# M7-01 · 经济初始条件

状态：已实现（2026-11-15），未验收。范围：确定首批商品、货币发行与回收边界、Demo 内容转换和库存所有权，并落地最小账本接口与无头夹具。不包含报价、订单、撮合、预留、物流、手续费或 UI。

权威设计：[ADR-010](../../decisions/ADR-010-economy-initial-conditions.md)；上层规格：[经济与金融](../../systems/economy-finance.md)、[M7 PLAN](PLAN.md)。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/farm/economy_catalog.gd` | 新增。纯数据商品目录：六种作物、来源、去向、参考价与 `COIN` 币种。 |
| `Game/farm/economy_state.gd` | 新增。经济账本与规则：开户发行、付款、Demo 转换、来源规范化、快照校验与幂等回放。 |
| `Game/farm/owner_id.gd` | 新增。农场口袋、偷菜、住宅与经济账户共用的所有者 id 格式，避免第二份规则。 |
| `Game/farm/farm_state.gd` | 农场快照增加可选 `economy` 键；接入校验、默认值与整数归一化；新增经济接口；所有者 id 校验委托给 `owner_id.gd`。 |
| `Game/farm/v27_importer.gd` | `KNOWN_FARM_KEYS` 增加 `economy`，导入旧 v27 时按可选键处理。 |
| `tests/economy_initial_test.gd` | 新增 154 项无头检查：目录完整性、守恒、转换、幂等、账本淘汰后的持久标记、拒绝路径、持久化与权威/本地一致。 |
| `docs/2.0/decisions/ADR-010-economy-initial-conditions.md` | 本切片的持久裁决。 |
| `docs/2.0/decisions/README.md` | 决策入口增加 ADR-010 一行。 |
| `docs/2.0/milestones/M7/PLAN.md` | M7-01 增加记录与决定链接。 |
| `docs/2.0/05-DATA-AND-NETWORK.md` | 注明农场快照新增可选 `economy`，信封 `money` 不是实时权威。 |
| `docs/2.0/milestones/M7/RECORD-01-economy-initial.md` | 本记录。 |

未新增依赖、网络消息、场景节点、HUD 行、美术资源或旧存档迁移器。农场格式版本保持 27，`economy` 是可选键。格子形状未变，`valid_cell_snapshot` 未改。

## 商品与去向

| 商品 | 来源 | 当前去向 | 参考价 |
|---|---|---|---|
| `greens` 青菜 | 地块种植，收获 1 篮 | 厨房、动物、邻里、M7-02 出售 | 6 |
| `spinach` 菠菜 | 同上 | 厨房、动物、邻里、M7-02 出售 | 9 |
| `radish` 白萝卜 | 同上 | 厨房、邻里、M7-02 出售 | 18 |
| `carrot` 胡萝卜 | 同上 | 厨房、邻里、M7-02 出售 | 24 |
| `celery` 芹菜 | 同上 | 厨房、邻里、M7-02 出售 | 20 |
| `garlic` 青蒜 | 同上 | 厨房、邻里、M7-02 出售 | 14 |

- 种子不进入市场：Demo 的无限种子没有有限来源，直接定价等于无成本增发。
- 建材不进入市场：住宅当前没有材料扣减（ADR-006），没有真实来源。
- `luffa` 等其余作物仍是正常食物与赠礼，但不进入首批定价；`luffa` 是唯一棚架作物，且没有厨房或动物吃法，首批只定价六种地块作物。
- 参考价只是 M7-02 价格区间的输入，不是成交价，也不是已平衡的数值。

## 命令与接口

经济命令不走网络命令边界（M7-02 再接入角色权限），由权威在农场快照上调用：

```text
economy_open_account(id, owner, now)               # 唯一发行入口，每名玩家一次
economy_convert_demo(id, now)                      # 从当前 bags/inventory 登记一次开库存
economy_pay(id, from, to, amount, now)             # 已发行货币的转移，不增发
economy_cash(owner) / economy_issued() / economy_total_cash()
economy_goods(owner) / economy_account(owner) / economy_snapshot()
```

- 所有者由权威从连接解析，命令不携带可冒领的 `from`；`@world` 是公共库存的保留所有者，不是合法玩家 id。
- 每条命令带 id 与规范化 payload。同 id 同 payload 回放原结果；同 id 不同 payload 返回 `command_conflict`；失败命令不写账本。
- `open_account` 的持久标记是 `accounts[owner].granted`，`convert_demo` 的持久标记是唯一的 `conversion` 记录；两者即使被 64 条有界账本窗口淘汰，也不会再次发行或转换。
- `pay` 的幂等目前依赖有界窗口；M7-03 的成交确认必须另带耐久记录，不能只靠这个窗口。

## 守恒实验数据

夹具 `tests/economy_initial_test.gd` 使用隔离目录 `.local/verification/economy-initial-*`，不读写玩家存档。关键观测：

| 步骤 | 账户 A | 账户 B | 全服现金 | 已发行 | 备注 |
|---|---:|---:|---:|---:|---|
| 新农场 | 0 | 0 | 0 | 0 | 无账户、无转换、无账本 |
| 开户 A | 120 | 0 | 120 | 120 | `OPENING_GRANT = 120` |
| 开户 B | 120 | 120 | 240 | 240 | 发行与现金相等 |
| A 付 B 50 | 70 | 170 | 240 | 240 | 付款只转移，不改变发行 |
| 重放付款 id | 70 | 170 | 240 | 240 | `duplicate=true`，无第二次移动 |

Demo 转换夹具的库存为：A 持有 2 青菜 + 1 生菜（非商品），B 持有 1 白萝卜，公共库存 1 白萝卜。转换结果：

| 观测 | 数值 |
|---|---:|
| 登记总量 | 4（2 青菜 + 2 白萝卜） |
| A 的商品视图 | 青菜 2，其余商品 0 |
| 生菜 | 仍在 A 的口袋，不进入商品视图 |
| 转换前后全服现金 | 0 → 0 |
| 转换前后 `issued` | 0 → 0 |
| 同 id 重试 | `duplicate=true`，总量仍 4 |
| 换 id 再转换 | `already_converted`，总量仍 4 |
| 同 id、库存变化后重试 | `command_conflict`，总量仍 4 |

拒绝路径均已验证：未知商品、非商品作物、负数、小数、字符串数量、非法所有者、空命令 id、负数时间、余额不足的付款、向未开户账户付款、自付款、非法金额。被拒绝的命令不改变快照、`issued` 或账本序号。

## 实际验证

命令均在仓库根目录执行，引擎为 `/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot`：

```
ECONOMY_INITIAL_TEST checks=154 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/economy-initial-235449
```

相关回归（同一引擎、同一工作树）：

```
FARM_STATE_TEST checks=385 failures=0
FARM_STORE_TEST checks=109 failures=0
FARM_COMMAND_TEST checks=45 failures=0
WORLD_PACKAGE_TEST checks=123 failures=0
V27_IMPORTER_TEST checks=69 failures=0
WORLD_TRANSFER_TEST checks=113 failures=0
HEADLESS_WORLD_RUNTIME_TEST checks=60 failures=0
PLAYER_BAGS_TEST checks=114 failures=0
BUILDING_TEST checks=149 failures=0
WORLD_SNAPSHOT_TEST checks=31 failures=0
WORLD_TAIL_TEST checks=27 failures=0
```

`WORLD_TRANSFER_TEST` 与 `WORLD_TAIL_TEST` 日志中的 `ERROR: Could not create directory` 与 `!is_inside_tree()` 是它们既有的失败路径探针输出；两个夹具均以 `failures=0` 退出。

## 未覆盖

- **M7-02/M7-03**：报价、限价单、预留、撤单、到期、撮合、部分成交、费用、断线重试和资金商品同时提交均未实现。`pay` 只是付款原语。
- **货币回收**：手续费、税、公共支出等真正减少 `issued` 的路径未实现；当前只有发行和转移。
- **网络与权限**：经济命令尚未进入 `FarmCommand`/WorldHost 的角色权限表；M7-02 接入时必须决定哪些角色可以开户、转换和下单。
- **UI/HUD**：没有钱包、商品目录或转换确认界面；玩家看不到现金或开库存量。
- **种子与建材**：没有有限来源，未进入市场；等来源和住宅材料账本落地后另行裁决。
- **全部作物**：只定价六种；其余作物仍是正常食物与赠礼，但不可出售。
- **世界包 `money`**：仍是 v27 导入信封字段（初始化为 0），不是实时权威；导出余额的定义留给 M7-02。
- **旧存档迁移**：按早期开发约定不写迁移器；旧档恢复为空经济，不会自动发钱。
- **内容派生标识**：世界包摘要包含农场快照，新增 `economy` 键会改变新导入／导出得到的 `world_id`／`farm_id`；已有导出不回溯重算，尚未验证历史导入目录的去重行为。
- **跨平台 CI**：本次只在本机 macOS 4.7.2 无头运行；Windows 与干净检出 CI 尚未执行。夹具尚未登记到 `.github/workflows/rule-tests.yml`。
- **真实玩家数据**：未使用真实存档；全部夹具为隔离目录。

## 待主会话登记

`.github/workflows/rule-tests.yml` 的 `tests` 数组需要新增一行（建议放在 `player_bags_test` 之后）：

```bash
# Economy initial conditions: a fixed six-good catalogue, one-time opening
# grants, a demo conversion that never stacks, and a ledger that replay and
# restart cannot turn into a second issuance.
economy_initial_test
```

`rules/project-context.md` 需要登记的项目事实：农场快照新增可选 `economy` 键；`FarmState` 新增经济接口；`V27Importer.KNOWN_FARM_KEYS` 已包含 `economy`；经济命令尚未接入网络命令边界。
