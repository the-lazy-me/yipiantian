# M8-04a · 公共项目真实网络测试（切片）

执行日期：2026-11-16。状态：切片完成，不表示 M8-04a 或 M8-04 验收完成。前置：[RECORD-10 · 公共项目接入世界权威](RECORD-10-public-works-authority.md)。

## 目的

权威直连测试已经覆盖项目规则与基金联动，但没有经过真实 RPC 21/22、真实 `world_server` 进程与真实落盘。本切片验证：玩家请求编码解码、频道预算、令牌桶、连接身份、重启恢复和同命令重放都在真实 WSS 路径上成立。

## 实现

新增 `tests/public_works_network_test.gd`，参照 `fund_network_test.gd`：

- 启动真实 `Game/world/world_server.gd`（`--host-player=PLAYER_A`），环回 WSS；
- 非 Windows 用 `/bin/sh -c 'exec ... > log 2>&1'` 捕获日志（`exec` 保留 PID）；Windows 直接 `OS.create_process` 并跳过依赖 shell 的日志断言；
- 所有项目操作经 `WorldClient.request_public_works()` / RPC 21，答复经 RPC 22；
- 测试产物在 `.local/verification/public-works-network-<pid>/`。

## 覆盖

| 范围 | 断言 |
|---|---|
| 启动 | `server-status.json` 的 `world_id`/`port`/`opened=created`/`running`/`pid`；READY 行带 `host_player`（非 Windows） |
| 加入与基金 | 成员加入、空项目表、组织创建、真实 `account_open`、基金开立、缴入 120 |
| open/pledge/release | 固定成本判定；退回后 `pledged=funded=60` 且 `unbuilt` |
| build | 组织基金余额 120→0、`@world` +120、总现金守恒、项目 `built`、`built_utc>0`、`public_works.json` 落盘、基金 history 恰一条 spend（金额 120、project `road_01`） |
| 幂等 | 同一 build 命令 id 即时重放 `duplicate`，farm/基金/项目文档字节不变；同 id 换项目 `command_conflict`，文档与现金不变 |
| 重启 | 同数据目录重启 `opened=loaded`；项目、`built_utc`、承诺记录、余额、history、账户现金全部保留；重启后重放仍 `duplicate`，换项目仍 `command_conflict` |
| 权限 | 访客 `state` 可读、写入 `forbidden`；匿名读可、写 `no_player`；已认证但未 join 的连接发写入得不到回复；`read-only` 写入 `read_only`、读取仍可用、无落盘 |
| 超预算 | 50 KB 原始请求返回 `payload_too_large`，连接随后仍可正常读 state |
| 停止 | 进程退出、状态 `stopped`、普通停止 `save=saved`、只读停止 `save=read_only_skipped`、STOP 日志 |

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 480 "$GODOT" --headless --path Game \
  --script "$PWD/tests/public_works_network_test.gd"
```

原始末行：

```text
PUBLIC_WORKS_NETWORK_TEST checks=107 failures=0
```

回归（合并后同一工作区）：`PUBLIC_WORKS_AUTHORITY_TEST 177/0`、`CONFLICT_AUTHORITY_TEST 276/0`、`PARTICIPATION_AUTHORITY_TEST 121/0`、`PARTICIPATION_NETWORK_TEST 102/0`。

## 缺陷

未发现生产缺陷，未修改 `Game/world/*.gd`。测试自身修复一处：重启会分配新端口，而旧 join code 内含旧 URL；重启后重建 join code 即可。

## 未覆盖

- 答复侧 48 KiB 预算：项目视图上限 32 行，正常无法撑爆，只验证了请求侧。
- Windows 实机网络运行；Windows 分支仅保留 `server-status.json` 与状态断言，日志断言按设计跳过。
- 多成员并发 build、组织职位变更/基金换届对 build 权限的影响（已有基金权威与网络测试覆盖部分）。
- 网络中断/重连期间的迟到响应、客户端 UI 联调。

## 关联

- 权威：[RECORD-10 · 公共项目接入世界权威](RECORD-10-public-works-authority.md)。
- 同类网络：[RECORD-09 · 公共基金真实网络测试](RECORD-09-public-fund-network.md)。
- 阶段计划：[M8 PLAN](PLAN.md)。
