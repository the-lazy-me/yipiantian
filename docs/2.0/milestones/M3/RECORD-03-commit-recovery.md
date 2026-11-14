# M3-03 · 提交中断与恢复切片记录

执行日期：2026-11-15。基线提交：`a08457f`；本记录与本切片同批提交。本记录只证明现有快照存储在命名提交边界被强制终止后的恢复行为，不表示 M3-03 或 M3 已完成验收，也不表示已选定 ADR-003 的事务数据库。

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

## 与验收目标的差距

- 命令结果与事件序号没有写入存档。`FarmCommand` 的已提交集合只在进程内；`main_replaced` 崩溃后重试同一 id 不会得到 `duplicate=true` 的回放结果，只能依赖 FarmState 的状态准入（空地不能再次收获）避免重复产出。当前收获、播种、浇水三类动作恰好都有这种状态约束，但这不满足 ADR-003 要求的“一次事务同时包含资源变更、事件与幂等结果”。
- 没有选择或接入事务数据库；本切片只验证既有“快照 + 临时件 + 备份”回退路径。
- 崩溃注入接缝位于提交路径，只在测试中启用；生产启动不能通过参数触发。
- 本机 macOS 47 项 0 失败；干净检出 CI（`.github/workflows/rule-tests.yml`，运行 43617479840）在 macOS 与 Windows 上均为 `HEADLESS_CRASH_COMMIT_TEST checks=47 failures=0`。Windows 将自我终止报告为退出码 0，夹具因此以子进程标记文件与其存活输出判定终止，而不是退出码。
- 未测提交过程中断电、磁盘写满、文件系统只读或并发第二写入者；这些属于存储候选选型试验。Windows CI 覆盖了正常文件系统上的四个边界，但不覆盖断电与只读介质。
- 未测恢复耗时、备份体积增长或长时间运行后的文件累积。

## 结论

命名边界上的进程终止不会产生部分主件或重复收成：未提交的候选被隔离，重试最多兑现一次；macOS 与 Windows 结果一致。命令结果跨进程幂等、事件序号与事务数据库选型仍未完成，M3-03 保持未验收。
