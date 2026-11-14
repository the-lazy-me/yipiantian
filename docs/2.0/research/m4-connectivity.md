# M4-01 传输与身份方案研究

状态：研究稿，支撑 [ADR-004](../decisions/ADR-004-transport.md)。写成时未改代码、未运行 Godot；随后 T1/T3 已由 `tests/m4_auth_test.gd` 在本机验证（见 ADR-004），其余实测项仍未执行。
日期：2026-11-15。
范围：局域网/自建房、Windows 与 macOS 客户端、Godot 4.7 无头服务端、手动邀请或局域网发现、会话撤销与重连、服务器搬迁后的世界身份校验。
版本基准：Godot 4.7 官方英文文档（`en/4.7`）；项目实际锁定 4.7.2 [R12]。文档页可能随 4.7.x 更新，本文记录的是 2026-11-15 读取到的内容。

## 结论摘要

- **推荐主方案**：`WebSocketMultiplayerPeer` + `wss://`（TLS）+ 应用层加入协议。邀请码手动输入为主，UDP 广播只作为可选发现提示；不使用 mDNS 作为首版依赖。
- **身份**：世界/服务器持有一对长期签名密钥和一张 TLS 证书；邀请码携带世界 ID、地址、证书指纹、角色、有效期和高熵邀请秘密。客户端用固定证书链验证服务器，用 HMAC 挑战应答证明邀请持有，服务端签发可撤销的会话令牌。现有 `player_id`/`device_id` 只是导入占位符，不能直接当作认证凭据 [R1][R8]。
- **回退**：`ENetMultiplayerPeer` + DTLS。Godot 4.7 的 DTLS 在 `ENetConnection`/`PacketPeerDTLS` 层可用，但 `ENetMultiplayerPeer` 没有暴露 DTLS 配置，需要自定义 `MultiplayerPeer` 或 GDExtension 原型；在证明可维护前不作为主方案 [G2][G3][G11][G12]。
- **暂不采用**：WebRTC（原生平台需要外部 GDExtension、还要信令与 STUN/TURN）、Steam 网络（GodotSteam 第三方且绑定 Steamworks）、Noise（Godot 无官方实现）、mDNS（Godot 无官方类）、Nakama（增加后端依赖，且不解决本阶段传输问题）[G6][G8][S2][G23][R11]。
- **关键风险**：WSS 自签证书 + IP 直连的证书校验尚未实测；WebSocket 只有 TCP 可靠有序，且有 64 KiB 默认缓冲区；当前幂等账本只有 64 条，长断线重连需要 M4-03 的持久事件尾部；macOS 15+ 本地网络权限与 Windows 防火墙会直接影响发现和直连；Godot 高层多人协议是引擎实现细节，跨引擎版本不保证稳定 [G4][G7][G17][A1][M1]。

## 1. 现有实现边界

这些边界决定了网络层不能怎么做：

1. **单写者**：单机世界由本地规则实例写入，共享世界由服务器写入；其他端只提交命令。共享世界迁移采用停写与代次切换 [R10][R3]。
2. **无头世界不碰网络**：`HeadlessWorld` 的职责是从 `FarmStore` 打开世界、在权威 `FarmState` 上执行命令、原子保存；它明确不访问场景、`DisplayServer`、GPU、时钟或网络 [R5]。网络层应把已认证、已解析的命令送入 `HeadlessWorld.execute()`，不能绕过 `FarmStore` 的提交边界。
3. **提交与幂等**：命令在候选状态上执行，资源变更、命令结果与事件序号在同一快照提交；已提交命令按 ID 重放 [R3][R7]。但 `FarmState` 只保留最近 64 条命令结果（FIFO 淘汰），它是幂等窗口，不是完整审计日志 [R7]。
4. **世界包 v1 的字段**：`format_version=1`、`rules_version=27`，含 `world_id`、`farm_id`、`player_id`、`device_id`、`committed_sequence`，但没有 `content_digest`、事件尾部或 `run_generation`；新增字段必须递增 `format_version` 并定义兼容规则 [R1][R6]。
5. **导入世界 ID 的特殊性**：v27 导入的 `world_id` 是规范化内容 SHA-256 的派生值，只作为一次性导入去重键，不是可变世界的长期身份；M4 若让导入世界联网，必须先建立稳定 ID 映射 [R1][R9]。
6. **身份占位符**：`player_id`/`device_id` 是首次导入时随机生成的占位标识，不是已验证的身份密钥或设备会话 [R1][R8]。
7. **验收门槛**：Q6 要求身份连续、重连幂等、访问/收获/建设权限分别生效 [R4]；M4-01 的交付要求是记录协议与威胁边界，并证明“未经邀请不能取得成员权限” [R2]。

## 2. 威胁边界与必须证明的属性

### 2.1 资产

- 世界状态、命令账本、事件序号、玩家财产与权限记录。
- 世界/服务器长期私钥、TLS 私钥、邀请秘密、会话令牌、设备撤销记录。
- 客户端身份包（可导出、需加密）与联系人/设备授权记录 [R1]。

### 2.2 对手

- 未被邀请的局域网或互联网攻击者。
- 被邀请但越权的成员（合法连接、非法命令）。
- 被撤销的设备或被盗的会话令牌。
- 路径上的窃听/篡改者。
- 伪造的局域网发现响应或过期服务器。
- 旧服务器仍在线、新旧服务器同时接受写入造成的分叉 [R3][R10]。

### 2.3 必须证明的属性

1. **服务器认证**：客户端能确认连接的是目标世界，而不是同名/同地址的冒名服务器。
2. **邀请约束**：没有有效邀请或未撤销令牌的客户端不能完成认证，不能进入 `peer_connected` 状态，不能发出业务 RPC。
3. **传输保护**：邀请秘密、令牌和命令不被路径上的攻击者直接读取或篡改。
4. **重放抵抗**：旧邀请、旧令牌、重复命令不能二次生效。
5. **撤销**：房主/管理员撤销邀请或设备后，现有会话失效且不能自动恢复。
6. **权限分离**：访问、照料、收获、建设、管理分别授权，服务端逐命令检查 [R1]。
7. **版本协商**：协议、规则、资源版本不兼容时给出明确原因 [R1]。
8. **迁移连续性**：地址变化后，客户端能确认“同一世界、更新运行代次”，并拒绝旧服务器或分叉。
9. **服务器权威**：所有重要状态由服务器裁决，客户端输入一律视为不可信 [G1]。

