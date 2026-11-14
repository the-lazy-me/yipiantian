# M4-02 · 创建与加入（权威世界 + 成员客户端）

执行日期：2026-11-15。状态：切片完成，不表示 M4 或 M4-02 验收完成。传输与身份裁决见 [ADR-004](../decisions/ADR-004-transport.md)。

## 实现

- `Game/world/world_invite.gd`（M4-02 第二轮）：邀请从“一个裸密钥”升级为**授权条目**：
  - 每条授权含独立 id、≥256 位密钥、角色（`member`/`visitor`）、所属 `world_id`、可选到期时间与是否一次性；
  - `encode()` / `decode()` 提供可分享的 `FARM1.` 前缀码，粘贴时容忍换行与空白；解码有大小上限，并对每个字段做类型与范围校验；
  - 角色权限表 `PERMISSIONS`：`member` 可收获/播种/浇水/除草/翻土，`visitor` 只能照料（浇水、除草）；
  - 一次性授权在**加入时**而非认证时消耗——证明密钥不应提前烧掉邀请；
  - 人工与已提交命令的权威判断仍在宿主：`execute_for_member()` 按宿主记录的角色拒绝越权命令（`forbidden`），不采信客户端的自称。
- `Game/world/world_host.gd`：共享世界的权威宿主节点。持有一个 `HeadlessWorld`、授权表与世界身份；两道闸门依次是
  1. **认证**：`SceneMultiplayer.auth_callback` 下的 HMAC-SHA256 挑战应答。客户端第一条消息只报授权 id，宿主无论该 id 是否存在都回一次性挑战，因此无法通过响应探测哪个邀请存在；
  2. **加入**：`join` 校验 `protocol_version`、`rules_version`、`world_id`，再检查该授权是否可用（已用/过期/已撤销都返回具名原因）。
  - 命令入口 `submit` 只在成员集合内接受；解析失败、payload 超长、命令不合法、角色越权都有明确原因。命令走 `HeadlessWorld.execute()`，因此仍是“先由 FarmStore 原子提交，再接受进内存”。
  - `revoke_grant()` 不仅让后续加入失败，还会断开已经用该授权建立的会话，否则撤销只对“还没来的人”生效。
  - RPC 路由按节点路径匹配，宿主与成员必须使用同一个节点名（`SESSION_NODE_NAME = "WorldSession"`）。
- `Game/world/world_member.gd`：成员侧。认证完成后再 `join`，核对宿主的协议/规则/世界身份；`submit_command` 在未加入时直接拒绝，不会把本地缓存当作已提交。服务器序号回退视为权威丢失（`stale_sequence`）。
- 拒绝加入时先回执、短暂延迟再断开，避免用户只看到“连接被断开”而拿不到原因。

## 验证

`tests/m4_join_test.gd` 启动真实宿主进程与四个真实成员进程（`--headless`、回环 WSS、自签证书、隔离目录 `.local/verification/m4-join-*`）：

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 240 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m4_join_test.gd"
```

结果：`M4_JOIN_TEST checks=54 failures=0`（第三轮加入“摘要附带完整快照”的恢复断言后）；`WORLD_INVITE_TEST checks=33 failures=0` 覆盖纯规则部分。

| 用例 | 断言 | 结果 |
|---|---|---|
| 匹配客户端 | 加入成功，回执带宿主 `world_id` 与 `run_generation` | 通过 |
| 命令提交 | 播种命令被接受，`sequence` 变为 1 | 通过 |
| 同 id 重试 | 第二次提交返回 `duplicate=true`，序号不二次推进 | 通过 |
| 世界不符 | 拒绝，原因 `world_mismatch` | 通过 |
| 协议版本不符 | 拒绝，原因 `protocol_version` | 通过 |
| 无邀请 | 认证阶段即失败，从未加入 | 通过 |
| 一次性授权 | 首个持有者加入成功；第二个得到 `invite_used` | 通过 |
| 访客权限 | 加入成功、`role=visitor`；收获被拒 `forbidden`，浇水成功 | 通过 |
| 过期授权 | 拒绝，原因 `invite_expired` | 通过 |
| 摘要快照 | 成员从 `summary.snapshot` 重建完整世界：序号、布局、自己的播种、季节与摆设 | 通过 |
| 宿主汇总 | 3 个成员加入、2 条命令提交、落盘世界序号为 2 | 通过 |
| 磁盘权威 | `FarmStore.load_state()` 读回 `transaction.sequence == 2` | 通过 |

`tests/world_invite_test.gd` 独立覆盖授权本身：编码往返（含换行粘贴）、每次签发密钥不同、缺字段/非 base64/无前缀/未知角色/过短密钥全部拒绝、到期语义（0 表示不过期）、一次性消耗、角色权限表。

用例已加入 `.github/workflows/rule-tests.yml`。

## 未覆盖

- 只测回环、单机、无 NAT、无防火墙；没有跨机器、真实网卡或 Windows 手工验证（CI 会跑同一用例）。
- 权限只区分 `member` / `visitor` 两个角色，粒度为命令种类。访问、照料、收获、建设、管理的逐命令权限矩阵与按地块/建筑的授权尚未实现。
- 没有世界包导入后的稳定 `world_id` 映射；当前世界身份由宿主参数给定。
- 授权表只在内存中，进程重启即丢失；部署入口每次启动重新登记一条长期授权（见 [M4-05](RECORD-04-deploy.md)），没有授权持久化或管理界面。
- 没有邀请分享界面（二维码/复制按钮）：`WorldInvite.encode()` 已给出可分享字符串，UI 未接入。
- 未测断线重连、`auth_timeout` 调整、事件尾部补齐，也没有把 `run_generation` 用于迁移（属 M4-04）。

## 关联

- [ADR-004 传输与身份](../decisions/ADR-004-transport.md)；研究稿：[m4-connectivity](../../research/m4-connectivity.md)。
- 无头世界：[M3-01](../M3/RECORD-01-headless.md)；事务账本：[M3-03](../M3/RECORD-03-commit-recovery.md)。
- 阶段计划：[M4 PLAN](PLAN.md) M4-02。
