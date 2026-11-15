# M8-04 · 公共基金调查与设计记录

状态：调查与设计完成（2026-11-15），**未实现、未验收**；M8-04 阻塞于公共支出 sink。本文只记录事实、代码位置与最小前置，不主张任何规则已落地。

权威设计：[ADR-024](../../decisions/ADR-024-public-funds.md)；上层规格：[经济与金融](../../systems/economy-finance.md)、[领土政治与法律](../../systems/politics-conflict-law.md)、[M8 PLAN](PLAN.md)、[M11 PLAN](../M11/PLAN.md)。

## 结论

1. **账户、转账、借贷分录和连接绑定 actor 已具备**，可以承载一个 `@org:<id>` 基金账户。
2. **权限模型可以最小实现**：member 可缴入/查看，visitor 无经济权限；keeper 由开立者产生，只有当前 keeper 能轮换和支出。
3. **当前没有真实公共支出对象**：建造免费、宅基私人、装饰私人、无税/公共采购/公共建筑；因此 M8-04 的“公共建设支出”无法验收。
4. **建议的最小前置 M8-04a**：新增一个固定成本的公共项目（公共设施）与独立公共项目表，由基金支付；在此之前不实现基金。
5. **首版资金来源只用成员自愿缴入**，不新增发行；一次性预算、成交费/银行费用改道、税费均留待后续裁决。
6. **`@org:<id>` 必须使用保留命名空间**；不能用 `coop:`/`org:` 这类玩家 id 合法字符串，否则可被客户端声明冒用。

## 调查事实与代码位置

### 经济账户与账本

| 事实 | 代码位置 |
|---|---|
| 现金账户 `economy.accounts[owner] = {cash, granted, pay_seq}`，`valid_owner` 只接受 `@world` 或 `OwnerIds.valid` | `Game/farm/economy_state.gd:56`、`:119` |
| `issued` 是净发行，`total_cash` 汇总账户、商人、托管、银行；快照要求 `total_cash == issued` | `Game/farm/economy_state.gd:117`、`:189` |
| `reconcile` 逐科目比较检查点与权威余额；`reserve_statement` 报告 `claims`/`reserve`/银行与贷款 | `Game/farm/economy_state.gd:225`、`:276` |
| 开户一次性发行 120 COIN；`open_account` 拒绝 `@world` | `Game/farm/economy_state.gd:506` |
| `pay` 只在两个已存在账户间转移，不改变 `issued`；`pay_seq` 提供窗口淘汰后的耐久幂等 | `Game/farm/economy_state.gd:560` |
| 科目：`account:<owner>`、`merchant`、`escrow`、`issuance`、`burn`、`bank`；`valid_account_code` 只接受系统科目或 `OwnerIds.valid` owner | `Game/farm/ledger_state.gd:51`、`:103` |
| `Ledger.post` 要求 2–4 行、逐笔借贷平衡、事件 id 在活跃日志内唯一 | `Game/farm/ledger_state.gd:228` |
| 成交卖方费用固定 1 COIN 并销毁，`issued` 同步减少；成交分录最多 4 行 | `Game/farm/market_state.gd:1342`、`:1359`、`:1394` |
| 运费固定 2 COIN 销毁，`issued` 同步减少 | `Game/farm/market_state.gd:939`、`:946` |
| 贷款费用留在银行；`bank.cash == capital - 未结清本金 + 已收费用` 被 `Economy.valid` 强制 | `Game/farm/loan_state.gd:303`、`Game/farm/economy_state.gd:480` |

### 建造、住宅与装饰

| 事实 | 代码位置 |
|---|---|
| `build()` 不扣现金或材料，建造者即 owner | `Game/farm/farm_state.gd:635` |
| `demolish()` 只允许 owner | `Game/farm/farm_state.gd:662` |
| 槽位是 `yard_a`…`yard_f` 个人宅基；蓝图 `cottage`/`workshop`/`pavilion` | `Game/farm/building_catalog.gd:8`、`:17` |
| 建筑快照只接受 `Buildings.SLOTS` 与 `OwnerIds.valid(owner)`；`@org:` 不是合法 owner | `Game/farm/farm_state.gd:1416` |
| 装饰是个人解锁/摆放，不涉及现金 | `Game/farm/decoration_state.gd` |
| 不存在 `housing_state.gd`；住宅由上述三处承担 | 本次调查确认 |
| 并发地籍切片已有 `public` 地块归属/通行状态，但没有公共建造、预算或支付路径 | `Game/world/territory_state.gd:19`、`:39`、`:236` |

