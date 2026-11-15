# ADR-019 · 共享世界经济命令：身份、权限与权威扫描

- 状态：采纳（2026-11-15），M4-09 切片实现完成；客户端接线与跨平台真实硬件验证仍待后续
- 关联：[M4-09 记录](../milestones/M4/RECORD-09-economy-commands.md)、[ADR-010](ADR-010-economy-initial-conditions.md)、[ADR-011](ADR-011-market-orders.md)、[ADR-012](ADR-012-matching-settlement.md)、[ADR-013](ADR-013-limited-logistics.md)、[ADR-014](ADR-014-double-entry-ledger.md)、[ADR-016](ADR-016-merchant-liquidity.md)、[ADR-017](ADR-017-bank-loans.md)

## 背景

M7/M8 的账户、市场、物流、银行和贷款规则都已在本地状态上实现，但共享世界此前只开放种田、建造与赠礼。要把它们接入网络，必须先回答四个问题：

1. 命令里的付款人、借款人、订单所有者从哪里来；
2. 成员和访客各自能执行哪些经济命令；
3. 到期、撮合、交付和逾期这类无客户端命令的权威扫描何时、以什么顺序运行；
4. 命令窗口淘汰后，重放是否还能二次转账。

[ADR-014 §6.1](ADR-014-double-entry-ledger.md) 已把第 4 点列为接入网络前必须处理的边界。本裁决把该修复与权限、扫描一起定稿。

## 决定

### 1. 身份只来自连接

- 新增十种命令：`account_open`、`pay`、`market_open`、`market_place`、`market_cancel`、`market_ship`、`market_deliver`、`bank_open`、`loan_borrow`、`loan_repay`。`market_open` 是需求清单之外补上的“开商人”命令，因为世界级一次性开市也需要经过同一条候选提交路径。
- `WorldHost.execute_for_member` 用 `_player_id(peer_id)` 解析 `actor`，再调用 `world.execute(command, actor)`。`FarmCommand._apply` 只把 `actor` 当作账户所有者、付款人、订单所有者或借款人。
- 命令的合法键集是精确的；`from`、`from_id`、`owner`、`owner_id`、`payer`、`borrower` 任一出现即 `invalid_command`。客户端无法在载荷中声明另一个身份。
- 匿名成员（已加入但没有玩家 id）执行经济命令返回 `no_player`；它仍保留既有 farm 权限。

### 2. 角色权限

| 命令 | member | visitor |
|---|---|---|
| `account_open` | 允许 | 拒绝 `forbidden` |
| `pay` | 允许，付款人只能是本人 | 拒绝 |
| `market_open` | 允许（世界级一次性开市） | 拒绝 |
| `market_place` | 允许，订单所有者是本人 | 拒绝 |
| `market_cancel` | 允许，只能撤自己的订单 | 拒绝 |
| `market_ship` | 允许，运费从本人账户扣 | 拒绝 |
| `market_deliver` | 允许（世界级扫描，幂等） | 拒绝 |
| `bank_open` | 允许（世界级一次性开业） | 拒绝 |
| `loan_borrow` | 允许，借款人是本人 | 拒绝 |
| `loan_repay` | 允许，只能还自己的贷款 | 拒绝 |
| `water` / `weed` | 允许 | 允许（不变） |

- 访客没有可信的经济身份，因此没有任何经济命令；原有浇水、除草权限不削弱。
- 社交协作授权只命名农活和地块，不能扩大经济权限。经济命令分支不读取 `_grant_allows`。
- `market_open`、`bank_open` 是**世界级一次性动作**：规则行只存在一份，给调用者本人不发行现金或货物；重复调用回放原结果。它们不是个人授权，所以由 member 触发。

### 3. 与农活相同的提交路径

所有经济命令都走 `WorldHost.submit` → `execute_for_member` → `HeadlessWorld.execute` → `FarmCommand.execute` → 候选状态 `_apply` → `commit_command` → `FarmStore.save_state` → `farm.accept`，没有任何绕过 `FarmCommand` 的快捷路径。

