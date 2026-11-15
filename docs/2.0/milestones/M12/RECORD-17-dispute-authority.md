# RECORD-17 · 执法闭环接入世界权威

状态：切片完成，未验收；只表示 M12-04 的权威接入部分，不表示 M12-04 已完成。
日期：2026-11-16。

## 问题

[RECORD-04](RECORD-04-disputes.md) 只实现了无磁盘、无网络、无权威时钟的纯规则。
本切片把 `DisputeState` 接到 `HeadlessWorld`、`disputes.json` 与真实 WSS，使用
RPC 23/24，解决：

- 缺失文档如何产生可用的权威花名册；
- 普通成员、管理员、访客与匿名连接分别能做什么；
- 同一命令重放如何不二次写，换参数如何被识别；
- 保存失败时内存与磁盘是否留下半状态；
- 重启后案件、裁定、审计与重放窗口是否保留；
- 视图是否只向连接暴露它有权看到的案件。

## 边界

- 仍然不执行真实处罚、资产扣减、补偿分录、封禁或恢复备份；`ruling.outcome`
  只是可审计的语义记录。
- 仍然不核验外部权威事件是否真实存在。`event_ids` 只做格式、非空、唯一与
  数量校验；事件日志切片不在本切片内。
- 角色权限只认 `disputes.json` 的 `authority_roles`。连接自报的角色、载荷里的
  `actor` / `submitted_by` 都不参与授权；证据的提交人与时间由权威重写。
- 未实现界面、通知、申诉时限升级、多管理员合议、回避与利益冲突处理。
- Windows 未验证；网络测试只在 macOS loopback WSS 上运行。

## 实现

### 存储：`Game/world/disputes_store.gd`

- 文档：`disputes.json`，信封
  `{"version": 1, "world_id": "...", "state": {...}, "commands": [...]}`。
- `state` 保持 `DisputeState` 的严格两键形状（`authority_roles`、`cases`）。
  `world_id` 与 `commands` 放在信封层，原因有两个：
  - `DisputeState` 没有世界字段。没有信封层 `world_id`，复制到另一个世界的
    案件表无法被拒绝；这与 participation/unit/conflict 的异世界策略不一致。
  - 重放窗口必须跨重启保留，而 `cases` 的键集由纯规则严格限定，不能加入
    命令表。`commands` 是存储层的有界日志，最多 64 条，最后一条溢出时丢弃最旧。
- 缺失文档：
  - 有房主：`DisputeState.empty([host], [])`。规则禁止同一玩家同时出现在
    admin 与 arbiter，因此房主写入 `admin`；`is_authority()` 接受两组中的任一
    组，房主仍是唯一权威。
  - 无房主：`{ok: true, kind: "hostless", state: {}}`，所有写操作返回 `no_host`。
  - 已存在文档：尊重其 `authority_roles`，不把启动房主强行加入花名册。
- 损坏/版本/异世界：`corrupt`、`unsupported`、`world_mismatch` 都让权威停止
  启动，分别映射为 `load_disputes_corrupt`、`load_disputes_unsupported`、
  `load_disputes_world_mismatch`。
- 落盘：`MAX_BYTES = 65536`，先写 `disputes.pending.json`，读回逐字节比对，
  再 `rename` 覆盖主文档。`state` 与 `commands` 在同一次原子替换中写入。

### 权威入口：`HeadlessWorld.execute_dispute()`

动作：`state` / `file` / `accept` / `reject` / `evidence` / `rule` / `appeal` /
`correct` / `close`。

- 操作者恒由调用方（连接层）提供；参数里的身份字段不参与授权。
- `accept`、`reject`、`rule`（权威模式）、`correct`、`close` 只认文档花名册。
  规则返回的 `not_authority` 在权威边界统一映射为 `forbidden`，普通成员只能
  立案、提交证据与申诉。
- `rule` 的 `advisor: true` 交给纯规则在读取案件前返回 `advisory_only`；它不
  进入重放日志，也不写状态或审计。
- 证据的 `submitted_by` 固定为连接玩家，`at_utc` 固定为权威时钟；客户端不能
  冒用他人或回填窗口外时间。
- 规则在副本上计算；成功后把候选与命令日志一起保存。保存失败返回
  `save_disputes_<kind>`，活文档、内存重放窗口与主文档都不变。
- 重放：`command_id` + `payload`（动作、操作者与参数）进入有界窗口。同一 id
  同一载荷返回首次结果并标记 `duplicate`，不再落盘；同一 id 换载荷返回
  `command_conflict`。窗口随 `disputes.json` 持久化，重启后仍然成立。
- 验证：`DISPUTE_AUTHORITY_TEST checks=105 failures=0`。

### 视图：`disputes_view(viewer)`

- 管理员（花名册中的 admin/arbiter）：`cases` 包含全部案件，`public` 包含全部
  公开状态行。
- 普通玩家：`cases` 只包含 `filed_by` / `against` / `evidence.submitted_by`
  与自身相关的案件；`public` 仍包含全部案件的编号、状态与立案时间。
- 访客与匿名连接：可以读取；`cases` 为空，只能看到 `public` 行。公开行不含
  证据、裁定、申诉或审计细节。
