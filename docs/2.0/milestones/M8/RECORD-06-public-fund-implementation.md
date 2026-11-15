# M8-04a/M8-04 · 公共项目与公共基金纯规则切片

执行日期：2026-11-15。状态：纯规则切片完成，不表示 M8-04a、M8-04 或 M8 验收完成。本文记录 `Game/world/public_works.gd`、`Game/world/public_fund.gd` 与 `tests/public_fund_test.gd`；未接权威、未创建真实账户、未调用 Economy/Ledger。

前置：[RECORD-04 · 公共基金调查](RECORD-04-public-funds.md)、[ADR-024 · 公共基金](../../decisions/ADR-024-public-funds.md)、[M8 PLAN](PLAN.md)、[M11 PLAN](../M11/PLAN.md)。

## 问题

RECORD-04 的结论是 M8-04 阻塞于“没有现实公共支出对象”：建造免费、宅基私人、装饰私人，也没有税或公共采购。只实现基金账户会形成只进不出的死钱，无法验证“公共建设支出”。ADR-024 因此把最小前置 M8-04a 定义为“一个固定成本的公共设施 + 独立公共项目表”，并建议基金支出按固定目录项目扣款。

本次把这条前置和后继基金规则落成可独立验证的纯规则：

- 公共项目只回答“项目类型、绑定地块、承诺额、是否足额、是否建成”。
- 公共基金只回答“谁缴入、谁当前负责、余额与累计支出是多少、某笔支出是否被当前负责人授权”。
- 两者都不发行货币、不转账、不创建建筑、不碰农场或经济文档；真实支付与账户仍由后续权威接线完成。

## 边界

- 新增 `Game/world/public_works.gd`、`Game/world/public_fund.gd`、`tests/public_fund_test.gd` 与本记录；未修改 `PLAN.md`、`project-context.md`、CI、`FarmState`、`EconomyState`、`LedgerState`、`WorldHost`、`OwnerId`、`organization_state.gd` 或其他模块。
- 不读取 RNG、系统时钟、磁盘、场景、网络、`FarmState`、`EconomyState`、`LedgerState` 或地籍文档。`built_utc` 与支出 `at_utc` 由调用方显式传入。
- 两个模块都只依赖 `Game/farm/owner_id.gd` 的 id 格式校验（纯字符串规则），不创建账户，不写存档，不改协议版本。
- 所有写入口返回 `{"ok", "reason", "state"}` 候选文档，不修改调用方输入；失败结果不带 `state`。
- 本切片不做 UI、不做项目完成时间扫描、不做施工工期、不做公共项目对玩法的增益。

## 规则形状

### 公共项目

```text
{
  "projects": {
    "<project_id>": {
      "kind": "village_square" | "public_well" | "road_segment",
      "parcel_id": "<cadastral parcel id>" | "",
      "funded": 300,
      "status": "unbuilt" | "funded" | "built",
      "pledged": 300,
      "built_utc": 0.0,
    }
  }
}
```

固定目录（`CATALOG`）：

| kind | 成本 |
|---|---:|
| `village_square` | 300 |
| `public_well` | 180 |
| `road_segment` | 120 |

- `funded` 是“已覆盖的固定成本”，恒等于 `min(pledged, cost)`。`pledged` 是累计承诺额，可以超过成本；`funded` 封顶为目录成本。
- 状态：
  - `unbuilt`：`funded < cost`；
  - `funded`：`funded == cost`，尚未建成；
  - `built`：`funded == cost`，`built_utc` 记录首次建成时刻。
- 未建成项目的 `built_utc` 固定为 `0.0`；建成后不再接受承诺或退回，重复标记返回 `already_built`。
- `parcel_id` 允许空串（尚未绑定地块），非空时必须是 `OwnerIds.valid` 的地块 id；项目不读取地籍文档，也不改变地块归属。

写入口：

| 入口 | 行为 | 主要具名拒绝 |
|---|---|---|
| `open_project(document, project_id, kind, parcel_id)` | 登记项目，初始承诺/成本覆盖为 0 | `invalid_project`、`invalid_kind`、`invalid_parcel`、`already_exists`、`too_many` |
| `pledge(document, project_id, amount)` | 增加累计承诺；达到成本后转 `funded` | `unknown_project`、`invalid_amount`、`amount_limit`、`already_built` |
| `release_pledge(document, project_id, amount)` | 退回承诺；低于成本时回到 `unbuilt` | `unknown_project`、`invalid_amount`、`amount_limit`、`insufficient_pledged`、`already_built` |
| `mark_built(document, project_id, now_utc)` | 把已足额项目标成建成 | `unknown_project`、`invalid_time`、`underfunded`、`already_built` |

