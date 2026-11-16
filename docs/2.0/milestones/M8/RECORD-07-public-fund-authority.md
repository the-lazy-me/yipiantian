# M8-04 · 公共基金接入世界权威（切片）

执行日期：2026-11-15。状态：切片完成，不表示 M8-04 或 M8 验收完成。前置：[M8 PLAN](PLAN.md)、[RECORD-04 · 公共基金调查](RECORD-04-public-funds.md)、[RECORD-06 · 公共项目与基金纯规则](RECORD-06-public-fund-implementation.md)、[ADR-024 · 公共基金](../../decisions/ADR-024-public-funds.md)。

## 问题

RECORD-06 只有纯规则：给定基金文档，回答谁能缴入、谁当前负责、某笔支出是否被授权，并把 `org_<org_id>` 存成派生字符串。它没有持久化、没有连接身份、没有真实账户，也没有网络入口，因此“负责人换人不丢账、越权支出拒绝”只在规则测试里成立；权威重启后不存在任何基金，组织账户里也没有一分钱。

本切片把同一份纯规则接到世界权威，解决三件事：组织成员如何开立与换届、缴入/支出如何真实转移现金、基金余额与组织账户如何在重启后仍然一致。它不实现公共项目联动、施工、UI 或基金经济之外的新玩法。

## 边界

- 新增 `Game/world/fund_store.gd`、`tests/public_fund_authority_test.gd` 与本记录。
- 修改 `Game/world/headless_world.gd`（加载、只读视图、权威操作入口、跨文档结算）、`Game/world/world_host.gd`（成员 RPC、权限与回复）、`Game/world/world_member.gd` 与 `Game/world/world_client.gd`（请求/答复代理）。
- `Game/world/public_fund.gd` 未修改：基金 id/账户派生、开立、缴入、支出、换届与严格校验保持原样。
- 未修改 `Game/ui/*`、`main.gd`、`world_server.gd`、`Game/world/public_works.gd`、农场格式、`.github/`、`rules/` 或任何 PLAN。农场仍为格式 27，`PROTOCOL_VERSION` 仍为 1。
- 现金读写只调用 `FarmState` / `EconomyState` / `LedgerState` 的既有公开 API；没有给农场文档增加新键。

## RPC 与频道

| 频道 | 方向 | 名称 | 说明 |
|---|---|---|---|
| 15 | 成员 → 权威 | `fund_request(payload)` | `{request_id, action, args}`；动作是 `open` / `contribute` / `spend` / `rotate` / `state` |
| 16 | 权威 → 成员 | `_fund_reply(request_id, payload)` | 携带 `{ok, action, fund_id, duplicate, reason, reason_text, state}`；`state` 是权威基金视图 |

频道核查：世界会话现有 RPC 使用 0（`join`）、1（`_join_reply`）、2（`command_result`）、3（`submit`）、4（`request_summary`）、6（`catch_up`）、7（`social_request`）、8（`_social_reply`）、9（`territory_request`）、10（`_territory_reply`）、11（`organization_request`）、12（`_organization_reply`）、13（`unit_request`）、14（`_unit_reply`）。5 仍未使用；基金沿用单位之后的下一个连续空位 15/16。全仓库 `Game/`、`tests/` 中检索 `"reliable", 15` / `"reliable", 16` 无其它占用。

请求与答复都受 48 KiB 线上预算（`WorldPayload.WIRE_BUDGET_BYTES`）：请求超长直接回可见 `payload_too_large`；答复在 `rpc_id` 之前编码，超预算时同样回可见拒绝。基金请求与 `submit` / `social_request` / `territory_request` / `organization_request` / `unit_request` 共用命令令牌桶。`WorldClient` 的 `WireMember` 在频道 16 先做预算解码再交给基类，损坏载荷不会进入基金视图。

## 持久化

`Game/world/fund_store.gd`：

