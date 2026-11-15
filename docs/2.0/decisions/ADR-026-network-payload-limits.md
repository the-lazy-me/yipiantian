# ADR-026 · 网络载荷上限：字节预算、压缩与 tail 裁剪

- 状态：裁决完成（2026-11-15），**已实现（2026-11-15）**；实现取舍与验证证据见文末“实现状态”。
- 关联：[ADR-004 传输](ADR-004-transport.md)、[ADR-019 经济命令权限](ADR-019-economy-command-permissions.md)、[RISKS](RISKS.md) R18/R19/R20、[载荷实测](../research/PAYLOAD-BUDGET.md)、`tests/world_tail_test.gd`、`tests/world_snapshot_test.gd`。
- 范围：`Game/world/*` 的服务端→客户端消息；不改经济规则、存档格式与 UI。

## 背景

R18 记录的是“summary 与 256 条 catch_up 可能超过 WSS 64 KiB 缓冲”。实测（[PAYLOAD-BUDGET](../research/PAYLOAD-BUDGET.md)）证明它已经不是“可能”：

- `WebSocketMultiplayerPeer` 默认 `inbound_buffer_size` / `outbound_buffer_size` 均为 65,535 B（4.7.2 公开属性读取）。
- 单条 WebSocket 消息 65,535 B 可交付，65,536 B 起被丢弃；`put_packet` 仍返回 `OK`，连接保持 CONNECTED，**应用层没有失败信号**。单条 RPC 的 JSON 实际上限是 65,510 B。
- 空世界 summary+snapshot 已 38,647 B；普通游玩规模 100,035 B；规则上限规模 692,623 B。
- 256 条真实 tail 63,709 B；合法最长 id 的 256 条 tail 122,441 B（ASCII）/ 187,977 B（中文）。
- `_broadcast_summary()` 订阅 `shared_changed`（原 `economy_changed`，2026-11-15 起同时覆盖地籍归属变化），每次经济提交、结算变化或首次建造隐式主张都会把完整 summary+snapshot 广播给每个成员；在普通规模下这条消息本身就已静默丢弃。客户端每 30 s 的 reconcile 也走同一路径。

现有代码没有任何发送前的大小检查，`command_result.rpc_id(...)` 的返回值也不能反映引擎的丢弃（`WebSocketMultiplayerPeer::put_packet` 忽略每 peer 的 `ERR_OUT_OF_MEMORY` 并返回 `OK`）。因此必须由应用层保证“不发出超限消息”，而不是事后发现。

现有恢复语义已经具备：`tail_expired` / `future_sequence` 会触发 `request_summary`（`WorldMember._apply_catch_up`），重连本来就走 summary（`WorldClient`）。`request_catch_up()` 目前没有生产调用方；summary 广播是当前实际失败路径，tail 是必须守住的协议承诺。

## 裁决

### 1. 一条线上预算：48 KiB，按 UTF-8 字节计量

所有服务端→客户端载荷（summary、catch_up、change、roster、命令回复）统一经过一个发送助手：

- 预算常量 `WIRE_BUDGET_BYTES = 48 * 1024 = 49,152`，在编码后的最终字符串上检查 `payload.to_utf8_buffer().size()`。
- 必须用 UTF-8 字节，不能用 `String.length()`：后者是字符数，中文名/中文命令 id 每个字符占 3 B。
- 超预算时**不得调用 `rpc_id`**；记录原始字节、线上字节与请求种类，返回可见失败。
- 选择 48 KiB 而不是 64 KiB：实测上限 65,510 B，出站检查还包含已排队消息（`queued_msg_length + p_buffer_size`），首次 RPC 还可能携带节点路径；48 KiB 留约 16 KiB 余量。该余量是安全侧默认，不是实测必需值。

### 2. 超过 8 KiB 的载荷先做 zstd + base64（实现改为按 48 KiB 预算触发，见“与裁决不同的取舍”）

- 复用现有 `command_result(request_id, payload: String)` 签名，不新增消息类型。
- 线上格式：`z1:<raw_bytes>:<base64(zstd(json))>`；`raw_bytes` 是解压后的 JSON 字节数。
- 只在 JSON 超过 `COMPRESS_MIN_BYTES = 8 * 1024` 时压缩，小回复保持原样。
- 客户端 `WorldMember.command_result` 在 `JSON.parse_string` 之前识别 `z1:` 前缀：校验 `raw_bytes` 在 `[0, CONTENT_MAX_BYTES]` 内（`CONTENT_MAX_BYTES = 2 * 1024 * 1024`，防解压炸弹），`base64_to_raw` → `decompress(raw_bytes, COMPRESSION_ZSTD)` → 再 `JSON.parse_string`；解码失败必须发出可见错误并重新请求，**不能**把空字典当成 summary 状态。
- `PROTOCOL_VERSION` 从 1 升到 2；加入握手已经校验版本，旧客户端会被明确拒绝，不存在半兼容状态。

