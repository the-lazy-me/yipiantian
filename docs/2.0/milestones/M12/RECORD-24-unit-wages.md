# RECORD-24 · 单位持续现金工资纯规则切片

状态：切片完成，未验收；只补齐 M12-01 “工资”明文要求中缺失的规则层部分（缺口
G14），不表示 M12-01 或 M12 验收完成。日期：2026-11-16。

## 问题

M12-01 要求“有限护卫/民兵、装备、驻地、工资与粮草，先低频战略结算”。
[RECORD-05](RECORD-05-units.md) 已给出招募、解散、粮草补给、逃兵与派生战力；
[RECORD-06](RECORD-06-unit-authority.md) 的“未覆盖”明确写了“只有一次性招募现金
和每日粮草”，没有持续现金工资。因此工资只出现在计划文字里，规则层
没有任何持续现金消耗，也没有“付不起工资会怎样”的可验证答案。

本切片在 `Game/conflict/unit_state.gd` 内补一个与粮草并列的纯规则入口
`pay_wages(state, available_cash, now_utc)`：按工程目录的每日工资逐单位结算，
现金不足时按确定性顺序部分支付并累计欠付天数，欠付与欠供共用同一份战力惩罚。
它不读取 `FarmState`、不扣真实账户、不写存档、不接权威或界面。

## 边界

- 只修改 `Game/conflict/unit_state.gd`；新增 `tests/unit_state_wages_test.gd` 与本文。
- 未修改 `Game/world/**`、`Game/scenes/**`、`Game/ui/**`、`.github/**`、`rules/**`、
  M12 `PLAN.md`、字体文件或既有 `tests/unit_state_test.gd`。
- 无随机数、无系统时钟、无磁盘、无场景、无网络；所有时刻与现金总量由调用方
  显式传入，同一输入逐字节相同。
- 写入口写时复制；失败只返回 `{ok:false, reason}`，不带候选文档，不修改输入。
- 现金扣减由调用方按返回的 `paid` 完成；单位文档只推进各单位的
  `last_wage_utc` 与 `sequence`，不碰 `last_upkeep_utc`。
- 未接权威结算：`headless_world.gd` 的 `upkeep` 动作仍只结算粮草，没有工资
  扣款、账户转账或 RPC 字段。

## 规则

### 文档形状

单位行新增两个严格校验字段：

```text
"unpaid_days": 0,          # 连续欠付天数，足额支付后清零
"last_wage_utc": 0.0,      # 最近一次工资结算时刻；招募时等于 recruited_utc
```

`valid()` 的键集 `UNIT_KEYS` 同步增加两项，并要求：

- `unpaid_days` 是非负整数且不超过 `MAX_UNPAID_DAYS`（1,000,000，与
  `MAX_UNFED_DAYS` 同值，给出无意义上限而不是无限增长）；
- `last_wage_utc` 是合法时间（有限、非负、不超过安全整数）；
- `last_wage_utc >= recruited_utc`：工资时钟不能早于单位存在之前。

`max_people_per_unit` 等既有约束不变。当前是早期开发阶段，按项目规则不为旧
`units.json` 增加兼容分支：缺字段的旧文档由 `valid()` 直接拒绝，不静默补默认值。

### 工程目录与周期

`CATALOG` 每类兵种新增 `daily_wage_per_person`：

| 兵种 | 每人每日工资 | 与每日粮草之比 |
|---|---:|---:|
| `militia` | 1 | 1:1 |
| `guard` | 2 | 1:1 |

理由：与现有 `daily_supply_per_person` 取同一数值，让“付得起工资”和“买得起粮”
落在同一经济尺度上，不凭空引入第二套物价；护卫的工资仍按双份人数成本体现更强
的常备属性。这个常量只被本模块读取，不修改 `EconomyCatalog` 的商品价格。

周期使用整数常量 `WAGE_PERIOD_SECONDS = 86400`：

- 只有完整跨过一个 86400 秒周期才计一天工资，不足一天不折算，避免浮点小时
  折算在幂等与确定性上引入误差；
- 用整数秒而不是月历，避免月份长度、时区周边与节日规则进入纯规则层；
- 跨多天时一次结算 `days` 天，按 `每日工资 × 人数 × days` 计，调用方不需要
  逐日循环。

### `pay_wages` 语义

```text
对 unit_id 升序的每一支单位：
  days      = floor((now_utc - last_wage_utc) / 86400)
  days <= 0 → 跳过（没有整日工资）
  required  = daily_wage_per_person × people × days
  paid      = min(required, 剩余可用现金)
  shortfall = required - paid
  last_wage_utc += days × 86400       # 余量保留，供下一次整日
  shortfall > 0 → unpaid_days += days
  shortfall = 0 → unpaid_days = 0     # 足额支付清除欠付
```

