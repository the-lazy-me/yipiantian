# ADR-029 · 玩家身份绑定（安装凭据 + 世界侧 TOFU）

- 状态：裁决完成并已实现（2026-11-15）；证据见文末。
- 关联：[ADR-004 联机传输与身份](ADR-004-transport.md)、[ADR-005 村落物资归属](ADR-005-player-bags.md)、[ADR-019 共享世界经济命令](ADR-019-economy-command-permissions.md)、[ADR-027 摘要可见性](ADR-027-summary-visibility.md)、[RISKS R16](RISKS.md)、[M4-08 本机玩家档案](../milestones/M4/RECORD-08-player-profile.md)、[M4-13 身份绑定](../milestones/M4/RECORD-13-identity.md)。
- 范围：只决定“有名玩家加入世界时，权威如何确认这个 `player_id` 还是上次那个人”；不改动邀请认证、角色/权限、经济记账、社交记录形状，不改变农场格式 27 与 `PROTOCOL_VERSION`。

## 背景

[R16](RISKS.md) 记录的核心缺口：`player_id` 只是加入请求里的一个字符串，任何拿到有效邀请的人都可以声称自己是某个已存在的玩家，从而接管那个 id 的口袋、账户、消息和地籍记录。此前的防线只有“同一时刻一个 `player_id` 只能有一个连接”（`player_id_in_use`），它能挡住并发冒用，但挡不住“等本人下线后再冒充”。

[M4-08](../milestones/M4/RECORD-08-player-profile.md) 已经交付了本机档案：`player.json` 里有一个跨启动稳定的 `player_id`，但它明确写着“身份仍是本机声明，没有密钥、没有签名”。ADR-004 的三层身份里，设备会话层原本只打算做短期令牌；真正需要的是一个**长期随安装走、不出本机**的凭据。

本 ADR 补这一层，并把风险降级为“首次认领仍是信任首次使用”。

## 决定

### 1. 安装凭据：32 字节随机值，存 `player.key`

- 客户端在 `player/player.key` 保存 32 字节随机凭据，base64 文本，44 个字符；与 `player.json` 同目录、不同文件。
- 首次生成后立刻写盘并回读比对；读回不一致、写失败或目录不可建时，`player_secret` 保持为空并 `push_warning("PLAYER_PROFILE stage=key_*")`，不以“这次会话能用”的假象继续。
- 读取时先做字母表/长度预检再解码，避免引擎对非法 base64 打印 ERROR；损坏的 key **不覆盖、不重新生成**，只报告 `key_invalid`。这样操作者还能从备份恢复原凭据，而不是在不知情时变成另一个人。
- `player.json` 的版本、字段与读写流程不变；没有迁移，也没有把 key 塞进档案文档。

### 2. 线上只出现“世界作用域证明”，凭据永不出本机

加入载荷携带：

```text
player_id:    "player_<32 hex>"
display_name: "…"
player_proof: base64(HMAC-SHA256(player.key 的 32 字节,
                                 "yipiantian.player.v1\n" + world_id))
```

- 权威按 `player_id` 绑定的是这份 32 字节证明，而不是安装凭据本身。一个世界的房主即使记录下证明，也不能在另一个世界重放：不同 `world_id` 得到不同证明，而由证明反推凭据或计算另一世界的证明需要 HMAC 密钥。
- 证明通过 pinned WSS 随加入请求发送，与邀请认证发生在同一条已认证连接上；权威从不回传证明，摘要投影（[ADR-027](ADR-027-summary-visibility.md)）也不含绑定文档。
- `PROTOCOL_VERSION` 保持 1：协议版本描述文档形状与 RPC 集合；这次加入的 `player_proof` 是新增的可选字段，旧客户端不带它时只会得到 `invalid_player`，不会误以具名身份进入。

### 3. 权威侧：信任首次使用（TOFU），失败即具名拒绝

`WorldHost.join` 的门禁顺序保持既有优先级，身份校验位于“名称/格式合法”与“同一 id 无活跃连接”之后、消耗邀请之前：

```text
protocol_version → rules_version → world_id
→ _valid_player_claim（id/显示名/证明形状）
→ _player_peer（player_id_in_use）
→ _verify_player（已绑定则常数时间比较；未绑定则绑定并落盘）
→ _spend(grant_id)
```

- **已绑定**：`Crypto.constant_time_compare` 比较证明；不一致返回 `player_proof`，不改动绑定。
- **未绑定**：`PlayerBindingState.bind` 生成候选文档，`PlayerBindingStore.save_state` 先写 `player_bindings.pending.json` 再原子重命名；只有落盘成功才替换内存文档并放行。写失败返回 `save_player_bindings_<kind>`，加入被拒，不会出现“这次能用、重启就丢”的静默绑定。
- **只读权威**（停写/退役）：已知 id 仍校验证明；未知 id 放行但不绑定、不写盘，由下一次可写权威在本人首次加入时绑定。
- 绑定文档损坏或版本不认识时，`configure()` 返回 `player_bindings_corrupt` / `player_bindings_unsupported`，权威拒绝启动；不猜、不迁移、不用空表覆盖。
- 绑定先于邀请消耗：证明错误时邀请不会被烧掉，本人可用正确档案重试；同时也不存在“先烧邀请再发现身份不对”的半途状态。