- 失败不提交：返回机器原因 `reason`，同时附带中文 `reason_text`。
- 成功提交后广播世界摘要（`command_result("summary", ...)`），其他成员无需自己请求即可拿到新余额/订单/合同；不新增网络消息类型。
- 幂等：同一命令 id 重试返回首次结果并标记 `duplicate`；同一 id 不同载荷返回 `command_conflict`。FarmState 与 economy 各有一个 64 条的有界窗口。

### 4. 权威扫描与固定顺序

命令提交后和 `advance_to` 到达目标时间后，权威按同一固定顺序运行：

```text
market_expire → market_match → market_deliver → economy_settle_loans
```

- 扫描没有命令 id，也不是客户端触发；调用者是权威自己的时钟。
- 命令路径在候选状态上、`save_state` 之前运行扫描，因此命令、扫描结果和事件序列落在同一份持久快照里；扫描失败则整个命令失败。
- `advance_to` 在目标时间只跑一次扫描，不随生长分段重复。
- 到期、交付和逾期是独立于作物阶段的截止时间，不能等下一次生长事件或玩家操作。部署型权威（`world_server.gd`）每秒调用一次 `HeadlessWorld.settle_economy_now(clock)`：在 `FarmState.copy()` 上运行同一固定顺序，只有确有变化才 `save_state` 并 `accept`，保存失败时活状态不变；只读迁移状态不扫描。它不推进 `now_utc`、不结算生长，因此不会改变作物基线或每次写入。
- 结果通过 `market_expired`/`market_matched`/`market_delivered`/`loans_settled` 计数进入回复和广播摘要。
- 单机路径不改：没有 `WorldHost` 时不会自动扫描，现有单机行为保持原样。

### 4.1 命令时间戳只作时间戳，不推进权威时钟

- 命令的 `at_utc` 是客户端观察时刻，不是“把世界推进到此刻”的指令。权威时钟只由 `advance_to`、扫描和真实经过时间推进。
- 容差：落后不超过 `COMMAND_CLOCK_TOLERANCE = 2.0` 秒的命令仍然接受（跨进程客户端用上一次摘要的时钟打戳，到达时总是略落后）；落后更多返回 `time_backwards`。
- 未来上界：超过权威时钟 `COMMAND_CLOCK_FUTURE_TOLERANCE = 3600.0` 秒返回 `time_forwards`，不推进时钟、不改任何状态。此前客户端可用未来时间戳强制订单/贷款到期并冻结生长（RISKS R15，已关闭）。
- 限时授权因此按权威时钟判断过期；测试不能再用“把时间戳设到未来”加速过期，必须让权威时钟真的走过截止点（`tests/m5_grant_test.gd` 已改为真实等待）。
- 已知边界：若干客户端只看到摘要里的 `now_utc`，而权威时钟还包含会话内单调时间，空闲世界会持续小幅度漂移；当前 UI 只发永久授权，任何限时授权的客户端都必须改用“TTL 秒数”或由权威下发 `authority_now`。

### 4.2 两个窗口之间的重放裁决

- 外层是农场事务窗口（64 条命令），内层是 `economy.command_results`（64 条）。外层淘汰后，若内层仍持有同一 id 的受理结果，规则按内部结果判为 `duplicate`：不提交、不保存、不广播（`M4_ECONOMY_COMMANDS_TEST` 覆盖）。
- 耐久守卫只属于有业务行的命令：`pay` 靠 `pay_seq`，市场扫描靠订单/成交/交付行，基金靠基金行。
- **礼物重放缺口已关闭**（2026-11-15）：礼物没有自己的业务行，因此已受理的 gift id 及其载荷另外保存在农场文档的 `transaction.gift_ids` 中，有界 1024 条，随同一份快照落盘。规则先查 64 条外层窗口，再查该集合；命中同一载荷回放固定的成功结果并标记 `duplicate`，同一 id 不同载荷仍返回 `command_conflict`。集合满时按插入顺序淘汰最旧一条，与命令窗口同一规则。窗口淘汰后、乃至保存并重启后，同一 gift id 都不会再次转移。该键嵌在既有 `transaction` 内，不新增农场顶层键，农场格式仍为 `27`，v27 导入的 `KNOWN_FARM_KEYS` 无需变化；缺失该键的文档恢复为空集合。