### 身份与权限

| 事实 | 代码位置 |
|---|---|
| 角色来自邀请：member 拥有经济命令，visitor 只有 `water`/`weed` | `Game/world/world_invite.gd:29` |
| `WorldHost.execute_for_member` 从连接解析 `actor`；经济命令要求 member 且 actor 非空；visitor `forbidden` | `Game/world/world_host.gd:389`、`:408` |
| `FarmCommand` 精确键集，拒绝 `from`/`owner`/`payer`/`borrower` 等身份字段 | `Game/farm/farm_command.gd:270` |
| 加入时 `player_id` 只做格式校验并存为 `_players[peer]`；未与认证会话强绑定，也未做活跃唯一性检查 | `Game/world/world_host.gd:284`、`:531` |
| 邀请认证是 HMAC 挑战；`player_id`/`device_id` 本身不是密钥 | `Game/world/world_host.gd:199`、`ADR-004` |

**身份结论：** 命令 actor 确实来自连接而不是载荷，这一点满足“不能接受客户端声明”的命令边界；但 `player_id` 字符串本身仍是客户端声明。基金负责人比普通账户更高风险，实施前应至少拒绝同一活跃世界的重复 `player_id`，更彻底的做法是把 keeper 绑定到认证会话/邀请记录。

### 组织与公共财政现状

| 事实 | 代码位置 |
|---|---|
| 没有税、公共采购、公共建筑、道路或活动支出 | 本次全仓搜索确认 |
| M8-04 只写“合作社预算与公共建设支出使用独立账户和权限”；M11-02 才计划成员、职位、公共账户与交接 | `docs/2.0/milestones/M8/PLAN.md:37`、`docs/2.0/milestones/M11/PLAN.md:19` |
| 规格要求基金独立账户、收支公开、负责人换人不改变账本身份；税费需预告 | `docs/2.0/systems/economy-finance.md:39`、`docs/2.0/systems/politics-conflict-law.md:9` |

## 资金来源结论

| 来源 | 建议 | 理由 |
|---|---|---|
| 成员自愿缴入 | **首版采用** | 复用 `pay` 与 `pay_seq`；`total_cash`/`issued`/`burn` 都不变；不新增发行 |
| 一次性公共预算 | 首版拒绝 | 会新增第四条无业务来源发行；若必须，需一次性上限、独立 kind 与显式对账 |
| 成交费转入 | 后续 | 不是新钱，但把 `burn` 改成转移；相对现行口径 `total_cash`/`issued` 多保留 fee；部分改道可能超过 4 行上限 |
| 银行费用转入 | 后续 | 会破坏 `bank.cash` 精确等式，需同步改 `_bank_consistent`/`reserve_statement` |
| 税费/摊派 | 后续 M11-03 | 是转移不是发行；需要预告、授权与规则版本，不能暗中扣既有资产 |
| 罚款/赔偿 | 后续 M11-04 | 依赖案件与证据规则 |

## 最小前置切片（M8-04a，建议）

这不是已实现内容，只是解除阻塞所需的最小改动面：

1. **公共项目目录**：在 `building_catalog.gd` 或独立目录新增一个固定项目，例如 `village_square`，绑定现有 `pavilion`，固定 `cost = 300`、`build_seconds = 300`。
2. **独立公共项目表**：新增 `farm.public_projects`（或 `economy.funds[id].projects`），不复用 `buildings`。原因：`_valid_buildings` 只接受个人槽位和 `OwnerIds.valid(owner)`，复用会迫使改私人住宅所有权规则，并让私人 `demolish` 与公共项目冲突。
3. **基金账户与元数据**：
   ```text
   economy.accounts["@org:coop"] = {cash: 0, granted: false, pay_seq: 0}
   economy.funds["coop"] = {
     owner: "@org:coop", keeper: "<player id>", opened_by: "<command id>",
     opened_utc: 0.0, keeper_change_id: "", spend_seq: 0,
     projects: {"<project command id>": {project: "village_square", cost: 300,
                started_utc: 0.0, done_utc: 0.0, spent_by: "<player id>"}}
   }
   ```
   基金现金仍放在 `economy.accounts`，`funds` 只存授权与项目元数据，不成为第二套余额。
