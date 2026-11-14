# ADR-004 · 联机传输与身份方案

状态：已确定传输主方案与身份分层（2026-11-15，本机原型验证）；会话令牌细节、发现方式与密钥存储仍待实现时确定。日期：2026-11-15。

## 问题

M4 需要 Windows 与 macOS 玩家进入同一世界，并证明“未经邀请不能取得成员权限”。要决定：用什么传输、邀请如何认证、发现怎么做、服务器搬迁后客户端凭什么确认“同一世界的新运行代次”。

现有 `player_id`/`device_id` 是导入时为设备稳定而生成的随机占位标识，不是密钥，也不带签名能力，不能当作认证凭据。

## 裁决

### 传输：`WebSocketMultiplayerPeer` + `wss://`

- 引擎内置，客户端与服务端在 Windows/macOS/Linux 无头均可用，不新增依赖。
- 低频农场命令只需要可靠有序；TCP 的队头阻塞在当前交互形态下不是主要问题。
- 服务端 `create_server(port, bind, TLSOptions.server(key, cert))` 与客户端 `create_client(url, TLSOptions.client(trusted_chain, common_name_override))` 已在 4.7.2 实机跑通。

不选 ENet：Godot 4.7 的 `ENetMultiplayerPeer` 没有任何加密或认证参数（`create_client`/`create_server` 签名里没有 TLS/DTLS），而 `ENetConnection` 层的 DTLS 需要在 `MultiplayerPeer` 之下自己装配；在证明这条路径可维护前，不能把明文 ENet 用于不可信网络。ENet 作为回退，前提是先交付 DTLS 原型。

不选 WebRTC（原生需外部 GDExtension 与信令/STUN/TURN）、Steam 网络（绑定 Steamworks）、Noise（无官方实现）、mDNS（无官方类）。理由与来源见 [M4-01 研究稿](../../research/m4-connectivity.md)。

### 身份：三层分离

| 层 | 材料 | 谁持有 | 作用 |
|---|---|---|---|
| 世界（长期） | 世界签名密钥对 + TLS 证书 | 服务器 | 证明“这是同一个世界”；签发迁移描述与成员记录 |
| 邀请/成员（中期） | 高熵邀请秘密（≥128 位）、角色、有效期、证书指纹 | 邀请持有者 | 证明“被邀请过”；决定权限集 |
| 设备会话（短期） | 随机会话令牌、绑定玩家/设备/代次 | 加入后的客户端 | 重连免重复出示邀请；可单独撤销 |

`world_id` 只标识世界，不承担认证；内容摘要只是某提交点的承诺，不能替换世界身份。

### 认证闸门：`SceneMultiplayer.auth_callback`

设置 `auth_callback` 后，新 peer 停留在认证阶段，`peer_connected` 在 `complete_auth()` 前不会发出，且只允许认证数据交换。邀请持有者用 HMAC-SHA256（`Crypto.hmac_digest` + `constant_time_compare`）回答服务器的一次性随机挑战；失败直接 `disconnect_peer`，不调用 `complete_auth`。

这不是“文档上可行”的推断：本机原型已验证未获邀请的客户端无法成为 peer，也无法让服务器执行任何业务 RPC（见下节）。

### 发现：手动邀请码

首版只用邀请码/地址。UDP 广播、mDNS、二维码属于体验优化，且都触发 macOS 15+ 本地网络权限与 Windows 防火墙差异；发现结果只能当“附近可能有服务器”，必须再用邀请与世界公钥验证，不能作为授权依据。

### 搬迁：断线重连 + 代次

Godot 没有连接迁移（无 QUIC 类）。搬迁是一次显式断开再连接，客户端核对由世界密钥签名的迁移描述：`world_id`、单调递增的 `run_generation`、`committed_sequence`、`content_digest`、`expires_at`。代次不高于本地记录即视为旧服务器/重放。旧服务器必须在应用层拒绝写入——`refuse_new_connections` 只影响新连接，`close()` 又不发 `peer_disconnected`，两者都不能当作停写手段。

## 原型证据（2026-11-15，macOS 27.0.1 / M4 Pro / 4.7.2-stable）

`tests/m4_auth_test.gd` 以真实子进程跑一个 WSS 服务端与三个客户端（`--headless`，本机回环，隔离目录 `.local/verification/m4-auth-*`）：

```text
M4_AUTH_TEST checks=24 failures=0
M4_AUTH_SERVER {"authenticated":1,"rejected":1,"post_auth_commands":1,"unauthenticated_commands":0,
  "notes":["peer_connected:…","peer_disconnected:…","reject:…"]}
```

- 被邀请客户端：自签证书 + `TLSOptions.client(cert, "localhost")` 完成握手，HMAC 挑战通过，命令被执行并收到回复；
- 未被邀请客户端：证书能验证，但 HMAC 不匹配，被记录为 `reject`，`authenticated` 不增加，`unauthenticated_commands=0`；
- 证书未固定名称（不给 `common_name_override`，用 IP 直连）：TLS 握手直接失败（mbedTLS `-0x2700`），邀请根本没有机会出示——说明证书校验确实生效，不是被跳过；
- 客户端在认证完成前抢先发的业务 RPC 未被服务器执行。

用例已加入 `.github/workflows/rule-tests.yml`。干净检出 CI（运行 `43632372834`，提交 `5a6370a`）在 macOS 与 Windows 上均得到 `M4_AUTH_TEST checks=24 failures=0`，说明 Windows 的回环 WSS、自签证书校验与认证闸门同样成立。

## 已知边界

- 原型只覆盖回环、单机、无 NAT、无防火墙、无真实证书轮换。Windows 已在 CI 跑通同一用例，但没有经过真实网卡、防火墙规则或跨机器连接。
- 未测超过 64 条命令账本窗口的断线重连（`MAX_COMMAND_RESULTS=64` 是幂等窗口，不是长期事件尾部）。
- 未测 `auth_timeout`、慢网络下的人工输入、长连接保活与 TCP 队头阻塞对交互的实际影响。
- 高层多人协议是引擎实现细节，不保证跨 Godot 版本稳定；两端必须锁定同一引擎版本并在应用层握手带协议版本。
- WebSocket 默认收发缓冲 65535 字节；大快照需要分块或独立下载，未实测。
- macOS 15+ 本地网络权限、导出包 Info.plist、Windows 防火墙与沙盒 entitlement 都未实测。

## 受影响规格

- [身份、存档、迁移与联机契约](../../05-DATA-AND-NETWORK.md)：玩家/设备身份与邀请、会话的区分；它把身份密钥方案列为待验证候选，本 ADR 给出了传输与认证层选择，密钥存储与轮换仍在实现时确定。
- [M4 PLAN](../milestones/M4/PLAN.md) M4-01：本 ADR 交付“记录协议与威胁边界”；M4-02 起实现创建/加入。

## 复审触发条件

出现下列任一情况时重开本裁决：WSS 在真实局域网/公网的握手或吞吐不满足；需要无端口映射的公网直连；需要不可靠通道做高频同步；Godot 升级破坏高层协议；或会话令牌/发现方案被证明不需要（例如改为仅手输地址）。