金额只接受正整数；JSON 往返产生的整值浮点（如 `100.0`）被接受，小数、零、负数、非有限值和字符串被拒绝。单笔承诺上限 `MAX_PLEDGE = 1_000_000`，项目累计上限 `MAX_PLEDGED = 10_000_000`。项目数上限 32。

### 公共基金

```text
{
  "funds": {
    "fund_<org_id>": {
      "org_id": "<org_id>",
      "keeper": "<player_id>",
      "contributors": {"<player_id>": 120},
      "balance": 120,
      "spent": 40,
      "history": [
        {"kind": "spend", "amount": 40, "actor": "<player_id>",
         "project": "<project_id>", "at_utc": 1800000000.0},
      ],
    }
  }
}
```

- 基金 id 与账户引用都由 `org_id` 派生：`fund_for(org_id) == "fund_" + org_id`，`account_for(org_id) == "org_" + org_id`。本切片只保存/返回派生字符串，不创建真实经济账户。
- 基金行键必须严格等于 `fund_for(org_id)`，因此改键、改 `org_id` 或把行搬到另一个键下都会被 `valid()` 拒绝。
- `keeper` 必须是 `contributors` 中的玩家；首任 keeper 在开立时以累计额 0 进入成员表。换届只改 `keeper`，不改基金 id、账户派生、余额、累计支出或成员累计。
- 守恒：`balance + spent == sum(contributors)`，且 `spent == sum(history.amount)`。

写入口：

| 入口 | 行为 | 主要具名拒绝 |
|---|---|---|
| `open_fund(document, org_id, keeper)` | 开立组织基金，keeper 成为首任负责人并进入成员表 | `invalid_org`、`invalid_player`、`already_exists`、`too_many` |
| `contribute(document, fund_id, contributor, amount)` | 增加余额与成员累计 | `unknown_fund`、`invalid_player`、`invalid_amount`、`amount_limit`、`contribution_limit`、`balance_limit`、`fund_full` |
| `authorize_spend(document, fund_id, actor, project, amount, now_utc)` | 只有当前 keeper 可支出；扣余额、加累计支出、追加一条 history | `unknown_fund`、`invalid_player`、`not_keeper`、`invalid_time`、`invalid_project`、`invalid_amount`、`amount_limit`、`insufficient_funds`、`history_full` |
| `rotate_keeper(document, fund_id, actor, new_keeper)` | 只有当前 keeper 可换届；新 keeper 必须是 contributor | `unknown_fund`、`invalid_player`、`not_keeper`、`same_keeper`、`not_member` |

上限与有界性：

