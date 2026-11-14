# M3-03 · 提交中断与恢复切片记录

执行日期：2026-11-15。基线提交：`a08457f`；事务账本补充位于 `6b8547b`。本记录只证明现有快照存储在命名提交边界被强制终止后的恢复行为，不表示 M3-03 或 M3 已完成验收，也不表示已选定 ADR-003 的事务数据库。

## 环境与输入

- macOS 27.0.1，arm64（Apple M4 Pro）。
- Godot 4.7.2-stable，`4.7.2.stable.official.ed1daf0bf`；仅使用 `--headless`。
- 隔离目录 `.local/verification/headless-crash-*`；无玩家真实存档参与。
- 夹具：世界从 `START=1800000000` 开始，播种 `field_01/cell_01` 的 greens，推进到 `START+9000` 后成熟并保存；崩溃动作是时间 `START+9000` 的收获命令 `crash-harvest`。

## 实现

- `Game/farm/farm_store.gd` 增加测试专用静态接缝 `fault_hook: Callable` 与 `_fault(stage)`。正常运行时接缝未设置，不改变任何存储行为。提交路径在四个持久化边界调用它：
  - `pending_written`：候选已写入 `farm.pending.json` 并回读一致；主件与备份未动。
  - `backup_replaced`：旧主件已复制为备份并完成替换；候选仍在 pending。
  - `before_main_replace`：即将用 pending 替换主件；备份已就绪。
  - `main_replaced`：pending 已重命名为主件；内存接受与命令登记尚未执行。
- `tests/headless_crash_commit_test.gd` 使用 `OS.execute()` 启动同一引擎的子进程；子进程在接缝写标记文件后对自身 `OS.kill()`。父进程逐边界检查磁盘足迹、重新打开无头世界并重试同一命令 id。另有首次保存阶段中断的用例。

## 结果

