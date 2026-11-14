# M0-02 · 收获命令链验收记录

执行日期：2026-11-14。固定提交：`2aa212c`（M0 命令边界）与 `24aaa3d`（macOS 构建支持）在同一 `main` 上。规则版本：FarmState v27，存档信封 `version=27`。

## 环境与输入

- macOS 27.0.1，Apple M4 Pro，Metal 4，3840×2160。
- Godot 4.7.2-stable（`.godot-version`），macOS 通用导出模板 4.7.2.stable。
- 隔离数据目录：`.local/verification/`；无玩家真实存档参与。

## 改动

- `Game/farm/farm_command.gd`：校验、在候选状态上执行收获、同批次按命令 id 回放；只有持久化并接受候选后才记录结果，载荷不同时拒绝为冲突。
- `Game/farm/world_command_entry.gd`：无场景单命令入口，参数 `--save-dir --id --field --cell --now`，按存储成功与否退出 1/0。
- `Game/scenes/main.gd`：收获分支改走命令边界，其他工具保持原路径。
- 测试：`tests/farm_command_test.gd`（26 项）、`tests/headless_world_test.gd`（14 项）。

## 结果

| 检查 | 命令 | 结果 |
|---|---|---|
| 命令语义 | `godot --headless --path Game --script tests/farm_command_test.gd` | 26 项通过，0 失败 |
| 无场景链路 | `godot --headless --path Game --script tests/headless_world_test.gd` | 14 项通过，0 失败；磁盘信封 v27 |
| 无头单命令 | `--script res://farm/world_command_entry.gd -- --id=…` | 首次收获库存 greens=1；重复或无效 id 返回 `command_empty`，退出 1，无额外奖励 |
| 主场景接入 | 主场景实例化后同一成熟地块连续收获 | 首次 greens 0→1 且仅提交 1 条命令；第二次不改变库存 |
| 启动体验回归 | `tests/startup_experience_test.gd` | 45 项通过，0 失败 |

`farm_command_test.gd` 同时对照 `FarmState.harvest()` 直调结果，覆盖同一 id 重放只奖励一次、重新播种后 id 仍存活、不同 id 各奖励一次、载荷冲突和无效命令不进入回放集。

## 未覆盖与后续

- Windows 同夹具本轮未执行；M0-05 的双平台等价结论需要两侧输出后补齐。
- 真实鼠标拖拽/取消路径只由既有场景测试间接覆盖；本轮主场景检查直接设置选择状态调用工具，不构成输入层证据。
- 播种、浇水尚未迁移到命令边界（M0-02 后续项）。
