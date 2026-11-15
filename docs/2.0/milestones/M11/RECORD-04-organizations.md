# M11-02 · 组织成员、职位与公共账户引用（最小切片）

执行日期：2026-11-15。状态：切片完成，不表示 M11-02 或 M11 验收完成。前置：[M11 PLAN](PLAN.md)、[ADR-024 · 公共基金](../../decisions/ADR-024-public-funds.md)（仅引用账户命名，不做基金发行）。

## 问题

M11-02 要求成员、职位、权限、公共账户与交接，并保证“换届/退出不改变组织资产身份，越权支出拒绝”。在本次切片之前，项目只有玩家的连接身份和 `@org:` 账户的裁决建议，没有任何组织成员表、职位或授权规则可供独立验证。经济接线、公共支出 sink 和 UI 都还不具备，若把组织规则直接塞进 `FarmState` 或 `Economy`，会把尚未决定的账户形状、存档位置和网络权限一起固化。

本次只建立纯规则：给定一份组织文档，回答“谁是成员、谁是什么职位、谁能支出、谁能管理、谁能交接”，并拒绝越权。不接网络、不写存档、不做 UI、不发行货币。

## 边界

- 新增 `Game/world/organization_state.gd` 与 `tests/organization_state_test.gd`；只在 `docs/2.0/milestones/M11/` 下新增本记录并在 PLAN 增加一行链接。未修改农场、经济、地籍、绑定、场景、UI、规则或其他代理可能改动的文件。
- 不读取 `FarmState`、`Economy`、`TerritoryState`；不新增顶层存档键；不改协议版本。
- 无 RNG、无系统时钟、无磁盘、无场景、无网络。所有入口显式传入 `now_utc`，同一输入序列得到同一文档。
- 所有写入口返回候选文档（`{"ok", "reason", "state"}`），不修改调用方传入的文档；`authorize_spend()` 只做判定，不产生候选状态。
- 只做合作社/商会可共用的最小职位模型，不引入表决、税费、预算、任期、解散或世袭。
- 只引用组织账户 id，不创建账户、不记分录、不检查余额，也不实现 ADR-024 的基金发行或支出 sink。

## 文档形状

```text
organizations = {
  "organizations": {
    "<org_id>": {
      "name": "河岸合作社",
      "created_utc": 1800000000.0,
      "members": {"<player_id>": "leader" | "officer" | "member"},
      "roles": {
        "leader":  {"can_spend": true,  "can_manage": true},
        "officer": {"can_spend": true,  "can_manage": false},
        "member":  {"can_spend": false, "can_manage": false},
      },
      "account_id": "org_<org_id>",
    }
  }
}
```

- `org_id` 与 `player_id` 都使用 `Game/farm/owner_id.gd` 的 `OwnerIds.valid`：非空、最长 64、仅允许字母、数字与 `_ - . :`。组织表以 id 为键，因此键级重复不可能存在；非法 id 键会被拒绝。
- `account_id` 必须严格等于 `"org_" + org_id`，由 `account_for()` 派生。换届、退出、改名都不改它，因此组织资产身份与负责人玩家 id 解耦，和 ADR-024“基金账户所有者是组织 id，不是负责人”一致。
- 职位只有 `leader`、`officer`、`member` 三种。权限是规则常量，`valid()` 要求文档中的权限表与规范值逐项一致，因此改文档不能把普通成员变成可支出角色。
- 每个组织恰好一名 `leader`。没有负责人会让账户无人管理；多个负责人则授权含混。
- 上限：最多 64 个组织、每个组织最多 256 名成员、恰好 3 个职位；名称最长 64 且不能有首尾空白或控制字符。

## 规则

### 创建

`create(state, org_id, name, creator, now_utc)`：

- 创建者必须是合法玩家，并成为首任 `leader`；账户 id 由组织 id 派生。
- 重复 id 返回 `already_exists`；超过组织上限返回 `too_many`。
- 非法组织 id、名称、玩家 id、时间分别返回 `invalid_org`、`invalid_name`、`invalid_player`、`invalid_time`；输入文档不合法返回 `invalid_state`。

### 加入与退出

`join(state, org_id, player_id, now_utc)`：新成员固定为 `member`；重复加入 `already_member`，满员 `org_full`，未知组织 `unknown_org`。

`leave(state, org_id, player_id, now_utc)`：

- 非成员 `not_member`；最后一名成员 `last_member`；负责人 `leader_must_transfer`。
- 本切片没有解散规则，因此不允许把组织留成零成员、无人可管理的状态；负责人必须先 `transfer_leadership()`。解散、冻结和资产清算属于后续切片。

### 职位与权限

| 职位 | `can_spend` | `can_manage` | 含义 |
|---|---|---|---|
| `leader` | 是 | 是 | 负责人；可支出、可指派、可交接 |
| `officer` | 是 | 否 | 干事/财务；可支出，不能改职位 |
| `member` | 否 | 否 | 普通成员 |

`appoint(state, org_id, actor, target, role, now_utc)`：

- 只有成员且当前职位 `can_manage` 为真才能指派，否则 `role_forbidden`；非成员 `not_member`。
- 目标必须是现有成员（`target_not_member`）；职位必须是枚举值（`invalid_role`）。
- `leader` 不能经 `appoint()` 指派或降级，统一返回 `leader_requires_transfer`，防止绕过显式交接。

### 负责人交接

`transfer_leadership(state, org_id, actor, new_leader, now_utc)`：

