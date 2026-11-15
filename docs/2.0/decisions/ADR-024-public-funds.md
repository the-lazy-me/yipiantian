# ADR-024 · 公共基金：独立账户、负责人权限与真实支出对象

- 状态：拟议；M8-04 当前**阻塞于公共支出 sink**（2026-11-15）。本裁决只确定账户、权限、账本与最小前置，不表示已实现。
- 关联：[M8-04 调查记录](../milestones/M8/RECORD-04-public-funds.md)、[经济与金融](../systems/economy-finance.md)、[领土政治与法律](../systems/politics-conflict-law.md)、[M8 PLAN](../milestones/M8/PLAN.md)、[M11 PLAN](../milestones/M11/PLAN.md)、[ADR-004](ADR-004-transport.md)、[ADR-012](ADR-012-matching-settlement.md)、[ADR-014](ADR-014-double-entry-ledger.md)、[ADR-017](ADR-017-bank-loans.md)、[ADR-019](ADR-019-economy-command-permissions.md)

## 背景

M8-04 要求“合作社预算与公共建设支出使用独立账户和权限；负责人换人不丢账，越权支出拒绝”。当前代码已经具备独立账户、逐笔借贷分录、连接绑定 actor 的经济命令和成员/访客角色，但：

- 建造不收费、没有材料账本，宅基是个人槽位，建造者即房主；没有“公共建筑”或“公共设施”对象。
- 没有任何税、成交费转公共、银行费用转公共或公共采购路径；成交费与运费目前直接销毁。
- 没有组织、职位或负责人模型；M11-02 才计划成员、职位、权限、公共账户与交接。
- 共享世界的 `actor` 来自连接，但连接加入时提交的 `player_id` 只是格式校验后的声明，不是密码学凭据。

因此 M8-04 的账户、权限和账本可以设计并实现，但“公共建设支出”没有真实收款对象；先建一个只进不出的基金只会制造死钱。本文将“可立即实现的部分”和“必须先补的 sink”分开。

## 决定

### 1. 结论与范围

1. **M8-04 整体阻塞于公共支出 sink**：在把某类建筑或设施定义为公共项目并由基金支付之前，不实现公共基金。基金账户本身不是验收对象，真实支出才是。
2. **最小前置切片 M8-04a**：只增加一个公共项目目录和一个公共项目表，让基金能按固定成本建造一个公共设施；不引入税、投票、组织职位或多级预算。
3. **M8-04 的资金来源首版只用成员自愿缴入**，不新增发行入口。一次性公共预算、成交费改道、银行费用改道和税费都列为后续选项，理由见下。
4. **基金身份不随负责人变化**：基金账户所有者是组织 id，不是负责人玩家 id；负责人只是账户上的授权元数据。
5. **负责人授权在权威规则层检查**，客户端不能声明 keeper、owner、payer 或基金来源；命令载荷出现这些身份字段即整体拒绝。

### 2. 资金来源与守恒影响

记 `total_cash` 为所有现金权威之和（账户、商人、买单托管、银行），`issued` 为净发行，`burn` 为销毁科目。现有恒等式是：

```text
total_cash == issued
issuance - burn == issued
```

| 来源 | 会计动作 | `total_cash` | `issued` | `burn` | 是否新增“无业务来源发行” |
|---|---|---|---|---|---|
| 成员自愿缴入 | 成员账户 → 基金账户（`pay`） | 不变 | 不变 | 不变 | 否。只是已发行货币的转移 |
| 一次性公共预算 | 借基金账户、贷 `issuance` | +X | +X | 不变 | **是**。与开户 120、商人 600、银行 2000 同类，必须一次性、有上限、有耐久标记 |
| 成交费转入 | 把 `trade` 费用行从 `burn` 改为基金账户 | 相对现行销毁口径多保留 fee | 相对现行口径多保留 fee | 减少 fee | 否，但这是把回收项改成转移项，长期会提高流通量 |
| 银行费用转入 | `loan_repay` 拆成银行本金 + 基金费用 | 不变 | 不变 | 不变 | 否，但会破坏现有 `bank.cash` 精确等式，需同步改 `_bank_consistent` |
| 税费/摊派 | 成员账户 → 基金账户 | 不变 | 不变 | 不变 | 否。需要预告与授权规则，属 M11-03 |
| 罚款/赔偿 | 玩家账户 → 基金账户 | 不变 | 不变 | 不变 | 否。需要案件与证据规则，属 M11-04 |

