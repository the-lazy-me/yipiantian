# M4-02 · 在线成员名册（presence）

执行日期：2026-11-15。状态：切片完成，不表示 M4 或 M4-02 验收完成。前置：[M4-02 创建与加入](RECORD-01-join.md)。

## 实现

宿主侧（`Game/world/world_host.gd`）：

- 成员加入成功（`_members`/`_players` 记录之后）、离开（`_forget` 断线清理、`_defer_disconnect`/`reject` 拒绝清理）以及撤销邀请踢出（`revoke_grant`）之后，向当前所有成员广播名册。
- 复用既有 `command_result` RPC 通道（序号 2），请求 id 为 `roster`；没有新增 RPC 方法或传输消息类型。载荷为 `{"members":[{"name","player_id","role"},...],"count":N}`。
- 与提交变更广播不同，名册发给**每个**当前成员，包括刚加入者：加入者由此确认自己已经入册，并立即看到在线成员，无需额外请求。
- 行按 `name`、`player_id`、`role` 依次排序；成员集合相同时载荷逐字节相同，重复投递可当作同一份名册。
- 匿名成员（未声明 `player_id`）的 `name` 与 `player_id` 都是空字符串，不编造显示名。

成员侧（`Game/world/world_member.gd`）：

- `command_result` 在回复序号陈旧检查之前处理 `roster`（它是广播而不是请求回复），不会发出 `reply_received`。
- 名册存入类型化属性 `roster: Array[Dictionary]`，整份替换后发出 `roster_changed(rows)`；非字典行被丢弃。

## 验证

`tests/m4_presence_test.gd`：一个真实宿主进程加 alice、bob、匿名三个真实成员进程同时在线（回环 WSS、自签证书、隔离目录 `.local/verification/m4-presence-*`）。确认 3 行名册后强杀 bob 进程，等待 alice 收到 2 行；再让 bob 以同一玩家标识重连，确认 alice 重新收到与之前相同的 3 行名册。

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 280 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m4_presence_test.gd"
```

结果：`M4_PRESENCE_TEST checks=38 failures=0`（后续加入活跃身份唯一与命令身份绑定断言）。早期基线为 `checks=25`，当时只断言名册本身；现在同一夹具还覆盖活跃身份唯一与命令归属。回归：`M5_SOCIAL_TEST checks=52 failures=0`，`M4_SYNC_TEST checks=39 failures=0`（后者包含在线变更广播用例，确认 `change` 广播未被破坏）。

| 用例 | 实际输出 | 结果 |
|---|---|---|
| 三人在线 | 三个客户端的名册都是 3 行，内容为 `[{"name":"","player_id":"","role":"member"},{"name":"小满","player_id":"player_...02","role":"member"},{"name":"阿青","player_id":"player_...01","role":"member"}]` | 通过 |
| bob 退出 | alice 名册降为 2 行，只剩匿名与阿青 | 通过 |
| bob 重连 | alice 名册回到 3 行，内容与退出前逐字节相同；`sizes` 历史最大值为 3，重复投递没有追加条目 | 通过 |
| 匿名成员 | alice 看到匿名行的 `player_id` 与 `name` 均为空 | 通过 |
| 排序 | 匿名（空名）→ 小满 → 阿青，符合 name、player_id、role 的排序 | 通过 |
| 重复身份 | 第二个连接声明 alice 的 `player_id` 被拒 `player_id_in_use`，名册仍 3 人 | 通过 |
| 断开释放 | alice 断开后名册降为 2；同 id 重连重新出现，命令按连接身份记账到 alice | 通过 |

## 未覆盖

- 名册只有 `name`/`player_id`/`role`，没有 peer_id、在线时长、位置或状态；两个匿名成员在名册中无法区分。
- 只在本机回环 WSS 验证，未测跨机器／局域网延迟、丢包或高并发加入离开；reliable 通道保证顺序，但没有慢消费者或队列上限测试。
- 名册没有独立的重发协议：重连成员靠重新加入触发广播，客户端不会主动请求名册；若广播未能送达，客户端保留上一份名册直到下一次加入／离开或重新加入。
- 未单独触发 `_defer_disconnect`／`reject`／`revoke_grant` 的踢出广播；测试覆盖的是常规加入与断线离开。
- 同时退出时，宿主的 `_forget` 可能连续处理多个断开，向已经关闭但尚未完成断开回调的 peer 发送名册，引擎会打印 `ready_state != STATE_OPEN` 的发送失败错误；剩余成员收到的名册内容仍正确，没有重试或队列。
- 名册只存在于成员进程内存，未持久化，也未接入界面（当前只是未来村庄 UI 的数据层）。

## 关联

- 前序：[M4-02 创建与加入](RECORD-01-join.md)；同步与在线变更广播：[M4-03 同步与重连](RECORD-02-sync.md)。
- 阶段计划：[M4 PLAN](PLAN.md) M4-02。