- 只有当前 `leader` 可以发起（非负责人 `not_leader`，非成员 `not_member`）；新负责人必须已是成员（`target_not_member`）且不能是本人（`same_leader`）。
- 成功后原负责人变为 `member`，新负责人变为 `leader`。组织 id、组织行和 `account_id` 均不改变，因此换届不改变组织资产身份。
- 旧负责人随职位降级自动失去 `can_spend`/`can_manage`；新负责人自动获得。

### 支出授权

`authorize_spend(state, org_id, actor, account_id, amount, now_utc)`：

- 只做判定，不改文档，也不转账或记账。
- 具名拒绝：未知组织 `unknown_org`、非成员 `not_member`、职位无支出权 `role_forbidden`、账户不是本组织声明账户 `wrong_account`、金额不是正整数 `invalid_amount`、非法玩家 `invalid_player`、非法时间 `invalid_time`、文档不合法 `invalid_state`。
- 金额接受正整数；为兼容 JSON 十进制往返，整值浮点（例如 `25.0`）也接受，但零、负数、小数、非有限值和字符串一律拒绝。成功结果带 `org_id`、`account_id` 和整数 `amount`。
- 本切片不检查账户是否存在或余额是否足够；这些属于经济接线，不在纯组织规则内伪造。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 120 "$GODOT" --headless --path Game \
  --script "$PWD/tests/organization_state_test.gd"
```

原始末行：

```text
ORGANIZATION_STATE_TEST checks=139 failures=0
```

覆盖：

| 用例 | 检查 |
|---|---|
| 创建 | 空文档有效；合法创建；名称/时间/账户派生；创建者为唯一负责人；权限表规范；输入不变；重复 id、非法 id/名称/创建者/时间、畸形文档、组织数上限与越界全部拒绝 |
| 加入/退出 | 加入为普通成员且文档有效；重加入、未知组织、非法玩家、负数时间拒绝；退出移除成员；非成员退出拒绝；最后成员不能退出；负责人必须先交接；普通成员可在负责人留下时退出；成员数上限与 `org_full` |
| 职位 | 负责人可指派；干事与普通成员无管理权；非成员发起、目标非成员、指派 leader、负责人自我降级、非法职位、未知组织、负数时间均具名拒绝；降级后可再次提升 |
| 越权支出 | 负责人与干事可支出；普通成员 `role_forbidden`；非成员 `not_member`；错误/空账户 `wrong_account`；未知组织；零/负数/小数/非有限/字符串金额；非法 actor、负数时间、畸形文档；授权不修改文档 |
| 交接 | 非负责人、目标非成员、交接给自己、未知组织拒绝；成功后新负责人获权、旧负责人失去支出与管理权；`account_id` 与 `org_id` 不变；文档仍有效；再次交接成功 |
| 严格文档 | JSON 往返仍有效；未知/缺失顶层键、未知组织键、空/带空白/控制字符名称、负数/非有限时间、账户不匹配、未知成员角色、非法成员 id、零成员、零负责人、双负责人、仅负责人降级、非法组织 id 键、非字典组织行、缺角色/多角色、权限篡改/非布尔/多余键；组织数与成员数超限 |
| 确定性 | 同一命令序列生成相同文档；库命令不修改调用方文档；授权结果与拒绝原因可重复 |

## 未覆盖

- 经济接线：没有创建 `@org:<id>` 或 `org_<id>` 经济账户、没有分录、没有余额与 `total_cash`/`reconcile` 纳入，也没有 ADR-024 的 `fund_spend` sink。`account_id` 目前只是文档内引用。
- 账户命名空间冲突：本切片按任务要求使用 `"org_<id>"`；`OwnerIds.valid` 也接受该字符串，因此它可能被玩家声明成自己的 id。接线前必须决定保留命名空间（ADR-024 建议 `@org:`）或显式禁止玩家使用 `org_` 前缀。
- 存档与迁移：没有把组织文档放进农场快照或独立文件，没有键校验、容量预算、损坏恢复或版本化。
- 网络与权限来源：没有命令 RPC、actor 解析、成员角色校验、广播或回执；`actor` 只是本切片传入的合法玩家 id，尚未接到连接身份或 `PlayerBindingState`。
- UI：没有组织面板、成员列表、职位编辑、交接确认或支出审批界面。
- 解散与资产处置：没有组织解散、成员全部退出、账户冻结/清算、负责人长期离线接管约定。当前默认是“最后成员不能走、负责人必须先交接”。
- 规则决议：没有提案、表决、授权、预告、生效、版本与撤销；税费、预算和公共建设仍属 M11-03。
- 职位模型：职位与权限表固定，不能自定义；没有任期、罢免、副负责人、多人共管或职位历史审计。
- 支出语义：`authorize_spend()` 只验证身份、账户引用与金额形状，不验证余额、项目、收款人或重复扣款；不能据此认为公共资金已安全。
- 组织生命周期：没有改名、创建时间单调性检查、名称唯一性、跨组织成员关系约束；同一玩家可以同时属于多个组织。
- 只在本机 macOS 无头模式运行；未在 Windows 实机或 CI 运行，也未做真实存档/网络集成测试。

## 关联

- 阶段计划：[M11 PLAN](PLAN.md)。
- 账户与权限裁决：[ADR-024 · 公共基金](../../decisions/ADR-024-public-funds.md)；本切片只引用其 `@org:<id>` 账户身份思路，不做基金、发行或支出 sink。
- 身份绑定：[M11 RECORD-01](RECORD-01-cadastre.md) 同目录的地籍切片风格；玩家 id 规则见 `Game/farm/owner_id.gd`，严格文档校验风格参考 `Game/world/player_binding_state.gd` 与 `Game/world/territory_state.gd`。
- 后续接线：M11-03 规则决议、M8-04 公共基金 sink，以及 `FarmState`/`Economy`/`WorldHost` 的接线切片。