- 现金总量是本次调用可用的金额，按 unit id 升序支付；与 `upkeep` 的粮草分配顺序
  一致，同一输入得到同一结果。现金不会跨单位重复使用。
- 现金不足不是拒绝：仍返回成功候选，只是 `status = "unpaid"`、`unpaid > 0`，
  由调用方决定是否照付部分工资。这与招募的 `insufficient_cash` 拒绝不同：招募
  是“能不能开始”，工资是“已经存在的单位必须按期结算”。
- 没有任何单位跨越整日时返回 `settled_this_tick = true`，文档原样返回、不推进
  `sequence`、不扣现金；因此同一 `now_utc` 重复调用天然幂等，不会多扣。
- 任一单位的 `last_wage_utc` 晚于 `now_utc` 时整批返回 `time_regression`；候选
  文档是副本，已处理的单位不会写回输入。
- `available_cash` 必须是非负整数（接受 JSON 往返后的等值浮点）；负数、小数、
  字符串、`null`、非有限值返回新增的 `invalid_cash`。
- 返回字段：

```text
{ok, reason, state, status, settled_this_tick,
 required, paid, unpaid, settlements, affected}
```

`settlements` 记录每支有整日工资的单位 `{unit_id, owner, kind, days, required,
paid, shortfall, unpaid_days}`；`affected` 只含 `shortfall > 0` 的条目副本。

### 战力

`_penalty_bps()` 的入参从“欠供天数”改为“短缺天数”：

```text
shortfall_days = unfed_days + unpaid_days
penalty_bps    = 10000 - min(shortfall_days × 2500, 7500)
```

`capability()` 返回新增 `unpaid_days`，`penalty_bps` 按合计天数给出。没有第二套
战力公式，也没有把两种短缺合起来叠加成更高惩罚；一天欠供与一天欠付同权，最多
保留 25% 系数。`SUPPLY_PENALTY_BPS_PER_DAY` / `MAX_SUPPLY_PENALTY_BPS` 常量名
保持不变，避免影响既有调用与测试。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/conflict/unit_state.gd` | 目录增加每日工资；单位行增加 `unpaid_days` / `last_wage_utc`；新增 `pay_wages`；`capability()` 与 `_power()` 使用合计短缺天数；新增 `invalid_cash` 与 `paid` / `unpaid` 状态 |
| `tests/unit_state_wages_test.gd` | 新增夹具，87 项检查 |
| `docs/2.0/milestones/M12/RECORD-24-unit-wages.md` | 本记录 |

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/unit_state_test.gd"
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/unit_state_wages_test.gd"
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/unit_conflict_test.gd"
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/font_coverage_test.gd"
```

原始最后一行（本切片改动落盘后立即运行）：

```text
UNIT_STATE_TEST checks=182 failures=0
UNIT_STATE_WAGES_TEST checks=87 failures=0
UNIT_CONFLICT_TEST checks=113 failures=0
FONT_COVERAGE_TEST checks=1276 failures=0 missing=0
```

`unit_conflict_test` 的 113 项是交付前并行任务完成防守损失用例后的工作树结果；
该测试与 `Game/conflict/unit_conflict.gd` 不属于本切片，本切片不修改、不回退
它们。`unit_state_test` 与 `unit_state_wages_test` 在各次重测中始终全绿。

回归原始最后一行（证明新增字段没有破坏既有接线）：

```text
UNIT_AUTHORITY_TEST checks=146 failures=0
UNIT_NETWORK_TEST checks=57 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/unit-network-334604
WORLD_TRANSFER_SIDECARS_TEST checks=152 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/world-transfer-sidecars-468127
```

字体门禁：本切片的三个文件（`Game/conflict/unit_state.gd`、
`tests/unit_state_wages_test.gd`、本记录）逐字符扫描都落在现有子集内，字体文件
未改动。中途有并行任务的字集外用字进入工作树让门禁短暂变红，各改动方自行处理
后，交付前全库重测为 `checks=1276 failures=0 missing=0`。

覆盖矩阵：

