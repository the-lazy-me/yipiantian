# M11-03 · 规则决议接入世界权威与网络

执行日期：2026-11-16。状态：切片完成，不表示 M11-03 或 M11 验收完成。前置：[M11 PLAN](PLAN.md)、[RECORD-05 · 规则决议](RECORD-05-resolutions.md)、[RECORD-11 · 规则决议 sidecar](RECORD-11-resolutions-store.md)、[RECORD-02 · 地籍接入世界权威](RECORD-02-cadastre-authority.md)。

## 问题

RECORD-05 冻结了决议的纯规则命令，RECORD-11 冻结了 `resolutions.json` 的四键信封与原子保存，但两者都没有接上世界权威：`HeadlessWorld` 打开世界时不加载决议文档，成员无法通过网络提案或表决，重启后即使文档存在也没有任何入口能读到规则版本。决议因此只是“能算、能存”，还不是“世界事实”。

本切片把已经落地的两部分接起来：打开世界时加载 sidecar，在文档副本上执行规则命令，保存成功后才替换活文档，并新增 RPC 27/28 供成员读写。仍然不做界面，也不改变农场存档格式。

## 边界

- 修改 `Game/world/headless_world.gd`（加载、`execute_resolution()`、`resolutions_view()`）、`Game/world/world_host.gd`（RPC 27/28、`resolutions_for_member()`、拒绝文案、令牌桶与预算通道）、`Game/world/world_member.gd`、`Game/world/world_client.gd`。
- 新增 `tests/resolution_authority_test.gd`、`tests/resolution_network_test.gd` 与本记录。
- 未修改 `Game/ui/**`、`Game/scenes/**`、农场存档格式、`.github/`、`rules/`、`PLAN.md`、`resolution_state.gd`、`resolutions_store.gd` 或既有测试的断言。
- 早期开发阶段：不承诺旧存档兼容，不新增迁移逻辑。没有决议的世界不会留下 `resolutions.json`。

## 权威接线

`open()` 在参与/纠纷 sidecar 之后加载决议 sidecar，错误前缀为 `load_resolutions_`：

- 缺失 -> 合法空文档，`kind="missing"`，**不写盘**。
- 读取失败、非 JSON、键集不符、`state`/`commands` 不合法 -> `corrupt`。
- 版本不符 -> `unsupported`；`world_id` 不同 -> `world_mismatch`。
- 以上任一失败都让整个权威拒绝启动，绝不以空决议表覆盖已生效的规则版本。

`execute_resolution(action, actor, args, command_id, is_member)` 只接受
`propose` / `vote` / `close` / `activate` / `withdraw` / `revoke`；`state` / `view`
是只读分支。要点：

- 操作者由连接层解析传入，载荷里的 `actor` / `proposer` / `voter` 不参与授权或归属。
- 时间统一取 `authority_now_utc()`，不读客户端时钟。
- 规则在 `resolutions` 的副本上计算；候选与命令日志在同一次
  `save_state(candidate, journal)` 原子写盘，成功后才替换活文档。
- 保存失败返回 `save_resolutions_<kind>`，活文档与重放窗口都不变。
- 同一 `command_id` 重放返回首次结果并标记 `duplicate`，不追加日志；换参数返回
  `command_conflict`。日志上限 `ResolutionsStore.MAX_COMMANDS = 64`，超出淘汰最旧。
- `vote` 要求 `approve` 是布尔值，否则在进入规则前返回 `invalid_request`。

命名上沿用 `execute_organization` / `execute_dispute` 的既有风格，而不是另起一套
“提案服务”抽象。

## RPC 与线上预算

- 新增通道 27 `resolutions_request(payload)` / 28 `_resolutions_reply(request_id, payload)`。
- 请求与答复共用 `WorldPayload.WIRE_BUDGET_BYTES`（48 KiB）；超预算在 `rpc_id`
  之前换成可见的 `payload_too_large` 拒绝，并计入 `payload_rejections`。
- 与其它权威写入共用命令令牌桶；被限流时返回 `rate_limited` 且不静默丢弃。
- 客户端 `WorldClient` 的 `WireMember` 在通道 28 上先 `WorldPayload.decode()`，
  压缩/损坏的回复命名失败并停在最后一次确认状态，再交给基类解析 JSON。
- `WorldClient.request_resolutions()` 未加入时返回 false，不假装已发出。

## 权限分级

| 身份 | 读取 | 写入 |
|---|---|---|
| 未加入连接 | 不答复（RPC 层丢弃） | 不答复 |
| 访客 / 匿名成员 | 可读 | `forbidden` / `no_player` |
| 具名成员 | 可读 | 允许（规则与成员资格决定后续拒绝） |
| 只读权威 | 可读 | `read_only` |

写入判定照抄纠纷：成员角色 + 非只读 + 具名玩家。`WorldInvite.VISITOR` 的写入在
进规则前就被拒绝，规则层不感知房间角色。

## 视图形状与隐私

`resolutions_view(viewer, is_member)` 返回：