- 单笔缴入 `MAX_CONTRIBUTION = 10_000`；单成员累计 `MAX_TOTAL_CONTRIBUTION = 100_000`；余额 `MAX_BALANCE = 1_000_000`；单笔支出 `MAX_SPEND = 1_000_000`。
- 基金数上限 64，成员数上限 256，history 上限 256。
- history 只记录支出，不记录缴入；`spent` 等于全部 history 金额之和。达到 256 条后返回 `history_full`，不淘汰旧行，避免审计行丢失或 `spent` 与 history 不再一致。
- 缴入不写 history，也不改变 `spent`；退货、退款、税费、发行和一次性公共预算均不在本切片。

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian
perl -e 'alarm shift; exec @ARGV' 180 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/public_fund_test.gd"
```

原始末行：

```text
PUBLIC_FUND_TEST checks=225 failures=0
```

覆盖：

| 用例 | 检查 |
|---|---|
| 项目基础 | 空文档与 JSON 往返有效；登记项目、目录成本、初始字段；输入不变；重复/非法 id/类型/地块/畸形文档拒绝；拒绝不带 state；项目数上限与越界 |
| 项目资金 | 承诺未达成本保持 `unbuilt`；达到成本转 `funded`；超额承诺封顶；退回后低于成本回到 `unbuilt`；退款超过承诺拒绝；未足额不能建成；足额建成记录时间；重复建成、建成后承诺/退回拒绝 |
| 项目严格校验 | 未知/缺失顶层与行键、非法状态、`funded` 与成本不一致、足额却标 `unbuilt`、负/小数承诺、非建成却有时间、非法/非有限时间、未足额却标 `built`、未知类型、非法地块、非字典行、超长 id、项目数超限 |
| 基金开立与缴入 | 派生 fund id/账户引用；开立字段；重复开立、非法组织/首任 keeper、基金数上限；缴入增加余额与成员累计且不写 history；非法玩家/金额、单笔/累计/余额上限、成员数上限；写时复制 |
| 基金支出 | keeper 可支出并扣余额/加 spent/写一条完整 history；非 keeper、余额不足、零/小数金额、非法项目/时间/actor、未知基金均拒绝；拒绝不带 state |
| 换届 | keeper 可换届；基金 id、org_id、余额、成员累计不变；前 keeper 失去支出与换届权；新 keeper 必须是 contributor；同一 keeper、非法新 keeper、未知基金拒绝 |
| history 上限 | 恰好接受 256 条；第 257 条返回 `history_full`；history 合计、`spent` 与 `balance + spent` 始终一致 |
| 严格校验 | 未知/缺失键、非字典行、改名/搬键、改 org_id、非法 keeper 或非成员 keeper、空/非法/负数/小数/超限 contributor、破坏守恒的 balance/spent、history 未知键/类型/金额/actor/project/时间、history 超限、基金数超限、非法基金 id |
| 确定性 | 同一基金/项目命令序列产生相同文档；库命令不修改调用方文档 |

## 真实账户与权威接入（未完成）

本切片产生的只是预算事实文档。要让 M8-04 真正满足“负责人换人不丢账，越权支出拒绝”，后续权威接线必须完成：

1. **真实账户**：在 `Economy` 中创建 `@org:<org_id>` 账户（不是文档里的 `org_<org_id>` 字符串），扩展 `valid_owner`/`valid_account_code`，并让 `open_account` 拒绝 `@org:`；本切片没有做这些修改。
2. **真实缴入**：复用现有 `pay`，由成员账户向 `@org:<org_id>` 付款；`pay_seq` 提供耐久幂等。
3. **真实支出**：keeper 提交 `fund_spend` 时，权威先调用本切片的 `authorize_spend` 生成候选基金文档，再按 ADR-024 的首版方案借 `burn`、贷基金账户，使基金成为真实货币 sink；本切片不调用 `Economy`/`Ledger`，不伪造资金。
4. **项目联动**：`authorize_spend` 目前只校验项目 id 格式；权威需要额外确认项目在 `public_works` 文档中存在且未建成，并把项目/地块与地籍或场景绑定。
5. **身份与权限**：actor 必须来自连接，member 角色才能提交基金命令，visitor 无经济权限；当前 `player_id` 仍是加入声明，未与认证会话强绑定，基金 keeper 的高风险缺口仍需按 ADR-024 处理。
6. **持久化**：基金与项目文档尚未进入农场快照、独立存档或 `WorldHost` 广播；没有键校验、容量预算、损坏恢复或版本迁移。
7. **界面**：没有基金/项目面板、缴入与支出确认、换届操作或收支公开视图。

## 未覆盖

- 未实现 `fund_spend` 命令、`FarmCommand` 键集、`WorldInvite` 权限、`WorldHost` 接线或任何 RPC。
- 未创建 `@org:` 账户、未扩展 `Economy.valid_owner`/`Ledger.valid_account_code`、未改 `total_cash`/`issued`/`reconcile`/`reserve_statement`。
- 未接入地籍：`parcel_id` 只是格式合法的字符串，不检查地块是否存在、是否 `public` 或是否与项目类型匹配。
- 未实现施工工期、完成扫描、公共项目视觉、玩法增益或私人 `demolish` 与公共项目的冲突处理。
- 未实现多基金治理、组织成员校验、职位表、表决、税费、罚款、退款、一次性预算或银行/成交费改道。
- 未覆盖 keeper 失联恢复、会话绑定、多设备、跨平台网络或管理审计通道。
- 未在 Windows 或 CI 运行；只在 macOS 无头 Godot 4.7.2 上执行上述测试。

## 关联

- 前置调查：[RECORD-04 · 公共基金调查](RECORD-04-public-funds.md)。
- 裁决：[ADR-024 · 公共基金](../../decisions/ADR-024-public-funds.md)（独立账户、负责人权限、固定目录支出与最小前置）。
- 计划：[M8 PLAN](PLAN.md) M8-04；[M11 PLAN](../M11/PLAN.md) M11-02/M11-03（组织、职位、预算与规则决议）。
- 相邻纯规则切片：[M11-02 组织规则](../M11/RECORD-04-organizations.md)（成员/职位/交接风格）、[M11-01 地籍规则](../M11/RECORD-01-cadastre.md)（严格文档与地块 id）。
- 代码：`Game/world/public_works.gd`、`Game/world/public_fund.gd`、`tests/public_fund_test.gd`。
