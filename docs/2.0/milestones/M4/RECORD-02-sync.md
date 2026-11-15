# M4-03 · 同步与重连（并发与幂等）

执行日期：2026-11-15。状态：切片完成，不表示 M4 或 M4-03 验收完成。前置：[M4-02 创建与加入](RECORD-01-join.md)。

## 实现

在 M4-02 的宿主/成员之上补齐两件事：

- **同一地块的并发裁决**：两个成员同时提交对同一成熟地块的收获。种子按顺序进入权威循环，先到者提交成功，后到者被规则以 `empty` 拒绝；落盘库存只增加 1，事件序号只前进 1。
- **重连幂等**：成员以新的 peer 重新加入后重试已提交过的命令 id。宿主从 `FarmState` 的事务账本读出原结果，返回 `duplicate=true` 与 `stage=duplicate`，不二次发奖、不推进序号。
- **事件尾部补齐**（第二轮）：宿主保留最近 `TAIL_LIMIT = 256` 条提交的尾部（序号、命令、结果）。成员可请求“自序号 N 之后的所有提交”；尾部还完整时按序返回，已经滚出保留窗口时返回 `tail_expired`，让客户端改拉快照而不是接受一个缺口。重复回放不进入尾部——重连成员不能把同一变更当成新事件应用两次。
- **在线成员同步**（第二轮）：一次提交除回复提交者外，还会以同一回复通道推送给其他成员。客户端按序号去重：`sequence <= last_sequence` 的推送直接丢弃，因此重复投递不会重复记账，旧发送者也不能把客户端拉回旧状态。
  - 广播条目现在带上执行者的 `from_id` 与 `from_name`（匿名成员两者为空）。客户端把别人的提交显示成“小满 收了青菜”这样的一行提示；匿名成员不会被编造称呼，也不会被提示。身份来自权威在加入时记下的玩家声明，不由客户端在命令里自带。
- 成员侧收到序号回退的回复时视为权威丢失（`stale_sequence`），不会把旧权威的结果当成当前状态。
- **命令前置条件**（第三轮）：成员提交时附带 `based_on_sequence`（它据以做决定的世界序号）。宿主在应用前比较；不一致返回 `stale_precondition` 并带上 `expected_sequence` 与实际序号，让客户端知道该重读哪一版。已提交 id 的重试豁免此检查，否则重放就不再幂等。
  - 这条补上了“规则仍然会接受、但决定所依据的状态已经变了”的空档：例如两人在同一成熟地块收获，败者现在得到 `stale_precondition` 而不是只能靠规则以 `empty` 拒绝。
  - 缺少该字段一律拒绝（`missing_precondition`），不退化成“没有前置条件也照做”。
- **完整快照**（第四轮）：`summary` 回复除展示用视图外，附带 `snapshot` 文档——`{now_utc, farm, decorations}`，与 `FarmStore` 落盘的两份快照同形。因此尾部滚出窗口、或成员首次加入时，恢复的不只是地块视图，而是布局、厨房、动物、记忆、季节与摆设。成员侧 `restore_state()` 用与磁盘加载完全相同的校验器重建 `FarmState`/`Decorations`，损坏或被截断的文档返回具名原因，不会半应用。

## 验证

