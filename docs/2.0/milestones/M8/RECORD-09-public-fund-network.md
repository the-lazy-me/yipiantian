# M8-04 · 公共基金真实网络测试（切片）

执行日期：2026-11-16。状态：切片完成，不表示 M8-04 或 M8 验收完成。前置：[RECORD-07 · 公共基金接入世界权威](RECORD-07-public-fund-authority.md)、[RECORD-08 · 公共基金面板](RECORD-08-public-fund-panel.md)。

## 问题

RECORD-07 的基金流程只在同进程无头夹具里验证；RPC 15/16 是否真的经过 WSS、身份是否只来自连接、48 KiB 预算与重启后的账本补写是否成立，都没有在真实服务器进程上跑过。本切片补一份真实网络端到端测试，不改生产代码。

## 边界

- 新增 `tests/fund_network_test.gd`。
- 未修改 `Game/`、其它测试、`rules/`、文档、CI 或 PLAN；生产代码无 bug，故没有修复项。
- 测试数据目录在 `.local/verification/fund-network-<微秒>/world`，结束后写 `stop` 并验证进程退出。

## 场景

测试用唯一空闲端口启动 `Game/world/world_server.gd`（`--headless --path Game --script … -- --data-dir=… --port=… --world=world-fund-network --run-seconds=0 --join-url=…`），等待 `server-status.json` 为 running，再用 `WorldClient` 通过真实 WSS 加入：

1. 成员 A（leader）经频道 11/12 创建组织；`open` 返回派生 `fund_<org_id>`、余额 0、无 history。
2. 真实 `account_open` 得到 120 现金；`contribute 100` 后本人 20、组织账户 100、基金余额 100，总额与发行量不变，sidecar 落盘。
3. 同 request_id 缴入重放返回 `duplicate`，现金与基金文档逐字节不变。
4. keeper `spend 40`：组织账户 60、`@world` +40、基金余额 60/支出 40，存储文档只有一条 history。
5. 成员 B（独立安装凭据）加入组织、开户 120、缴入 1（组织账户 61、余额 61）；普通成员 spend 被拒 `not_keeper`。
6. leader 任命 B 为 officer 后 `rotate` 成功；旧 keeper spend 被拒 `not_keeper`；新 keeper spend 10 成功（组织账户 51、`@world` +10、余额 51/支出 50）。
7. 访客写 `forbidden`、匿名写 `no_player`，两者仍可读 `state`。
8. 超过 48 KiB 的原始 `fund_request` 返回 `payload_too_large`，随后 `state` 仍正常。
9. 优雅停止后同一数据目录、新端口重启；重放同一缴入 request_id 返回 `duplicate` 且不二次扣款，换金额返回 `command_conflict`。
10. 结束关闭全部客户端、写 `stop`，验证进程退出且状态文件为 `stopped`。

两个具名成员必须使用不同安装凭据：ADR-029 下每个凭据只领一次开户赠款，同一凭据的第二次 `account_open` 会被 `grant_already_issued` 拒绝。两个成员顺序连接而不是同时在线——`WorldClient` 的会话节点固定为 `/root/WorldSession`，同进程无法并存两个在线客户端；组织、基金与账户都是世界持久事实，换届与支出验证不受影响。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
cd /Volumes/Disk-1tb/yipiantian
perl -e 'alarm shift; exec @ARGV' 420 "$GODOT" --headless --path Game \
  --script "$PWD/tests/fund_network_test.gd"
```

原始末行（连续两次运行均通过，目录随时间变化）：

```text
FUND_NETWORK_TEST checks=99 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/fund-network-339960
FUND_NETWORK_TEST checks=99 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/fund-network-358326
```

回归原始末行：

```text
PUBLIC_FUND_AUTHORITY_TEST checks=211 failures=0
```

## 未覆盖

- 两个客户端同时在线（`WorldClient` 固定会话路径）；换届与支出用顺序连接验证。
- 网络抖动、代理、IPv6、LAN 跨机与 Windows 实机。
- 基金视图进入摘要/投影；本测试只用频道 15/16 的 `state`。
- 公共项目施工与建筑联动。

## 关联

- 权威切片：[RECORD-07 · 公共基金接入世界权威](RECORD-07-public-fund-authority.md)。
- 界面：[RECORD-08 · 公共基金面板](RECORD-08-public-fund-panel.md)。
- 同型真实网络测试：[M12-06 单位权威](../M12/RECORD-06-unit-authority.md) 中的 `UNIT_NETWORK_TEST`。