| 用例 | 检查 |
|---|---|
| 初始字段 | 新单位 `unpaid_days=0`、`last_wage_utc=recruited_utc`；文档与 JSON 往返有效；查询战力带欠付天数与无惩罚 |
| 现金充足 | `status=paid`；按 id 升序逐单位支付；民兵 1/人/日、护卫 2/人/日；`last_wage_utc` 推进整日；不推进 `last_upkeep_utc`；不修改输入；`sequence+1` |
| 现金不足 | `status=unpaid`；只付到可用数量；前一单位足额、后一单位欠付一天；欠付单位战力下降且 `penalty_bps=7500`；足额单位战力不变；补付后清零并恢复战力 |
| 欠付惩罚 | 零现金全员欠付；一天 25%、两天 50%、四天起封顶 75%（保留 25% 系数）；欠供与欠付合计计入同一公式；按同一战力公式派生 |
| 重复调用 | 同一 `now_utc` 返回 `settled_this_tick`；不扣现金、不新增欠付、不推进序列；返回原文档；空名册同样同刻返回 |
| 多日与余量 | 跨三天一次结算 60 现金；明细 `days=3`；工资时钟推进三个整日；半日不额外计工资但余量保留；同一半日重复不再计；超长欠付候选仍有效且封顶在文档上限 |
| 时间倒退 | 结算时刻早于任一单位工资时钟时整批 `time_regression`；失败无候选文档 |
| 非法输入 | 非字典文档 `invalid_state`；负/非有限时刻 `invalid_time`；负/小数/字符串/`null`/非有限现金 `invalid_cash`；失败无候选 |
| 文档校验 | 缺 `unpaid_days` 或 `last_wage_utc`；负、小数、超上限欠付天数；负、非数字工资时钟；工资时钟早于招募时刻都无效 |
| 写时复制 | 成功与失败路径都不修改输入；欠付不写回调用方文档 |
| 确定性 | 同输入逐字节相同；候选文档与明细一致 |

## 未覆盖

- 权威接线：`HeadlessWorld` / `WorldHost` 没有 `wage` 动作，没有从玩家账户向
  `@world` 或单位所属账户的现金转账，没有账本分录、权限门、RPC 或重启幂等。
  目前 `pay_wages` 只能由测试或未来调用方驱动。**已由下文《增补：权威工资结算》
  补齐。**
- 补给与工资的联合结算：两者是独立入口、独立时刻（`last_upkeep_utc` 与
  单位行 `last_wage_utc`），没有“一次战略结算同时扣粮与扣钱”的组合动作；
  按日结算与整秒量化由调用方负责。
- 工资发放对象：现金只作为总量传入，不区分是玩家账户、组织金库还是 `@world`；
  没有欠付收款方记录、补发队列或利息。
- 心气：欠付只通过既有短缺惩罚降低战力，不产生逃走、拒绝命令或投降；也没有
  单独心气值。
- 按小时/半天折算、月度工资、等级工资、随装备或经验变化的工资：只有整数日与固定
  每人工资。
- 发放上限与防刷：任何调用方都可以高频调用；整日规则让同日重复调用幂等，但
  没有权威侧的每日一次限制。
- 旧存档：早期开发阶段，缺 `unpaid_days` / `last_wage_utc` 的旧 `units.json`
  会被 `valid()` 拒绝，不做迁移。手工构造的单位文档必须同时补这两个字段。
- UI：单位面板不显示欠付天数、工资总额或部分支付结果；权威视图
  `units_view()` 未增加 `unpaid_days`。**已由下文《增补：权威工资结算》补齐。**
- 只在本机 macOS 无头模式验证；未在 Windows/CI 运行。新增与修改的中文注释都
  落在现有字体子集内，`FONT_COVERAGE_TEST` 通过，字体文件未改动。

## 关联

- 单位规则：[RECORD-05 · 单位与补给](RECORD-05-units.md)。
- 权威接线与其未覆盖工资：[RECORD-06 · 单位接入世界权威](RECORD-06-unit-authority.md)。
- 规格：[领土政治、私兵与有限 PvP](../../systems/politics-conflict-law.md)。
- 阶段计划：[M12 PLAN](PLAN.md)（本次不修改计划文字）。
- 实现：`Game/conflict/unit_state.gd`；测试：`tests/unit_state_wages_test.gd`。

## 增补：权威工资结算（2026-11-16）

### 问题

`pay_wages()` 只有测试驱动，玩家单位永远不会跨过整日，`unpaid_days` 永远是 0，
“付不起工资”在真实世界里不可达。本增补只把工资接到权威，不改补给、招募、解散
的语义，也不加自动定时结算：与补给一样，由成员在面板里显式触发一次低频结算。

### 改动

