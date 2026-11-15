# M4-07b · 加入码轮换（切片）

执行日期：2026-11-16。状态：切片完成，不表示 M4 或 M4 验收完成。前置：[M4-05 服务器部署](RECORD-04-deploy.md)、[M4-06 加入码与客户端入世](RECORD-06-client.md)。`RECORD-07` 的编号已被 [启动界面开房与加入](RECORD-07-rooms.md) 占用，本文件以 `07b` 区分。

## 实现

此前加入码泄露后只能由操作者手动替换房间数据里的 `invite.bin` 再重开房，游戏内没有入口。本切片把“停房—换文件—按旧端口重开”做成房间面板上的一个动作。

权威进程不需要改：`world_server.gd` 每次启动都从 `invite.bin` 重建授权表，访客授权由该文件 HMAC 派生（见 RECORD-06），所以换掉文件并重启就同时废除成员码与访客码。

`Game/world/world_hosting.gd`：

- 新增 `rotate_invites(wait_ms := 8000) -> Dictionary`。顺序固定：
  1. 只在房间运行中（`pid > 0`）且是编辑器构建时执行，否则返回 `not_started` / `unsupported_build`；`invite.bin` 缺失返回 `invite_missing`。
  2. 先把新的 32 字节随机邀请写到 `invite.pending.bin` 并读回比对，失败返回 `write_failed`。这一步发生在停房之前，磁盘问题不会打断正在服务的房间。
  3. 记录 `pid`，用 `stop(wait_ms)` 优雅停止（沿用既有控制文件 + 超时终止）；成员连接随进程退出而断开，这是轮换的既定语义。
  4. 清掉被停进程可能遗留的 `authority.lock`（只清理 owner 文件写着刚停止的那个 pid 的锁，别的活权威不受影响），否则重启会被自己的旧锁挡成 `data_dir_locked`。
  5. 旧 `invite.bin` 移到 `invite.previous.bin`，`invite.pending.bin` 改名为 `invite.bin`。任一步失败返回 `archive_failed` / `replace_failed`。
  6. 在同一目录、同一端口重新 `start()`，最多等 30 秒；成功返回 `poll()` 的 `{ok, reason:"", join_code, visitor_join_code, url, pid, world_id, previous}`。
- 失败回滚：`_rotate_restore()` 把 `invite.previous.bin` 放回 `invite.bin`（放不回时返回 `*_rollback_failed`），并在旧邀请上重启。重启也失败时返回 `*_restart_failed`，房间保持停止。因此“具名失败”要么旧码仍然有效、房间仍在服务，要么明确报告旧码也未能恢复。
- 宿主身份在轮换中保留：`start()` 记住的 `host_player` 被重开时带回去，房间不会因为轮换变成匿名房。
- `invite.previous.bin` 是上一份邀请的归档；再次轮换时被覆盖（只保留最近一份）。
- 端口沿用 `port`，不重新挑选；目前没有“换端口”的语义，因为成员码里写的是同一地址。

`Game/ui/room_panel.gd`：

- 新增 `rotate_requested` 信号与“更换加入码”按钮（`Rotate`），只在 `show_room()` 之后可见；`show_idle()` / `show_failure()` / `show_joining()` 都隐藏它。按钮在轮换进行中（`_busy`）不再响应，面板隐藏时确认框也会收起。
- 按钮先弹 `ConfirmationDialog`（`RotateConfirm`），正文说明“房间会短暂重启、已连进来的成员会断开、成员码和访客照料码都会失效”。取消不发动作且两串码保持原样；Esc 只关确认框，不关整个面板。之后才会 `rotate_requested.emit()`。
- 新增 `show_rotating()`（禁用轮换与进入，旧码仍显示）、`show_rotated(join_code, visitor_code)`（更新两串码、启用控件、复制成员码；访客码为空时按既有规则提示“暂不可用，重启房间再试”）、`show_rotate_failure(message)`（只显示原因，不清空也不隐藏旧码）。
- 泄露提示改为“点‘更换加入码’，房间会短暂重启、成员会断开、两串码都会失效”，不再写“当前没有撤销界面”。

`Game/scenes/startup.gd`：

