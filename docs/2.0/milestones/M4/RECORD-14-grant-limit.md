# M4-14 · 开户赠款按成员发行（切片）

执行日期：2026-11-15。状态：切片完成，不表示 M4 或验收完成。前置：[M4-13 身份绑定](RECORD-13-identity.md)、[ADR-029](../../decisions/ADR-029-player-identity-binding.md)、[ADR-019](../../decisions/ADR-019-economy-command-permissions.md)。

## 问题

开户赠款原本只按 `accounts[owner].granted` 幂等，而 `owner` 是加入时的 `player_id`。同一安装换一个新 `player_id` 加入，就是一个新的 `owner`，`OPENING_GRANT` 会再发一次；命令窗口和重启都不会阻止，因为每个 id 的发放都“恰好一次”。R16 因此只剩这一半未关闭。

邀请 id 不能作为发行键：ADR-029 已明确多个成员共享同一邀请，`server-invite` 也是可重复兑换的房间码；按邀请限制会把“每个成员一次”变成“每个世界一次”。

## 实现

成员证据来自已有的 `player_bindings.json`，不新增字段、不改农场格式 27：

- `PlayerBindingState.bind()` 按 `player_id` 保存加入时出示的世界作用域证明。同一安装的 `player.key` 对同一世界派生出同一个证明，因此同一成员换新 id 后，两个绑定条目的 `secret` 相同。
- `WorldHost.execute_for_member` 在 `ACCOUNT_OPEN` 进入规则前调用 `_grant_held_by_another_id(actor)`：若另一条同证明的绑定已经持有 `accounts[id].granted`，返回具名 `grant_already_issued`，不写候选、不落盘、不广播。
- 已提交的命令 id 豁免该门禁，交给 `HeadlessWorld.execute` 正常回放 `duplicate`；因此旧世界的既有发放记录不会让一次合法重试变成拒绝。
- `actor` 自己的账户仍由经济规则返回 `already_granted`；跨 id 门禁只处理“另一个 id 已领过”的新证据。
- `FarmState.economy_granted(owner_id)` 是只读访问器，读取同一份 `granted` 标记，不新增持久键。
- 中文原因进入 `WorldHost._reason_text`，客户端直接展示服务端 `reason_text`。

门禁顺序：角色/经济权限 → `grant_already_issued` → 收割授权 → `HeadlessWorld.execute`。身份仍只来自连接（ADR-019）：命令载荷没有 owner 字段，门禁读的是权威自己的绑定文档和农场账户。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/grant_limit_test.gd"
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/economy_initial_test.gd"
perl -e 'alarm shift; exec @ARGV' 540 "$GODOT" --headless --path Game \
  --script "$PWD/tests/m4_economy_commands_test.gd"
```

原始末行：

```text
GRANT_LIMIT_TEST checks=24 failures=0 root=…/grant-limit-…
ECONOMY_INITIAL_TEST checks=154 failures=0 root=…/economy-initial-…
M4_ECONOMY_COMMANDS_TEST checks=169 failures=0 dir=…/m4-economy-commands-…
```

| 用例 | 检查 |
|---|---|
| 首次发行 | 成员 A 首次开户得到完整 120，`issued` 只增加一次 |
| 换 id 拒绝 | 同一证明、不同 `player_id` 的账户命令返回 `grant_already_issued`，别名无账户、`issued` 与账户总和不变 |
| 再换 id | 同一证明的第三个 id 仍被拒绝，不能靠换字符串绕过 |
| 其他成员 | 不同安装证明的成员 B 正常得到自己的 120 |
| 重连/回放 | 同一 id 重连后新命令 id 返回 `already_granted`；原命令 id 回放 `duplicate` 且农场快照不变 |
| 重启 | 重开世界后别名仍被拒绝，B 的账户仍只有一次，`issued` 保持 240 |
| 真实会话 | `M4_ECONOMY_COMMANDS_TEST` 用同一 `invite-a.bin`、同一安装凭据、第二个 `player_id` 发起真实 WSS 加入并开户，拒绝 `grant_already_issued`；A/B 用不同安装凭据分别首次发行仍通过 |

回归：`PLAYER_IDENTITY_TEST 41/0`、`M4_JOIN_TEST 67/0`、`M4_RECONNECT_TEST 31/0`。

测试夹具调整：`M4_ECONOMY_COMMANDS_TEST` 的每个具名成员现在使用各自的 32 字节安装凭据（此前所有成员共用 `PLAYER_SECRET`，会被新门禁正确识别为同一成员）；`a2` 刻意复用 A 的凭据，用于真实会话的换 id 用例。

## 未覆盖与残留

- **主动轮换凭据仍是新成员**：客户端删除/重建 `player.key` 后派生出不同证明，权威无法与旧成员关联，仍可再领一次。这与 [R28](../../decisions/RISKS.md) 的“身份丢失/迁移”是同一问题；彻底关闭需要成员级邀请或房主审批的入会记录，本轮不引入。
- **没有绑定文档的旧世界退化为逐 id 发放**：`player_bindings.json` 缺失/为空时没有跨 id 证据，只剩原来的 `granted` 标记。R28 已记录绑定文档不进入世界导出包。
- **既有重复发放不追回**：门禁只阻止新的发行，不改旧账。
- **真实多机/Windows 与 1024 条绑定上限下的门禁耗时未测**；门禁只在 `account_open` 上遍历绑定表，按常数时间比较。

## 关联

- 身份：[ADR-029](../../decisions/ADR-029-player-identity-binding.md)、[M4-13](RECORD-13-identity.md)。
- 经济身份与命令权限：[ADR-019](../../decisions/ADR-019-economy-command-permissions.md)、[M4-09](RECORD-09-economy-commands.md)。
- 风险：[R16、R28](../../decisions/RISKS.md)。
