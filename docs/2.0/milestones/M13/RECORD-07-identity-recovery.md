# M13-07 · 身份材料的备份、迁移与重置演练（本机）

执行日期：2026-11-15。状态：本机演练通过，不表示 M13-03 或 M13 完成。前置：[ADR-029](../../decisions/ADR-029-player-identity-binding.md)、[M4-13 身份绑定](../M4/RECORD-13-identity.md)、[M13-03 恢复与升级演练](RECORD-03-recovery.md)。

## 问题

身份绑定落地后，备份面多出两份材料：客户端 `player/player.key`，世界侧 `player_bindings.json`。玩家指南与自托管文档已写“整目录备份、单独重置条目”，但没有任何实际演练证明这些说法成立，[R28](../../decisions/RISKS.md) 因此只能标“未演练”。

本记录用可重复的无头夹具覆盖四种真实操作：整目录迁移、只迁移导出包、丢失本机凭据、房主重置与重置前恢复。

## 演练内容

夹具 `tests/identity_recovery_test.gd` 在 `.local/verification/identity-recovery-<usec>/` 下建一个已绑定的世界与一份本机档案，然后：

| 场景 | 操作 | 期望 |
|---|---|---|
| 整目录迁移 | 复制世界目录与档案目录到新路径 | 绑定随目录保留；原凭据通过，外来凭据仍 `player_proof`；档案 ID 与凭据都不变 |
| 只迁移导出包 | 只有不含 `player_bindings.json` 的目录（导出世界不带 sidecar） | 世界以空绑定打开；同名 ID 首次加入即被绑定，身份层退化为 TOFU；再次换证被拒 |
| 丢失 `player.key` | 新安装生成新凭据 | 证明不同；原世界拒绝（`player_proof`）；原 key 文件仍在磁盘上，可供恢复 |
| 房主重置 | 停写后从 `player_bindings.json` 删除该 ID 条目 | 条目消失；原凭据可重新绑定 |
| 重置前备份 | 复制重置前的世界目录 | 恢复后原证明仍通过，外来证明仍被拒 |

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 120 "$GODOT" --headless --path Game \
  --script "$PWD/tests/identity_recovery_test.gd"
```

原始末行：

```text
IDENTITY_RECOVERY_TEST checks=26 failures=0
```

夹具只做本机文件操作，不启动服务端、不联网；它验证的是“文档里写的操作确实产生预期结果”，不是 Windows 或真实部署环境。

## 操作结论

- 备份/迁移必须整目录复制世界目录**和**玩家档案目录；只备份 `world.json` 会让所有人退化为 TOFU，迁移后第一个持邀请者可以抢先认领任意已知 ID。
- 丢失 `player.key` 时游戏不会静默换新凭据；恢复文件是唯一无副作用的修复，否则只能由房主删除该 ID 的绑定条目。
- 重置条目后，旧凭据再次加入会重新绑定；重置前保留一份整目录备份即可回滚。

## 未覆盖

- Windows 实机与真实常驻服务端的停写窗口（夹具直接改已关闭的世界目录）。
- 导出世界包本身的生成/导入流程没有在本夹具中跑；夹具只验证“没有 sidecar 的目录”这一身份层形状。
- 多玩家、多世界同时迁移；`player_bindings.json` 与其他 sidecar 的一致性快照。
- 面向房主的界面化重置入口仍未实现。

## 关联

- 裁决：[ADR-029](../../decisions/ADR-029-player-identity-binding.md)。
- 实现：[M4-13](../M4/RECORD-13-identity.md)；备份与恢复流程：[RECORD-03](RECORD-03-recovery.md)、[self-host.md](../../release/self-host.md) §10。
- 风险：[R28](../../decisions/RISKS.md)。
