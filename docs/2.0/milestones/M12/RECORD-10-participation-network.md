# M12-02 · 参与制度真实网络测试（切片）

执行日期：2026-11-16。状态：切片完成，不表示 M12-02 或 M12 验收完成。前置：[RECORD-09 · 参与制度接入世界权威](RECORD-09-participation-authority.md)。

## 问题

RECORD-09 只在同进程无头夹具里验证；频道 17/18 是否真的经过 WSS、`--host-player` 是否进入状态文件、网络重试是否仍返回 `duplicate`、重启后房主绑定是否成立，都没有在真实服务器进程上跑过。本切片补真实网络端到端测试，并修复它暴露的两处生产缺陷。

## 边界

- 新增 `tests/participation_network_test.gd`。
- 修复 `Game/world/world_server.gd`（状态文件缺少 `host_player`）与 `Game/world/headless_world.gd`（重试时间不稳定导致 `command_conflict`）。
- 未改其它 `Game/` 代码、`rules/`、玩家指南或农场格式。

## 修复

### 状态文件缺少房主

`server-status.json` 的写盘载荷没有 `host_player`，而 ready 行有；开房客户端与运维只能从状态文件读到世界事实。现在 `world_server.gd` 把 `host_player` 保存在成员变量里，ready 行与状态文件写同一值。

### 重试时间不稳定

`execute_participation()` 每次请求都取新的 `authority_now_utc()`，而规则的幂等载荷包含声明/同意/退战时间。同一 `request_id`、同一参数隔几毫秒重发时，只有时间不同，`_replay()` 逐字节比较后返回 `command_conflict`，永远到不了持久 command id 的 `duplicate` 分支；重启后同样。这使网络的正常重试与真正的换参数冲突不可区分。

修复：`_participation_action_time()` 在调用规则前检查该 command id 是否已是文档里的耐久命令——`regime.command_id`、参与者的 `consent_command_id` / `withdraw_command_id`；命中时复用首次的 `declared_utc` / `consent_utc` / `withdraw_utc`，否则取权威时钟。只有 id 真正对得上才复用旧时间，规则随即走自己的重放分支；换参数仍由规则判 `command_conflict`。该标记随文档持久化，重启后同样成立。

## 场景

测试用唯一空闲端口启动真实 `world_server.gd`（`--host-player=PLAYER_A`、`--data-dir=.local/verification/participation-network-<ticks>/world`、`--run-seconds=0`、`--join-url`），等待 `server-status.json` 为 running，再用 `WorldClient` 走真实 WSS：

1. ready 行与状态文件都记录 `host_player=PLAYER_A`。
2. 成员 A 加入，`state` 为 available、peace、revision 0、host=A。
3. 非房主 B 声明 `not_host`；房主 A 声明 limited+higher_risk+区域+窗口+上限成功，revision=1 且落盘。
4. 同 request_id 重放 `duplicate`，`participation.json` 逐字节不变；换声明同 id `command_conflict`。
5. A `declare` attacker 成功；同 id 重放 `duplicate`。
6. B `declare` defender、`withdraw` 成功，延迟 3600 秒；再 `declare` 返回 `withdrawal_pending`。
7. 访客写 `forbidden`、匿名写 `no_player`，两者仍可读 `state`。
8. 超过 48 KiB 的原始请求 `payload_too_large`，随后 `state` 正常。
9. 优雅停止后同目录、同 host、新端口重启：声明、参与者、退战延迟仍在，同声明 command id 重放 `duplicate`。
10. 用 `--host-player=PLAYER_C` 启动同一目录失败（`host_mismatch`），原文档字节不变。
11. 关闭客户端、写 `stop`，进程退出且状态为 `stopped`。

两个具名成员使用不同安装凭据（ADR-029），顺序连接（`WorldClient` 固定会话路径 `/root/WorldSession`）。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
cd /Volumes/Disk-1tb/yipiantian
perl -e 'alarm shift; exec @ARGV' 420 "$GODOT" --headless --path Game \
  --script "$PWD/tests/participation_network_test.gd"
```

修复前原始末行（失败断言稳定复现两处缺陷）：

```text
PARTICIPATION_NETWORK_TEST checks=100 failures=5 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/participation-network-324210
```

修复后：

```text
PARTICIPATION_NETWORK_TEST checks=100 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/participation-network-343601
PARTICIPATION_AUTHORITY_TEST checks=114 failures=0
```

## 未覆盖

- 无 `--host-player` 的 hostless 网络路径（权威测试已覆盖 `no_host`，网络侧未重复）。
- 真实交战与损失上限：本切片没有 `engage` 入口。
- 答复侧 48 KiB 超预算：参与视图受上限约束，当前不可达；只覆盖请求侧。
- 限流 `rate_limited` 未专门构造；同 id 更换 action/role 的冲突只覆盖了声明。
- 两个客户端同时在线；Windows 实机；ready 行捕获依赖 `/bin/sh` 重定向。

## 关联

- 权威切片：[RECORD-09 · 参与制度接入世界权威](RECORD-09-participation-authority.md)。
- 纯规则：[RECORD-02 · 参与制度](RECORD-02-participation.md)；裁决 [ADR-025](../../decisions/ADR-025-conflict-participation.md)。
- 同型网络测试：[M8-09 公共基金真实网络测试](../M8/RECORD-09-public-fund-network.md)、[M12-06 单位权威](RECORD-06-unit-authority.md)。