实测依据：规则上限世界 692,599 B → zstd 18,679 B → base64 约 24,906 B（同一夹具多次运行相差数 B）；普通世界 98,186 B → 7,256 B → 约 9,676 B；长 id tail 123,612 B → 2,392 B → 3,192 B。全部远低于 48 KiB。压缩比在合成夹具上偏乐观，所以压缩不是免检通行证，预算检查仍是无条件的。

### 3. catch_up：压缩后仍超预算才裁剪，只保留最新连续后缀

- 先按 `sequence > since` 收集事件，编码/压缩后检查线上字节。
- 超预算时从最旧事件开始丢弃，直到装下；若保留窗口的起点晚于 `since + 1`，返回 `tail_expired`（带 `floor`），由客户端请求 summary。
- 绝不返回带空洞的事件列表；`events[0].sequence == since + 1` 且末条为 `current`，否则就不是 `ok`。
- `TAIL_LIMIT = 256` 继续作为内存上限；字节预算独立生效。两者都必须满足。
- 实测：256 条普通事件 63,709 B（48 KiB 下约能保留 197 条）；合法最长 id 的 256 条 122,441–187,977 B（48 KiB 下约 66–96 条）。固定条数无法保证字节上限。

### 4. summary：压缩后的确定性回退

压缩后仍超预算时：

1. 去掉显示用的 `summary.fields`（与 `snapshot.farm.fields` 重复，客户端只从 snapshot 恢复），重试一次；
2. 仍超预算则发送一个可解析的 `{"error":"payload_too_large", ...}` 拒绝文档并记录计数；客户端保持连接、显示可见错误并按现有 30 s 节奏重试。

这条路径在实测形状下不会触发（最坏约 24.9 KB），它是防止未来世界悄悄退化为静默丢弃的硬边界。`summary.fields` 的删除是可选项：它省 16.2 kB（空）/ 16.7 kB（普通）/ 61.0 kB（上限），但不改变“必须压缩”的结论。

### 5. 不采用分块传输（方案 B），保留触发条件

分块能解决任意大小，但需要新的传输状态机（transfer id、分片序号、重组、超时、丢弃半包、per-peer 内存上限），并与重连、加入握手和所有“同步解析 payload”的测试交互。实测压缩后所有形状都低于 25 KB，现在引入分块没有要服务的当前需求。

重新评估的触发条件：真实世界压缩后仍超过 48 KiB；或产品要求单次传输超过 1 MiB 的文档；或 Godot 改变默认缓冲/RPC 封装。

### 6. 不采用“只提高缓冲区”

两端都提到 1 MiB 确实能让 692,623 B 往返（实测），但：

- 每个 peer 的收发缓冲都按此分配，成员数线性放大内存；
- 它不限制文档继续增长，只是把上限推后；
- 只提高发送端会造成接收端以 `MESSAGE_TOO_BIG`（1009）立刻断开（实测 0–1 ms），比静默丢弃更糟；
- 不解决 R19/R20。

因此缓冲大小只作为诊断手段，不作为修复。

### 方案对比

| | A 字节预算裁剪 tail | B 分块传输 | C 压缩 / 按需快照（推荐 C1+A） |
|---|---|---|---|
| 解决范围 | 只解决 tail | summary 与 tail 都能到任意大小 | 压缩解决实测所有形状；硬预算兜底 |
| 协议变化 | 无需新消息；`tail_since` 增加字节上限语义 | 新分片信封、重组、确认/超时；需协议版本升级 | 复用 `command_result`，加 `z1:` 前缀；协议版本 1→2 |
| 重连语义 | 不变；`tail_expired` 已经触发 summary | 断开即丢弃半包；重连后重新请求；实现新的“传输中”状态 | 不变；summary/catch_up 解码后语义相同 |
| 客户端状态机 | 无变化 | 新增 receiving/assembling/timeout 状态 | 仅在 `command_result` 前增加解码一步；失败可见并重试 |
| 测试面 | 扩展 tail 字节用例 | 分片、乱序、缺片、超时、重复、并发、恶意 total、内存上限 | 编解码往返、还原等价、预算断言、篡改/截断、回环传输 |
| Windows | 无平台差异 | 无平台差异，但更多超时路径 | zstd/base64 为引擎内置、平台无关；CI 回环可覆盖 |
| 不能解决 | summary 仍超限；会把客户端推向更大的快照 | R19；仍需要总大小上限防内存放大 | R19；压缩后仍需硬预算；超 2 MiB 的内容仍要另案 |
| 结论 | 必要但不充分，作为压缩后的兜底 | 现在不必要，保留为触发后的逃生通道 | **采纳** |

