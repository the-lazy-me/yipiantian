# M12-02 · 参与制度接入世界权威（切片）

执行日期：2026-11-16。状态：切片完成，不表示 M12-02 或 M12 验收完成。前置：[M12 PLAN](PLAN.md)、[RECORD-02 · 参与制度纯规则](RECORD-02-participation.md)、[ADR-025 · 冲突参与](../../decisions/ADR-025-conflict-participation.md)。

## 问题

RECORD-02 的和平/有限冲突、区域、窗口、同意、退战延迟与损失上限只是纯规则：没有持久化、没有房主身份、没有网络入口，也没有任何东西把玩家连接与声明人对应起来。权威重启后不存在任何参战声明，房主也无法对真实房间发布风险范围。

本切片把同一份规则接到世界权威：房主身份如何进入世界、声明如何落盘、成员如何同意和退战、重启后如何保持同一份声明。它不实现真实交战、资产冻结、战利品或 UI。

## 边界

- 新增 `Game/world/participation_store.gd`、`tests/participation_authority_test.gd` 与本记录。
- 修改 `Game/world/headless_world.gd`（加载、只读视图、权威操作入口）、`Game/world/world_host.gd`（成员 RPC、权限与回复）、`Game/world/world_member.gd` 与 `Game/world/world_client.gd`（请求/答复代理）、`Game/world/world_hosting.gd`、`Game/world/world_server.gd`（`--host-player`）与 `Game/scenes/startup.gd`（开房时传本机玩家 id）。
- `Game/conflict/participation_state.gd` 未修改：声明、同意、退战、区域/窗口/上限校验保持原样。
- 未修改 `Game/ui/*`、农场格式（仍 27）、`PROTOCOL_VERSION`（仍 1）或任何 `Game/farm/*`。

## 房主身份与持久化

- 房主玩家由权威启动参数 `--host-player=<player id>` 显式给出；桌面开房时 `startup.gd` 把本机 `player_id` 传给 `WorldHosting.start()`，再由它追加该参数。
- 没有 `--host-player` 时权威照常开房，但参与制度保持 `hostless`：`participation.json` 不创建，所有写操作返回 `no_host`。不虚构房主，也不把“无人声明”当成和平。
- `Game/world/participation_store.gd`：
  - 文件 `participation.json`，与 `territory.json`、`units.json`、`public_funds.json` 同级；信封 `{version: 1, state: {...}}`。
  - `state` 必须通过 `Participation.valid()` 的严格校验；缺失且给了合法 host 时返回 `Participation.initial_state(world_id, host)`（和平、revision 0），`kind="missing"`，此时不写盘。
  - 缺失且没有 host 返回 `kind="hostless"`、`state={}`。
  - 版本不匹配返回 `unsupported`；解析失败、空文件、超过 64 KiB 或文档不合法返回 `corrupt`；文档 `world_id` 不同返回 `world_mismatch`；显式 host 与文档 `host` 不同返回 `host_mismatch`。
  - 保存先写 `participation.pending.json`，回读逐字节比对后再 rename；保存前执行同一份 `valid()`。
  - `HeadlessWorld.open()` 加载失败返回 `load_participation_<kind>` 并拒绝启动；损坏、异世界或换房主不会被空文档覆盖。
- 房主是该文档的持久事实。显式传入另一个 host 会拒绝启动，而不是让新 host 静默扩大风险范围并使所有成员此前的同意失效。

## 动作语义

`HeadlessWorld.execute_participation(action, actor, args, command_id)`。操作者由连接层解析，`args` 里的 `actor` / `host` 永不参与授权。

| 动作 | 规则调用 | 参数 | 说明 |
|---|---|---|---|
| `regime` | `Participation.declare_regime` | `args.declaration` | 只有文档 host 可调用；新声明 revision+1，旧同意全部失效 |
| `declare` | `Participation.declare_participation` | `args.role`（`attacker` / `defender`） | 绑定当前 revision；退战生效前不能再加入 |
| `withdraw` | `Participation.withdraw` | 无 | 声明后 3600 秒生效；生效前新交战仍结算 |
| `state` | 无 | 无 | 已入册连接均可读 |

- 时间统一取权威 `authority_now_utc()`；载荷里的 at_utc 不参与，客户端无法回填或提前风险声明。
- 规则在文档副本上执行，`save_state` 成功后才替换活文档；失败不写盘、不改内存。
- 命令幂等由规则自身保证：声明/同意/退战的 command id 写进文档，同 id 同参数重放返回 `duplicate`，同 id 换参数返回 `command_conflict`；重启后仍成立。
- `engage` 不在本切片暴露：真实交战属于 M12-03，需同时处理资产冻结、战利品入账与资源守恒。

## 视图

`participation_view()` 只下发公开事实：`available`、`host`、`sequence`、`regime`（tier/revision/declaration_id/declared_by/declared_utc/effective_utc/higher_risk/area_ids/window_ids/loss_cap/offline_loss_cap），以及按 id 排序的 `areas`、`windows`、`participants`（含 attacker/defender、consent_revision/utc、withdraw_utc/effective_utc）与 `losses`。不下发 `command_results`、`engagements` 或命令载荷。

## RPC 与频道

| 频道 | 方向 | 名称 | 说明 |
|---|---|---|---|
| 17 | 成员 → 权威 | `participation_request(payload)` | `{request_id, action, args}` |
| 18 | 权威 → 成员 | `_participation_reply(request_id, payload)` | 携带 `{ok, action, subject, duplicate, reason, reason_text, state}` |

