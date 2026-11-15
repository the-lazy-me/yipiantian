# M4-13 · 玩家身份绑定（切片）

执行日期：2026-11-15。状态：切片完成，不表示 M4 或验收完成。前置：[M4-08 本机玩家档案](RECORD-08-player-profile.md)、[M5 RECORD-01 社交记录](../M5/RECORD-01-social.md)，裁决见 [ADR-029](../../decisions/ADR-029-player-identity-binding.md)。

## 问题

M4-08 交付了跨启动稳定的 `player_id`，但它只是加入请求里的一个字符串。任何拿到有效邀请的人都能声称自己是某个已经存在的玩家：并发冒用靠“同一时刻一个 id 只有一个连接”挡住，本人下线之后再冒充则没有任何机制。R16 因此只能标为“部分关闭”。

本切片给具名身份加一层安装凭据：客户端本机保存 32 字节随机值，加入时只出示由它和 `world_id` 派生的 HMAC 证明；权威按 `player_id` 绑定首个证明，之后的连接必须出示同一个。

## 实现

### 客户端

| 文件 | 改动 |
|---|---|
| `Game/social/player_profile.gd` | 新增 `player.key`（32 字节，base64 44 字符）。首次生成写盘并回读校验；损坏只 `push_warning("PLAYER_PROFILE stage=key_*")`，不覆盖、不重生成，`player_secret` 留空。`player.json` 字段与版本不变 |
| `Game/world/world_member.gd` | `join_payload()` 在具名加入时发送 `player_proof = base64(HMAC-SHA256(player.key, "yipiantian.player.v1\n" + world_id))`；匿名加入不发送身份字段；没有可用凭据时不伪造证明 |
| `Game/world/world_client.gd` | `start(..., profile_secret)` 把档案凭据交给成员；重连复用 |
| `Game/scenes/startup.gd` | 启动时把档案凭据传入；新增 `player_proof`/`player_invalid_secret`/`player_bindings_unavailable`/`invalid_player`/`save_player_bindings_*` 的中文原因 |
| `Game/scenes/main.gd` | 房间面板加入失败的同类中文原因 |

凭据本身从不出本机：一个世界即便记录了证明，也不能在另一个世界重放，因为另一世界的证明需要 HMAC 密钥才能算出。

### 权威

| 文件 | 改动 |
|---|---|
| `Game/world/player_binding_state.gd`（新增） | 纯规则：`proof()` 派生、`bind()`、`matches()`（`Crypto.constant_time_compare`）、严格文档校验（每 id 只允许 `secret` 与 `created_utc`，上限 1024） |
| `Game/world/player_binding_store.gd`（新增） | `player_bindings.json` sidecar：64 KiB 上限、`{version, state}` 信封、pending + rename 原子写、缺失返回空表 |
| `Game/world/world_host.gd` | `configure()` 加载绑定文档，损坏/版本不支持拒绝启动；`join()` 在格式与并发唯一之后、消耗邀请之前校验证明：已绑定常数时间比较，未绑定先落盘再放行；只读权威校验已知 id、不新增绑定 |

门禁顺序：`protocol_version → rules_version → world_id → 身份字段形状 → player_id_in_use → 证明 → 消耗邀请`。证明错误时邀请不会被烧掉。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 120 "$GODOT" --headless --path Game \
  --script "$PWD/tests/player_identity_test.gd"
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m4_join_test.gd"
```

原始末行：

```text
PLAYER_IDENTITY_TEST checks=41 failures=0
M4_JOIN_TEST checks=67 failures=0 dir=…/m4-join-…
```

| 用例 | 检查 |
|---|---|
| 首次绑定 | 新世界无绑定；首个证明绑定该 id 并落盘；同证明再次通过；第二个 id 独立绑定 |
| 冒用拒绝 | 他证返回 `player_proof` 且不覆盖原绑定；缺证明被拒 |
| 重启保持 | 重开同一世界后正确证明通过、错误证明仍 `player_proof` |
| 只读 | 未知 id 放行但不写 `player_bindings.json` |
| 证明形状 | 32 字节 base64；短证明、缺创建时间、额外键、非法 id 整份拒绝；store 拒绝下一次加载会拒绝的文档 |
| 加入载荷 | 匿名无身份字段；具名缺凭据只有 id；有凭据时证明等于派生值、**不等于**安装凭据；换 world_id 证明不同 |
| 档案 | `player.key` 生成 32 字节并写盘；重启同一凭据；损坏 key 保留文件、保留 id、不自动换证 |
| 损坏/版本 | `player_bindings.json` 非法 JSON → `player_bindings_corrupt`；`version: 99` → `player_bindings_unsupported` |
| 真实会话 | `M4_JOIN_TEST` 三个身份用例：正确证明加入；错误证明 `player_proof`；拒绝后正确证明仍可加入且名册出现该 id |

回归：`PLAYER_PROFILE_TEST 39/0`、`M4_PRESENCE_TEST 38/0`、`M4_RECONNECT_TEST 31/0`、`M4_ACTIVITY_TEST 18/0`、`M4_CLIENT_SCENE_TEST 42/0`、`M4_ECONOMY_COMMANDS_TEST 162/0`、`M4_SERVER_TEST 79/0`、`M4_HOSTING_TEST 25/0`、`VISITOR_JOIN_CODE_TEST 28/0`、`M5_GIFT_TEST 38/0`、`M5_GRANT_TEST 56/0`、`M5_SOCIAL_TEST 58/0`、`VILLAGE_BETA_TEST 116/0`。

## 未覆盖

- **首次认领仍是 TOFU**：本人第一次加入某世界之前，持有效邀请者可抢先绑定该 id。
- 没有面向房主的重置/撤销入口，只能手工删除 `player_bindings.json` 中的条目；没有“换电脑”迁移流程。
- 绑定文档不进入世界导出包；迁移只带 `world.json` 会丢失绑定（见 [R28](../../decisions/RISKS.md)）。
- `player.key` 未做文件权限加固；丢失后以原 id 加入会被拒，只能恢复文件或请房主重置。
- 邀请本身仍是唯一的入门口令；本切片不把邀请升级为可追责的成员身份。
- 新 `player_id` 在同一安装下的开户赠款已由 [RECORD-14](RECORD-14-grant-limit.md) 关闭；删除/重建 `player.key` 仍等于新成员。
- Windows、真实多机多世界、丢失与迁移演练均未验证。

## 关联

- 身份分层：[ADR-004](../../decisions/ADR-004-transport.md)；本切片裁决：[ADR-029](../../decisions/ADR-029-player-identity-binding.md)。
- 档案：[M4-08](RECORD-08-player-profile.md)；社交归属：[M5 RECORD-01](../M5/RECORD-01-social.md)。
- 风险：[R16](../../decisions/RISKS.md)、[R28](../../decisions/RISKS.md)。
