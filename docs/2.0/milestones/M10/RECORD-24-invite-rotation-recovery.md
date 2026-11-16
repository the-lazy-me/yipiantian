# RECORD-24 · 邀请码轮换中断恢复

执行日期：2026-11-16。状态：切片完成，未验收。前置：
[M10 PLAN](PLAN.md)、[M4 邀请码轮换](../../M4/RECORD-07-invite-rotation.md)。
记录的是本机房间邀请码轮换被强杀后的启动自愈，不表示 M10 完成。

## 问题

桌面端轮换加入码时，`WorldHosting.rotate_invites()` 的顺序是：先把新邀请写入并读回
`invite.pending.bin`，停止权威，删除旧归档，把 `invite.bin` 改名为
`invite.previous.bin`，再把 `invite.pending.bin` 改名为 `invite.bin`，最后重启权威。
如果进程在两次改名之间（或改名完成后、重启前）被强杀，目录会停在：

```text
invite.bin          不存在
invite.pending.bin  存在（已完整写入并读回的新邀请）
invite.previous.bin 存在（轮换前的旧邀请）
```

下一次启动不会报错，而是由 `world_server._material()` 把缺失的邀请当成首次运行，生成
一份与这次轮换无关的随机邀请。结果是：旧码已失效、轮换写入的新码从未被使用、归档文件
成为孤立残留；玩家看到的房间码既不是旧码也不是轮换时生成的新码。轮换的“新码已发出”和
“目录里实际服务的码”因此分叉。

## 修复

`WorldHosting.start()` 在清空残留状态文件、启动权威之前调用
`_recover_interrupted_rotation(directory)`。它只在以下条件全部成立时行动：

- `invite.bin` 缺失；
- `invite.pending.bin` 存在；
- `invite.previous.bin` 存在；
- 目录没有仍新鲜的 `authority.lock`（与权威相同的 30 秒心跳判据）。

满足时把 `invite.pending.bin` 改名成 `invite.bin`，保留
`invite.previous.bin`，即完成被中断的那次轮换。改名失败时退回到用
`invite.previous.bin` 恢复当前邀请并删除 pending；两者都失败则返回
`invite_recovery_failed`，不启动一个没有明确邀请的房间。

其它情况一律保持原行为：

- `invite.bin` 存在：完全不动文件；
- pending 缺失，或只有 previous：不是这次轮换留下的状态，不恢复；
- 存在新鲜 `authority.lock`：另一个权威仍占用目录，返回 `data_dir_locked`，不改任何文件；
- 陈旧锁按权威自身的规则视为崩溃残留，可以恢复，随后的权威启动会正常回收它。

恢复成功时打印一行 `WORLD_HOSTING_INVITE_RECOVERED rotation=promoted|rolled_back`，
便于从客户端日志确认发生过自愈。`start()` 的返回形状仍是 `{ok, reason}`，未新增对外契约。

## 取舍

**优先完成轮换，而不是回滚到旧码。** `rotate_invites()` 在停止权威之前已经完整写入并
读回 pending，因此这个文件是一份有效的新邀请；完成它能兑现轮换的语义（让泄漏的旧码
失效），同时 previous 仍保留给人工恢复。回滚会把本应撤销的旧码重新放回服务面，与操作者
执行轮换的意图相反。

**用锁心跳判断目录归属，而不是新增占用标记或状态文件。** 权威已经用
`authority.lock` 的 owner 心跳保证单目录单权威；恢复路径复用同一判据，避免在轮换和
启动之间引入第二套权威归属协议，也不改变任何存档格式。

**只识别完整的三文件残留。** 缺少 pending 或 previous 的状态可能来自手工操作或其它
故障，无法证明 pending 是这次轮换写入的有效新码；此时保持普通启动行为，由权威按既有
规则生成或沿用邀请，不让恢复逻辑猜测。

## 边界

- 修改 `Game/world/world_hosting.gd`（启动恢复与锁新鲜度判断）和
  `tests/invite_rotation_test.gd`（强杀窗口、错误残留、锁占用用例），新增本记录。
- 未修改 `Game/scenes/startup.gd`、`Game/world/world_server.gd`、轮换文件格式或
  `rotate_invites()` 的返回字段；面板文案和加入码协议不变。
- 未处理：pending 写入本身被强杀（此时 `invite.bin` 仍在，不需要恢复）；锁的陈旧时间
  仍由权威决定；名称不同的手工残留不会被识别。