## 实施顺序与改动文件

1. `Game/world/world_host.gd`
   - 增加 `WIRE_BUDGET_BYTES`、`COMPRESS_MIN_BYTES`、`CONTENT_MAX_BYTES` 与 `_wire_payload()` / `_send_payload()`；
   - `_broadcast_summary()`、`request_summary()`、`catch_up()`、`_append_tail()` 的广播以及所有 `command_result.rpc_id` 调用统一走助手；
   - `tail_since()` 增加“压缩后仍超预算则裁掉最旧事件”的路径；
   - summary 的超限回退（去 `fields` → 可见拒绝）；
   - `PROTOCOL_VERSION = 2`。
2. `Game/world/world_member.gd`
   - `command_result()` 解析前解码 `z1:`；失败发出可见原因并请求 summary，不写入空状态。
3. `Game/world/world_client.gd`
   - 预期无需状态机改动（重连走 summary）；确认 `payload_too_large` 时不会卡在 joining，按既有节奏重试或显示错误。
4. `Game/world/headless_world.gd`
   - 仅当采用可选步骤时：从 `summary()` 去掉显示用 `fields`。
5. 测试
   - 新增 `tests/world_payload_test.gd`：空/普通/上限三种世界，断言线上字节 ≤ 48 KiB、还原等价、tail 裁剪/`tail_expired`、超限拒绝可见；
   - 扩展 `tests/world_tail_test.gd`（字节预算与连续性）、`tests/world_snapshot_test.gd`（压缩往返）；
   - 收紧 `tests/village_beta_test.gd` 的 `MAX_SUMMARY_BYTES`（当前 262,144，约为传输上限的 4 倍）：它度量的是解码后的文档，不能替代 `world_payload_test` 的线上字节断言；把内容上限降到有意义的值，并按是否保留 `summary.fields` 调整 cells 断言。
6. 文档
   - 实现后更新 `docs/2.0/decisions/RISKS.md` 的 R18 证据与状态、`docs/2.0/decisions/README.md` 索引；若协议版本成为稳定事实，同步 `rules/project-context.md`。

先做 1+2（同一提交，保持两端一致），再做 3 的 tail 路径与 5 的测试；可选的 `fields` 删除放在最后，避免和传输修复混在一起评估。

## 验收标准

以下断言都应能在无窗口的 headless 测试中执行，且不依赖真实公网。

1. **预算不变量**：空世界、普通世界、规则上限世界各构造一次；`request_summary` 与 `_broadcast_summary` 产生的最终线上字符串 `to_utf8_buffer().size() <= 49,152`。规则上限世界的原始 JSON 为 692,623 B，因此该断言必然覆盖压缩路径。
2. **还原等价**：客户端解码并 `restore_state()` 返回 `ok`；本地 `farm.snapshot()`、`decorations.snapshot()`、`nature.snapshot()` 与权威一致；summary 的 `committed_sequence`、`role`、`run_generation` 不变。
3. **tail 连续性**：256 条普通事件要么全部返回且 `events[0].sequence == since + 1`、末条 == `current`，要么 `{ok:false, reason:"tail_expired"}`；任何 `ok` 回复的线上字节 ≤ 49,152。用合法最长 id（128 字符中文命令 id、64 字符玩家 id、24 字符中文名）重复一次，结果必须是“装得下且连续”或 `tail_expired`，不能是带空洞的部分列表。
4. **超限可见**：在测试中注入一个压缩后仍超过 48 KiB 的文档；断言宿主没有调用 `rpc_id`、拒绝计数增加、连接仍为 CONNECTED，客户端能读到 `payload_too_large` 而不是空 summary。
5. **回环端到端**：用现有 WSS 回环夹具发送规则上限世界的 summary；客户端在超时内收到、解码、还原；线上字节 ≤ 48 KiB。
6. **无旁路**：`Game/world/world_host.gd` 中除发送助手外不再直接调用 `command_result.rpc_id`；新增的发送路径只能使用助手。
7. **既有语义不回退**：`tests/world_tail_test.gd` 的 `tail_expired`/`future_sequence` 用例、`tests/world_snapshot_test.gd` 的快照校验与拒绝用例继续通过。