### 2.4 不在本阶段承诺

- 不做匿名通信、抗流量分析或公网 DDoS 防护。
- 不承诺无端口映射的自动 NAT 穿透；M4 的边界是局域网/自建服务器，必要时手动转发端口。
- 不承诺跨服资产互兑、自动全网好友发现或无限公开服务器规模 [R2]。
- 不承诺主机被攻陷后的世界完整性；主机本身是信任边界。

## 3. 传输候选矩阵

| 候选 | 加密 | NAT/穿透 | 局域网发现 | 连接迁移 | 每个对等端可靠性/通道 | 依赖 | 跨平台/无头 | 主要风险 |
|---|---|---|---|---|---|---|---|---|
| `ENetMultiplayerPeer` | 文档化 API 无加密/认证参数；DTLS 只在 `ENetConnection` 扩展层 [G2][G3] | 手动 UDP 端口转发；UPnP 可选；无自动穿透 [G1][G22] | 无内置发现 | 无内置迁移；断线重连靠应用层 | 可靠/不可靠/不可靠有序通道；每个对等端可发不同传输模式 [G1] | 引擎内置 | Windows/macOS/Linux/无头均可用；默认最多 32 客户端，可调到 4095 [G2] | 明文直连不可用于不可信网络；DTLS 未在高层的 `MultiplayerPeer` 暴露 [G2][G3] |
| `WebSocketMultiplayerPeer`（`ws`/`wss`） | `wss://` 走 TLS；客户端默认校验证书主机名；服务端可传 `TLSOptions.server` [G4][G5][G9] | TCP 端口转发或反向代理；无自动穿透；UPnP 可转发 TCP [G22] | 无内置发现 | 无内置迁移；TCP 断线即重连 | 底层 TCP，可靠有序；文档未提供 unreliable/通道参数，`transfer_mode` 行为需实测 [G4][G8] | 引擎内置 | 原生客户端/服务端可用；Web 导出不能做服务端 [G5] | TCP 队头阻塞；默认收发缓冲 64 KiB、最多 4096 个排队包，大快照需分块 [G4]；自签 + IP 直连校验待测 |
| `WebRTCMultiplayerPeer` | Godot 4.7 文档把 DTLS 列为 WebRTC 依赖的底层技术，但未明确写数据通道加密；需实测确认 [G7][G8] | ICE/STUN/TURN；需要信令交换；TURN 可中继 [G7][G8] | 无内置发现 | 无内置迁移 | 每个对等端三路通道：可靠、不可靠、有序 [G6] | 原生平台需要外部 GDExtension 插件；还需自建信令 [G8] | 可跨平台，但打包/部署复杂 | 依赖多、信令与 TURN 成本高；不适合作为 M4 首版主方案 |
| Steam 网络（`SteamMultiplayerPeer`/GodotSteam） | Steam 网络提供强加密与认证 [S1] | Steam Datagram Relay 中继、NAT 穿透、认证票据 [S1] | Steam 好友/大厅体系 | 重连由 Steam 层与应用层配合 | Steam 网络提供可靠/不可靠消息与虚拟端口 [S1] | 第三方 GodotSteam（社区版，MIT）；需要 Steamworks 与 AppID [S2] | Windows/macOS/Linux；必须有 Steam 客户端 | 平台绑定；不能覆盖非 Steam 分发；Godot 4.7 兼容性需核验 [S2] |
| 自定义 UDP + `PacketPeerDTLS`/`DTLSServer` | DTLS 内置；客户端可验证服务器证书 [G11][G12] | 手动端口转发；UPnP 可选；无自动穿透 | 无内置发现 | 无内置迁移 | 需要自行实现可靠/有序/分片/对等端管理 | 引擎内置 mbedTLS 类 | 理论跨平台 | 工作量大；DTLS 文档明确不支持证书吊销与证书固定；没有现成高层 `MultiplayerPeer` [G11] |

### 3.1 关键说明

- **ENet**：Godot 高层多人 API 基于修改过的 ENet，使用 UDP，支持 IPv6；局域网地址与公网地址的区别、UDP 端口转发在官方页有说明，但没有自动 NAT 穿透 [G1]。`ENetConnection` 的 `socket_send` 可用于打 NAT 映射，但要求事先知道对端地址/端口（例如来自 STUN），且对对称 NAT 不工作 [G3]。`ENetMultiplayerPeer` 默认 `max_clients=32`，可到 4095，但实际并发可能远低 [G2]。
- **ENet 加密边界**：`ENetConnection` 文档提供 `dtls_client_setup`/`dtls_server_setup`，描述为“自定义 Godot 扩展”，客户端在 `connect_to_host()` 前调用、服务端在 `create_host_bound()` 后调用，可用 `TLSOptions` 配置 CA 与主机名校验 [G3]。但 `ENetMultiplayerPeer` 文档中没有 encrypt/DTLS/TLS/secure/authentication 任何字样，`host` 只是底层 `ENetConnection`，且在 `create_client()`/`create_server()` 之后才存在 [G2]。因此，**不能仅靠 `ENetMultiplayerPeer` 打开 DTLS**；需要自定义 peer 或引擎/GDExtension 改造，属于待实测项。
- **WebSocket**：`create_server(port, bind_address, tls_server_options)` 可传 `TLSOptions.server` 启用 TLS；`create_client(url, tls_client_options)` 在 `wss://` 下默认验证主机名 [G4][G5]。`WebSocketPeer` 明确说不要用 IP 直连 `wss://`，因为证书主机名不匹配；应使用与证书匹配的 FQDN [G5]。这意味着局域网 IP 直连需要 `common_name_override` 或等价方案，必须实测。
- **WebSocket 的可靠性**：底层是 TCP，官方 WebRTC 教程用“WebSockets use TCP, which is good for reliability but not for latency”对比 [G8]。`WebSocketMultiplayerPeer` 页没有 unreliable/通道/`transfer_mode` 说明 [G4]，所以“高层 `transfer_mode` 在 WebSocket 上是否被忽略”必须实测。对低频农场命令，可靠有序通常够用；若以后要做高频移动/位置同步，需要回退 ENet。
- **WebRTC**：`WebRTCPeerConnection.initialize()` 接受 ICE 服务器（STUN/TURN），有 ICE candidate 交换 [G7]；官方教程说原生平台需要外部 GDExtension 插件，并且需要信令服务器 [G8]。`WebRTCMultiplayerPeer` 每个对等端三路通道，支持可靠/不可靠/有序 [G6]。它适合“公网无端口映射”场景，不适合作为 M4 局域网首版的最低复杂度方案。
- **Steam**：Steam 官方网络文档称其提供“Strong encryption and authentication”，认证票据可让客户端在 Steam 离线/断线后仍连接，P2P 流量可经 Steam Datagram Relay 中继并隐藏 IP [S1]。GodotSteam 是社区第三方、MIT，需要 Steamworks；Godot 4 分支包含 multiplayer peer/packet peer 代码，但 4.7 兼容性需核验 [S2]。
- **高层协议稳定性**：`SceneMultiplayer` 文档明确说高层多人协议是“implementation detail”，不面向非 Godot 服务器，且“may change without notice” [G17]。因此服务端与客户端应锁定同一 Godot 版本（项目已是 4.7.2），并把应用层协议版本放进握手；不能把高层协议当作跨引擎版本的稳定线协议。