## 测试覆盖

`INVITE_ROTATION_TEST checks=78 failures=0`（原 48 项，新增 30 项）。新增用例：

- **强杀窗口**：把当前邀请改名为 previous，再写入新的 32 字节 pending，使 `invite.bin`
  缺失；直接调用 `start()`。断言房间用 pending 里的新邀请启动、pending 被消费、previous
  与旧邀请逐字节一致、旧码加入被拒绝、新码仍以成员身份加入。
- **pending 缺失**：只保留 previous 后启动，断言不把归档提升为当前邀请，归档原样保留，
  权威按普通首次启动生成另一份邀请。
- **只有 pending**：缺少 previous 时启动，断言 pending 不被提升且原样保留。
- **另一个权威占用**：构造完整的三文件可恢复状态，再放置新鲜的 `authority.lock` 与
  owner；断言 `start()` 返回 `data_dir_locked`，`invite.bin` 仍缺失，pending 与 previous
  均未改变。

失败证据：临时把启动恢复调用替换为空操作后，测试报 4 项失败
（新邀请未生效、pending 未被消费、pending 缺失残留用例的前置被破坏、占用锁时未拒绝）；
恢复调用后 78/0。

回归：`M4_HOSTING_TEST 25/0`、`VISITOR_JOIN_CODE_TEST 28/0`、`STARTUP_ROOM_TEST 27/0`、
`WORLD_IDENTITY_TEST 24/0`、`IDENTITY_RECOVERY_TEST 26/0`、`M4_SERVER_TEST 84/0`。

## 未覆盖

- 未在 Windows 上验证；恢复只依赖 Godot 的 `DirAccess.rename_absolute`、文件 mtime 与
  `Time.get_unix_time_from_system()`，未使用平台特有接口。
- `rolled_back` 分支（pending 提升失败、previous 改回成功）未在自动测试中构造；该分支
  只在文件系统拒绝第一次改名时出现。
- 未覆盖外部工具在轮换期间同时改写目录的并发场景；本项目单机房间以 `authority.lock`
  为唯一占用协议。

## 增补：消除缺档窗口与并发恢复（2026-11-16）

对抗审查指出原修复只是事后弥补：强杀窗口仍由“先归档、后提升”的两次改名制造，
直接启动 `world_server` 或另一个客户端并发启动都仍可能让房间生成无关新码，甚至
在并发恢复时由后到者用旧码覆盖新码。已按最小正确方案调整：

- **轮换不再移走当前邀请**。`rotate_invites()` 先把当前 `invite.bin` 完整复制并回读
  到 `invite.previous.bin`，再用一次 `rename(pending, invite)` 原子替换。任何中间
  状态都保有当前邀请，强杀最多留下“旧码仍服务 + pending 新码”，不再出现缺档。
  服务端 `--rotate-invite` 路径同步改成复制归档；替换失败时保持当前邀请与 pending
  不动，不再删除已校验的新码。
- **启动恢复只处理旧版本留下的三文件残形**，并新增两条保护：pending 必须是完整的
  32 字节才提升；提升失败后若发现 `invite.bin` 已出现（另一个启动者刚完成提升），
  按成功处理，不再用归档覆盖它。归档可用时仍回滚，pending 保留供人工提升。
- 两种残留都不是完整邀请时不再报错：按普通启动由权威生成新邀请。
- `startup.gd` 补了 `data_dir_locked` 与 `invite_recovery_failed` 的中文提示；
  `start()` 的可观察 reason 集合确实新增了后者，记录不再声称对外契约完全不变。

测试 `INVITE_ROTATION_TEST` 从 78 增至 88 项，新增：短 pending + 有效归档时回滚并
保留 pending；pending 与归档都不完整时正常启动并写出 32 字节新邀请。回归：
`M4_HOSTING_TEST 25/0`、`VISITOR_JOIN_CODE_TEST 28/0`、`STARTUP_ROOM_TEST 27/0`、
`WORLD_IDENTITY_TEST 24/0`、`FONT_COVERAGE_TEST 1272/0`。

仍未覆盖：两个进程在“检查锁”与“恢复改名”之间精确交错（无锁窗口仍在，但新轮换不
再产生可恢复残形）；Windows 上 rename 覆盖语义的实机确认；rollback_failed 分支。