**首版选择：只采用“成员自愿缴入”。** 它复用现有 `pay` 与 `pay_seq`，不需要新发行、不改 `burn`、不改银行恒等式。基金账户初始现金为 0，由成员缴入形成余额。

**明确拒绝首版一次性公共预算。** 除非产品明确接受“世界预算”作为新的发行来源，否则不新增第四条永久发行路径。若演示必须启动资金，只能作为一次性、有上限、单独 kind 的 `fund_endow`，并在 `issued`/`total_cash`/对账里显式呈现，不能伪装成缴入。

**成交费改道不是“新钱”，但会改变回收结构。** 现行每笔成交固定 1 COIN 由卖方承担并销毁；若改为进入基金，`trade` 的 `burn` 行换成基金账户行，`issued` 不再减少该 fee。相对现行行为，`total_cash` 与 `issued` 都会多保留 fee。部分改道时，现有分录上限 `MAX_LINES = 4` 可能不够（买方退款、卖方成交款、销毁、基金、托管会到 5 行），必须先决定提高上限还是只做全额改道。

**银行费用改道会破坏现有强不变量。** 现行 `bank.cash == capital - 未结清本金 + 已收费用` 由 `Economy.valid` 强制；费用一部分转基金后，必须把“留存费用”与“转出费用”分开，并同步改 `reserve_statement` 与贷款测试。首版不做。

**税费不是发行，也不是销毁。** 它是成员之间/成员到基金的转移，`total_cash` 与 `issued` 不变。规格要求税费预告、不能暗中扣除既有资产；这需要 M11-03 的规则决议，不在 M8-04 首版发明。

**“缴入等于自愿销毁”只在经济意义上部分成立。** 会计上缴入仍留在基金账户、计入 `total_cash`，不是销毁；如果基金既没有 sink 也不退款，缴入者只是永久失去支配权。这正是当前阻塞点，而不是可接受的默认结果。

### 3. 支出用途：当前没有真实 sink

已核实的现有事实：

- `Game/farm/farm_state.gd:635` 的 `build()` 明确“no material ledger in this slice”，建造不扣现金或材料。
- `Game/farm/farm_state.gd:662` 的 `demolish()` 只允许记录中的 owner 拆除。
- `Game/farm/building_catalog.gd:8` 的槽位是 `yard_a`…`yard_f` 个人宅基；`cottage`/`workshop`/`pavilion` 都是私人蓝图。
- `Game/farm/decoration_state.gd` 的装饰是个人解锁与摆放，不涉及现金。
- 没有 `housing_state.gd`；住宅状态由 `building_catalog.gd`、`farm_state.gd` 的 `build`/`demolish` 和 `decoration_state.gd` 承担。
- 没有税、公共采购、公共建筑、道路或活动支出路径。

**结论：公共基金当前无真实 sink。** 若现在只实现基金账户，资金只能沉淀或被负责人转走，无法验证“公共建设支出”，也无法形成有意义的预算。

**最小可行前置（M8-04a，建议而非已实现）：**

1. 在目录中新增一个公共项目，而不是改造现有私人住宅：
   ```text
   public_projects = {
     "village_square": {name: "村口广场", blueprint: "pavilion", cost: 300, build_seconds: 300}
   }
   ```
2. 新增独立的公共项目表（例如 `farm.public_projects`，或 `economy.funds[id].projects`），不要复用 `buildings`：
   - 现有 `_valid_buildings` 只接受 `Buildings.SLOTS` 和 `OwnerIds.valid(owner)`，`@org:` 不是合法 owner，直接复用会迫使修改私人住宅的所有权规则。
   - 独立表可以明确“公共项目不可由私人 `demolish` 拆除”，避免公共/私人建筑权限冲突。
   - 并发地籍切片已有 `public` 地块状态（`Game/world/territory_state.gd`），可把项目绑定到这类地块；但该模块当前只描述归属与通行，不提供建造或支付，仍不构成 sink。