频道核查：现有 RPC 使用 0–4、6–16；5 仍未使用；本切片取 17/18。请求与答复都受 48 KiB `WorldPayload.WIRE_BUDGET_BYTES`，超长请求回可见 `payload_too_large`，答复在 `rpc_id` 之前编码。参与请求与 `submit` / `social_request` / `territory_request` / `organization_request` / `unit_request` / `fund_request` 共用命令令牌桶。`WorldClient.WireMember` 在频道 18 先做预算解码。

## 权限

- 身份只来自连接：`WorldHost.participation_for_member()` 用 `_members` 判断入册、用 `_players` 解析操作者。
- 读取：`state` 对所有已入册连接开放，包括访客与匿名成员。
- 写入：要求成员角色（`WorldInvite.MEMBER`）、非只读权威、非空玩家身份；拒绝顺序为 `not_a_member`、`forbidden`、`read_only`、`no_player`、`unknown_action`、`invalid_command`。
- 房主判定只比较 `actor` 与文档 `host`，不由网络层代劳；非房主声明返回 `not_host`。
- 具名拒绝由 `WorldHost` 补中文 `reason_text`：`no_host`、`not_host`、`peace`、`risk_not_declared`、`invalid_role`、`withdrawal_pending`、`already_withdrawn`、`not_participating`、`regime_not_effective`、`declaration_conflict`、`capacity`、`save_participation_*` 等。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
cd /Volumes/Disk-1tb/yipiantian
perl -e 'alarm shift; exec @ARGV' 240 "$GODOT" --headless --path Game \
  --script "$PWD/tests/participation_authority_test.gd"
```

原始末行（连续三次运行均通过）：

```text
PARTICIPATION_AUTHORITY_TEST checks=114 failures=0
```

回归原始末行：

```text
UNIT_AUTHORITY_TEST checks=146 failures=0
PUBLIC_FUND_AUTHORITY_TEST checks=211 failures=0
ORGANIZATION_AUTHORITY_TEST checks=84 failures=0
```

覆盖：

| 用例 | 检查 |
|---|---|
| 无房主 | 世界照常打开；参与文档为空；view `available=false`；写操作 `no_host`；不创建 `participation.json` |
| 缺失文档 | 有房主时为和平初始声明（revision 0、无参与者）；`Participation.valid`；不立即写盘；store 返回 `missing` |
| 声明 | 非房主 `not_host`；房主 limited+higher_risk+区域+窗口+上限成功；revision=1、declared_by/host、cap 正确；落盘；store 重载 `loaded` |
| 幂等 | 同声明同 id `duplicate` 且文件字节与 sequence 不变；同 id 换声明 `command_conflict` |
| 同意 | 进攻方/防守方分别成功；view 的 attacker/defender、consent_revision/utc 正确；同 id 同角色 duplicate；同 id 换角色 conflict |
| 退战 | `withdraw_effective = withdraw_utc + 3600`；pending 期间再同意 `withdrawal_pending`；同 id 重复 withdraw duplicate；同 id 换操作 conflict |
| 具名拒绝 | `unknown_action`、`invalid_command`、`invalid_declaration`；和平下 `declare` 返回 `peace` 且不落盘 |
| 重启 | 同房主重开保留声明、参与者与视图；声明 command id 重放 duplicate |
| 加载不匹配 | 异房主 `load_participation_host_mismatch`、异世界 `load_participation_world_mismatch`，均不覆盖原文件 |
| 坏文档 | 损坏 `load_participation_corrupt`、版本 2 `load_participation_unsupported`，均不覆盖；合法文档 store 往返；`save_state({})` 拒绝 |
| 写时复制 | 非房主与非法声明后活文档 JSON、落盘字节与 sequence 均不变 |
| 视图 | 区域/窗口按 id、参与者按 player id 升序；losses 为空；不下发 `command_results` / `engagements` |

真实 WSS 频道 17/18 的端到端测试另行记录。

## 未覆盖

- 真实交战：没有 `engage` 入口，不扣资产、不发战利品、不结算损失上限；损失上限只在规则层成立。
- 参与制度进入摘要/投影：客户端必须主动 `state` 请求，摘要广播不带参战声明。
- UI：没有声明编辑、区域/窗口展示或同意/退战按钮。
- 房主身份轮换：文档 host 写死，没有移交流程；换人只能由运维替换文档（当前会与 `--host-player` 不一致而拒绝启动）。
- 离线保护与真实在线状态：`defender_online` 由未来交战入口决定，本切片没有在线判定接入。
- 命令窗口：规则文档自带 64 条命令结果与持久 command id；未做淘汰后的重放压力测试。
- 身份可信：`player_id` 仍是加入声明，不是密码学凭据；房主权限依赖 ADR-029 的安装凭据绑定，而不是额外签名。
- 只在 macOS 无头模式验证；未在 Windows、CI 或真实网络传输中运行。

## 关联

- 阶段计划：[M12 PLAN](PLAN.md)；纯规则：[RECORD-02 · 参与制度](RECORD-02-participation.md)。
- 裁决：[ADR-025 · 冲突参与](../../decisions/ADR-025-conflict-participation.md)。
- 同形接线参考：[M8-07 公共基金权威](../M8/RECORD-07-public-fund-authority.md)、[M12-06 单位权威](RECORD-06-unit-authority.md)。
- 存储参考：`Game/world/unit_store.gd`、`Game/world/fund_store.gd`。