```text
{
  "available": false,            // 会话未打开时
  "now_utc": 0.0,
  "viewer": "<player id 或空串>",
  "is_member": false,
  "rules_version": 0,            // 顶层规则版本，始终公开
  "versions": [                  // 按版本号升序的差异摘要
    {"version": 1, "resolution_id": "res_1", "change": "effective"},
    {"version": 2, "resolution_id": "res_1", "change": "revoked"},
  ],
  "resolutions": [
    {
      "resolution_id": "res_1", "kind": "public_works", "title": "修桥",
      "proposed_by": "<player id>",     // 公开事实
      "proposed_utc": 0.0, "vote_start_utc": 0.0, "vote_end_utc": 0.0,
      "effective_utc": 0.0, "status": "effective", "revision": 3,
      "effective_version": 1, "revoked_by": "", "revoked_utc": 0.0,
      "revoked_version": 0,
      "ends_utc": 0.0,                  // revoked 行等于 revoked_utc，其他为 0
      "approvals": 2, "rejections": 1,  // 仅已加入成员
      "approvers": [...], "rejecters": [...]  // 仅与该决议相关的查看者
    }
  ]
}
```

隐私分级沿用纠纷视图的分层思路，但阈值不同：

- **匿名/未加入读取**（`is_member=false`）只拿公开行，没有计票人数，也没有任何
  投票人身份。
- **已加入成员**（含匿名成员）额外拿到赞成/反对**人数**，但没有身份明细。
- **与该决议相关的查看者**（提案人、赞成者或反对者）才拿到投票人 id 列表；即使
  票数为零，相关查看者也会拿到空列表，字段存在性与“是否相关”一致，避免客户端
  靠字段缺失推断关系。

提案人是公开事实，所有层级都下发。命令日志不下发：重放窗口是存储层事实，不是
世界公开事实。`ends_utc` 用 0 而不是 `null` 表示“未失效”，与文档里“未撤销为
0.0”的既有约定一致，也免去客户端对空值的额外分支。

## 验证

实际运行：

```text
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 420 /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot --headless --path Game --script "$PWD/tests/resolution_authority_test.gd"
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 420 /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot --headless --path Game --script "$PWD/tests/resolution_network_test.gd"
```

原始末行：

```text
RESOLUTION_AUTHORITY_TEST checks=121 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/resolution-authority-619971
RESOLUTION_NETWORK_TEST checks=47 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/resolution-network-373468
```

回归（未改动断言，仅确认接线没有破坏既有接缝）：

```text
RESOLUTION_STATE_TEST checks=330 failures=0
RESOLUTIONS_STORE_TEST checks=73 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/resolutions-store-139511
DISPUTE_AUTHORITY_TEST checks=177 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/dispute-authority-567366
ORGANIZATION_AUTHORITY_TEST checks=84 failures=0
WORLD_RATE_LIMIT_TEST checks=21 failures=0
WORLD_PAYLOAD_TEST checks=67 failures=0
DISPUTE_NETWORK_TEST checks=95 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/dispute-network-372170
```

覆盖：

- 权威：空文档合法且缺失不写盘、提案→两票赞成→关闭→生效→撤销全链与
  rules_version 1→2、视图三级隐私分级、版本摘要顺序、同命令重放不追加日志、
  换参数冲突、日志 64 行上限与最旧淘汰、重启后版本/文档/重放保持且不重写、
  损坏/不支持版本/异世界/内部不一致拒绝启动、保存失败不改内存且首存不产生主文档。
- 网络：真实 `world_server.gd` + loopback WSS 27/28，成员提案与身份归属、重放、
  未知动作、超预算拒绝后连接继续可用、匿名只读与写入拒绝、重启后文档与重放保持。

## 缺陷与未覆盖

- **无界面**：本切片不修改 `Game/ui/**` 与 `Game/scenes/**`，决议只能在视图与
  RPC 层使用。面板与规则差异展示留给后续切片。
- **无摘要/推送**：成功写入后不广播摘要，也不向其他成员推送新版本；成员需要主动
  `state` 请求才能看到变化。`shared_changed` 未接入决议，因为决议不改农场、现金
  或地籍。
- **未裁决“税费/公共建设”效果**：`kind` 只有 `public_works` / `tax`，本切片不执行
  任何实际效果，只维护规则版本。
- **成员资格与职位不参与表决**：规则允许任何具名成员投票，权威层只校验“已加入 +
  具名”，不读取组织成员表或职位。设计与职位相关的表决资格留给后续切片。
- **日志淘汰与重放**：淘汰故意让旧命令重新执行规则（测试用过期窗口验证），没有
  跨重启的“已执行但已淘汰”永久去重表。这是 64 行有界窗口的既有取舍，与纠纷一致。
- **并发写入**：与其他 sidecar 一致，假定世界权威是唯一写者；同一目录两个权威
  同时打开不在验证范围。
- **未验证 Windows 实机文件系统**：原子保存测试用 pending 路径被目录占用来制造
  真实失败，而不是依赖权限位。

## 关联

- 阶段计划与验收：[M11 PLAN](PLAN.md)（本记录不修改）。
- 纯规则与持久化前序：[RECORD-05](RECORD-05-resolutions.md)、[RECORD-11](RECORD-11-resolutions-store.md)。
- 参照模板：[RECORD-02 · 地籍接入世界权威](RECORD-02-cadastre-authority.md)、`disputes_store.gd` 的有界命令日志与 RPC 23/24。