3. `fund_spend(project_id)` 由负责人提交，按目录固定成本扣基金并创建项目；工期用 `done_utc` 派生，不新增权威扫描。
4. 首版把成本转入 `burn`（代表外部材料与工程消耗），使基金成为真实货币 sink；若以后要支付给玩家建造者，再加“建造者账户”并改为转移，不改变基金身份。

这仍然只是“一个固定成本的公共设施”，不是完整预算/表决系统；M11-03 才负责提案、表决、预告、生效与撤销。

### 4. 权限模型

#### 4.1 身份只来自连接（现状与边界）

- `WorldHost.execute_for_member` 从 `_player_id(peer_id)` 解析 `actor`，再调用 `world.execute(command, actor)`；`FarmCommand._apply` 只把 `actor` 当作账户所有者、付款人或基金负责人（`Game/world/world_host.gd:389`、`Game/farm/farm_command.gd:71`）。
- `FarmCommand.valid` 对经济命令使用精确键集，`_has_identity_key` 拒绝 `from`、`from_id`、`owner`、`owner_id`、`payer`、`borrower`（`Game/farm/farm_command.gd:270`）。基金命令必须沿用这一点：客户端不能提交 `keeper`、`owner` 或“从哪个基金扣款”的身份字段。
- 角色来自已兑换邀请：member 拥有经济命令，visitor 只有 `water`/`weed`（`Game/world/world_invite.gd:29`、`Game/world/world_host.gd:408`）。基金命令应归入经济命令类别，visitor 一律 `forbidden`；匿名成员 `no_player`。

**必须同时说明的缺口：** 当前 `player_id` 是加入时客户端提交、只做格式校验的声明（`Game/world/world_host.gd:531`、`Game/world/world_client.gd:82`），不是 ADR-004 规划的会话令牌或密钥。因此：

- “身份来自连接”只能保证命令不能自己声明 actor，不能保证 actor 字符串本身不可冒用。
- 活跃会话唯一已实现（2026-11-15）：同一世界的一个 `player_id` 同时只能绑定一个连接，重复声明返回 `player_id_in_use`；断开即释放，同一 id 可以重连，命令仍按连接解析的身份记账（`M4_PRESENCE_TEST 38/0`）。这阻止了“同时冒用”，但没有阻止“换一个 id”：任何 member 邀请持有者都能声明一个新 `player_id` 并再次领取 120 的开户赠款。
- 对低风险账户，这与现有经济命令的边界一致；对基金负责人，这仍是高风险缺口。
- 更彻底的做法是把 keeper 绑定到经过认证的会话/邀请记录，并按邀请限制开户赠款。不能把客户端提交的 `keeper` 字段当作授权。

#### 4.2 负责人的产生、轮换与失联

建议的最小模型：

- **产生**：`fund_open` 是会员可触发的世界级一次性动作；成功提交的连接 actor 成为首任 keeper。基金 id 首版固定（例如 `coop`）或限制为 1 个，避免任意创建。重复开立返回原结果或 `already_opened`，不改变首任 keeper。
- **轮换**：`fund_set_keeper(new_keeper)` 只接受 `actor == fund.keeper`；`new_keeper` 是目标玩家 id，不是 actor，必须通过 `OwnerIds.valid` 且不能是 `@org:`/`@world`。成功后更新基金行的 keeper 与 `keeper_change_id`；基金账户所有者 `@org:<id>` 不变，因此账本、余额和分录都不迁移。新 keeper 不必在线，但必须是一个可被未来连接使用的合法玩家 id。
- **失联**：首版**不自动接管**。keeper 离线只意味着支出暂停；基金余额、缴入、只读对账和账本仍可核对。只有当前 keeper 能轮换，因此“失联”不会变成任意成员夺取基金。管理员/运营者的离线恢复是单独的管理操作，必须留下独立审计事件，不能伪装成普通 keeper 命令；该管理通道当前不存在，M8-04 不发明它。
- **预置副手**：可作为后续选项，但需要定义“离线多久后副手可接管”、防止副手提前夺权、以及原 keeper 回归后的冲突。首版不引入。