## R18 与 R19 的关系

R18 与 R19 是两个不同不变量：

- R18：权威发出的单条消息必须能被传输层完整交付（字节上限、静默丢弃、重连可用）。
- R19：成员不应收到超出其最小需要的数据（所有玩家的 `bags`、完整经济账本）。

实测表明二者互不蕴含：

- 字节上限方案（压缩或分块）不裁剪任何字段：结构上限世界压缩到 18.7 KB 后 R18 解决，但仍然是全部 bags、账本和市场行都发给每个成员，R19 原样存在。
- 只做 R19 的裁剪也不能解决 R18：结构上限世界的 economy 块 524,423 B 中，公开市场行占 381,717 B（订单 82,837、成交 128,405、发货 93,845、交付 76,181），账本 141,347 B，别人的 `bags` 只有 1,422 B。即使把 bags 和账本全部裁掉，公开市场行仍有 382 KB，是 64 KiB 上限的 5.8 倍。

因此**不合并决策**。ADR-026 只裁决 R18，并明确 R19 未解决；R19 需要单独的 ADR，因为它要先决定“每种角色能看到哪些字段”，以及一个更深的问题：`WorldMember.restore_state()` 现在要求完整持久化文档（`FarmState._valid_snapshot`、`Ledger.valid()` 要求余额与账本对账），按字段裁剪后客户端是否还能重建权威状态、还是需要新的投影/校验契约。这不是传输层能顺带回答的问题。

两者共享同一个实现缝：把“按 peer 生成 summary/snapshot”收敛到一个构造点（本 ADR 的 `_send_payload` 之前的文档构造），R19 之后再在这个点上做按角色投影。R18 的实现不得以压缩或分块作为关闭 R19 的证据。

## 未验证

- zstd 压缩/解压的实际耗时与峰值内存；每次经济提交都压缩完整 summary 的成本未计时。
- 真实玩家数据（随机 id、长中文名）的压缩率；现有夹具偏重复，压缩比偏乐观。
- Windows 上这些探针与压缩路径的执行；引擎 API 应平台无关，但未实测。
- 出站队列在拥塞/突发下的累积丢弃；源码检查包含 `queued_msg_length`，但没有构造拥塞场景。
- 真实场景首条 RPC 的节点路径开销；按几十字节估计，48 KiB 余量应能吸收，未精确测量。
- 已实现客户端解码与 `payload_too_large` 拒绝（见“实现状态”）；仍未覆盖的是真实 WSS 会话中的压缩摘要端到端、压缩耗时/内存与 Windows 实测。

## 复审触发条件

- 任何一个合法世界压缩后仍超过 48 KiB，或出现无法压缩的文档；
- 需要传输超过 1 MiB 的文档（届时评估方案 B）；
- Godot 升级改变默认缓冲、RPC 封装或 `command_result` 的可靠通道行为；
- R19 的角色投影落地，文档形状或 `restore_state` 契约发生变化；
- 真实网络（非回环）出现与本地不一致的交付行为。

## 实现状态（2026-11-15）

### 代码

