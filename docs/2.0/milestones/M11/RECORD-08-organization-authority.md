# M11-02 · 组织接入世界权威（切片）

执行日期：2026-11-15。状态：切片完成，不表示 M11-02 或 M11 验收完成。前置：[M11 PLAN](PLAN.md)、[RECORD-04 · 组织规则](RECORD-04-organizations.md)、[ADR-024 · 公共基金](../../decisions/ADR-024-public-funds.md)（仅沿用“负责人只是授权元数据、组织/账户身份不随换届变化”的边界，不做基金）。

## 问题

RECORD-04 只有纯规则：给定一份组织文档，回答成员、职位、权限与交接。它没有持久化、没有连接身份、没有网络入口，因此“越权支出拒绝”只能在单元测试里证明，权威重启后也不存在任何组织。

本切片把同一份纯规则接到世界权威，只解决成员与职位：谁创建、加入、退出、被任命、接任负责人，以及在重启后仍然成立。它不涉及金钱、农场资产、地籍或建造。

## 边界

- 新增 `Game/world/organization_store.gd`、`tests/organization_authority_test.gd` 与本记录。
- 修改 `Game/world/headless_world.gd`（加载、只读视图、权威操作入口）、`Game/world/world_host.gd`（成员 RPC、权限与回复）、`Game/world/world_member.gd` 与 `Game/world/world_client.gd`（请求/答复代理）。
- `Game/world/organization_state.gd` 未修改：规则 API、文档形状与纯规则测试保持原样，所有校验继续由 `Organization.valid()` 与各命令函数负责。
- 未修改 `world_server.gd`、`FarmCommand`、`WorldProjection`、农场格式、场景或 UI；未新增顶层农场键、协议版本或经济账户。
- 组织操作不涉及金钱、公共基金、地籍、通行权、建造或拆除；本切片不调用 `TerritoryState`、`FarmState` 或经济命令。

## RPC 与频道

| 频道 | 方向 | 名称 | 说明 |
|---|---|---|---|
| 11 | 成员 → 权威 | `organization_request(payload)` | `{request_id, action, args}`；动作是 `create` / `join` / `leave` / `appoint` / `transfer_leadership` / `state` |
| 12 | 权威 → 成员 | `_organization_reply(request_id, payload)` | 携带 `{ok, action, org_id, duplicate, reason, reason_text, state}`；`state` 是权威组织视图 |

频道核查：世界会话现有 RPC 使用 0（`join`）、1（`_join_reply`）、2（`command_result`）、3（`submit`）、4（`request_summary`）、6（`catch_up`）、7（`social_request`）、8（`_social_reply`）、9（`territory_request`）、10（`_territory_reply`）。频道 5 未使用，但为避免与既有分组交错，组织沿用在地籍 9/10 之后的下一个连续空位 11/12；全仓库 `Game/`、`tests/` 中检索 `"reliable", 11` / `"reliable", 12` 无其它占用。

请求与答复都受 48 KiB 线上预算（`WorldPayload.WIRE_BUDGET_BYTES`）：请求超长直接回可见 `payload_too_large`；答复在 `rpc_id` 之前编码，超预算时同样回可见拒绝，不会让传输层静默丢包。请求与 `submit`、`social_request`、`territory_request` 共用命令令牌桶。

## 持久化

`Game/world/organization_store.gd`：

- 文件 `organizations.json`，与 `territory.json`、居民账本同级；信封为 `{version: 1, state: {...}}`。
- `state` 必须通过 `Organization.valid()` 的严格校验（精确键集、名称/时间/id、角色枚举与规范权限表、恰好一名负责人、数量上限）。
- 缺失返回 `{ok: true, kind: "missing", state: Organization.empty()}`，即空组织表。
- 版本不匹配返回 `unsupported`；解析失败、空文件、超过 64 KiB 或文档不合法返回 `corrupt`。
- 保存先写 `organizations.pending.json`，回读逐字节比对后再 rename 到主文件；保存前执行同一份 `valid()`，因此不会写出下一次加载会拒绝的文档。
- `HeadlessWorld.open()` 加载失败返回 `load_organizations_<kind>` 并拒绝启动；损坏、未知键或版本不支持的组织文件不会被空表覆盖。

组织操作在 `HeadlessWorld.execute_organization()` 中执行：规则在副本上计算，`save_state()` 成功后才替换 `organizations` 活文档；失败或拒绝不改内存、不写盘。sidecar 的 `state` 必须保持 `Organization.valid()` 的精确形状，所以命令重放窗口只存在内存里（最多 64 条）：同一命令 id、同一动作与参数立即重放返回首次成功结果并标记 `duplicate`；同一 id 不同载荷返回 `command_conflict`。重启后重试同一 id 不再有内存记录，但规则自身的 `already_exists` / `already_member` / `not_member` 等具名结果仍然确定。

## 权限