## 4. 身份方案候选矩阵

| 方案 | 服务器认证 | 成员/邀请证明 | 撤销 | Godot 4.7 可用性 | 能否证明“未经邀请不能取得成员权限” | 结论 |
|---|---|---|---|---|---|---|
| 邀请码/预共享密钥 + HMAC 挑战应答 + 会话令牌 | 由 TLS 证书（自签固定或 CA 签发）证明 | HMAC（邀请秘密或令牌）证明持有者 | 服务端删除令牌哈希并断开 | `Crypto.hmac_digest`、`constant_time_compare`、`generate_random_bytes` 内置 [G14] | 能，前提是高熵秘密、挑战含随机 nonce、服务端限速、认证前不暴露业务 RPC | **推荐主方案** |
| TLS 服务器证书（自签固定/CA 签发） | 能 | 只证明服务器，不证明成员 | 不适用 | `Crypto.generate_rsa`、`generate_self_signed_certificate`、`TLSOptions.server/client` 内置 [G9][G10][G14] | 不能单独证明；必须叠加成员认证 | 作为服务器认证层，不作为完整身份方案 |
| TLS 客户端证书（mTLS） | 能 | 理论上能 | 理论上能 | Godot 文档化的服务器 TLS 配置只接受服务器密钥/证书，没有客户端证书验证参数 [G9][G12][G13] | 不能直接使用；需 GDExtension 或外部代理 | 不采用 |
| Noise 协议 | 取决于实现 | 取决于 PSK/静态密钥 | 取决于实现 | Godot 4.7 类参考没有 Noise 协议类；只有程序化噪声 `Noise` [G23] | 理论可行，但无官方实现 | 不采用 |
| DTLS + PSK/证书 | 能（证书） | 需要应用层 PSK/令牌 | 应用层 | `PacketPeerDTLS`/`DTLSServer` 内置；但文档明确不支持证书吊销与证书固定 [G11] | 能，但传输层工作量大 | 仅作 ENet 回退的一部分 |
| Steam 身份 | Steam 登录/认证票据 | SteamID + 应用层邀请/白名单 | 应用层 + Steam | 第三方 GodotSteam；需要 Steamworks [S2] | 能证明 Steam 账号，但不能自动证明“被邀请”；仍需应用层授权 | 仅 Steam 发行时考虑 |
| 明文 ENet + 无认证 | 无 | 无 | 无 | 内置 | 不能 | 拒绝 |

### 4.1 现有身份材料不能直接用于认证

`player_id`/`device_id` 是导入时用系统随机字节生成的占位标识，目的是设备更换不换人、设备会话可撤销；它们不是密钥，也没有签名能力 [R1][R8]。如果直接把 `player_id` 当作“我是谁”的凭据，任何知道 ID 的客户端都能冒用。M4-01 必须把“稳定标识”和“证明标识归属的密钥/令牌”分开。

### 4.2 推荐的身份信封

建议把身份分成三层，避免把世界身份、成员身份、设备会话混成一个字段：

1. **世界身份（长期）**
   - 稳定 `world_id`（首次创建分配，不随后续内容变化）。
   - 世界签名密钥对（服务器持有私钥；RSA 生成在 Godot 内置可用 [G14]；曲线密钥可加载但生成/签名的实际支持需实测 [G15]）。
   - 世界公钥指纹写入邀请码；客户端首次加入时由邀请固定（TOFU），后续连接和迁移都校验同一公钥。
   - 世界公钥用于签署房间/迁移描述和成员记录；不用于每条命令签名（RSA 验签成本可接受在加入/迁移，不适合每帧）。
2. **邀请/成员资格（中期）**
   - 邀请秘密：至少 128 位随机值（`Crypto.generate_random_bytes` [G14]），服务端只存哈希。
   - 邀请绑定：`world_id`、角色/权限集、有效期、最大使用次数、服务器地址列表、TLS 证书指纹、协议/规则版本。
   - 邀请可以是一次性或多用；撤销=删除邀请哈希；邀请不是玩家身份，不能跨世界复用。
   - 成员记录：绑定 `player_id` + `device_id` + 角色 + 有效期，由世界密钥签名；用于重连和跨设备迁移。
3. **设备会话（短期）**
   - 加入成功后签发至少 256 位随机会话令牌；服务端存哈希，绑定 `player_id`、`device_id`、角色、过期时间、世界运行代次。
   - 令牌放在加密身份包中，不放进普通世界包 [R1]；撤销=删除哈希并断开对应 peer。
   - 令牌短 TTL + 刷新；旧令牌重放因过期/代次不匹配被拒绝。