| 文件 | 内容 |
|---|---|
| `Game/world/headless_world.gd` | `execute_unit()` 新增 `wage` 分支；新增 `_pay_unit_wages()`、`_unit_owners()`、`_wage_payment_id()`；`_unit_action_time()` 的新记录量化到整秒；`units_view()` 增 `unpaid_days` |
| `Game/farm/ledger_state.gd` | `RESERVED_EVENT_PREFIXES` 增 `unit_wage_`，客户端命令 id 不能占用该命名空间 |
| `Game/world/world_host.gd` | `unit_for_member()` 放行 `wage`；`_unit_reason_text()` 补 `invalid_cash` |
| `Game/world/world_projection.gd` | 摘要单位块白名单增 `unpaid_days` |
| `Game/ui/unit_panel.gd` | 新增「发工资」按钮与结果文案；单位行显示欠付天数 |
| `tests/unit_authority_test.gd` | 新增两个用例共 50 项检查，含写失败恢复与权限门 |
| `tests/unit_panel_test.gd` | 新增 3 项检查：发薪意图、请求 id、结果文案 |

### 结算语义

- 时刻 `now = floorf(authority_now_utc())`，与补给一致；同一秒内的重复请求是同一
  次结算，所有单位都没有整日可计时返回 `settled_this_tick`，不写任何文档。
- 按 `unit_id` 升序的 owner 集合逐个拆 `_owner_document(owner)`，用该 owner 的
  现金调用 `UnitState.pay_wages()`；整批有任何单位跨日才推进 `sequence`。
- 先写农场（每个有付款的 owner 各一条 `economy_authority_pay(owner, @world,
  paid, event_id, now)`），后写单位文档。农场保存失败则两份都不写；单位保存失败
  则农场已付，下一次调用补写单位文档。

### 幂等键

工资是时间驱动，不写单位命令表（`UnitState.valid()` 要求命令记录都指向单位，
工资没有对应单位记录）。用命令 id 做幂等键会在“农场已付、单位未写”后换一个
命令 id 重试时二次扣款。因此事件 id 只由结算前的状态派生：

```text
"unit_wage_" + sha256(owner + "|" + 升序拼接 "<unit_id>@<last_wage_utc>")
```

- 单位文档没写成功时前状态不变，任意命令 id 的重试都落到同一条账本分录；命中
  分录时用分录的 `at_utc` 重算（`available_cash` 取分录金额），结果与首次完全
  相同，只补写单位文档，不再次转账。
- 成功结算必然推进 `last_wage_utc`，下一日摘要不同，不会误判为重试。
- 命中分录但重算金额与分录不一致时返回 `command_conflict`，不静默跳过。
- 已知窗口：单位写失败后、重试前又增删了该 owner 的单位，摘要会变，已付那部分
  可能再付一次。这与招募的“换命令 id 重试”窗口同源；正常重试不会触发。

### 量化修复

招募原先用未量化的 `authority_now_utc()` 作为 `recruited_utc`/`last_wage_utc`，
带毫秒零头；一天后再用 `floorf(now)` 结算，差值差几毫秒不足 86400 秒，整日数
算成 0，工资永远发不出去（首版夹具即因此全红）。`_unit_action_time()` 的新记录
改为 `floorf(authority_now_utc())`；已存命令 payload 中的旧时刻原样复用，重放
语义不变。

### 网络答复字段

`WorldHost.unit_request()` 原先只透传 `ok/action/unit_id/duplicate/reason/
reason_text/state` 七个字段，工资的 `status/required/paid/unpaid/affected`
在真实 WSS 上会被整层丢掉：面板既看不到结算状态，也进不了“今天已经结算过”的
分支。现在按存在性逐项透传结算字段（`status`、`settled_this_tick`、`required`、
`paid`、`unpaid`、`consumed`、`deserters`、`affected`），非结算答复的线形状与
改动前逐字节相同。**新增任何结算字段时都要同步这份白名单**。`unit_network_test`
新增 3 项检查：`wage` 走同一 RPC 通道、同秒返回 `settled_this_tick`、总量字段
到达客户端（`UNIT_NETWORK_TEST 57/0`）。

### 视图与界面

`units_view()` 与摘要单位块白名单都增加 `unpaid_days`（面板本来就能显示
`unfed_days`，字段沿同一行下发）。面板行文本追加「欠付 %d 天」，新增「发工资」
按钮，成功答复显示「本次发放工资 N，欠付 M。」；同一秒重放显示「今天已经结算
过工资。」。新增文案逐字落在现有字体子集内，字体文件未改动。

### 验证