- 文件 `public_funds.json`，与 `territory.json`、`organizations.json`、`units.json` 同级；信封为 `{version: 1, state: {...}}`。
- `state` 必须通过 `PublicFund.valid()` 的严格校验（精确键集、派生 fund id、keeper 是 contributor、history 合计等于 spent、`balance + spent` 等于缴入合计；成功命令记录的 payload 是规范请求的 SHA-256）。
- 缺失返回 `{ok: true, kind: "missing", state: PublicFund.empty()}`，即空基金表。
- 版本不匹配返回 `unsupported`；解析失败、空文件、超过 64 KiB 或文档不合法返回 `corrupt`。
- 保存先写 `public_funds.pending.json`，回读逐字节比对后再 rename 到主文件；保存前执行同一份 `valid()`。
- `HeadlessWorld.open()` 加载失败返回 `load_funds_<kind>` 并拒绝启动；损坏、未知键或版本不支持的文件不会被空表覆盖。

## 账户与不变式

- 组织账户 id 由 `PublicFund.account_for(org_id)` 派生，即 `org_<org_id>`，与 `OrganizationState.account_for()` 完全相同。基金文档只保存 `org_id`，账户是派生字符串。
- 初始经济文档没有 `org_<org_id>` 账户。缴入/支出前在候选农场上按空账户 `{"cash": 0, "granted": false}` 补齐后 `restore_snapshot`；真正转账仍由 `economy_pay` 写入平衡分录。支出还补齐 `@world` 收款账户。
- 不变式：每支基金的 `balance` 必须等于其组织账户的 `economy_cash(account_for(org_id))`。加载时检查整份文档，任一行不一致返回 `load_funds_mismatch` 并拒绝启动；每次提交在候选农场 + 候选基金上做同一检查，不一致返回 `balance_mismatch` 且不写盘。没有静默修正路径。
- 该不变式同时让“农场已提交、基金文档未写”的重试可以被识别：组织账户现金已经变化而基金余额未变，说明基金文档落后于转账。
- 玩家普通 `pay` 命令不能直接转入 `org_` 账户：`FarmCommand` 在支付分支返回 `reserved_account`，现金与两份文档都不变。否则一笔绕过基金的转账会让余额不变式失败，甚至永久阻止基金开立。基金内部缴入/支出仍走 `FarmState.economy_pay`，不受该命令限制。
- 玩家 id 不能占用 `org_` 前缀：`SocialState.valid_identifier()` 在身份入口拒绝组织账户命名，防止成员以基金账户身份付款、收款或领取开户赠款；已有绑定文档若含这类 id 会因严格校验拒绝启动，而不是继续沿用。

## 动作语义

`HeadlessWorld.execute_fund(action, actor, args, command_id)`。操作者由连接层解析，`args` 里的 `actor` / `owner` 永不参与授权。

| 动作 | 规则调用 | 额外权威检查 | 现金 |
|---|---|---|---|
| `open` | `PublicFund.open_fund` | 组织存在、actor 是成员、当前职位 `can_spend`；keeper = actor | 不移动 |
| `contribute` | `PublicFund.contribute` | 只有具名成员、命令 id 非空；`fund_id` 或 `org_id` 都可定位基金 | contributor → 组织账户 |
| `spend` | `PublicFund.authorize_spend`（keeper 判定） | actor 仍是组织成员且当前职位 `can_spend` | 组织账户 → `@world` |
| `rotate` | `PublicFund.rotate_keeper` | 新 keeper 仍是组织成员 | 不移动 |
| `state` | 无 | 已入册连接均可读 | 不移动 |

- 组织权限判定使用 `OrganizationState.role_of()` 与 `OrganizationState.ROLE_PERMISSIONS` 这同一份角色权限表，没有新建权限表。未知组织、非成员、职位无支出权分别返回 `unknown_org` / `not_member` / `role_forbidden`。
- 缴入事件 id 为 `fund_pay_<command_id>`；支出事件 id 为 `fund_spend_<command_id>`。两者都写入平衡分录，保持 `total_cash == issued`。
- `spend` 的 `project_id` 只是格式合法的项目 id；本切片不读取 `public_works.gd`，不校验项目是否存在、足额或已建成。
- 视图只含 `fund_id` / `org_id` / `keeper` / `balance` / `spent` / `contributors`，按 `fund_id` 排序；不下发 `history`、命令记录或账户内部结构。

## 重试与跨文档事务

缴入与支出同时改两份文档，顺序固定为：