### 4.3 邀请如何证明“未经邀请不能取得成员权限”

推荐使用 `SceneMultiplayer.auth_callback` 作为认证闸门：设置回调后，新 peer 先进入 `peer_authenticating`，在 `complete_auth()` 前 `peer_connected` 不发出，且只允许认证数据收发 [G17]。具体协议：

1. 客户端连上 TLS（先验证服务器证书/固定链）。
2. 服务器发随机 challenge（含 `world_id`、`run_generation`、过期时间、服务器 nonce）。
3. 客户端回 `invite_id` + HMAC(邀请秘密, challenge || 客户端 nonce || world_id) + `player_id`/`device_id` + 客户端 nonce；或回会话令牌。
4. 服务器用常量时间比较验证 HMAC/令牌哈希；失败则 `disconnect_peer`，不调用 `complete_auth`。
5. 成功后签发会话令牌与成员记录，调用 `complete_auth`；业务 RPC 只在 `peer_connected` 后开放。
6. 每条命令仍由服务器检查权限、数量、目标状态和规则版本 [R1]；认证只解决“谁”，不替代授权。

安全要点：

- 邀请秘密必须高熵，不能是短数字码；如需短码，必须配合服务端限速、失败锁定和一次性使用，不能仅靠短码本身。
- HMAC 的 challenge 必须含服务器随机 nonce 和世界/代次，防止旧邀请/旧握手重放。
- 不能在明文 `ws://` 上发送邀请秘密或令牌；必须 `wss://` 或等价加密层。
- `Crypto.hmac_digest` 只支持 SHA-256/SHA-1；用 SHA-256 [G14]。比较用 `constant_time_compare` [G14]。
- `auth_timeout` 默认 3 秒，遇到慢网络/手动输入需要调整 [G17]；认证失败要记录可诊断原因，但不要向未认证 peer 泄漏世界细节。

### 4.4 密钥存储、轮换、丢失

- **存储**：世界私钥/TLS 私钥保存在服务器世界目录，文件权限限制；客户端成员记录/令牌放入加密身份包 [R1]。Godot 没有内置 OS keychain 封装；是否需要 GDExtension 或用户口令加密，属于 M4-02 实现选择，不在本次决定。
- **轮换**：新公钥必须由旧公钥签名（轮换证明），或通过新邀请重新固定；不能静默替换已固定的世界公钥，否则客户端无法区分“轮换”和“冒名”。
- **丢失**：世界私钥丢失后，现有客户端无法验证“同一世界”的连续性；只能重新邀请并显式建立新的信任，或从备份恢复。这与风险登记 R12“身份密钥丢失/联系人迁移后无法识别”一致，必须如实说明，不能承诺无条件找回 [R1]。
- **TLS 证书轮换**：证书指纹在邀请里；轮换需要新邀请或由世界密钥签名的证书轮换记录。TLS 私钥与证书过期时间要写入世界元数据，避免客户端在迁移时遇到过期证书。

## 5. 局域网发现候选矩阵

| 方案 | Godot 内置 | 跨平台 | 权限/防火墙 | 信任属性 | 结论 |
|---|---|---|---|---|---|
| 邀请码/手动地址 | 是；字符串输入 + 直连 | Windows/macOS/Linux | 不做发现，但仍需服务端入站端口规则；Windows 防火墙、macOS 本地网络权限仍可能影响直连 [A1][M1] | 邀请本身可认证；地址不是信任来源 | **首版主方案** |
| UDP 广播（`PacketPeerUDP`/`UDPServer`） | 是；广播发送、绑定接收、`take_connection` [G19][G20] | 理论跨平台 | Windows 默认阻止未授权入站，需在活动配置文件放行；macOS 15+ 触发本地网络权限；沙盒/App Store 的原始广播可能还要 multicast entitlement [A1][M1] | 广播响应未认证，只能当“发现提示”，不能授权 | 可选；用于减少输入，不作为安全边界 |
| mDNS/DNS-SD | **无官方类**；4.7 类参考没有 MDNS/mDNS [G23]，`class_mdns.html` 为 404 | 需要第三方 GDExtension 或原生 DNS-SD；Windows 通常还要 Bonjour/DNS-SD 依赖 | macOS Bonjour 触发本地网络权限，需 `NSLocalNetworkUsageDescription` + `NSBonjourServices`；原始广播另需 entitlement [A1] | 未认证，需邀请/世界密钥二次校验 | 不作为首版依赖；若产品强需“自动发现”，先做第三方库评估 |
| 二维码 | 无官方 QR 生成类；需第三方/外部工具 | 取决于实现 | 与手动邀请码相同 | 与邀请码相同 | 可作 UX 增强，不是 M4-01 决策必需 |
| Steam 大厅/好友 | 第三方 GodotSteam | 仅 Steam | Steam 客户端/网络 | Steam 身份 + 应用层邀请 | 仅 Steam 发行时考虑 |

### 5.1 平台权限与防火墙事实

- **macOS 15 Sequoia 及以后**：首次访问本地网络会弹权限；单播到局域网地址、广播/组播、Bonjour 都会触发。拒绝后该应用的局域网单播、Bonjour、广播/组播全部失败，但仍能访问互联网。需要 `NSLocalNetworkUsageDescription`；用 Bonjour 还要 `NSBonjourServices`。沙盒应用还需要 `com.apple.security.network.client`/`network.server`；原始组播/广播需要受限的 `com.apple.developer.networking.multicast`（需向 Apple 申请），Bonjour 不需要该 entitlement [A1]。
- **Godot macOS 导出**：导出预设提供 Network Client/Network Server 沙盒开关；正式分发默认要求签名和公证，未签名/未公证会被 Gatekeeper 阻止 [G25]。该页没有说明如何加 `NSLocalNetworkUsageDescription`/`NSBonjourServices`；实际需要在导出时自定义 Info.plist 或后处理 `.app`，这是待实测项。
- **Windows**：Windows Defender Firewall 默认阻止未获允许的入站流量、允许出站；按域/专用/公用三种网络配置文件应用规则。公共网络配置更严格，未放行的监听端口会被阻止 [M1]。因此服务端首次监听 TCP/UDP 端口时，用户可能需要在专用网络放行；拒绝或在公共网络下会表现为“客户端连不上”，需要有清晰提示和手动重试路径。UDP 广播发现同样受入站规则影响。
- **UPnP**：Godot `UPNP.discover()`/`add_port_mapping()` 可尝试自动端口映射，但方法是同步阻塞的，且依赖路由器启用 UPnP；不能把它当作可靠的 NAT 穿透 [G22]。

