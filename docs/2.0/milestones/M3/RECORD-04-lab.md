# M3-04 · 多世界模拟实验入口

执行日期：2026-11-15。状态：切片完成，未表示 M3 验收。环境：macOS 27.0.1 / Apple M4 Pro；Godot 4.7.2-stable（`4.7.2.stable.official.ed1daf0bf`），`--headless`。

## 实现

- `Game/world/headless_runner.gd` 增加 `--worlds=N`（2–16）。每个世界在自己的子目录 `world-00…` 中运行同一命令计划，种子为 `base + index * 7919`，起始 UTC 由种子决定；单个世界仍走 `HeadlessWorld`、`FarmStore` 与 `FarmCommand`，不实例化主场景。
- 聚合行 `HEADLESS_WORLDS {json}` 输出：世界数、基础种子、每个世界的种子、库存、收获、命令数与事件序号、下一事件、分段数、隔离目录标签与失败列表；路径只输出仓库相对标签。
- 单个世界的输出仍为 `HEADLESS_WORLD {json}`，参数与退出码不变。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
"$GODOT" --headless --path Game --script "$PWD/tests/world_lab_test.gd"
```

结果：`WORLD_LAB_TEST checks=47 failures=0`。用例在同一台机器上运行两次三世界实验（`--worlds=3 --seed=11 --advance-seconds=9000`，播种/浇水/收获）：

- 两次运行的每个世界摘要逐项相同（种子、库存、收获、命令数、事件序号、下一事件、分段数），即同种子可重复。
- 每个世界 `committed_sequence=3`、`inventory.greens=1`、各自有独立 `farm.json`；三个派生种子互不相同。
- `root_children=0`，未加载 3D 主场景。
- 聚合输出不含 `$HOME` 绝对路径；世界目录以 `.local/verification/...` 标签出现。

干净检出 CI（`.github/workflows/rule-tests.yml`，运行 `43623633298`，提交 `607ac5f`）在 macOS 与 Windows 上均得到 `WORLD_LAB_TEST checks=47 failures=0`。

单世界直跑同一参数退出码 0，输出 `checks=39`、`failures=[]`、`committed_sequence=3`、`root_children=0`。

## 限制

- “可重复”只覆盖同机、同引擎、同命令计划与种子；不证明跨架构浮点或跨版本完全一致（当前成长计算为秒级加法，风险低但未测）。
- 每个世界共享同一份命令计划文本与派生种子，尚未支持逐世界不同计划或随机事件注入。
- 账本只保证最近 64 条命令的跨进程幂等（见 [M3-03 记录](RECORD-03-commit-recovery.md)）；实验目录会累积，脚本不自动清理。
- 未测数十个世界并发的资源上限、长时间循环或断电恢复；`--worlds` 上限为 16；本入口只在 `rule-tests.yml` 中作为夹具运行，未设置定时或结果归档。

## 关联

- 无头入口：[RECORD-01](RECORD-01-headless.md)；事件调度：[RECORD-02](RECORD-02-events.md)；事务账本：[RECORD-03](RECORD-03-commit-recovery.md)。
- 阶段计划：[M3 PLAN](PLAN.md) M3-04。