#### 4.3 越权拒绝点

按执行顺序，任一层拒绝都发生在候选状态写入之前：

1. `FarmCommand.valid`：命令 kind 合法、键集精确、无身份字段、金额/项目 id/序号合法。
2. `WorldHost.execute_for_member`：角色为 member 且 actor 非空；visitor/匿名成员拒绝。
3. `Economy`/基金规则：基金存在；`actor == fund.keeper`；项目在固定目录；成本精确匹配；`seq` 严格大于 `fund.spend_seq`；基金余额足够。
4. 分录 `Ledger.post`：借贷平衡、科目合法、事件 id 唯一；失败则整个候选丢弃。

拒绝原因至少区分 `not_keeper`、`unknown_fund`、`unknown_project`、`insufficient`、`stale_sequence`、`forbidden`、`no_player`。不能只返回笼统失败，否则无法证明“越权支出拒绝”。

#### 4.4 与成员/访客权限的关系

- member：可缴入、可查看授权范围内的基金收支；只有 keeper 可支出和轮换。
- visitor：没有可信经济身份，不开放基金读写；保留原有 `water`/`weed`。
- 社交协作授权（`SocialState`）只命名农活和地块，不能扩大基金权限；基金分支不读取 `_grant_allows`。
- 私人 `build`/`demolish` 不变；公共项目只能通过基金命令创建，不能被私人 owner 规则接管。

### 5. 账本与账户表达

#### 5.1 账户所有者命名

建议使用保留命名空间 `@org:<id>`，例如 `@org:coop`：

```text
economy.accounts["@org:coop"] = {"cash": 0, "granted": false, "pay_seq": 0}
```

理由：

- `OwnerIds.valid` 和 `SocialState.valid_identifier` 都不接受 `@`，因此玩家不能把 `@org:coop` 声明成自己的 `player_id`；反过来，`coop:seed` 这类 `OwnerIds` 合法字符串可以被玩家声明，不能作为组织保留名。
- `@world` 已被公共库存占用；不要把它复用为基金，否则世界公共物资与组织预算混在一起，M11 多组织时还要迁移。
- 不建议新增 `economy.public.cash` 这类独立现金字段：那会成为第二套余额权威，必须侵入 `total_cash`、`reconcile`、`reserve_statement` 和账本科目；放进 `accounts` 则自动被现有对账覆盖。

需要的最小代码扩展（实施时）：

- `Economy.valid_owner` 接受 `@org:` 前缀，且后缀通过 `OwnerIds.valid`；`@world` 行为不变。
- `Ledger.valid_account_code` 对 `account:@org:<id>` 做同样校验；`SYSTEM_ACCOUNTS` 不变。
- `Economy.open_account` 显式拒绝 `@org:`（和 `@world` 一样），防止把 120 COIN 开户发行打进基金。
- `Economy.pay` 的 `valid_owner` 因而允许成员向基金缴入；基金自身不能作为 `pay` 的 actor，因为 actor 来自玩家连接，而玩家 id 不含 `@`。

#### 5.2 分录科目与 kind

建议新增/复用的业务事件：

| 业务 | kind | 借方 | 贷方 | 说明 |
|---|---|---|---|---|
| 基金开立（0 现金） | 无分录 | — | — | 创建账户与元数据，金额为 0，不伪造借贷对 |
| 成员缴入 | `pay`（复用） | `account:@org:<id>` | `account:<member>` | 已有 `pay`、`pay_seq` 与分录路径 |
| 公共项目支出（首版付外部） | `fund_spend`（新增） | `burn` | `account:@org:<id>` | 基金现金减少、`burn` 增加、`issued` 同步减少 |
| 公共项目支出（后续付建造者） | `fund_spend` | `account:<builder>` | `account:@org:<id>` | 转移，不改变 `issued`/`total_cash` |
| 一次性公共预算（不建议首版） | `fund_endow`（新增） | `account:@org:<id>` | `issuance` | 新增发行来源，必须一次性、有上限 |
| 成交费转入（后续） | `trade`（复用） | 卖方成交款 + 基金 | `escrow` | 把 `burn` 行改为基金行，需处理 4 行上限 |
| 银行费用转入（后续） | `loan_repay`（复用） | 银行本金 + 基金费用 | 借款人总额 | 需改 `bank.cash` 恒等式 |