### 5.2 发现的安全结论

发现协议只能回答“附近可能有服务器”，不能回答“这个服务器被允许加入”。任何 UDP 广播/mDNS 响应都必须用邀请里的世界 ID、证书指纹和 HMAC 挑战二次验证；否则同一局域网内的攻击者可以伪造响应，把客户端引到自己的服务器。推荐首版只做手动邀请码，把 UDP 广播作为 M4-02 之后的体验优化。

## 6. 会话撤销与重连

### 6.1 Godot 原生提供了什么

- `SceneMultiplayer.auth_callback` 可以拦截新 peer；设置后先 `peer_authenticating`，`complete_auth()` 前不发出 `peer_connected`，且只允许认证数据 [G17]。
- `send_auth()` 发送任意 `PackedByteArray`；引擎不定义其格式 [G17]。
- `auth_timeout` 只限制“认证阶段”的停留时间，默认 3 秒 [G17]。
- `disconnect_peer(peer, force=false)` 可断开指定 peer；`force=true` 时不发 `peer_disconnected` [G18]。
- `close()` 立即关闭并回到断开状态；已连接 peer 被丢弃且不发 `peer_disconnected` [G18]。
- `refuse_new_connections` 只拒绝新连接；文档没有说它影响已连接 peer [G18]。
- **没有**内置会话令牌、令牌撤销、自动重连或重连后的状态恢复；这些都必须应用层实现 [G17][G18]。

### 6.2 应用层会话与重连建议

1. **令牌**：加入成功后服务端签发随机令牌，存哈希（SHA-256）+ 绑定信息 + 过期时间 + 允许的角色/权限 + 世界运行代次。客户端把令牌存进加密身份包 [R1]。
2. **撤销**：删除令牌哈希；调用 `disconnect_peer` 断开当前连接；把设备 ID 加入撤销列表。被撤销设备即使持有旧令牌也无法再次认证。不要依赖 `refuse_new_connections` 来撤销现有会话 [G18]。
3. **重连**：每次重连都是新的 peer ID；客户端重新走 TLS + `auth_callback`，提交令牌或邀请证明；服务端验证令牌未撤销/未过期/代次匹配。
4. **状态恢复**：客户端提交最后确认的 `committed_sequence`；服务端返回当前序号和事件尾部/快照。客户端不能因为“没收到成功”就重发奖励；所有未确认命令用原 command ID 重试，服务端按幂等结果返回 [R1][R7]。
5. **当前账本边界**：`FarmState` 只保留最近 64 条命令结果，超过窗口的旧命令会被淘汰 [R7]。如果客户端断线期间世界推进超过 64 条命令，服务端不能保证旧 command ID 仍在账本里；M4-03 必须用持久事件尾部/快照补齐，或扩大/改造账本。不能把 64 条窗口当作长期重连保证。
6. **关闭/迁移时的信号**：`close()` 不触发 `peer_disconnected` [G18]，所以迁移/关服前应先发一个应用层“服务器即将关闭/迁移”的通知 RPC，再 `disconnect_peer(force=false)`，让客户端进入重连流程，而不是静默掉线。
7. **认证前不开放业务 RPC**：`auth_callback` 未完成时不要处理任何农场命令；把命令入口统一放在 `peer_connected` 之后的授权层，避免“认证消息和业务消息混用”。

### 6.3 重连验收要点

- 同一玩家/设备用同一令牌重连，身份和权限不变。
- 撤销后重连被拒绝，且不会重新获得旧权限。
- 断线期间重复提交同一 command ID 只产生一次结果。
- 服务端重启后，客户端能从 `committed_sequence` 恢复，不需要重新发奖。
- 超过 64 条命令的断线场景有明确行为（补齐事件或要求重新拉快照），不能静默重复发奖。

## 7. 服务器搬迁：同一世界、新运行代次

### 7.1 传输层没有连接迁移

Godot 4.7 没有 QUIC 类 [G23]；ENet、WebSocket、WebRTC 的连接都绑定到当前地址/端口，文档没有提供“保持连接、切换地址”的迁移 API [G2][G4][G18]。因此服务器搬迁在传输层一定是“断开 + 重新连接”，客户端需要应用层证明“新地址仍是同一世界的新运行代次”。

### 7.2 现有字段与缺口

- 已有：`world_id`、`committed_sequence`、`rules_version`、包格式版本 [R1][R6]。
- 缺少：`run_generation`、`content_digest`、迁移描述/签名、地址列表、旧代次证明。包 v1 没有这些字段；新增必须走 `format_version` 演进 [R1]。
- 导入世界的 `world_id` 是内容哈希，只用于一次性导入去重；不能把内容哈希当长期世界身份 [R1][R9]。联网前要为导入世界建立稳定 ID 映射。

### 7.3 推荐的迁移描述与客户端校验

服务端在停写、排空已接受命令、生成一致快照与事件尾部后，递增 `run_generation`，并生成迁移描述（由世界私钥签名）。新服务器需要安全获得世界私钥，或由旧服务器预先签署迁移描述；私钥不能放进普通世界包 [R1]。