### 5. `pay` 的耐久序号与窗口淘汰

[ADR-014 §6.1](ADR-014-double-entry-ledger.md) 的 `pay` 重放问题用持久字段解决：

- `economy.accounts[owner]` 新增 `pay_seq`（安全整数，默认 0），表示该付款人已被接受的最大支付序号。旧文档缺省时恢复为 0；它不是农场顶层键，农场格式仍为 `27`。
- `pay` 命令新增必填 `seq`（正安全整数）。规则先查有界窗口：同 id 同载荷回放原结果；否则若 `seq <= pay_seq`，返回 `ok=false, reason="stale_sequence"`，不动任何余额；成功时在同一候选提交中把 `pay_seq = seq`。
- 只要求严格递增，不要求连续：一条失败或未发送的命令不会卡住后续序号。
- 因此命令窗口淘汰后，同 id 或新 id 携带旧序号都无法二次转账。市场扫描类命令没有同类序号：淘汰后重试可能重跑扫描并返回与首次不同的计数，但订单行、`closed_by` 和耐久成交/交付行阻止二次记账，这一点仍是已知边界。
- 直连单机/测试调用可以省略 `seq`，保持旧载荷格式；网络命令始终携带。

### 6. 不改存档形状与消息类型

- 不新增网络消息类型；摘要复用现有 `command_result` 通道。
- 不新增农场顶层键、不改农场格式版本、不改 `Game/scenes` / `Game/ui`。共享世界的客户端接线（下单面板等）不在本切片。

## 为什么不是另一侧

- **不接受载荷身份**：任何客户端字段都可伪造；连接解析出的 `actor` 是唯一可信来源。
- **不给访客经济权限**：访客没有账户归属，给钱或下单会制造无法追责的余额。
- **不把扫描做成客户端命令**：到期、撮合、交付和逾期必须由权威时钟推进，否则离线世界不会结算。
- **不复用订单 id 做 `pay` 幂等**：付款没有耐久业务行；`pay_seq` 是当前最小且可持久验证的守卫。
- **不新建消息类型**：现有摘要广播已能携带完整世界视图，新增通道只会扩大协议面。

## 后果

- `FarmCommand` 增加十种命令的校验、`make_*`、actor 绑定载荷与 `_apply`；`WorldInvite` 更新成员权限；`WorldHost` 增加经济门禁、中文失败原因和摘要广播；`HeadlessWorld` 增加固定顺序扫描、`settle_economy_now` 并纳入 `advance_to`；`world_server` 每秒补扫一次；`FarmState.economy_pay` 透传可选 `seq`；`Economy.pay`/`normalize_ledger` 维护 `pay_seq`；`FarmState.commit_command` 把已受理的 gift id 写入有界 `transaction.gift_ids`，`command_result` 在该集合上回放固定成功结果。
- 共享世界现在可以完整走完开户、付款、挂单、撮合、撤单、发货、交付、开市、开业、借款和还款；现金守恒仍是 `total_cash == issued`。
- 未覆盖：客户端 UI 接线、跨平台真实硬件、窗口淘汰后的市场扫描幂等、审计导出。

## 复审触发条件

客户端接线要求本地预测或离线队列；真实世界长期超过 64 条命令窗口且市场扫描结果差异影响玩家；需要把 `pay_seq` 扩展为每账户多设备并发序号；或访客需要受限的经济能力。