1. 规则在副本上生成基金候选；
2. 在农场副本上 `economy_pay`；
3. 校验候选基金余额等于候选组织账户现金；
4. 保存农场；
5. 农场保存成功后才保存基金文档；
6. 两份都成功后替换活对象并广播摘要。

失败处理：

- 规则拒绝、权限拒绝、余额不足、金额冲突、不变式不成立：农场与基金都不写，活文档不变。
- 农场保存失败：基金文档不写，内存不变，返回 `save_<kind>`，可安全重试。
- 农场保存成功、基金保存失败：接受同一农场候选（内存与磁盘一致），返回 `save_funds_<kind>`；基金文档仍为旧版本。下一次同 id 重试时，`fund_pay_<id>` / `fund_spend_<id>` 账本分录（金额、付款方、收款方三方匹配）证明农场侧已提交，只把同一规则重新应用到旧基金文档并落盘，不再调用 `economy_pay`，因此绝不二次转账。
- 恢复后的重试返回 `ok=true, duplicate=true`，与即时重放保持同一语义。
- 开立与换届只写基金文档，失败返回 `save_funds_<kind>`，无跨文档部分状态。

命令重放有两层：内存窗口（最多 64 条）与基金文档顶层 `commands` 表（最多 64 条）。成功命令在修改基金余额的**同一次原子保存**里写入 `{payload: sha256, result}`，因此重启后同一命令 id 同参数重放返回 `duplicate`，换参数返回 `command_conflict`，不会再次转账；`open` / `contribute` / `spend` / `rotate` 与恢复补写都走同一路径。`commands` 表满时淘汰最早一条，仍然是有限窗口；超过窗口的完整命令重放在旧文档上会按规则重新执行，这与账本分录 512 条上限共同构成残余风险。农场已付款、基金文档未写时，仍由 `fund_pay_<id>` / `fund_spend_<id>` 账本分录恢复；分录被淘汰后该窗口没有持久证据。

## 权限

