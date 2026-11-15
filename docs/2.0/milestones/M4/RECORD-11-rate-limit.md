# M4-11 · 每 peer 请求限频

执行日期：2026-11-15。状态：切片完成，不表示 M4 或 R20 验收完成。关联：[ADR-026](../../decisions/ADR-026-network-payload-limits.md)、RISKS R20、[M4-10 经济面板](RECORD-10-economy-panels.md)。

## 背景

ADR-026 的 48 KiB 预算只约束单条消息的大小，不约束一个成员多频繁地让权威序列化世界、压缩摘要或写盘。单个 peer 可以反复请求 summary/catch_up，或连续提交命令，把一次连接变成对 CPU、磁盘和所有成员广播的放大器。本切片在权威入口增加每 peer 的令牌桶，不做通用限流框架，也不改存档格式。

## 实现

`Game/world/world_host.gd`：

| 桶 | 覆盖入口 | 突发 | 补充 | 挡住的放大路径 |
|---|---|---|---|---|
| `command` | `submit`、`social_request` | 20 | +1/s | 规则计算 + FarmStore 落盘 + 经济变更广播 |
| `summary` | `request_summary` | 5 | +0.5/s | 整份世界序列化、zstd 压缩与发送 |
| `catch_up` | `catch_up` | 4 | +0.5/s | 256 条 tail 的切片、字节预算与压缩 |

- 三类桶按 `peer_id → kind` 存在内存字典 `_rate` 中，不写存档、不跨重启。命令桶由 `submit` 与 `social_request` 共用，因为两者都可能持久化；summary 与 catch_up 各自独立，摘要刷新不会挤掉命令额度。
- 突发值覆盖现有夹具：M4 经济访客的 `weed,water,deny` 会在一个会话里连续提交十余条命令；加入/重连会在 1 秒内请求两次 summary，之后每 30 秒 reconcile 一次。
- 超限时 `rate_rejections` 加一，`push_warning` 记录 peer、request id 与桶种类，并回一条小型 `{"ok":false,"error":"rate_limited","reason":"rate_limited","reason_text":"请求太频繁，请稍后再试。"}`。命令/summary/catch_up 走现有 `_send_payload`，社交走 `_send_social`；拒绝文档本身仍经过 ADR-026 的 48 KiB 预算，不会静默丢弃。
- 客户端把 `rate_limited` 与 `payload_too_large` 一样当作“摘要拒绝”：`WorldPayload.is_summary_refusal()` 识别两者，已拿到快照的客户端保留上一份状态并显示可重试提示，首次快照前才按加入失败处理。
- 拒绝携带客户端提供的合法 request id，使 `WorldClient` 的待决表可以清掉对应请求。`_reason_text` 与 `Game/scenes/main.gd::_remote_reason` 都增加了中文文案。
- `_forget`、`reject`、`_defer_disconnect` 与撤销授权都会清掉该 peer 的桶；重连是新连接，从满额开始。summary 桶按时间补充，成员不会因为一次超频被永久卡死。

`_broadcast_summary` 仍由经济变更触发，本次没有给广播本身加每 peer 出站预算；触发它的命令已被 `command` 桶限频。

## 验证

全部在 macOS `4.7.2.stable.official.ed1daf0bf`、`--headless` 下执行；产物在 `.local/verification/`。

| 入口 | 结果 |
|---|---|
| `tests/world_rate_limit_test.gd`（新增，21 项） | `WORLD_RATE_LIMIT_TEST checks=21 failures=0` |
| `tests/world_payload_test.gd`（回归） | `WORLD_PAYLOAD_TEST checks=67 failures=0` |
| `tests/world_tail_test.gd`（回归） | `WORLD_TAIL_TEST checks=31 failures=0` |
| `tests/m4_server_test.gd`（回归） | `M4_SERVER_TEST checks=79 failures=0` |
| `tests/m4_sync_test.gd`（回归） | `M4_SYNC_TEST checks=39 failures=0` |
| `tests/m4_client_scene_test.gd`（回归） | `M4_CLIENT_SCENE_TEST checks=39 failures=0` |
| `tests/m5_social_test.gd`（回归） | `M5_SOCIAL_TEST checks=58 failures=0` |
| `tests/m4_economy_commands_test.gd`（回归） | `M4_ECONOMY_COMMANDS_TEST checks=162 failures=0` |

新增测试用真实 `WorldHost` 节点：先确认桶内的命令真正执行，再耗尽命令桶并确认后续 `submit` 不进入规则、拒绝文档具名为 `rate_limited`；catch_up 与 summary 各自验证突发通过、溢出拒绝；不同 peer 与不同桶互不影响；`_forget` 后桶消失且重连立刻可用；summary 等待 2.5 秒后重新放行。

回归中没有夹具触发限频，既有断言没有必要放宽。`world_rate_limit_test` 已加入 `.github/workflows/rule-tests.yml`，紧邻 `world_payload_test`。

## 未覆盖

- 没有在真实 WSS 会话里用多个恶意 peer 做并发压力测试；限频只在无传输的宿主夹具中验证分类、计数、隔离与补充。
- 没有给 `_broadcast_summary` 增加按 peer 的出站预算；单个 peer 仍可通过接近命令桶上限的经济操作触发较频繁的广播。要彻底解决需要对广播做合并或独立配额。
- 未在 Windows 上执行本机测试以外的路径；限值未做真实硬件下的吞吐标定。

## 关联

- 预算与拒绝文档：[ADR-026](../../decisions/ADR-026-network-payload-limits.md) 的“实现状态 · 与 R20 限频的关系”。
- 风险条目：RISKS R20（本次不修改该文件，由维护者统一更新）。
- 前序切片：[M4-10 经济面板](RECORD-10-economy-panels.md)。