- 视图按案件 id 排序，携带权威 `now_utc`、`viewer`、`is_authority` 与
  `authority_roles`，相同输入产生逐字节相同的载荷。

### 网络：RPC 23/24

- `world_host.gd`：`dispute_request`（23）与 `_dispute_reply`（24），
  `DISPUTES_MAX_PAYLOAD = WorldPayload.WIRE_BUDGET_BYTES`（48 KiB）。
- 请求与答复共用命令令牌桶；超预算在 `rpc_id` 之前返回 `payload_too_large`，
  连接继续可用。答复编码超出预算时通过 `_reject(..., on_disputes_channel=true)`
  回一条可见拒绝。
- 读取对成员开放（含访客与匿名成员）。写入要求成员角色、非只读、具名玩家；
  管理员权限再由文档花名册决定。
- `world_member.gd` / `world_client.gd`：新增 `dispute_result` 信号、
  `request_dispute()`、RPC 23 stub 与 24 线上预算解码转发。
- 拒绝文案：`_dispute_reason_text()` 覆盖案件、证据、裁定、申诉、更正、结案、
  保存失败与通用请求错误，保持中文可读；未知原因回退到通用文案。

## 覆盖矩阵

| 要求 | 证据 |
|---|---|
| 缺失文档以房主初始化唯一权威 | authority：`The host is the only authority id in the fresh roster` |
| 已存在文档尊重 `authority_roles` | authority 重启：`The stored authority roster survives the restart` |
| 普通成员立案 | authority + network：`An ordinary member files a case` |
| 普通成员提交证据 | authority + network：`A party submits evidence` |
| 普通成员申诉 | authority + network：`appeals the ruling` |
| 非管理员受理/裁定 `forbidden` | authority + network：`A non-authority accept/ruling is refused as forbidden` |
| 管理员受理→裁定→申诉→更正→结案 | authority + network 全链路 |
| 原裁定与审计保留 | `An appeal preserves the original ruling`、`The full audit trail survives the restart` |
| `advisor_only` 零变化 | `An advisor ruling changes no case state`、文档字节不变 |
| 恶意/空证据拒绝 | `invalid_evidence` 三条 |
| 非法/未知事件 id 拒绝 | `invalid_events`（仅格式与唯一性；存在性未核验） |
| 同命令重放不二次写 | authority + network：`duplicate` 且文档字节不变 |
| 换参数 `command_conflict` | authority + network：file/rule 冲突 |
| 保存失败不留半状态 | `A failed save leaves no half-applied case in memory` |
| 视图按身份过滤 | authority：管理员/当事人/证据提交人/无关成员/匿名五路 |
| 访客只读 | network：`A visitor may read` + `forbidden` 写入 |
| 匿名只读 | network：`An anonymous member sees the public status row` + `no_player` |
| 超预算 | network：`payload_too_large` 且连接继续工作 |
| 重启保留与重放 | authority + network：案件/审计/裁定保留，file/accept/close 重放 `duplicate` |

## 验证

实际运行命令：

```sh
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 600 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/dispute_authority_test.gd"

cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 600 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/dispute_network_test.gd"
```

原始末行：

```text
DISPUTE_AUTHORITY_TEST checks=105 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/dispute-authority-529665
DISPUTE_NETWORK_TEST checks=94 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/dispute-network-375992
```

回归：

```text
M4_SERVER_TEST checks=84 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/m4-server-362173
PARTICIPATION_NETWORK_TEST checks=102 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/participation-network-369008
PUBLIC_WORKS_NETWORK_TEST checks=107 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/public-works-network-367564
```

## 未覆盖

- 真实处罚、资产扣减、补偿分录、权属更正事件、封禁与恢复备份。
- 外部权威事件的存在性、内容与事件日志核验；当前只校验 id 格式、非空与唯一。
- 游戏官府与服务器管理员的独立凭据、管理操作独立日志通道。
- 界面、通知、申诉时限升级、多管理员合议、回避与利益冲突。
- 房主之外的权威角色分配流程（当前只尊重文档已有花名册）。
- Windows、真实跨机网络、TLS 证书轮换与长时间运行。
- `outcome` 仍为语义记录，没有对应的执行器；因此 M12-04 不能标记完成。

## 关联

- [M12 计划](PLAN.md) 的 M12-04 段（本记录不修改计划）。
- [RECORD-04 · 案件基础](RECORD-04-disputes.md)。
- [领土政治、私兵、有限 PvP 与官府执法](../../systems/politics-conflict-law.md)。
- 实现：[`Game/world/disputes_store.gd`](../../../../Game/world/disputes_store.gd)、
  [`Game/world/headless_world.gd`](../../../../Game/world/headless_world.gd)、
  [`Game/world/world_host.gd`](../../../../Game/world/world_host.gd)、
  [`Game/world/world_member.gd`](../../../../Game/world/world_member.gd)、
  [`Game/world/world_client.gd`](../../../../Game/world/world_client.gd)。
- 测试：[`tests/dispute_authority_test.gd`](../../../../tests/dispute_authority_test.gd)、
  [`tests/dispute_network_test.gd`](../../../../tests/dispute_network_test.gd)。
