# 网络载荷预算实测（R18）

- 日期：2026-11-15
- 环境：macOS 27.0.1 / Apple Silicon；Godot `4.7.2.stable.official.ed1daf0bf`，`--headless`
- 目的：为 [ADR-026](../decisions/ADR-026-network-payload-limits.md) 提供可复现的字节数据，不改变任何项目代码。
- 所有探针与原始日志：`.local/payload-probe/`（未纳入版本控制，不参与构建）。

## 结论摘要

| 事实 | 实测值 |
|---|---|
| `WebSocketMultiplayerPeer` 默认收发缓冲 | `inbound_buffer_size = 65535`、`outbound_buffer_size = 65535`（公开属性读取） |
| 单条 WebSocket 消息上限 | 65,535 B 交付；65,536 B 被丢弃，`put_packet` 仍返回 `OK`，连接不断开 |
| 单条 `command_result(request_id, payload)` 的 JSON 上限 | 65,510 B；65,511 B 起静默丢弃（请求 id 长度 1 与 8 时一致） |
| 空世界 summary + snapshot | 38,647 B（占 64 KiB 的 59%） |
| 普通游玩规模 summary + snapshot | 100,035 B（已超限） |
| 结构上限世界 summary + snapshot | 692,623 B（超限 10.6 倍） |
| 256 条真实 tail | 63,709 B（只剩 1.8 KiB 余量） |
| 256 条合法最长 id tail | 122,441 B（ASCII id）/ 187,977 B（中文 id） |
| 普通世界 zstd 后 | 7,256 B（base64 约 9,676 B） |
| 结构上限世界 zstd 后 | 18,679 B（base64 约 24,906 B） |

## 1. 传输层默认值与行为

### 1.1 默认值（公开 API）

```text
ws has inbound_buffer_size  = 65535
ws has outbound_buffer_size = 65535
ws has max_queued_packets   = 4096
ws has handshake_timeout    = 3.0
```

属性列表中没有 `max_packet_size`、`support_big_packets`、`server_relay`。引擎源码里的默认值与此一致（`modules/websocket/websocket_multiplayer_peer.cpp` 构造函数）。

### 1.2 单条消息上限

同一对 loopback 服务端/客户端，服务端用 `put_packet()` 发送一段 `PackedByteArray`：

```text
size=65535 put_err=0 got=65535 packets=1 status_s=2 status_c=2
size=65536 put_err=0 got=-1    packets=0 status_s=2 status_c=2
size=100035 put_err=0 got=-1   packets=0 status_s=2 status_c=2
```

- 65,535 B 完整到达；65,536 B 起不交付。
- `put_packet` 返回 `0`（`OK`），两端状态仍为 `2`（CONNECTED），没有 `peer_disconnected`；只有引擎自身打印一条：`WSLPeer::_send: ... Returning: ERR_OUT_OF_MEMORY`。
- 根因（源码）：`WSLPeer::_send` 检查 `queued_msg_length + p_buffer_size > outbound_buffer_size`，超限返回 `ERR_OUT_OF_MEMORY`；`WebSocketMultiplayerPeer::put_packet` 忽略每 peer 的返回值，仍向调用方返回 `OK`。因此**服务端无法从返回值发现丢弃**。
- 该检查是“队列长度 + 本条消息”的和，不只是本条消息。拥塞或突发时，多条都低于上限也可能因为排队而丢；本节未做拥塞压测，见“未验证”。

### 1.3 RPC 封包上限

使用与项目相同的签名 `command_result(request_id: String, payload: String)`（reliable，通道 2），服务端→客户端，先发一条小 RPC 预热节点路径缓存，再发目标大小：

```text
request_id = "x"（1 字符）
65509 pass / 65510 pass / 65511 drop
request_id = "catch_up"（8 字符）
65509 pass / 65510 pass / 65511 drop
```

结论：可交付的 JSON 文本上限为 **65,510 B**；再多 1 B 即静默丢弃。RPC 头、长度前缀、引号与请求 id 合计约 25 B；1 字符与 8 字符请求 id 的实测边界相同，说明封装存在对齐/填充。这个上限尚未扣除“首次 RPC 携带节点路径”的几十字节，实际应留更大余量。

### 1.4 只提高发送端缓冲是危险的