| 字段 | 作用 |
|---|---|
| `protocol_version` / `rules_version` | 版本协商；不兼容时说明需更新哪一项 [R1] |
| `world_id` | 必须与客户端已知世界一致 |
| `run_generation` | 单调递增，标识新的权威运行实例 |
| `committed_sequence` | 迁移点的已提交序号 |
| `content_digest` | 迁移点状态/事件尾部的 SHA-256 承诺（规范 JSON + 序号 + world_id，不含地址/导出时间） |
| `endpoints` | 新服务器地址/端口/协议（可多个候选） |
| `issued_at` / `expires_at` | 限制旧描述被长期重放 |
| `previous_generation_hash` | 可选，串起代次链，防止跳代/分叉 |
| `signature` | 世界私钥对上述字段的签名（SHA-256）[G14] |

客户端校验顺序：

1. 用首次邀请时固定的世界公钥验证签名；公钥不匹配直接拒绝。
2. `world_id` 必须与本地一致；`rules_version` 必须兼容。
3. `run_generation` 必须严格大于本地记录的最高代次；小于或等于则视为旧服务器/重放，拒绝。
4. `content_digest` 必须与本地最后确认的 `committed_sequence` 对应状态一致，或客户端能用事件尾部从本地序号哈希到新摘要；不一致且无法证明连续 => 视为分叉，拒绝并让用户选择显式新世界，不能自动合并。
5. `issued_at`/`expires_at` 在可接受时钟偏差内；地址来自描述，不从 DNS/广播单独信任。
6. 连接新服务器后，在应用层握手再次核对 `world_id`、`run_generation`、`committed_sequence`、`content_digest`；不能只信 TLS 证书。

### 7.4 旧服务器与新服务器

- 迁移前：旧服务器停写、排空、快照、递增代次、签名描述；旧服务器保持只读或关闭写入。
- 旧服务器必须拒绝继续写入：`refuse_new_connections` 只影响新连接 [G18]，所以至少要在命令入口拒绝所有写命令；更彻底的是同时主动 `disconnect_peer` 所有客户端。不能只设 `refuse_new_connections`。
- 新服务器恢复后，客户端通过签名描述和代次确认；旧服务器即使仍在运行，因代次较低会被客户端拒绝。
- 新旧不能同时接受命令；否则即使有代次，仍可能产生两个分叉状态 [R1][R3]。
- 好友识别：`Player ID` 与世界财产记录不变；`Room ID`/地址可更新；客户端用世界公钥和 `world_id` 识别“同一个人/同一个世界”，不能仅凭同名或同地址 [R1]。

### 7.5 与现有 `World ID`/内容哈希的关系

- `world_id` 是长期身份，内容摘要只是某个提交点的状态承诺；不能用内容摘要替换 `world_id`。
- 内容摘要的计算应复用现有规范 JSON 的排序/规范化方式 [R6]，并覆盖快照 + 事件尾部 + `committed_sequence`；跨 Windows/macOS/无头的浮点序列化一致性需要测试。
- 如果 M4 把内容摘要/事件尾部加入世界包，必须递增 `format_version` 并定义拒绝/兼容规则 [R1]；不能无版本地塞进 v1。

## 8. 推荐方案与回退

### 8.1 主方案

**传输**：`WebSocketMultiplayerPeer` + `wss://`（TLS），客户端/服务端均为 Godot 4.7.2 原生/无头。  
**身份**：世界签名密钥 + 自签 TLS 证书（或 CA 证书）+ 手动邀请码 + `SceneMultiplayer.auth_callback` HMAC 挑战 + 会话令牌。  
**发现**：手动邀请码/地址为主；UDP 广播作为可选提示，不授权。  
**权限**：邀请绑定角色/有效期；服务端逐命令检查访问/照料/收获/建设/管理 [R1]。

选择理由：

1. TLS、WebSocket、`MultiplayerPeer`、`Crypto` 都是引擎内置，不引入新依赖，符合“最小完整方案”和当前早期阶段边界。
2. 低频农场命令只需要可靠有序；TCP 的队头阻塞在这一阶段不是主要问题，换来的是内置 TLS 和更少的自定义安全代码。
3. `SceneMultiplayer.auth_callback` 提供了认证闸门，能在 `peer_connected` 前拒绝未邀请 peer [G17]，直接支撑 M4-01 验收。
4. 手动邀请码不依赖 mDNS/Bonjour/广播，避开 macOS 本地网络权限、Windows 防火墙发现和多网卡问题；仍然需要用户放行入站 TCP 端口，但这是自建服务器的明确成本。
5. 无头 Linux/Windows/macOS 都可以跑 WebSocket 服务端；Web 导出不能做服务端，但不影响本阶段。

### 8.2 回退

**回退 A：`ENetMultiplayerPeer` + DTLS**  
适用条件：WSS 的延迟/吞吐/队头阻塞经实测不满足需求，或需要 UDP 广播/组播发现且愿意承担自定义传输。  
前提：先做原型证明能在不改引擎的情况下通过 `ENetConnection` 的 DTLS 扩展或自定义 `MultiplayerPeer` 启用 DTLS；否则不能把明文 ENet 用于不可信网络。`PacketPeerDTLS`/`DTLSServer` 是另一条备选，但要自行实现可靠性、有序、分片和 peer 管理 [G11][G12]。  
限制：DTLS 文档明确不支持证书吊销与证书固定 [G11]；需要额外的密钥/证书轮换策略。

**回退 B：CA 签发的 TLS + 域名/反向代理**  
适用条件：自签 + IP 直连的证书校验经实测不可行，且部署方能提供域名/反向代理。  
代价：局域网/自建场景下用户需要域名或本地 DNS；不适合“拷贝一个 App 就能建房”的体验。

**不推荐的回退**：明文 `ws://`/裸 ENet + 仅 HMAC。HMAC 能证明邀请持有，但不能保护邀请秘密、令牌和命令内容；路径上的攻击者可窃听/篡改，不能作为互联网或不可信局域网的默认方案。

### 8.3 暂不采用