```text
UNIT_AUTHORITY_TEST checks=196 failures=0
UNIT_PANEL_TEST checks=56 failures=0
UNIT_STATE_TEST checks=182 failures=0
UNIT_STATE_WAGES_TEST checks=87 failures=0
UNIT_NETWORK_TEST checks=57 failures=0
WORLD_PROJECTION_TEST checks=258 failures=0
LEDGER_TEST checks=1841 failures=0
ECONOMY_INITIAL_TEST checks=154 failures=0
M4_ECONOMY_COMMANDS_TEST checks=169 failures=0
HEADLESS_WORLD_RUNTIME_TEST checks=83 failures=0
HEADLESS_WORLD_TEST checks=14 failures=0
CONFLICT_AUTHORITY_TEST checks=294 failures=0
CONFLICT_NETWORK_TEST checks=117 failures=0
CHAIN_CONFLICT_INTEGRATION_TEST checks=512 failures=0
UNIT_CONFLICT_TEST checks=117 failures=0
SUMMARY_BLOCK_TEST checks=18 failures=0
FONT_COVERAGE_TEST checks=1272 failures=0 missing=0
```

新增覆盖：两个 owner 一次结算各付各的、工资落到 `@world`、发行量守恒、同日重放
零扣款、次日新分录、现金不足部分支付并累计一个欠付日、视图下发欠付天数、时间
倒退拒绝且两份文档不变、访客/匿名/只读拒绝、单位写失败后换命令 id 重试不二次
扣款且磁盘时钟正确。

反向验证：把 `_pay_unit_wages()` 的 `_ledger_payment_marker()` 查找临时改成恒
空，`UNIT_AUTHORITY_TEST` 报 4 项失败（换命令 id 不能完成结算、重试时钟错误、
恢复未落盘、再次调用仍在扣款），证明恢复用例确实守着幂等键而不是碰巧通过。

### 仍未覆盖

- 没有自动周期结算或计划任务：只有成员显式触发，权威不按墙上时间自行发薪。
- 部分支付只汇总总额与受影响单位，没有逐单位的补发队列、利息或收款方记录。
- 结算时刻来自权威会话时钟；断线重连或时钟回拨由 `time_regression` 拒绝，
  没有追赶式补发。
- 未接真实 WSS 工资端到端与 Windows 实机；`unit_network_test` 只覆盖既有动作。

## 增补：两阶段工资结算（2026-11-16）

原实现的恢复依赖“结算前名册”派生的单一账本事件 id。单位写盘失败后，若在重试前
又招募或解散了该 owner 的单位，派生摘要改变，旧分录不再命中，存活单位会被二次
扣款。现在改为两阶段写入，并用单位文档保存待付记录：

1. `UnitState.pay_wages()` 在副本上算出每个 owner 的应发额；
2. 单位候选写入推进后的 `last_wage_utc`/`unpaid_days`，同时把
   `pending_wages: {owner: {event_id, amount, stamp}}` 与之一同原子落盘；
3. 农场按待付记录付款（每个 owner 一条 `economy_authority_pay`）；
4. 付款成功后清除 `pending_wages` 并再次保存单位文档。

任何一步失败或进程退出的恢复方式：

- 单位文档里有 `pending_wages` 时，下一次工资调用先 `_finish_pending_wages()`：
  账本已有同 id、同金额分录则跳过；没有则按记录里的金额与时刻补付；最后清除
  待付记录。记录不再从当前名册推导，因此期间的招募、解散或换命令 id 都不会
  改变付款身份。
- 第一阶段（写单位）失败时农场未动，两份文档都不变。
- 农场写失败或清除待付记录的写入失败时，单位时钟已推进且农场可能已付款；
  下一次调用只补完成，不会再次推进时钟。
- 事件 id 仍是 `unit_wage_<sha256(owner|结算前时钟)>`，但现在只在第一阶段计算
  一次并持久化；账本分录被 512 条环形窗口淘汰且进程在付款后退出时，待付记录
  仍会尝试补付，这条极端窗口没有第二个持久付款证据。

单位文档形状新增顶层 `pending_wages`（空表合法、最多 64 名 owner、事件 id 必须
是 `unit_wage_` 加 64 位小写十六进制、金额为正、时刻合法）。这是本切片唯一的
存档格式变化，早期开发阶段不提供旧 `units.json` 迁移。

验证：

```text
UNIT_AUTHORITY_TEST checks=224 failures=0
UNIT_STATE_TEST checks=182 failures=0
LONG_SIMULATION_TEST checks=11650 failures=0
UNIT_NETWORK_TEST checks=57 failures=0
```

新增覆盖：第一阶段写失败不付款、不推进时钟、不留分录；第二阶段写失败后农场已付、
待付记录保留；随后解散单位再换命令 id 重试，只清除待付记录、不二次付款，磁盘上的
待付表为空。