`fund_spend` 首版只接受固定目录项目，不接受任意收款人或任意金额；这是防负责人挪用的第一道边界。

#### 5.3 恒等式与准备金

若基金现金放在 `economy.accounts`：

- `Economy.total_cash` 自动包含基金账户，无需新增现金权威。
- `Economy.reconcile` 的逐科目对账自动包含 `account:@org:<id>`；不会出现“未知科目”。
- `reserve_statement.accounts` 自动包含基金现金；建议额外增加只读字段 `public_funds`（所有 `@org:` 账户现金之和）和 `public_projects` 计数，但不要把它再从 `accounts` 里加一次，避免双计。
- `claims` 仍为 0，`reserve = total_cash`，`covered` 口径不变。
- `bank.cash == capital - 未结清本金 + 已收费用` 在首版不受影响；只有银行费用改道时才需要改。
- 公共项目支出付 `burn` 时，`total_cash` 与 `issued` 同时减少、`burn` 增加；付建造者账户时三者都不变。

#### 5.4 幂等与命令窗口淘汰

首版命令与耐久守卫建议：

| 命令 | 有界窗口内 | 窗口淘汰后的耐久守卫 |
|---|---|---|
| `fund_open` | 同 id 同载荷回放；同 id 不同载荷 `command_conflict` | 基金行的 `opened_by`；重复开立返回原结果或 `already_opened` |
| `fund_set_keeper` | 同 id 同载荷回放 | 基金行保存 `keeper_change_id`；同 id 不同目标 `command_conflict`，不重复轮换 |
| `fund_spend` | 同 id 同载荷回放 | 基金行 `spend_seq` 严格递增；旧序号 `stale_sequence`，项目行/project id 作为耐久证据 |
| `pay` 缴入 | 同 id 同载荷回放 | 成员账户 `pay_seq`（现状） |

`fund_*` 命令共用现有 64 条 `economy.command_results` 窗口；不能把窗口当作唯一幂等依据。基金行自身的 `opened_by`、`keeper_change_id`、`spend_seq` 才是跨淘汰守卫。

**审计缺口：** 现有 `Ledger.entry` 不保存 actor，只有 `kind`、`event_id`、`at_utc` 和账户行。缴入可以从 `account:<member>` 行反推付款人；支出到 `burn` 时无法从分录反推是哪个 keeper 批准。为满足“收支公开到授权范围”，建议在基金行增加一个有界历史（例如 256 条 `{command_id, kind, amount, actor, project, at_utc}`），或让项目行保存 `keeper_at`/`spent_by`。不要为此无界扩展分录形状。

### 6. 风险

| 风险 | 说明 | 首版处置 |
|---|---|---|
| 负责人挪用 | keeper 可提交支出；若允许任意收款人/金额，等同于把基金交给他 | 只允许目录内固定项目与固定成本；首版付 `burn` 或固定建造者，不接受任意转账 |
| 无 sink 的死钱 | 没有公共项目时，基金只进不出，缴入者永久失去支配权 | 先做 M8-04a 再开放缴入；否则不实现基金 |
| 缴入被理解为销毁 | 会计上不是销毁，但经济上可能等同捐赠 | UI/文案明确“不可退款、用于公共项目”；不伪造退款 |
| 公共/私人建筑冲突 | 现有宅基和 `demolish` 是个人所有权；公共项目若复用会绕过 owner 规则 | 独立公共项目表与槽位；私人 `demolish` 不作用于公共项目 |
| 身份冒用 | `player_id` 是加入声明，未与认证会话强绑定 | 至少活跃唯一；高风险场景要求会话/邀请绑定；ADR 复审触发 |
| 费用改道改变货币供给 | 成交费/运费/银行费用原本销毁或留存，改道后少销毁或多流通 | 首版不改道；后续单独裁决并测 `issued`/`burn`/银行恒等式 |
| 负责人失联 | 无人能支出，基金冻结 | 明确冻结是安全默认；不自动接管；运营者恢复另立审计通道 |
| M11 范围蔓延 | 组织、职位、表决、税费不在 M8-04 | 首版只做单基金、单 keeper、固定项目；M11-02/03 再扩展 |