- 面板的 `rotate_requested` 接到 `_rotate_room_codes()`：房间没在运行或已经进入农场时给出可见原因；否则 `show_rotating()` → `rotate_invites(8000)` → 成功 `show_rotated()`，失败 `show_rotate_failure(_rotate_message(reason))`。
- `_rotate_message()` 把权威返回的原因映射成中文（`write_failed`、`archive_failed`、`data_dir_locked`、`timeout`、`*_restart_failed`、`*_rollback_failed` 等），与开房失败一样区分“旧码仍然有效”和“需要重新开房”。

## 覆盖

`tests/invite_rotation_test.gd`（真实进程，目录在 `.local/verification/invite-rotation-*`）：
真实开房 → 旧成员码加入并提交一条 `set_theft` 命令、要求摘要确认生效 → 轮换 → 断言新成员码/访客码可解析、两串码都变了、地址与端口不变、`invite.bin` 字节变化且为 32 字节、旧文件逐字节归档为 `invite.previous.bin`、不留 pending 文件、新码内嵌密钥就是当前文件 → 旧成员码与旧访客码均无法拿到权威状态 → 新成员码加入且世界状态（`theft_enabled`）保留 → 新访客码以 `visitor` 角色加入 → 连续第二次轮换产生第三枚成员码且新码可加入、归档更新为第一次轮换的文件 → 写失败路径（pending 名被目录占住，`write_failed`，房间继续运行、旧码仍可加入）→ 归档失败回滚路径（归档名被目录占住，`archive_failed`，房间在旧邀请上重启、旧码仍可加入）→ 停止后轮换返回 `not_started` 且不改写 `invite.bin`。

`tests/room_panel_rotation_test.gd`（场景夹具，依赖 FarmTheme）：
空闲时不显示按钮；开房后显示；点击先弹确认且不发动作；确认文案含“断开”和“失效”；取消不发动作、不关确认、两串码不变、按钮仍可用；Esc 只关确认框；确认只发一次 `rotate_requested`；`show_rotating()` 禁用轮换与进入且旧码仍显示；`show_rotated()` 更新两串码、启用控件、状态含“已更换/已复制”；无访客码的成功路径仍显示成员码与进入并提示不可用；`show_rotate_failure()` 保留两串旧码并显示原因；关闭面板会一并收起确认框。

## 原始末行

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 280 "$GODOT" --headless --path Game \
  --script "$PWD/tests/invite_rotation_test.gd"
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/room_panel_rotation_test.gd"
```

```text
INVITE_ROTATION_TEST checks=48 failures=0
ROOM_PANEL_ROTATION_TEST checks=25 failures=0
```

回归：

```text
M4_HOSTING_TEST checks=25 failures=0
STARTUP_ROOM_TEST checks=27 failures=0
ROOM_PANEL_TEST checks=35 failures=0
```

`STARTUP_ROOM_TEST` 与 `ROOM_PANEL_TEST` 的泄露提示断言由“没有撤销界面”改为“更换加入码/成员会断开”，与新行为一致。

## 未覆盖

- 离线成员重连：轮换后旧码被拒，客户端按既有退避不断重试，没有“房间已更换加入码，请向房主重新索取”的专门提示或自动停止重试。
- 只测 macOS 回环；Windows（无便携停止信号，只有控制文件与终止）、真实局域网、防火墙与 NAT 下的停房/重启时序未验证。
- 真实点按（鼠标/触屏）没有自动化：面板测试用 `pressed.emit()` 和确认框按钮信号，没有走实际指针输入与弹窗布局。
- 未测轮换到一半进程被外部杀死（例如在 `stop()` 之后、重命名之前强杀桌面端）：磁盘上可能留下 `invite.pending.bin` 或只有 `invite.previous.bin`，下一次开房会重新生成邀请；没有针对该崩溃点的自动恢复。
- 轮换期间成员只是被断开，没有广播“房间正在轮换”的通知；重新开房后旧成员需要房主重新发码并自行重连。
- 房间面板的确认框在进入农场前才可用；进入农场后没有轮换入口（按钮和调用都拒绝），这与“只能在加载页选房”一致但未提供运行期管理。

## 关联

- 加入码与访客码：[M4-06](RECORD-06-client.md)。
- 房间进程与部署：[M4-05](RECORD-04-deploy.md)。
- 邀请与认证：[M4-02](RECORD-01-join.md)、[ADR-004](../../decisions/ADR-004-transport.md)。