实际执行：

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
"$GODOT" --headless --path Game --script "$PWD/tests/headless_crash_commit_test.gd"
"$GODOT" --headless --path Game --script "$PWD/tests/farm_store_test.gd"
```

- `HEADLESS_CRASH_COMMIT_TEST checks=47 failures=0`，退出码 0。每个子进程都被 SIGKILL（macOS 报 `Killed: 9`），标记文件证明到达指定边界。
- `FARM_STORE_TEST checks=109 failures=0`：新增接缝未改变既有存储语义。
- 四个边界上主件始终是一个完整可读版本：
  - `pending_written`、`backup_replaced`、`before_main_replace`：主件仍是收获前状态（库存 0、作物仍在），pending 候选不被正常加载采纳；重试同一命令 id 后恰好收获一次。
  - `main_replaced`：主件已是收获后状态（库存 1、地块空）；新进程重试同一 id 返回失败，库存仍为 1。
- 首次保存中断：只有 pending 文件，没有主件；`load_state()` 返回 `recovery_available(PENDING)`，要求显式恢复，不制造“已提交”的主件。

## 事务账本（本次补充）

上一轮记录的差距是“命令结果与事件序号没有写入存档”。本轮选择 ADR-003 的备选形态：不引入嵌入式数据库，把幂等结果与事件序号放进同一份农场快照，由现有单写者存储原子提交。

- `FarmState` 增加 `transaction` 字段：`sequence` 与有界的 `command_results`（最多 64 条，固定记录 `ok`/`reason`/`changed_fields`/`visual_changed`/`reward_crop_id`/`reward_amount`）。恢复时校验结构并归一化数值；负序号、超量、畸形结果按损坏档拒绝。
- `FarmCommand.execute()` 在候选状态上调用 `commit_command()`，因此资源变更、回放结果与序号一起进入候选；`FarmStore.save_state()` 一次写盘即包含三者，不存在“先写资源、后写结果”的窗口。
- 重试已提交的 id：新进程从状态中的账本读取原结果并返回 `duplicate=true`，不再依赖地块状态推导；payload 不同仍返回 `command_conflict`。
- `HeadlessWorld`、`world_command_entry` 与主场景收获路径都接受带账本的候选；世界摘要输出 `committed_sequence`。导入导出携带农场快照，账本随世界一起迁移。
- 账本有界意味着它只保证最近 64 条命令跨进程幂等；更早的 id 会重新进入规则准入。该边界是本切片的明确限制，不是审计日志。

复跑（macOS，headless）：

```text
FARM_COMMAND_TEST checks=34 failures=0
FARM_STATE_TEST checks=385 failures=0
FARM_STORE_TEST checks=109 failures=0
HEADLESS_WORLD_TEST checks=14 failures=0
HEADLESS_WORLD_RUNTIME_TEST checks=56 failures=0
HEADLESS_EVENT_SCHEDULE_TEST checks=56 failures=0
HEADLESS_CRASH_COMMIT_TEST checks=51 failures=0
WORLD_PACKAGE_TEST checks=106 failures=0
WORLD_TRANSFER_TEST checks=72 failures=0
V27_IMPORTER_TEST checks=68 failures=0
world_roundtrip_stage：create 7、modify 12、continue 7，失败均为 0
```

`HEADLESS_CRASH_COMMIT_TEST` 现在在四个边界上同时核对：`main_replaced` 的新进程重试返回 `duplicate=true` 并回放原结果，其他边界重试恰好提交一次；账本序号分别等于“夹具播种 1 条”与“再加本次收获 1 条”。

窗口路径另跑 `FARM_STORAGE_SCENE_TEST checks=17 failures=0`、`ATMOSPHERE_SCENE_TEST checks=21 failures=0`、`FARM_INTERACTION_TEST checks=78 failures=0`（均为 macOS 实窗）。

## 与验收目标的差距

- 旧格式快照（`fields` 等 9 个键、无 `transaction`）不再被接受；当前处于早期开发阶段，不做迁移。此前的导出包需要重新导出。
- 命令账本只覆盖走 `FarmCommand` 的动作（收获，以及无头世界的播种/浇水）。主场景的播种、浇水与除草仍直接调用 `FarmState`，它们的幂等性依赖地块状态准入，不写命令结果。若要把全部场景动作纳入账本，需要先扩展 M0 命令集合，属于后续工作。
- 没有选择或接入事务数据库；本切片只证明“快照 + 临时件 + 备份 + 内联账本”的提交完整性。
- 崩溃注入接缝位于提交路径，只在测试中启用；生产启动不能通过参数触发。
- 本机 macOS 结果如上；干净检出 CI（`.github/workflows/rule-tests.yml`，运行 `43623633298`，提交 `607ac5f`）在 macOS 与 Windows 上全部用例通过：`HEADLESS_CRASH_COMMIT_TEST checks=51 failures=0`、`HEADLESS_WORLD_RUNTIME_TEST checks=56`、`HEADLESS_EVENT_SCHEDULE_TEST checks=56`、`FARM_COMMAND_TEST checks=34`、`FARM_STATE_TEST checks=385`、`FARM_STORE_TEST checks=109`、`WORLD_PACKAGE_TEST checks=106`、`WORLD_TRANSFER_TEST checks=72`、`V27_IMPORTER_TEST checks=68`、`V27_FIXTURES_TEST checks=27`、`WORLD_LAB_TEST checks=47`，失败均为 0。旧夹具因缺少事务字段被拒绝后，已用真实序列化重新生成。
- 未测提交过程中断电、磁盘写满、文件系统只读或并发第二写入者；这些属于存储候选选型试验。Windows CI 覆盖了正常文件系统上的四个边界，但不覆盖断电与只读介质。
- 未测恢复耗时、备份体积增长或长时间运行后的文件累积。
- 账本最多 64 条，超出后的旧命令只靠规则准入；不支持跨设备并发同一 id 的强一致。

## 结论

命名边界上的进程终止不会产生部分主件或重复收成；命令结果、资源变更与事件序号现在位于同一份已提交快照，重启后的重试可以回放原结果。macOS 与 Windows 的存储边界行为仍需在本次提交上重新跑 CI 后才能声称一致；事务数据库选型与“全部场景动作纳入命令边界”仍未完成，M3-03 保持未验收。
