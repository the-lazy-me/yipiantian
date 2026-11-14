# M4-08 · 本机玩家档案（切片）

执行日期：2026-11-15。状态：切片完成，不表示 M4 或验收完成。前置：[M4-06 加入码与客户端](RECORD-06-client.md)、[M4-07 开房与加入](RECORD-07-rooms.md)，社交记录见 [M5 RECORD-01](../M5/RECORD-01-social.md)。

## 问题

在此之前，玩家身份只能从命令行 `--player-id=` 传入，显示名默认是“旅人”。启动界面开房之后，任何人从界面进世界都是匿名成员：名册里是一串同样的“一位匿名旅人”，联系人、留言、授权这些按玩家 ID 归属的记录也无法在两次启动之间延续。也就是说，M5 的社交能力在真实游戏里还不能用。

## 实现

### `Game/social/player_profile.gd`

- `user://player/player.json`，字段只有 `version`、`player_id`、`name`。
- 首次运行立即生成并写盘：`player_` + 32 个小写十六进制字符。ID 随机生成，不从机器或用户名派生——同一台 Mac 上的两份安装是两个邻居。
- 改名保留 ID：联系人按 ID 认人，改名不会把已有关系切断。空名字表示匿名（仍然保留 ID），下次可以再起名。
- 名字校验：去空白后 1–24 个字符，不含控制字符。ID 校验：前缀与 32 位十六进制都必须吻合。
- 损坏的文件先复制为 `player.unreadable.json` 再生成新 ID；复制失败时**不覆盖**原文件，改用仅本次会话有效的 ID。版本不认识时既不迁移也不覆盖，返回 `unsupported`。
- 档案只在玩家真正进入房间时写入；单机游戏不读也不写它。

### 接入

- 启动场景默认取档案里的 ID 与名字，`--player-id=` / `--player-name=` 仍然优先，便于测试与运维覆盖一次启动的身份。
- 联机面板新增“你的名字”，预填档案里的名字。进入房间前必须有一个合法名字——权威会拒绝“有 ID 但没有称呼”的成员（`invalid_player`），所以这个检查在拨号之前完成，面板留在原地说明缺什么，而不是连上后被拒。
- 档案加载失败（例如未来版本的档案）时以匿名身份进入：能种田、能建房，但社交记录不归属到任何人。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 60 "$GODOT" --headless --path Game \
  --script "$PWD/tests/player_profile_test.gd"
perl -e 'alarm shift; exec @ARGV' 150 "$GODOT" --headless --path Game \
  --script "$PWD/tests/startup_experience_test.gd"
perl -e 'alarm shift; exec @ARGV' 200 "$GODOT" --headless --path Game \
  --script "$PWD/tests/startup_room_test.gd"
```

结果：`PLAYER_PROFILE_TEST checks=26 failures=0`；`STARTUP_EXPERIENCE_TEST checks=45 failures=0`（启动流程未受影响）；`STARTUP_ROOM_TEST checks=20 failures=0`（新增“没有名字时留在面板”一项）。

| 用例 | 实际观察 | 结果 |
|---|---|---|
| 首次运行 | 生成合法 ID 并立刻写盘，名字为空 | 通过 |
| ID 稳定 | 第二次启动读到同一 ID | 通过 |
| 改名 | 名字去空白后保存，重启后仍在，ID 不变 | 通过 |
| 拒绝非法名 | 25 字、换行、内嵌控制字符被拒绝，且旧名字不变 | 通过 |
| 匿名 | 清空名字保留 ID | 通过 |
| 损坏文件 | 报告 `recovered`、换新 ID、原文件逐字节保留在 `player.unreadable.json` | 通过 |
| 未来版本 | 不采纳、不覆盖，返回 `unsupported` | 通过 |
| 未加载就保存 | 拒绝，不为无关调用方发明身份 | 通过 |
| 进入房间 | 面板没有名字时留在面板并提示；填名字后正常进入联机世界 | 通过 |

## 未覆盖

- 身份仍是**本机声明**，没有密钥、没有签名：服务器接受 `player_id` 这个声明，同一个人换机器或重装就是新邻居。真正不可冒用的身份要等设备密钥与迁移（ADR-004 的第三层）。
- 没有“查看/编辑档案”的独立界面，改名只能经由联机面板；也没有导入导出或“搬去另一台机器”的流程。
- 档案写入采用直接覆盖，没有 pending 文件与哈希复核（界面设置那种强度）；写失败时 ID 只在本会话有效，下次启动会再生成一个。
- 没有同一台机器上多档案（多个玩家共用一台电脑）的切换。
- 只有本机用例；Windows 由 CI 跑同一份档案测试，但没有手工验证。

## 关联

- 客户端与加入：[M4-06](RECORD-06-client.md)、[M4-07](RECORD-07-rooms.md)。
- 社交记录按 ID 归属：[M5 RECORD-01](../M5/RECORD-01-social.md)、[M5 RECORD-02](../M5/RECORD-02-grants.md)。
- 身份分层裁决：[ADR-004](../../decisions/ADR-004-transport.md)。