`tests/m4_sync_test.gd`：一个真实宿主进程 + 四个真实成员进程（回环 WSS、自签证书、隔离目录 `.local/verification/m4-sync-*`）。先启动一个只连接不提交的“旁观成员”，再同时启动两个竞争成员，最后启动一次重连成员。

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 280 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m4_sync_test.gd"
```

结果：`M4_SYNC_TEST checks=39 failures=0`（第三轮加入前置条件后，本机连续复跑 2 次通过）。尾部规则由 `WORLD_TAIL_TEST checks=27 failures=0` 独立覆盖；快照完整性由 `WORLD_SNAPSHOT_TEST checks=28 failures=0` 覆盖，`M4_JOIN_TEST checks=54`（第四轮）在真实 WSS 会话上验证成员能从摘要恢复完整世界。

| 用例 | 实际输出 | 结果 |
|---|---|---|
| 并发收获 | 胜者 `ok=true, stage=committed, reward_amount=1`；败者 `ok=false, reason=stale_precondition, expected_sequence=0, sequence=1`；两者都看到序号 1 | 通过 |
| 前置条件判定 | 败者据以提交的序号是 0，权威已是 1，因此不是笼统失败而是“你基于旧状态” | 通过 |
| 规则仍独立生效 | 之后再加入的成员基于当前序号提交，被规则以 `empty` 拒绝 | 通过 |
| 在线广播 | 旁观成员未提交任何命令，却收到 1 条 `sequence=1` 的变更，`last_sequence` 随之变为 1 | 通过 |
| 重连重试 | 新 peer 加入后返回 `duplicate=true, ok=true, sequence=1`（前置条件豁免） | 通过 |
| 不重复发奖 | 落盘 `inventory.greens=1`、`harvested.greens=1` | 通过 |
| 单条事件 | 宿主汇总 `commands=1`，落盘 `transaction.sequence=1` | 通过 |
| 加入次数 | 5 次（旁观、两个竞争者、规则检查、一次返回） | 通过 |
| 快照恢复 | 成员从 `summary.snapshot` 重建 `FarmState`/`Decorations`，与宿主落盘快照逐字段相等；空/缺字段/篡改文档分别返回 `no_snapshot`、`invalid_farm`、`invalid_decorations`、`invalid_time` | 通过 |

尾部补齐的独立用例（`WORLD_TAIL_TEST`）覆盖：空尾、请求点在尾部内、恰好在保留窗口边界、滚出窗口后返回 `tail_expired`、未来序号被拒、重复回放不入尾、成员端对补齐与广播都按序号去重、失败补齐不推进本地序号。

用例已加入 `.github/workflows/rule-tests.yml`。首次 CI（运行 `43633387624`，提交 `990384f`）在两平台都失败，原因是测试断言写死了“`race-a` 获胜”，而实际先后顺序取决于进程调度；产品侧裁决本身正确（一成一败）。断言已改为跟随胜者，不再假设顺序。

断言修正后的双平台绿色证据：CI 运行 `43633628528`（提交 `867d0a8`）与 `43638240059`（提交 `036e2fe`，含 `world_snapshot_test` 与第四轮断言），`rules (macos-latest)` 与 `rules (windows-latest)` 均通过。第三轮前置条件（提交 `c888220`）的双平台绿色证据为 CI 运行 `43637616958`。

## 第五轮：客户端自动重连

前面的重连是“成员重新加入一次”的服务器侧规则；客户端自己没有任何恢复流程，断线只能停在最后一帧等人重启游戏。第五轮把它接到 `world_client.gd` 上。

- 权威丢失（`server_disconnected`、`connection_failed`、拨号超时）后进入退避重试：1、2、4、8、16 秒，之后每 30 秒一次，没有总时长上限。每次尝试都新建 `WebSocketMultiplayerPeer`，复用同一个 `/root/WorldSession` 成员节点；成员节点若已失效则重建，路径不变。
- 每次尝试有 10 秒拨号看门狗：对端不存在时 WebSocket 不一定立刻报错，靠它把退避继续推进。重连成功后再给摘要 10 秒期限，摘要不来就继续退避。
- 重连成功先按既有 `summary.snapshot` 整份校正本地（`state_ready` 走主场景同一条 `_on_remote_state`），再发 `reconnected(sequence)`。主场景据此提示“已重新连上世界”；重连期间保持最后确认的画面，不产生本地写入。
- **第一次加入就被拒**不能重试：同一张码不会得到不同答案。`_ever_joined` 之前的 `join_failed`/`authority_lost` 一律转成 `refused(reason)` 交给启动界面，而不是排一个永远失败的计时器。终端拒绝（邀请过期/已用/已撤销、世界或版本不符）同样停止重试。
- 成员节点的 `SceneMultiplayer` 信号改为只注册一次，重连不再累积回调。

`tests/m4_reconnect_test.gd`：真实权威子进程 + 随机端口 + 隔离目录。客户端加入、提交一次收获；写 `stop` 文件让权威干净退出并读 `farm.json`；断言进入 `reconnecting`（第 1 次、1 秒）且没有永久 `lost`；在相同端口、相同目录重启权威，40 秒内等到 `reconnected`，并把序号、收获、院落布局与库存同落盘结果逐项比较。最后用一个秘密不对的加入码断言“第一次就被拒”只发出一次 `refused`、3 秒内不排重试。

结果：`M4_RECONNECT_TEST checks=27 failures=0`。回归：`M4_CLIENT_SCENE_TEST checks=19 failures=0`（加入邻居提示后为 21 项）、`M4_HOSTING_TEST checks=25 failures=0`。

执行者身份由 `tests/m4_activity_test.gd` 覆盖：真实宿主、两个具名成员（小满、阿青），小满收获一次，阿青收到的唯一一条广播带有小满的玩家 ID 与显示名，序号与提交回复一致。结果 `M4_ACTIVITY_TEST checks=18 failures=0`（连续运行两次）。

## 第六轮：网络载荷预算（ADR-026）

R18 的实测结论是普通游玩规模的 summary+snapshot 已达 100,035 B、结构上限约 692,623 B，而 `WebSocketMultiplayerPeer` 单包只交付 65,535 B，超出后 `put_packet` 仍返回 `OK`，应用层没有失败信号。本轮按 [ADR-026](../decisions/ADR-026-network-payload-limits.md) 在发送前统一守住 48 KiB。

- 新增 `Game/world/world_payload.gd`：≤48 KiB 原样发送；超过时压缩为 `z1:<原始字节>:<base64(zstd)>`；压缩后仍超限返回具名失败。解码侧校验前缀、声明长度（上限 2 MiB）与解压后长度，`payload_invalid_prefix` / `payload_too_large` / `payload_decode_failed` / `payload_length_mismatch` 分别可诊断。
- `WorldHost` 的 `roster`、命令回复、`change`、`catch_up`、`summary`/广播摘要全部经过 `_send_payload()`；宿主拒绝超限文档时计数并回一条很小的 `payload_too_large` 文档。summary 的超限回退先去 `fields` 再重试。
- `tail_since()` 在压缩后仍装不下时只保留“最新连续后缀”用于计算 `floor`，返回 `tail_expired`，不返回带空洞的部分列表；`TAIL_LIMIT` 的条数上限继续独立生效。
- 客户端由 `WorldClient` 创建 `WireMember`（`WorldMember` 子类），在解析 JSON 前解码；解码失败按具名原因进入既有重连/重新请求摘要流程，不会把失败当成空快照。摘要本身 `payload_too_large` 时恢复上一份 `snapshot`/`state`：已加入的世界发 `summary_refused`、HUD 说明“世界资料过大”，保持加入状态与未决请求，由 30 s reconcile 重试；尚未加入时才按加入失败发 `lost`。
- 压缩按“是否超过预算”触发，而不是对 8 KiB 以上一律压缩；`PROTOCOL_VERSION` 保持 1。取舍与原因见 ADR-026 的“实现状态”。

验证结果：`WORLD_PAYLOAD_TEST checks=51 failures=0`（结构上限世界 692,612 B → 24,918 B、真实普通世界压缩后恢复等价、不可压缩文档具名拒绝、损坏载荷不覆盖状态、尾部裁剪）；`WORLD_TAIL_TEST checks=31 failures=0`（256 条完整尾部压缩后 ≤ 48 KiB 且连续）；`WORLD_SNAPSHOT_TEST checks=33 failures=0`（快照经线路编解码不改变内容）；回归 `M4_SYNC_TEST checks=39`、`M4_CLIENT_SCENE_TEST checks=39`、`M4_RECONNECT_TEST checks=31` 均为 `failures=0`。

未覆盖：真实 WSS 会话上的压缩摘要端到端（现有回环世界都低于预算，走明文）；压缩/解压耗时与内存；Windows 实测；协议版本升级与旧客户端拒绝。

## 未覆盖

- “同时”是进程级并发，不是毫秒级同步；两条命令仍按到达顺序处理。种子内的规则是确定性的，因此结果可重复，但没有测真实网络抖动或乱序到达。
- 前置条件以“世界序号”为单位，粒度是整个世界而不是单个地块或建筑：序号一致就放行，因此“中间发生过一件与目标无关的事”不会阻止命令。需要按目标细化时，还要引入地块版本。
- 事件尾只存在于宿主内存，重启即清空；重启前离开的成员一律只能拉快照。尾部上限 256 条，且只按序号补齐，不含“补齐失败后自动重拉快照”的完整客户端流程（成员只发出 `request_summary`）。
- 广播按提交顺序发送，但没有测高并发下的重排、丢包或慢消费者；成员只处理序号，不校对命令内容与本地状态的一致性。
- 摘要附带的快照是整世界文档，没有增量差量；大世界下每次重连都传完整状态（当前默认世界约 17 KB，未测更大布局）。成员侧只重建出 `FarmState`/`Decorations`；主场景经 `world_client.gd` 接入权威世界（见 [RECORD-06](RECORD-06-client.md)）。
- 未覆盖断线期间客户端离线排队与离线收益：重连只做状态校正，断线期间发出的命令不会补发，客户端也不会在离线时重放。
- 未测同一世界多个会员同时加入时的认证顺序压力、`auth_timeout` 边界或恶意重复提交。
- 没有跨机器、Windows 手工验证（CI 会跑同一用例）；没有测真实局域网延迟与丢包。

## 关联

- 前序：[M4-02 创建与加入](RECORD-01-join.md)；传输裁决 [ADR-004](../decisions/ADR-004-transport.md)。
- 事务账本与幂等窗口：[M3-03](../M3/RECORD-03-commit-recovery.md)。
- 阶段计划：[M4 PLAN](PLAN.md) M4-03。