4. **命令**：
   - `fund_open`：member 触发，actor 成为首任 keeper；创建 0 现金账户与基金行；无分录；重复开立返回原结果或 `already_opened`。
   - `fund_set_keeper`：只有当前 keeper；`new_keeper` 是目标玩家 id；更新 `keeper` 与 `keeper_change_id`；基金账户 owner 不变。
   - `fund_spend`：只有当前 keeper；只接受目录内项目；`seq` 严格大于 `spend_seq`；基金余额足够；首版借 `burn`、贷基金账户，`issued` 同步减少；写项目行。
   - 缴入复用现有 `pay`，`to_id = "@org:coop"`，由成员账户 `pay_seq` 防重。
5. **账户/科目校验扩展**：
   - `Economy.valid_owner` 接受 `@org:<id>`，后缀用 `OwnerIds.valid`。
   - `Ledger.valid_account_code` 接受 `account:@org:<id>`。
   - `Economy.open_account` 拒绝 `@org:`（与 `@world` 相同），防止把 120 COIN 开户发行打进基金。
6. **权限接线**：
   - `FarmCommand.ECONOMY_KINDS`/`KINDS` 增加 `fund_open`、`fund_set_keeper`、`fund_spend`；键集精确，拒绝 `keeper`/`owner`/`from` 等身份字段。
   - `WorldInvite.PERMISSIONS[MEMBER]` 增加三种命令；visitor 不开放。
   - `FarmCommand._economy_payload` 绑定 actor；`FarmState` 用候选快照提交；`HeadlessWorld` 不需要新增扫描，项目完成时间由 `done_utc` 派生。
7. **准备金视图**：`reserve_statement` 增加只读 `public_funds`（所有 `@org:` 账户现金之和）与公共项目计数；不要重复计入 `accounts`。`claims`/`reserve`/`covered` 口径保持不变。
8. **测试（实施时）**：缴入不改变 `issued`；支出付 `burn` 时 `total_cash`/`issued` 同步减少；非 keeper 支出/轮换拒绝；keeper 轮换后账户 owner 与账本不变；重复命令与窗口淘汰后旧 `seq` 拒绝；`@org:` 不能被玩家声明；旧快照无 `funds` 时按空读入；`reconcile`/`reserve_statement` 通过。

## 风险与未覆盖

### 风险

- **负责人挪用**：若允许任意收款人/金额，keeper 可以把基金转给自己。首版只允许固定目录项目与固定成本，并记录 `spent_by`。
- **无 sink 的死钱**：在 M8-04a 之前，缴入只会沉淀；因此基金不应先于 sink 上线。
- **缴入等同捐赠**：会计上不是销毁，但若不可退款且无公共项目，缴入者永久失去支配权；UI/文案必须明示。
- **公共/私人建筑冲突**：现有 `build`/`demolish` 是个人 owner 规则；公共项目必须用独立表/槽位，不能让私人拆除或占位。
- **身份冒用**：`player_id` 是加入声明，未与认证会话强绑定；高风险基金应补活跃唯一性或会话绑定。
- **费用改道**：成交费/银行费用改道会改变 `burn`、`issued` 或银行恒等式，且可能触碰 4 行分录上限；首版不做。
- **负责人失联**：首版冻结支出，不自动接管；运营者恢复通道不存在，需另立审计边界。

### 未覆盖

- 未实现任何代码、命令、账户、科目、公共项目或 UI；本文所有结构均为建议。
- 未运行新测试；本次只做只读调查。既有贷款/账本/市场测试未被修改或复跑。
- 未决定公共项目首版是否提供玩法增益、视觉模型或场景接线。
- 未覆盖多基金、多负责人、副手、表决、税费、罚款、组织职位、M11 地籍与官府。
- 未覆盖 `player_id` 会话令牌、设备身份、邀请轮换与跨平台网络验证。
- 未登记到 `docs/2.0/decisions/README.md` 或更新 `M8 PLAN.md`：本次文件边界只允许新增 ADR-024 与本记录，入口登记由主会话统一处理。

## 建议的下一步

1. 产品裁决是否接受“公共设施（固定成本）作为首版 sink”；若接受，先实现 M8-04a。
2. 在 M8-04a 中同时补“活跃 `player_id` 唯一”或明确的会话绑定方案，再开放基金支出。
3. sink 与身份前置完成后，再按 ADR-024 的账户/权限/账本设计实现 M8-04，并补述实测输出与守恒数据。