- 身份只来自连接：`WorldHost.fund_for_member()` 用 `_members` 判断是否入册、用 `_players` 解析操作者；`args` 里的 `actor` / `owner` 永不参与授权。`fund_id` / `org_id` 只表示目标基金，`new_keeper` 只表示换届目标。
- 读取：`state` 对所有已入册连接开放，包括访客与匿名成员。
- 写入：要求成员角色（`WorldInvite.MEMBER`）、非只读权威、非空玩家身份。拒绝原因按顺序具名：`not_a_member`、`forbidden`、`read_only`、`no_player`、`unknown_action`、`invalid_command`。换届还要求操作者仍是该组织成员：已退出的旧 keeper 不能凭 keeper 身份改派基金。
- 基金层继续给出 `unknown_fund`、`unknown_org`、`already_exists`、`not_keeper`、`same_keeper`、`not_member`、`role_forbidden`、`insufficient_funds`、`history_full`、`insufficient_cash`、`invalid_amount`、`invalid_project`、`invalid_org`、`invalid_player`、`balance_mismatch`、`command_conflict` 等具名拒绝；普通支付转入组织账户由命令层返回 `reserved_account`；`WorldHost` 为其中基金特有的原因提供中文 `reason_text`。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
cd /Volumes/Disk-1tb/yipiantian
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/public_fund_authority_test.gd"
```

原始末行：

```text
PUBLIC_FUND_AUTHORITY_TEST checks=242 failures=0
```

回归原始末行（串行执行）：

```text
UNIT_AUTHORITY_TEST checks=224 failures=0
ORGANIZATION_AUTHORITY_TEST checks=200 failures=0
M4_SERVER_TEST checks=84 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/m4-server-348662
```

覆盖：

| 用例 | 检查 |
|---|---|
| 存储 | 缺失为空表且有效；64 KiB 常量；空表写盘后重载；未知顶层键与畸形文档在写盘前拒绝 |
| 开立 | 未知组织 `unknown_org`；非成员 `not_member`；普通成员 `role_forbidden`；leader 开立成功且 keeper=actor、余额 0、缴入表含 keeper、视图无 history；不动现金；重放幂等；同 id 换参数冲突；写盘且校验通过 |
| 缴入 | 成员通过权威缴入；载荷 `actor`/`owner` 被忽略；现金从连接身份真实转入 `org_<org_id>`；总额与发行量不变；余额与成员累计增加；落盘；重放不二次扣款/加款；同 id 换金额冲突；无账户 `insufficient_cash`；未知基金；`org_id` 与 `fund_id` 定位同一基金 |
| 支出 | officer keeper 支出成功；组织账户 → `@world`；总额不变；视图余额/累计支出更新；history 记录金额与项目；非 keeper `not_keeper`；超额 `insufficient_funds`；重放幂等；换金额冲突；降职后 keeper `role_forbidden`；退出组织后 `not_member`；失败不动现金 |
| 换届 | 非组织成员的缴入者不能接任 `not_member`；组织成员缴入者可接任；keeper/余额/成员累计正确；不动现金；重放幂等；前 keeper `not_keeper`；同一 keeper `same_keeper`；已退出组织的旧 keeper 改派返回 `not_member` 且 keeper 不变 |
| 账户保护 | 玩家普通支付直接转入组织账户被 `reserved_account` 拒绝，付款方现金、组织账户与总额都不变；之后仍可正常开立基金且余额不变式成立 |
| 重启 | 重开权威后基金、keeper、余额、缴入累计与组织账户现金仍在；同 id 缴入重试经文档命令表返回 `duplicate` 且不二次转账；换金额冲突 |
| 持久重放 | 缴入与支出完成后把整本账本折叠进 opening（等价于付款分录全部被淘汰），重启后同 id 重试仍返回 `duplicate`，双方现金、余额与 history 都不再变化；同 id 换金额返回 `command_conflict` |
| 付款重试 | 农场已保存、基金文档未写的缴入与支出都只补写基金文档，不二次转移；恢复后余额、累计支出与 history 一致；账本标记拒绝不同金额 |
| 不变式 | 篡改基金余额而组织账户不变时，加载返回 `load_funds_mismatch` 且不覆盖原文件 |
| 坏文档 | `public_funds.json` 损坏、版本不支持均拒绝启动且不覆盖；直接无头打开得到空且有效的基金表 |
| 权限与视图 | 访客/匿名成员可读、不可写；未入册 `not_a_member`；未知动作；空命令 id；只读 `read_only` 且仍可读；视图按 fund id 排序且不含 history/命令记录 |
| 写时复制 | 未知基金、无现金缴入、非法换届都不改变活基金、活农场或已落盘基金文档 |

## 未覆盖

- 公共项目联动：`spend` 只校验 `project_id` 格式，不读取 `public_works.gd`，不确认项目存在、未建成或金额与目录成本一致；不创建建筑、不改变地块、不做施工工期。
- 基金之外的公共支出路径：`@world` 只是收款方；没有预算、税率、罚款、退款、银行/成交费改道或发行规则。
- 跨重启的完整命令幂等已由基金文档 `commands` 表覆盖（64 条）；超出窗口的旧命令仍会按规则重新执行。缴入/支出的农场已付款、基金未写窗口仍依赖 512 条环形账本分录，分录被淘汰后没有持久证据。
- 支出恢复的事件载荷绑定：账本分录持久化了金额、付款方与收款方，但没有项目字段；同一 command id 以相同金额、不同 `project_id` 重试时，基金 `history` 仍保留对应金额与权威时刻则返回 `command_conflict`，history 也被淘汰后只能依赖账本金额这层证据（见增补）。
- 恢复路径不重新检查当前组织权限：转账已经发生，补写只完成账目；若在部分提交后组织成员或职位变化，恢复仍会补记，以免资金与账目永久不一致。
- 网络 UI 与场景：没有基金面板、缴入/支出/换届入口或公开收支展示；`WorldMember` / `WorldClient` 只提供请求方法与信号。基金不进入 `WorldProjection` / 摘要广播，客户端通过 `state` 请求或操作答复刷新。
- 命令窗口：内存与文档命令表各最多 64 条；已覆盖账本分录全被淘汰后的重启重放，未单独构造 64 条文档命令记录全部淘汰后的重放。基金规则自身的 64 支基金 / 256 名缴入者 / 256 条 history 上限由纯规则测试覆盖。
- 身份可信：`player_id` 仍是加入声明，不是密码学凭据；keeper 的高风险权限缺口仍需后续会话强绑定。
- 只在 macOS 无头模式验证；未在 Windows 实机、CI 或真实网络传输中运行，也未做并发双权威写入验证。

## 增补：付款意图、容量预判与半提交识别（2026-11-16）

审计确认真实重启路径上的三个缺口，现已修复：

- **付款前落盘意图**：缴入/支出在动农场现金之前，把
  `{command_id, action, actor, fund_id, amount, project_id, payload, at_utc}`
  写进 `public_funds.json` 信封层的可选 `pending`。农场保存成功、基金文档保存
  失败的进程退出后，启动会在余额总校验之前结算意图：账本里有同事件 id、同金额、
  同收付方的分录就重新应用规则补写基金文档（不再调用 `economy_pay`）；没有分录
  就丢弃意图。农场文档缺失时带意图拒绝启动，因为无法判断付款是否发生。
  付款前的规则失败与农场保存失败会清除意图；清除写盘失败时保留内存意图，
  下次启动按“无分录”丢弃。信封仍通过 `FundStore.load_state` 的严格校验，
  世界包与迁移导入允许该可选键。
- **容量预判**：`FundStore.fits(state, pending)` 在农场提交前检查含本条命令
  记录的基金文档能否写进 64 KiB；不能则返回 `fund_document_too_large`，不扣款、
  不写意图。之前该上限只在基金保存时检查，而保存排在农场提交之后，接近上限的
  世界会确定性地留下“农场已扣款、基金永远写不下”的半提交。
- **半提交换参识别**：账本事件 id 已存在但收付方或形状不符时返回
  `command_conflict`，不再当成“尚未付款”重新执行；同一 command id 换成另一支
  基金不会再扣一次款。支出恢复在基金 `history` 仍保留对应金额与权威时刻时比对
  `project_id`，同成本换项目同样返回冲突；history 也被淘汰时仍只剩账本金额证据。

测试 `PUBLIC_FUND_AUTHORITY_TEST` 242→291：写入旧基金文档加意图后重启，缴入
补写余额且贡献者现金只扣一次，重试返回 `duplicate` 且意图被清除；无账本分录的
意图被丢弃且不写余额；淘汰内存与文档命令记录后同 id 换基金/换项目均返回
`command_conflict` 且现金、支出不变；自校准的 64 KiB 超限文档在付款前返回
`fund_document_too_large`，现金与磁盘文件不变。回归
`FUND_NETWORK_TEST 110/0`、`WORLD_PACKAGE_TEST 126/0`、
`SIDECAR_STORE_GUARDS_TEST 246/0`、`PUBLIC_WORKS_AUTHORITY_TEST 243/0`、
`ORGANIZATION_DISSOLVE_TEST 171/0`、`ORGANIZATION_AUTHORITY_TEST 264/0`、
`FONT_COVERAGE_TEST 1272/0 missing=0`。

仍保留：基金命令表 64 条全局 FIFO 与账本 512 条环形窗口都淘汰后，极旧命令 id
的同参重放会走正常规则再次执行。彻底消除需要把命令回执移出有界窗口或改为
容量满时显式拒绝新命令，属于存储取舍，不在本次切片内。付款分录在意图结算前
被 512 条分录淘汰（基金保存失败后进程继续运行足够久）时，意图会被当作未付款
丢弃；正常崩溃—重启路径不会产生这么多新分录。

## 关联

- 阶段计划：[M8 PLAN](PLAN.md)；规则切片：[RECORD-06 · 公共项目与公共基金纯规则](RECORD-06-public-fund-implementation.md)。
- 裁决：[ADR-024 · 公共基金](../../decisions/ADR-024-public-funds.md)。
- 同形接线参考：[M11-02 组织接入世界权威](../M11/RECORD-08-organization-authority.md)、[M12-01 单位接入世界权威](../M12/RECORD-06-unit-authority.md)。
- 资产与账本：`Game/farm/farm_state.gd` 的 `economy_pay` / `economy_cash`，`Game/farm/economy_state.gd` 的 `@world` 账户，`Game/farm/ledger_state.gd` 的平衡分录。
- 存储与严格校验参考：`Game/world/organization_store.gd`、`Game/world/unit_store.gd`。
