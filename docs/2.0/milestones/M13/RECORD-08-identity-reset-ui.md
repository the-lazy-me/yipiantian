# M13-08 · 界面化身份重置

执行日期：2026-11-15。状态：本机实现与无头验证通过，不表示 M13-03 或 M13 完成。前置：[ADR-029](../../decisions/ADR-029-player-identity-binding.md)、[RECORD-07 身份材料演练](RECORD-07-identity-recovery.md)、[M4-08 本机玩家档案](../M4/RECORD-08-player-profile.md)、[M4-13 身份绑定](../M4/RECORD-13-identity.md)。

## 问题

RECORD-07 与 ADR-029 都把“面向玩家的界面化重置”列为未实现：玩家想换一个本机身份，只能在文件系统里手工处理 `user://player/player.json` 与 `player.key`。这既容易误删旧身份材料，也无法在游戏内看到“旧成员资格和开户赠款不会跟着新身份走”的后果。

## 边界

- 只重置本机玩家档案：归档现有 `player.json` 与 `player.key`，生成新的玩家 id 和新的 32 字节凭据。
- 不删除任何农场或世界数据，不修改 `world.json`、`player_bindings.json` 或其他世界侧绑定文档。新 id 在已有世界里会表现为一位新邻居。
- 旧身份在世界里的成员资格、开户赠款与社交记录不迁移到新身份；新身份从匿名名称开始。
- 重置后不自动退出。当前会话继续使用启动时读入的身份，重启游戏或重新进入世界后才使用新身份。
- 入口位于设置菜单“世界”页的“重置身份”，沿用现有危险操作样式。

## 确认流程

- 点击入口只打开确认面板，标题“重置玩家身份？”，正文说明：会换用新的玩家 ID 和本机凭据；旧身份在世界里的成员资格和开户赠款不会迁移；旧身份材料会归档保留。
- 取消或按 Esc／右键返回世界页，不产生任何写入；菜单焦点回到“重置身份”。
- 确认后菜单只发出 `identity_reset_requested`，由主场景调用 `PlayerProfile.reset_identity()`。结果写在世界页状态行：成功提示旧材料已归档、重启或重新进入世界后生效；失败给出具体原因，并说明旧文件保持不变或仍在归档中。
- 菜单自身不读写档案文件，只表达玩家意图；关闭菜单不会触发重置。

## 归档语义

- 归档名形如 `player.identity_reset.<unix_us>.<sha256 前 12 位>.json` 与 `.key`，与损坏恢复使用的 `player.corrupt.*` 明确区分。
- 复用并抽出 `_archive_original()` 的归档语义：重命名、按 SHA-256 回读确认字节一致、同一微秒内重名追加序号。损坏归档仍只保留最新 5 份；身份重置是玩家主动操作，归档不自动裁剪，便于事后手工恢复。
- 先写 `.player.json.reset.<unix_us>.tmp` 和 `.player.key.reset.<unix_us>.tmp` 并回读验证，再归档旧文件，最后原子改名到正式路径。任一步失败都会回滚已归档文件并返回命名失败；旧文件保持可恢复，不会出现“新 id 只存在本次会话”的静默结果。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/player_profile_reset_test.gd"
```

原始末行：

```text
PLAYER_PROFILE_RESET_TEST checks=48 failures=0
```

回归末行：

```text
PLAYER_PROFILE_TEST checks=39 failures=0
PLAYER_IDENTITY_TEST checks=41 failures=0
GAME_MENU_TEST checks=92 failures=0
```

`Game/scenes/main.gd` 另行通过 `--headless --check-only`（退出码 0）。

## 未覆盖

- Windows 实机上的归档、改名与界面布局。
- 真实世界重连后新身份被权威按 TOFU 绑定的完整链路；夹具只验证本地档案文件。
- 界面截图与真实点按：本机截图受 TCC 限制，仅有无头控件断言与焦点检查。
- 重启后从启动页实际切换身份的端到端观察；本轮只验证档案可被重新加载。

## 关联

- 裁决：[ADR-029](../../decisions/ADR-029-player-identity-binding.md)。
- 前置演练：[RECORD-07](RECORD-07-identity-recovery.md)；档案实现：[M4-08](../M4/RECORD-08-player-profile.md)、[M4-13](../M4/RECORD-13-identity.md)。