- `Game/world/world_payload.gd`（新增）：唯一的编解码模块。`WIRE_BUDGET_BYTES = 48 * 1024`、`CONTENT_MAX_BYTES = 2 * 1024 * 1024`；`encode()` 在 JSON ≤ 48 KiB 时原样返回，超过时压缩为 `z1:<原始字节>:<base64(zstd)>`，压缩后仍超预算返回 `{ok:false, reason:"payload_too_large"}` 且不带可发送载荷。`decode()` 对 `z1:` 结构、声明长度和内容上限逐一校验，失败分别命名 `payload_invalid_prefix`、`payload_too_large`、`payload_decode_failed`、`payload_length_mismatch`；普通 JSON 超过预算同样拒绝。
- `Game/world/world_host.gd`：`_encode_document()` / `_send_payload()` / `_send_summary()` / `_send_encoded()` 是唯一发送缝。`roster`、全部命令回复与拒绝、`change` 广播、`catch_up`、`summary` 与广播摘要都经过它，文件内除助手外不再直接调用 `command_result.rpc_id`。压缩后仍超限时 `payload_rejections` 计数、`push_warning` 记录请求种类/原始字节/线上字节，并向该 peer 发送一条很小的 `payload_too_large` 拒绝文档，而不是让 WebSocket 静默丢弃。summary 的超限回退按裁决执行：先去掉重复的 `fields` 重试一次，仍失败才发拒绝。
- `Game/world/world_host.gd: tail_since()`：先用最终 `catch_up` 文档（含固定 `request_id`）做预算检查；装不下时二分查找“能装下的最新连续后缀”，只把该后缀的首序号作为 `floor` 返回 `tail_expired`，绝不返回带空洞的事件列表。`floor` 只是“预算最多能装到这里”的诊断值：客户端拿到快照后不需要续传这段，重复应用会二次计数。`TAIL_LIMIT` 继续作为内存上限，字节预算独立生效。
- `Game/world/world_host.gd` 的社交回复：`social_request` 的回复、拒绝与在线留言推送原本直接 `JSON.stringify` 后 `rpc_id`，现全部经 `_send_social()` 走同一预算；超限同样计数、告警并回一条小型 `payload_too_large`。
- `Game/world/world_client.gd`：`WireMember` 子类在基类 `command_result()` 与 `_social_reply()` 解析 JSON 之前调用 `WorldPayload.decode()`；解码失败（损坏、截断、声明长度不符、空文档）或解码后不是 JSON 对象时以具名原因发出 `authority_lost`，不把空文档交给基类。summary 被权威拒绝时恢复 `snapshot` 与 `state` 为上一份确认文档，不当作空快照：已经应用过一份摘要的世界只发 `summary_refused` 并在 HUD 说明“世界资料过大，暂时无法刷新”，连接与未决请求都不受影响，30 s reconcile 会再问一次；还没有任何已应用摘要时（首次加入或重连中）没有可保留的状态，才按加入失败发出 `lost`。“是否已有摘要”由 `_has_snapshot` 判定，不能用 `joined`——加入回复先于摘要到达。
- `Game/world/world_member.gd` 未改动：解码节点由 `WorldClient` 创建（`WireMember`），所以直接实例化基类的旧夹具仍走普通 JSON，不需要迁移。

### 与裁决不同的取舍

- **压缩只在超过预算时触发，而非固定的 8 KiB**：≤48 KiB 的文档本来就能完整交付，提前压缩只是带宽优化。按预算触发保持普通流量与现有成员夹具在明文路径，超限时才进入 `z1:`，把协议变化的暴露面压到最小的当前需求。
- **`PROTOCOL_VERSION` 保持 1**：当前是早期开发阶段、不承诺旧客户端兼容；升级协议版本会拒绝所有直接实例化 `WorldMember` 的现有 M4/M5 回环夹具，而本切片已通过客户端子类在唯一会收到超限文档的路径上解码。若发布后仍需“旧客户端明确被拒”，再单独升级版本。

### 验证

全部在 macOS `4.7.2.stable.official.ed1daf0bf`、`--headless` 下执行；产物在 `.local/verification/`。

| 入口 | 结果 |
|---|---|
| `tests/world_payload_test.gd`（新增，64 项） | `WORLD_PAYLOAD_TEST checks=64 failures=0` |
| `tests/world_tail_test.gd`（新增字节预算断言，31 项） | `WORLD_TAIL_TEST checks=31 failures=0` |
| `tests/world_snapshot_test.gd`（新增线路往返断言，33 项） | `WORLD_SNAPSHOT_TEST checks=33 failures=0` |
| `tests/m4_sync_test.gd`（回归） | `M4_SYNC_TEST checks=39 failures=0` |
| `tests/m4_client_scene_test.gd`（回归，覆盖 `WorldClient` 子类路径） | `M4_CLIENT_SCENE_TEST checks=39 failures=0` |
| `tests/m4_reconnect_test.gd`（回归） | `M4_RECONNECT_TEST checks=31 failures=0` |

新增测试的具体覆盖：

