# M12-03 · 交战真实网络测试（切片）

执行日期：2026-11-16。状态：切片完成，不表示 M12-03 或 M12 验收完成。前置：[RECORD-12 · 交战权威接入](RECORD-12-conflict-authority.md)。

## 目的

直连测试覆盖了结算、资产、恢复与权限，但没有经过真实 RPC 19/20、真实 `world_server` 与真实落盘。本切片用数学上可复现的小规模交战，验证完整网络路径：制度声明与同意经真实交互完成，单位经真实招募得到，资产变化以服务端文档差值核对，重试不二次发放。

## 实现

新增 `tests/conflict_network_test.gd`，参照 `public_works_network_test.gd` / `participation_network_test.gd`：

- 真实 `Game/world/world_server.gd --host-player=...` + 环回 WSS；
- 非 Windows 用 `/bin/sh -c 'exec ... > log 2>&1'` 捕获日志；Windows 直接 `OS.create_process`，跳过依赖 shell 的日志内容断言；
- 通过真实账户与规则商人购买物资，经 RPC 13/14 招募双方单位，不直写 `units.json`；
- 交战经 RPC 19/20，制度经 17/18；
- 产物在 `.local/verification/conflict-network-<pid>/`。

## 覆盖

| 范围 | 断言 |
|---|---|
| 启动/停止 | `server-status.json` 的 running/port/opened/world/host_player；停止后 `stopped` + `save=saved`；非 Windows 断言 READY/STOP 日志且无 SCRIPT ERROR |
| 和平档 | 默认和平下 engage 拒绝 `peace`，farm/units 字节不变，不生成 `conflicts.json` |
| 未同意 | 房主声明 limited 前同一 engage 拒绝 `no_consent` |
| 成功交战 | 房主经 17/18 声明并自任 attacker，成员经 17/18 同意 defender；engage 答复 `ok`，`state.targets` 损失累计 3 |
| 资产 | 服务端 `farm.json`：进攻方现金 +1、防守方现金 −3、进攻方物资 −4、防守方物资不变；`units.json`：进攻单位 4→1、防守单位不变；`conflicts.json` 目标损失 3 且 `applied=true` |
| 幂等 | 同 command id 重放 `duplicate`，farm/units/participation/conflicts 字节不变；同 id 改坐标 `command_conflict`，不落盘 |
| 权限 | 访客读成功、engage `forbidden`；匿名读成功、engage `no_player`；已认证未 join 的连接 engage 无答复 |
| 超预算 | 原始超过 48 KiB 的请求返回 `payload_too_large`，连接随后仍可读 |
| 重启 | 同目录重启 `opened=loaded`；目标预算、单位与 `conflicts.json` 保留；重放仍 `duplicate`，四类文档字节不变 |

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 600 "$GODOT" --headless --path Game \
  --script "$PWD/tests/conflict_network_test.gd"
```

原始末行（本机两次完整运行一致）：

```text
CONFLICT_NETWORK_TEST checks=117 failures=0
```

回归：`CONFLICT_AUTHORITY_TEST 276/0`。

## 缺陷

未发现生产缺陷，未修改 `Game/world/*.gd`。

## 未覆盖

- Windows 实机网络运行；日志内容断言按设计跳过，状态文件断言保留。
- 网络答复只携带 `state`，不含完整 `outcome`；断言使用目标累计与服务端文档差值。
- 真实网络下的崩溃恢复（农场/单位/参与保存失败）不可在外部可靠注入，仍由直连夹具覆盖。
- 两个客户端同时交战、交战 UI 联调与延迟/丢包不在本切片内。

## 关联

- 权威：[RECORD-12 · 交战权威接入](RECORD-12-conflict-authority.md)。
- 参与制度网络：[RECORD-10 · 参与制度真实网络测试](RECORD-10-participation-network.md)。
- 阶段计划：[M12 PLAN](PLAN.md)。