### 4. 文档与上限

```text
player_bindings.json（世界目录）
{ "version": 1,
  "state": { "players": { "<player_id>": { "secret": "<base64 证明>", "created_utc": 12.5 } } } }
```

- `MAX_PLAYERS = 1024`；每个条目只允许 `secret` 与 `created_utc` 两个键，多一个键即整份拒绝，避免旧权威静默丢弃未来字段。
- 存储仿 `territory_store`：64 KiB 文档上限、严格校验、pending + rename、缺失文件返回空表。

### 5. 客户端拒绝路径

- `main.gd` / `startup.gd` 把 `player_proof`、`invalid_player`、`player_bindings_unavailable`、`player_invalid_secret`、`save_player_bindings_*` 翻成中文原因，例如“这个世界登记的是另一个玩家档案；换回原来的档案，或请房主重置这个身份的绑定”。
- 匿名加入（空 `player_id`）不发送任何身份字段，行为与以前一致；有 id 但没有可用凭据时仍会带着 id 尝试，权威按 `invalid_player` 拒绝，而不是静默降级为匿名——降级会让人以为社交记录还在。

## 替代方案与取舍

| 方案 | 结论 |
|---|---|
| 把凭据直接放进 `player.json` | 否。档案损坏会自动换 id，凭据跟着换会把身份和凭据生命周期绑死；分开文件也便于单独备份/恢复与单独报错 |
| 跳过 WSS，改用邀请 HMAC 挑战 | 不适用。邀请证明的是“被邀请过”，多个成员共享同一邀请；身份需要每条连接、每个 id 独立作答，本轮不做第二套挑战协议 |
| 权威保存可逆哈希（如 SHA-256(证明)） | 否。证明本身就是高熵随机派生值，保存原值即可做常数时间比较；再加哈希不改变冒用模型，却增加一次不可逆复位带来的运维负担 |
| 面向玩家的密钥轮换/重置界面 | 本轮不做。房主删除该 id 的绑定条目即可重置；界面化留到需要时 |
| 服务器挑战 + 客户端签名（公钥身份） | 留作正式身份层。那时 `player_id` 与密钥对绑定，本 ADR 的绑定文档可整表迁移为公钥表 |

## 残留

- **首次认领是 TOFU**：在本人第一次加入某世界之前，任何持有有效邀请的人都能抢先绑定这个 id。之后的所有连接都必须出示同一证明。
- **新 id 领取开户赠款**：本 ADR 的证明被用作成员证据（同一证明 = 同一安装），另见 [M4-14](../milestones/M4/RECORD-14-grant-limit.md)：同一安装的别名无法二次领取；删除/重建 `player.key` 则等同于新安装，会作为新成员领取一次。
- **绑定文档不在世界导出包内**：与 `territory.json` 等 sidecar 一样，导出世界不会携带它；迁移/备份需要整目录。丢失它的后果是所有人退化为 TOFU，而不是世界打不开。
- **没有 revocation 与轮换入口**：房主只能手工删条目；没有“我换电脑了”的迁移流程，旧电脑上的 `player.key` 仍是唯一凭据。
- **没有文件权限加固**：`player.key` 依赖用户目录权限，未显式 chmod。
- **邀请层未改**：仍以“持有有效邀请”为加入前提，本 ADR 不把邀请升级为可追责的成员身份。

## 证据

| 验证 | 结果 |
|---|---|
| `PLAYER_IDENTITY_TEST` | `checks=41 failures=0`：首次绑定、同证明通过、他证 `player_proof`、重启保持、只读不写、状态形状严格、join 载荷匿名/缺凭据/带证明、证明跨世界不同、凭据不出现在载荷、`player.key` 生成/稳定/损坏不覆盖、损坏与不支持版本拒绝启动 |
| `M4_JOIN_TEST` | `checks=67 failures=0`：真实 WSS 上正确证明加入、错误证明 `player_proof`、拒绝后正确证明仍可加入、名册出现该 id |
| 回归 | `M4_PRESENCE_TEST 38/0`、`M4_RECONNECT_TEST 31/0`、`M4_ACTIVITY_TEST 18/0`、`M4_CLIENT_SCENE_TEST 42/0`、`M4_ECONOMY_COMMANDS_TEST 162/0`、`M4_SERVER_TEST 79/0`、`M4_HOSTING_TEST 25/0`、`VISITOR_JOIN_CODE_TEST 28/0`、`M5_GIFT_TEST 38/0`、`M5_GRANT_TEST 56/0`、`M5_SOCIAL_TEST 58/0`、`VILLAGE_BETA_TEST 116/0`、`PLAYER_PROFILE_TEST 39/0` |
| 未验证 | Windows、真实多机/多世界、房主手工删除条目后的复位流程、`player.key` 丢失后的恢复演练 |

## 后续

- R16 的赠款半边：按邀请/成员资格限制开户发行，避免换 id 重复领取。
- 房主侧重置入口（面板或命令行），以及 `player.key` 备份提示进入玩家指南与自托管文档。
- 正式身份层（挑战-签名或公钥）落地时，把 `players` 表迁移为公钥表并保留现有 `created_utc` 以维持审计。