- 发送端 `outbound_buffer_size = 1 MiB`、接收端保持默认 65,535：发送 100,035 B 后，接收端在 0–1 ms 内以 `MESSAGE_TOO_BIG`（1009）关闭连接，两端都收到 `peer_disconnected`。
- 两端都提高到 1 MiB：692,623 B 可完整往返。

因此“只调服务端缓冲”会把静默丢弃变成硬断开；缓冲大小不是协议修复。

## 2. World summary + snapshot 字节数

夹具由真实的 `HeadlessWorld` / `FarmState` / `MarketState` / `EconomyState` 规则构造，`JSON.stringify` 后按 UTF-8 计。

| 形状 | summary 视图 | snapshot | 合计 |
|---|---:|---:|---:|
| 空世界：默认 6 块田 × 16 格（96 格），没有任何订单/账户 | 17,060 | 21,515 | **38,647** |
| 普通游玩：8 账户、68 格已种植、35 订单、8 发货、8 交付、10 成交、52 条账本、64 条命令结果 | 18,308 | 81,655 | **100,035** |
| 结构上限：12 块田 × 32 格（384 格）、256 订单、256 发货、256 交付、512 成交、512 条账本、64 条命令结果、8 账户 | 63,247 | 629,304 | **692,623** |

结构上限世界的组成（字节）：

```text
snapshot.farm.economy      524,423   （订单簿、发货、交付、成交、账本、账户）
  market                   381,717
    orders                  82,837
    trades                 128,405
    shipments               93,845
    deliveries              76,181
    merchant                   245
  ledger                   141,347
  accounts                     441
snapshot.farm.fields        62,481
snapshot.farm.transaction   32,807   （最近 64 条命令结果）
summary.fields              60,999   （与 snapshot.farm.fields 重复的显示视图）
snapshot.decorations           438
snapshot.farm.animals          568
snapshot.farm.bags            1,422  （所有玩家的口袋）
snapshot.nature                 43
```

三个观察：

1. **普通游玩就已超限**：100,035 B > 65,510 B。这不是“结构上限才会发生”的边界问题。
2. **summary.fields 与 snapshot.farm.fields 是同一批格子的两次编码**。空世界重复 16,239 B，普通世界 16,742 B，结构上限 60,999 B。客户端恢复状态只读 `snapshot.farm`，`summary.fields` 目前只有测试在度量。
3. 结构上限下，公开市场行（订单/发货/交付/成交）占 economy 的 381,717 B，账本 141,347 B，所有玩家的 bags 只有 1,422 B。只裁剪“别人的 bags/账本”无法把文档降到 64 KiB 以下：仅公开市场行就还有 382 KB（R19 不能替代 R18）。

## 3. tail 字节数

### 3.1 真实事件

普通游玩夹具中，256 条连续提交的回复：

| 条数 | 回复 JSON 字节 |
|---:|---:|
| 16 | 4,048 |
| 32 | 8,044 |
| 48 | 12,073 |
| 64 | 16,082 |
| 96 | 24,074 |
| 128 | 32,112 |
| 192 | 48,103 |
| 256 | **63,709** |

256 条 = 事件 63,381 B + 包装 328 B（`ok/reason/events/current/request_id`）。按种类：

```text
sow          144 条  34,935 B（单条最大 243）
market_place  35 条   9,647 B（最大 276）
market_ship   35 条   9,647 B（最大 276）
pay           36 条   8,002 B（最大 223）
account_open   4 条     772 B
bank_open      1 条     187 B
market_open    1 条     191 B
```

单条事件约 187–276 B，均值 247.6 B。

### 3.2 合法最大 id

命令 `id` 上限 128 字符（`FarmCommand.MAX_ID_LENGTH`），玩家 id 上限 64 字符，显示名上限 24 字符。客户端可以在这三个字段里放大字节数：

| 形状 | 单条事件 | 256 条回复 |
|---|---:|---:|
| 128 字符 ASCII 命令 id、64 字符玩家 id、24 字符名 | 479 B | 122,441 B |
| 128 字符中文命令 id、64 字符玩家 id、24 字符中文名 | **735 B** | **187,977 B** |
| 另一夹具（128 字符 ASCII id，更长显示名） | 555 B | 129,809 B |