- 身份只来自连接：`WorldHost.organization_for_member()` 用 `_members` 判断是否入册、用 `_players` 解析操作者；`args` 里的 `actor` / `owner` 永不参与授权。`player_id` 只在 `appoint` 与 `transfer_leadership` 中表示目标成员。
- 读取：`state` 对所有已入册连接开放，包括访客与匿名成员；只返回 `id` / `name` / `created_utc` / `members` / `roles`，不下发账户 id、命令窗口或其它内部表。
- 写入：要求成员角色（`WorldInvite.MEMBER`）、非只读权威、非空玩家身份。拒绝原因按顺序具名：
  - 未入册：`not_a_member`
  - 访客：`forbidden`
  - 匿名成员：`no_player`
  - 迁移中/只读权威：`read_only`
  - 未知动作：`unknown_action`
  - 空或超长命令 id：`invalid_command`
- 规则层继续给出 `unknown_org`、`already_exists`、`already_member`、`not_member`、`last_member`、`leader_must_transfer`、`target_not_member`、`role_forbidden`、`leader_requires_transfer`、`not_leader`、`same_leader`、`invalid_role` 等具名拒绝。
- 负责人交接只改两名成员的职位，`org_id` 与 `account_id` 不变；旧负责人随职位降级失去任命权，新负责人获得。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 240 "$GODOT" --headless --path Game \
  --script "$PWD/tests/organization_authority_test.gd"
```

原始末行：

```text
ORGANIZATION_AUTHORITY_TEST checks=84 failures=0
```

回归原始末行：

```text
ORGANIZATION_STATE_TEST checks=139 failures=0
TERRITORY_AUTHORITY_TEST checks=69 failures=0
M4_SERVER_TEST checks=84 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/m4-server-326007
```

覆盖：

| 用例 | 检查 |
|---|---|
| 存储 | 缺失为空表且有效；写入后重载角色/名称一致；64 KiB 常量；未知顶层键与畸形表在写盘前拒绝 |
| 创建与重启 | 成员通过权威创建；创建者成为负责人；权威时钟打戳；载荷 `actor`/`owner` 被忽略；重启后成员、职位与创建时间仍在 |
| 幂等 | 同命令 id 重放返回 `duplicate`；同 id 不同载荷 `command_conflict`；新 id 重复创建 `already_exists`、重复加入 `already_member` |
| 职位 | 非成员不能任命；目标必须为成员；非法职位拒绝；负责人可任命干事；干事不能管理；负责人不能经任命产生 |
| 交接 | 交接成功并互换职位；账户 id 不变；旧负责人失去任命权；新负责人可任命；旧负责人不能再交接；不能交接给自己或非成员 |
| 退出 | 普通成员可退出；退出后再次退出/任命均为 `not_member`；最后成员不能退出；有其它成员时负责人必须先交接 |
| 拒绝 | 访客写入 `forbidden`、访客可读；匿名 `no_player`；未入册 `not_a_member`；未知动作；空命令 id；非法组织 id/名称；未知组织；只读权威 `read_only` 且仍可读 |
| 写时复制 | 被拒绝的任命不改变活文档 |
| 坏文档 | `organizations.json` 损坏、版本不支持、含未知顶层键均拒绝启动且不覆盖原文件；直接无头打开得到空且有效的组织表 |

## 未覆盖

- 金钱与公共基金：没有 `@org:` 经济账户、分录、余额、缴入或支出，也没有 ADR-024 的 `fund_spend` sink。“越权支出拒绝”仍只在 `Organization.authorize_spend()` 的纯规则测试中成立，未接入经济命令。
- 摘要投影：组织不在 `WorldSummary` / `WorldProjection` 中，不随摘要广播；成员只能通过 `state` 请求或操作答复刷新。成功写入后不触发 `shared_changed` 或摘要广播。
- UI：没有组织面板、成员列表、职位编辑、交接确认或退出入口；`WorldMember` / `WorldClient` 只提供请求与信号。
- 解散与资产处置：没有解散、账户冻结/清算、负责人离线接管；维持“最后成员不能走、负责人必须先交接”。
- 跨重启命令去重：重放窗口只在内存中，重启后同一命令 id 不会被识别为 `duplicate`；规则结果仍确定，但不是持久幂等窗口。
- 规则决议、税费、预算（M11-03）与案件（M11-04）均未接入。
- 组织视图与答复只在无头 macOS 上验证；未在 Windows 实机、CI 或真实网络传输中运行，也未做并发迁移/双权威写入验证。

## 关联

- 阶段计划：[M11 PLAN](PLAN.md)；规则切片：[RECORD-04](RECORD-04-organizations.md)。
- 地籍接入的同形参考：[RECORD-02](RECORD-02-cadastre-authority.md)、[RECORD-06](RECORD-06-cadastre-client.md)。
- 账户与负责人边界：[ADR-024](../../decisions/ADR-024-public-funds.md)。
- 存储与严格校验参考：`Game/world/territory_store.gd`、`Game/world/player_binding_store.gd`。