- 结构上限世界（实测 692,612 B）压缩到 24,918 B 线上字节，解码后逐字节等于原始 JSON；普通规模世界（100,052 B）压缩、解码并 `restore_state()`，恢复出的 `farm`/`decorations`/`nature` 与权威完全相等。
- 随机不可压缩文档（160,041 B）压缩后仍超限：`encode()` 返回 `payload_too_large`、无载荷；宿主 `payload_rejections` 增加且不把原文档交给 `rpc_id`。
- `z1` 无冒号、非数字长度、超过内容上限、解压后偏短、声明长度偏长分别命中各自的具名错误；损坏载荷不会覆盖客户端上一份好快照。
- `WorldClient.WireMember` 直接接收压缩 summary，读到解码后的文档并能恢复；这是 `WorldClient` 实际创建的节点类型。社交通道的压缩回复同样被解码，空载荷与 `z1:0:` 具名拒绝，解码后不是对象的消息既不进入基类也不覆盖快照。
- 满 256 条 200 字收件箱的社交回复在明文下超过 48 KiB；宿主社交通道对不可压缩文档同样计数拒绝。
- 注入 300 条不可压缩尾部后，`tail_since()` 返回 `tail_expired` + `floor` 且事件为空；合法 256 条完整尾部以压缩形式装下，序号从请求点连续到 `current`。

### 与 R20 限频的关系（2026-11-15）

R18 的 48 KiB 预算回答“一条消息能有多大”，R20 的每 peer 令牌桶回答“一个连接能多频繁地让权威做事”。两者独立且互补：预算保证发得出去，限频保证不会被单个成员拖住。

- `Game/world/world_host.gd` 增加三类内存令牌桶：`command`（`submit` 与 `social_request` 共用，二者都可能触发规则计算与写盘）、`summary`（`request_summary`）和 `catch_up`。默认值见代码常量：命令 20 突发 +1/s；summary 5 突发 +0.5/s；catch_up 4 突发 +0.5/s。突发窗口覆盖现有 M4/M5 夹具和“加入时连续两次 summary + 30 s reconcile”的正常路径。
- 超限时计数 `rate_rejections`、写告警，并回一条很小的 `{"ok":false,"error":"rate_limited","reason":"rate_limited",...}`；命令/summary/catch_up 走 `_send_payload`，社交走 `_send_social`，因此拒绝文档本身仍经过 48 KiB 预算，不会变成新的静默丢弃路径。
- 桶不进入存档、不跨重启；`_forget`、拒绝加入、撤销授权都会清掉对应 peer 的桶，重连从满额开始。summary 桶按时间补充，不会把成员永久锁死。
- `_broadcast_summary` 仍由经济变更触发，本次没有给广播本身加每 peer 出站预算；但触发它的命令已被 `command` 桶限频，单个成员无法再以无限速率放大广播。
- `WorldPayload.is_summary_refusal()` 同时识别 `payload_too_large` 与 `rate_limited`。已拿到过权威快照的客户端保留上一份状态并显示可重试提示（`summary_refused`），首次快照前收到拒绝才按加入失败处理；两类拒绝都不会把已确认状态替换成空文档。
- `rate_limited` 的拒绝计数与显示文案已接入 `WorldClient`、`WireMember` 与 `main.gd`；重连后的新 peer 有完整桶，正常路径不受影响。

验证：`tests/world_rate_limit_test.gd`（21 项）覆盖正常请求通过、超频拒绝且具名、不同 peer/不同桶互不影响、断开重连恢复额度、summary 桶补充后重新可用。回归 `WORLD_PAYLOAD_TEST 67/0`、`WORLD_TAIL_TEST 31/0`、`M4_SERVER_TEST 79/0`、`M4_SYNC_TEST 39/0`、`M4_CLIENT_SCENE_TEST 39/0`、`M5_SOCIAL_TEST 58/0`、`M4_ECONOMY_COMMANDS_TEST 162/0`。

### 未覆盖

- 没有在真实 WSS 会话里构造一个“压缩摘要”世界端到端跑一遍；客户端解码路径由 `WireMember` 节点直测与一个两进程 RPC 覆写探针验证。现有 M4/M5 回环世界都低于 48 KiB，走明文路径。
- 未计时 zstd 压缩/解压的耗时与峰值内存，也未在 Windows 上执行本机测试以外的路径。
- `PROTOCOL_VERSION` 未升级，部署中的旧客户端不会在握手阶段被明确拒绝；当前仅适用于同一代码基线的两端。
- 限频只在无传输的 `WorldHost` 夹具里验证了分类、计数、按 peer 隔离与桶补充；没有在真实 WSS 会话下用多个恶意 peer 做压力测试，也未在 Windows 上执行。