- **WebRTC**：原生平台需要外部 GDExtension、信令服务器和 STUN/TURN [G8]；M4 是局域网/自建，手动端口映射比引入这些依赖更简单。若以后要求“无端口映射的公网直连”，再评估 WebRTC/TURN。
- **Steam 网络**：GodotSteam 第三方且绑定 Steamworks [S2]；只有在确定 Steam 发行时才考虑。Steam 的强加密/认证/中继能力本身是合适的，但不是跨平台通用方案 [S1]。
- **Noise**：Godot 4.7 没有官方 Noise 协议类 [G23]；需要第三方 GDExtension，增加许可与维护面。
- **mDNS**：没有官方类 [G23]；第三方库 + 平台权限 + Windows Bonjour 依赖，收益不足以抵消首版成本。
- **Nakama**：是身份/社交/多人后端，不是本阶段的传输层；ADR-003 已限定只有在收益超过部署依赖时才评估 [R3][R11]。

## 9. 尚需实测清单

T1/T3 已在本机回环验证（见上）；其余仍未执行。按阻塞程度排序。

| ID | 测试 | 通过标准 | 说明 |
|---|---|---|---|
| T1 | WSS + 自签证书 + IP 直连：`WebSocketMultiplayerPeer.create_client("wss://IP:port", TLSOptions.client(cert, common_name_override))` | macOS/Windows/无头均能完成 TLS 握手；错误证书/错误 CN 被拒绝 | **macOS 已验证**（`tests/m4_auth_test.gd`）：自签 + IP + `common_name_override` 通过；不给 override 时握手失败。Windows 与错误证书/错误 CN 的拒绝仍未测 |
| T2 | 证书指纹计算与固定 | 客户端能从 PEM/证书计算 SHA-256 指纹，与邀请一致；轮换后旧指纹被拒绝 | `X509Certificate` 没有文档化指纹访问器 [G16]，需哈希 `save_to_string()` |
| T3 | `SceneMultiplayer.auth_callback` 闸门 | 未完成 `complete_auth` 时业务 RPC 不可达；失败发 `peer_authentication_failed`；`auth_timeout` 可配置 | **macOS 已验证**：无邀请者被拒、认证前抢先发送的业务 RPC 未被执行；`auth_timeout` 与慢网络仍未测 |
| T4 | WebSocket 传输模式与缓冲 | 确认 `transfer_mode` 在 WebSocket 上的实际行为；64 KiB 缓冲/大快照分块方案可行 | 文档未说明 unreliable/通道 [G4]；默认 65535 字节、4096 包 [G4] |
| T5 | 重连与 64 条账本窗口 | 断线超过 64 条命令后，客户端能靠事件尾部/快照恢复；重复 command ID 不二次发奖 | 当前 `MAX_COMMAND_RESULTS=64` 且 FIFO 淘汰 [R7]；M4-03 必须补 |
| T6 | 迁移代次与旧服务器拒绝写入 | 旧服务器 `refuse_new_connections` + 应用层写拒绝；客户端拒绝低代次/分叉摘要 | `refuse_new_connections` 只影响新连接 [G18]；`close()` 不发 `peer_disconnected` [G18] |
| T7 | UDP 广播发现权限 | Windows 专用/公用网络、macOS 15+ 本地网络权限、沙盒 multicast entitlement 下的行为明确 | Windows 默认阻止未授权入站 [M1]；macOS 权限/entitlement 见 [A1] |
| T8 | mDNS 第三方方案 | 若要做：4.7 兼容、双平台二进制、`NSBonjourServices`、Windows Bonjour/DNS-SD 依赖、许可 | Godot 无官方 mDNS [G23]；不通过则维持手动邀请 |
| T9 | 密钥/证书存储与轮换 | 私钥不进入世界包；身份包加密；轮换有旧钥签名；丢失有明确限制 | 现有身份占位符不可认证 [R1][R8]；R12 风险 [R3] |
| T10 | 跨平台内容摘要 | 同一世界在 Windows/macOS/无头得到相同 `content_digest` | 浮点/JSON 规范化需用现有 canonical JSON 方式验证 [R6] |
| T11 | 性能对照 | WSS 与 ENet+DTLS 在局域网/公网的握手、延迟、吞吐、CPU/内存有配对数据 | 本机当前不可运行 Godot；留待性能测量结束后 |
| T12 | WebRTC 回退可行性 | 仅当需要无端口映射公网直连时：4.7 GDExtension、信令、STUN/TURN 可用 | 原生需外部插件 [G8] |
| T13 | GodotSteam 兼容性 | 仅当 Steam 发行时：4.7 构建、SteamMultiplayerPeer、认证票据 | 第三方、社区版 [S2] |
| T14 | TLS 吊销/CRL 行为 | 明确 WSS 是否检查 CRL/OCSP；若不检查，采用短周期证书/轮换 | DTLS 文档明确不支持吊销/固定 [G11]；WSS 未文档化 |

## 10. 风险与未决项

| 风险 | 影响 | 处置 |
|---|---|---|
| WSS 自签 + IP 直连证书校验不可行 | 主方案需要域名/反向代理或改回 ENet+DTLS | T1 先做；失败则回退 B/A |
| WebSocket TCP 队头阻塞/仅可靠有序 | 高频同步体验差 | 农场命令低频可接受；若未来需要移动同步，回退 ENet |
| 64 条幂等窗口 | 长断线重连重复发奖或无法确认命令 | M4-03 持久事件尾部/快照；不要把 64 条当长期保证 [R7] |
| 高层协议是引擎实现细节、可能变化 | 跨 Godot 版本/非 Godot 服务端不兼容 | 锁定 4.7.2；应用层握手带协议版本；不承诺跨引擎线协议 [G17] |
| macOS 本地网络权限/沙盒 entitlement | 发现和局域网直连被拒，用户看到“连不上” | 加 `NSLocalNetworkUsageDescription`；必要时 `NSBonjourServices`；沙盒评估 multicast entitlement [A1][G25] |
| Windows 防火墙/公共网络配置 | 服务端入站被阻止 | 首次监听提示用户放行专用网络；提供手动端口转发说明 [M1] |
| 证书轮换/吊销/固定限制 | 旧证书长期可用或客户端无法识别轮换 | 邀请带指纹；轮换由世界密钥签名；短周期证书；T14 验证吊销 [G11] |
| 世界私钥丢失 | 无法证明同一世界连续性 | 备份/恢复材料；丢失时显式重新邀请，不承诺自动找回 [R1][R3] |
| 邀请码短/弱 | 可被暴力猜测 | 至少 128 位随机；限速/锁定；一次性优先 [G14] |
| 旧服务器仍接受写入 | 双写/分叉 | 停写+代次+签名迁移描述；旧服务器应用层拒绝写入 [R1][R3][G18] |
| UDP 广播/mDNS 伪造 | 客户端被引到恶意服务器 | 发现只作提示；必须用邀请/世界公钥二次验证 [A1] |
| WSS 大快照超过 64 KiB | 同步失败/分块复杂 | 事件/快照分块或独立 HTTP 下载；T4 实测 [G4] |

