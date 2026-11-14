# M4-02 · 创建与加入（权威世界 + 成员客户端）

执行日期：2026-11-15。状态：切片完成，不表示 M4 或 M4-02 验收完成。传输与身份裁决见 [ADR-004](../decisions/ADR-004-transport.md)。

## 实现

- `Game/world/world_host.gd`：共享世界的权威宿主节点。持有一个 `HeadlessWorld`、邀请秘密与世界身份；两道闸门依次是
  1. **认证**：`SceneMultiplayer.auth_callback` 下的 HMAC-SHA256 挑战应答，决定 peer 能不能成为会话成员；
  2. **加入**：`join` 校验 `protocol_version`、`rules_version` 与 `world_id`，不匹配时返回具名原因并断开。
  - 命令入口 `submit` 只在成员集合内接受；解析失败、payload 超长、命令不合法都有明确原因。命令走 `HeadlessWorld.execute()`，因此仍是“先由 FarmStore 原子提交，再接受进内存”。
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

结果：`M4_JOIN_TEST checks=31 failures=0`。

| 用例 | 断言 | 结果 |
|---|---|---|
| 匹配客户端 | 加入成功，回执带宿主 `world_id` 与 `run_generation` | 通过 |
| 命令提交 | 播种命令被接受，`sequence` 变为 1 | 通过 |
| 同 id 重试 | 第二次提交返回 `duplicate=true`，序号仍为 1，不二次生效 | 通过 |
| 世界不符 | 拒绝，原因 `world_mismatch` | 通过 |
| 协议版本不符 | 拒绝，原因 `protocol_version` | 通过 |
| 无邀请 | 认证阶段即失败，从未加入 | 通过 |
| 宿主汇总 | 仅 1 个成员加入、仅 1 条命令提交、落盘世界序号为 1 | 通过 |
| 磁盘权威 | `FarmStore.load_state()` 读回的 `transaction.sequence == 1` | 通过 |

用例已加入 `.github/workflows/rule-tests.yml`。

## 未覆盖

- 只测回环、单机、无 NAT、无防火墙；没有跨机器、真实网卡或 Windows 手工验证（CI 会跑同一用例）。
- 权限只区分“成员/非成员”。访问、照料、收获、建设、管理的逐命令权限矩阵尚未实现。
- 没有世界包导入后的稳定 `world_id` 映射；当前世界身份由宿主参数给定。
- 未测并发两名成员同时操作同一地块（只有一个成员进程在提交）。
- 未实现邀请码的编码/分享界面、一次性使用、有效期与撤销；`secret` 目前是测试直接传递的 32 字节。
- 未测断线重连、`auth_timeout` 调整、事件尾部补齐，也没有把 `run_generation` 用于迁移（属 M4-04）。

## 关联

- [ADR-004 传输与身份](../decisions/ADR-004-transport.md)；研究稿：[m4-connectivity](../../research/m4-connectivity.md)。
- 无头世界：[M3-01](../M3/RECORD-01-headless.md)；事务账本：[M3-03](../M3/RECORD-03-commit-recovery.md)。
- 阶段计划：[M4 PLAN](PLAN.md) M4-02。