因此“256 条”这个数量上限不能保证字节上限：固定条数的最坏情况是 64 KiB 的 2.9 倍。

### 3.3 安全条数

设可用预算为 `B`，包装固定 328 B，则条数上限约 `(B - 328) / 单条字节`：

| 单条字节 | 64 KiB 上限 65,510 B | 推荐预算 48 KiB = 49,152 B |
|---:|---:|---:|
| 248（普通实测均值） | 263 | 197 |
| 506（ASCII 最长 id 实测） | 128 | 96 |
| 735（合法最坏，中文 id） | 88 | 66 |

结论：只能按字节预算裁剪，不能按固定条数裁剪。

## 4. 压缩

`PackedByteArray.compress(FileAccess.COMPRESSION_GZIP / COMPRESSION_ZSTD)`，同一夹具：

| 夹具 | 原始 JSON | gzip | zstd | zstd + base64 |
|---|---:|---:|---:|---:|
| 普通 summary + snapshot | 98,186 | 8,400 | 7,256 | ≈9,676（计算） |
| 结构上限 summary + snapshot | 692,599 | 37,690 | 18,679 | ≈24,906（计算） |
| 结构上限 snapshot（不含 summary 视图） | 629,291 | 35,837 | 17,996 | ≈23,995（计算） |
| 结构上限 summary 视图 | 63,232 | 1,559 | 1,098 | ≈1,464（计算） |
| 256 条长 id tail | 123,612 | 3,628 | 2,392 | **3,192（实测）** |
| 256 条普通 tail | 62,428 | 1,775 | 987 | ≈1,316（计算） |

- 压缩后所有实测形状都远低于 65,510 B；结构上限世界的 base64 结果约 24.9 KB，相对推荐的 48 KiB 预算仍有约 24 KB 余量。
- 同一夹具的原始 JSON 在不同运行间相差数 B（如 692,599 与 692,601），不影响压缩结论。
- 这些夹具高度重复，压缩比偏乐观；真实玩家的命令 id 可以接近随机，压缩率会下降。因此压缩之后仍需硬字节预算兜底。
- 压缩/解压耗时未计时（见“未验证”）。

## 5. 复现

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
cd /Volumes/Disk-1tb/yipiantian

# 默认缓冲
"$GODOT" --headless --path Game --script "$PWD/.local/payload-probe/api_probe.gd"

# 世界文档大小
"$GODOT" --headless --path Game --script "$PWD/.local/payload-probe/measure.gd"

# 单条消息上限 / 接收端断开 / 提高缓冲
"$GODOT" --headless --path Game --script "$PWD/.local/payload-probe/ws_limit.gd"
"$GODOT" --headless --path Game --script "$PWD/.local/payload-probe/ws_recv_limit.gd"
"$GODOT" --headless --path Game --script "$PWD/.local/payload-probe/ws_raise.gd"

# RPC 上限（脚本内部为每个大小起一对新进程）
"$GODOT" --headless --path Game --script "$PWD/.local/payload-probe/rpc_budget8.gd" -- --id=catch_up

# tail 与压缩
"$GODOT" --headless --path Game --script "$PWD/.local/payload-probe/tail_real.gd"
"$GODOT" --headless --path Game --script "$PWD/.local/payload-probe/compress2.gd"
"$GODOT" --headless --path Game --script "$PWD/.local/payload-probe/worst_tail.gd"
```

探针只读项目代码、不写项目文件；夹具写在 `.local/payload-probe/*/`。日志中的 `ERROR: ... ERR_OUT_OF_MEMORY` 是被测行为本身，不是探针失败。

## 6. 未验证

- zstd 压缩/解压在游戏循环中的耗时与峰值内存（未计时）。
- 真实玩家数据（随机 id、长中文名）的压缩率；现有夹具偏重复。
- Windows 上同一路径的执行；引擎行为应与平台无关，但本次未在 Windows 跑这些探针。
- 出站队列拥塞时多条中等消息的累积丢弃；源码显示检查包含 `queued_msg_length`，但未构造拥塞场景。
- 真实场景中 `WorldMember` 节点路径长度对首条 RPC 的额外开销；按几十字节估计，48 KiB 预算已吸收。
- 服务端在广播时逐个 peer 构造 JSON 的 CPU/分配成本（每次经济提交都会广播完整 summary）。