未决项（需要 M4-01 决策记录明确）：

- 自签证书 + 固定链 vs CA 证书 + 域名：取决于 T1/T2 结果。
- 会话令牌 TTL、刷新周期、是否绑定设备 ID/世界代次。
- 邀请是一次性还是可多用；短码是否允许（若允许，限速/锁定策略）。
- 世界私钥的存储方式（文件权限/口令加密/系统密钥环）与备份责任。
- 导入世界联网前的稳定 `world_id` 映射规则。
- 是否在 M4-02 就做 UDP 广播发现，还是先只做手动邀请码。

## 11. 来源

### Godot 4.7 官方文档（2026-11-15 读取）

- [G1] High-level multiplayer: https://docs.godotengine.org/en/4.7/tutorials/networking/high_level_multiplayer.html
- [G2] ENetMultiplayerPeer: https://docs.godotengine.org/en/4.7/classes/class_enetmultiplayerpeer.html
- [G3] ENetConnection: https://docs.godotengine.org/en/4.7/classes/class_enetconnection.html
- [G4] WebSocketMultiplayerPeer: https://docs.godotengine.org/en/4.7/classes/class_websocketmultiplayerpeer.html
- [G5] WebSocketPeer: https://docs.godotengine.org/en/4.7/classes/class_websocketpeer.html
- [G6] WebRTCMultiplayerPeer: https://docs.godotengine.org/en/4.7/classes/class_webrtcmultiplayerpeer.html
- [G7] WebRTCPeerConnection: https://docs.godotengine.org/en/4.7/classes/class_webrtcpeerconnection.html
- [G8] WebRTC tutorial: https://docs.godotengine.org/en/4.7/tutorials/networking/webrtc.html
- [G9] TLSOptions: https://docs.godotengine.org/en/4.7/classes/class_tlsoptions.html
- [G10] TLS/SSL certificates tutorial: https://docs.godotengine.org/en/4.7/tutorials/networking/ssl_certificates.html
- [G11] PacketPeerDTLS: https://docs.godotengine.org/en/4.7/classes/class_packetpeerdtls.html
- [G12] DTLSServer: https://docs.godotengine.org/en/4.7/classes/class_dtlsserver.html
- [G13] StreamPeerTLS: https://docs.godotengine.org/en/4.7/classes/class_streampeertls.html
- [G14] Crypto: https://docs.godotengine.org/en/4.7/classes/class_crypto.html
- [G15] CryptoKey: https://docs.godotengine.org/en/4.7/classes/class_cryptokey.html
- [G16] X509Certificate: https://docs.godotengine.org/en/4.7/classes/class_x509certificate.html
- [G17] SceneMultiplayer: https://docs.godotengine.org/en/4.7/classes/class_scenemultiplayer.html
- [G18] MultiplayerPeer: https://docs.godotengine.org/en/4.7/classes/class_multiplayerpeer.html
- [G19] UDPServer: https://docs.godotengine.org/en/4.7/classes/class_udpserver.html
- [G20] PacketPeerUDP: https://docs.godotengine.org/en/4.7/classes/class_packetpeerudp.html
- [G21] IP: https://docs.godotengine.org/en/4.7/classes/class_ip.html
- [G22] UPNP: https://docs.godotengine.org/en/4.7/classes/class_upnp.html
- [G23] Class index（用于确认 MDNS/Noise/QUIC 无官方类）: https://docs.godotengine.org/en/4.7/classes/index.html
- [G24] HashingContext: https://docs.godotengine.org/en/4.7/classes/class_hashingcontext.html
- [G25] Exporting for macOS: https://docs.godotengine.org/en/4.7/tutorials/export/exporting_for_macos.html

### 平台与第三方

- [A1] Apple TN3179: Understanding local network privacy: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- [M1] Windows Firewall overview: https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/
- [S1] Steamworks ISteamNetworkingSockets: https://partner.steamgames.com/doc/api/ISteamNetworkingSockets
- [S2] GodotSteam (Codeberg): https://codeberg.org/GodotSteam/GodotSteam

### 仓库内依据

- [R1] `docs/2.0/05-DATA-AND-NETWORK.md`：身份/世界包/迁移/握手/权限契约。
- [R2] `docs/2.0/milestones/M4/PLAN.md`：M4-01 范围与验收。
- [R3] `docs/2.0/decisions/ADR-003-storage.md`：单写者、事务提交、Nakama 评估边界。
- [R4] `docs/2.0/09-QUALITY-GATES.md`：Q6 权限联机门槛。
- [R5] `Game/world/headless_world.gd`：无头世界不访问网络/场景/GPU。
- [R6] `Game/farm/world_package.gd`：包字段、规范 JSON、v1 无内容摘要。
- [R7] `Game/farm/farm_state.gd`：命令结果 64 条 FIFO、事件序号。
- [R8] `Game/farm/v27_importer.gd`：`player_id`/`device_id` 随机占位、内容哈希派生世界 ID。
- [R9] `docs/2.0/milestones/M0/RECORD-04-v27-import.md`：导入内容哈希只作一次性键的限制。
- [R10] `docs/2.0/decisions/ADR-001-authority.md`：单写者与有限迁移的产品边界。
- [R11] `docs/2.0/research/nakama.md`：Nakama 仅作候选，未选定。
- [R12] `rules/project-context.md`：项目锁定 Godot 4.7.2 与 macOS/Windows 开发环境事实。