### 7. 为什么不是另一侧

- **不建第二套余额**：基金现金必须在 `economy.accounts` 内，才能被 `total_cash`、`reconcile` 和准备金报告解释；独立 `fund.cash` 会重复所有消费路径。
- **不使用 `@world`**：公共库存已经占用该 owner；复用会让物资与预算混同，也无法支持 M11 多组织。
- **不使用 `coop:`/`org:` 普通 id**：玩家 id 允许 `:`，可被客户端声明冒用；`@` 是现有校验器共同拒绝的保留字符。
- **不先发一笔公共预算**：这会新增第四条无业务发行路径，违背“不暗中增发”的压力测试目标；成员缴入足够验证账户与权限。
- **不做自动接管**：负责人失联时自动把权限交给副手/多数，需要离线判定、任期和冲突规则；M8-04 没有这些制度，冻结比错误授权安全。
- **不复用私人建造**：`build`/`demolish` 的 owner 规则、槽位和“无材料账本”边界会与公共项目冲突；独立公共项目表更小且更清晰。

### 8. 复审触发条件

出现以下任一情况时重开本裁决：

- 公共项目目录和 sink 被采纳，或决定取消 M8-04 的“公共建设支出”要求；
- 要把成交费、运费或银行费用的一部分转入基金；
- 要引入税、摊派、罚款或任何自动扣款；
- 要发放一次性公共预算或任何新的 `issuance` 来源；
- 要支持多个基金、多个负责人、副手接管、表决或组织职位（M11-02/03）；
- 要允许基金向任意玩家/账户付款，或允许基金在市场上挂单；
- `player_id` 的会话绑定、唯一性或密钥方案发生变化；
- 分录行数上限、基金账户形状或农场快照键需要改变。

## 未决问题

1. `fund_open` 是否只允许世界级一次性开立，还是允许每个 `@org:<id>` 各开一次？首版建议只开一个 `coop`。
2. 公共项目首版是否只做“记录 + 工期 + 视觉占位”，不提供玩法增益？建议是，避免把 sink 变成新的经济系统。
3. 基金支出是否允许退回成员？首版建议不允许，防止 keeper 用退款绕过支出审计。
4. 负责人是否必须同时是成员？规则层只能校验玩家 id 格式；成员关系是 `WorldHost` 的动态状态。建议在 `WorldHost` 入口额外校验，但不要把成员表复制进经济快照。

## 受影响规格

- [经济与金融](../systems/economy-finance.md)：确认“合作社和官府基金独立账户、收支公开、负责人换人不改变账本身份”的账户与权限边界；首版只覆盖合作社单基金。
- [M8 PLAN](../milestones/M8/PLAN.md) M8-04：在公共支出 sink 前置完成前不标记实现；记录见 [RECORD-04](../milestones/M8/RECORD-04-public-funds.md)。
- [M11 PLAN](../milestones/M11/PLAN.md) M11-02/M11-03：公共账户、成员职位、预算/表决与税费由后续阶段扩展；本裁决的 `@org:` 账户命名和 keeper 元数据应作为其起点。
- [ADR-014](ADR-014-double-entry-ledger.md)：基金不新增现金权威，只新增科目命名空间与 `fund_spend` 事件；分录仍是有界证据。
- [ADR-017](ADR-017-bank-loans.md)：首版不改银行费用路径，`bank.cash` 精确等式保持。
- [ADR-019](ADR-019-economy-command-permissions.md)：基金命令沿用“身份来自连接、载荷不含身份字段、visitor 无经济权限”的边界；同时暴露 `player_id` 声明未强绑定的缺口。
