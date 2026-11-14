# M2-05 · macOS 单 Godot 壁纸测量入口

执行日期：2026-11-14（工具与冒烟）、2026-11-15（配对短测）。状态：配对短测完成，可支撑 macOS 采用候选 A 的方向性判断；仍无整机功率与长期驻留结论。冒烟固定提交：`31e3c3b`；配对短测固定提交：`be09071`（引擎 4.7.2-stable）。

## 环境

- macOS 27.0.1（26A434），Apple Silicon arm64，Apple M4 Pro，统一内存。
- 单屏 3840×2160 像素，缩放 2.0（逻辑 1920×1080）；Wallpaper 窗口 `size=(1920, 1080)`。
- Godot 4.7.2-stable（`4.7.2.stable.official.ed1daf0bf`），Forward+，Metal 4。
- 测量方式：同一进程内采样，不启动独立宿主；未使用 `sudo`、`powermetrics` 或网络。

## 实现

- `Game/scenes/main.gd` 增加内部开关 `--dev-wallpaper`：
  - 从 `OS.get_cmdline_user_args()` 识别，不出现在任何界面。
  - 主场景就绪后等待 `get_tree().current_scene == self`，即启动场景完成交接，再复用既有 `_enter_wallpaper()`；不复制壁纸模式逻辑。
  - 首次启动的画质选择页不会自动关闭；等待条件因此不会满足，脚本按“未进入壁纸模式”失败。`--editor` 直接加载主场景可绕过该页。
  - 壁纸模式激活时在 `_wallpaper_changed(true)` 输出唯一标记行：`WALLPAPER_ACTIVE screen=0 size=(1920, 1080)`。该打印不改变玩法或存档。
- `scripts/measure-macos.sh`：
  - `--app PATH.app` 执行包内 `Contents/MacOS/<CFBundleExecutable> -- --dev-wallpaper`，走正常启动流程。
  - `--editor`（默认）执行 `scripts/godot-macos.sh Run res://scenes/main.tscn -- --dev-wallpaper`，静音并直接加载主场景。
  - 轮询 stdout/stderr 日志与进程存活；超时、进程提前退出或出现 `STARTUP_CHOICE_READY` 均带原因失败，而不是把启动画面当作壁纸样本。
  - 就绪后先 warmup，再按固定间隔采样；`--count` 与 `--duration` 先到者停止。结束时只终止本脚本启动的进程（TERM，必要时 KILL）。

### 命令

```bash
# 冒烟：主场景直接启动，5 秒预热 + 30 秒采样
scripts/measure-macos.sh --editor --label smoke \
  --warmup 5 --duration 30 --interval 1

# 导出包测量（需要包内包含本次改动，且已有设置文件）
scripts/measure-macos.sh --app ".local/builds/macos/我有一片田.app" \
  --label wallpaper-a --warmup 60 --duration 300 --interval 5
```

输出文件位于 `.local/measurements/<UTC>-<label>.csv` 与同名 `.log`。CSV 表头：

```text
timestamp_utc,elapsed_s,phase,sample,pid,cpu_time,cpu_time_s,cpu_percent,cpu_delta_percent,rss_kib,phys_footprint_kib
```

| 字段 | 来源 | 说明 |
|---|---|---|
| `timestamp_utc` / `elapsed_s` | `date -u` / bash `SECONDS` | 采样时刻与测量窗口内偏移；整数秒。 |
| `phase` | 脚本 | 当前仅 `measure`；warmup 样本不写 CSV。 |
| `sample` | 脚本 | 从 1 递增；到达 `--count` 时停止。 |
| `pid` | `ps` | 被测 Godot 进程。 |
| `cpu_time` / `cpu_time_s` | `ps -o time` | 累计 CPU 时间原值与换算秒数。 |
| `cpu_percent` | `ps -o %cpu` | 平台报告的进程 CPU 百分比原值。 |
| `cpu_delta_percent` | 累计时间差 | 相邻样本 CPU 秒差 ÷ 实际间隔 × 100；首样本为空。 |
| `rss_kib` | `ps -o rss` | 常驻集大小，KiB；受压缩/换出影响。 |
| `phys_footprint_kib` | `footprint` | 进程 physical footprint，KiB；不可用时为空。 |

脚本同时打印 `MEASURE_READY`、`MEASURE_SAMPLES` 与 `MEASURE_SUMMARY`；汇总只描述 CSV 中的进程指标。

## 配对短测结果（2026-11-15 执行）

按上节计划执行 3 对 A/B，顺序 A→B、B→A、A→B，每轮 `--warmup 120 --duration 300 --interval 5`，每轮前把隔离存档恢复为同一份模板。A = `--dev-wallpaper`（桌面层、30 帧、隐藏 HUD）；B = 同构建直接运行主场景的普通窗口。两组均为编辑器调试构建；测量期间不操作窗口。

```text
A(pair1) cpu_median=21.6%  B(pair1) cpu_median=35.4%  A-B=-13.8pp
A(pair2) cpu_median=23.7%  B(pair2) cpu_median=36.3%  A-B=-12.6pp
A(pair3) cpu_median=24.2%  B(pair3) cpu_median=34.2%  A-B=-10.0pp
```

| 轮次 | 模式 | 样本 | CPU 中位 | CPU p10–p90 | 5 分钟 CPU 秒 | RSS 中位 / 峰值 | footprint 中位 / 峰值 |
|---|---|---|---|---|---|---|---|
| pair1-a | 壁纸 | 60 | 21.6% | 19.0–23.4% | 63.9 s | 249088 / 267712 KiB | 2338816 / 2343936 KiB |
| pair1-b | 窗口 | 60 | 35.4% | 31.8–38.2% | 105.2 s | 255776 / 400256 KiB | 2266112 / 2270208 KiB |
| pair2-b | 窗口 | 61 | 36.3% | 33.6–38.8% | 109.1 s | 251936 / 373744 KiB | 2274304 / 2278400 KiB |
| pair2-a | 壁纸 | 61 | 23.7% | 21.8–25.0% | 71.1 s | 244608 / 385456 KiB | 2316288 / 2324480 KiB |
| pair3-a | 壁纸 | 61 | 24.2% | 23.2–25.2% | 72.8 s | 247504 / 266080 KiB | 2275328 / 2284544 KiB |
| pair3-b | 窗口 | 60 | 34.2% | 32.4–38.4% | 103.5 s | 247072 / 251296 KiB | 2269184 / 2273280 KiB |

方向性结论：

- 三对中壁纸模式的进程 CPU 都低于普通窗口，差值 −10.0 至 −13.8 个百分点（相对下降约 28–39%），三对方向一致。壁纸模式的样本分布更窄（p10–p90 约 2–7 个百分点，窗口约 6–7），符合固定 30 帧、隐藏 HUD 的预期。
- 两组 footprint 都约 2.27–2.34 GiB，差异小于 3%，RSS 在 240–400 MiB 间随压缩漂移；本轮数据不支持“壁纸模式显著降低常驻内存”的说法，只能说明 CPU 时间更低。
- 测量前热身后的两次尝试被丢弃：第一次在测量期间修改了运行时代码；第二次隔离模板仍是事务账本之前的 9 键格式，6 次运行全部以 `FARM_STORE stage=corrupt` 失败。失败尝试的 CSV/日志已删除，上表只来自产生完整 300 秒样本的 6 次运行。
- 这是编辑器构建、单机单屏、单进程指标。窗口 B 的 CPU 更高部分来自可达帧率更高而非仅 HUD 显示；不能换算成功率或能耗积分，也不能据此宣称 M2-05 验收完成（缺 8 小时驻留、休眠恢复、导出包与 Windows 对照）。

## 冒烟结果

命令（实际执行，`GODOT_PATH` 指向上文引擎）：

```bash
scripts/measure-macos.sh --editor --label smoke-record2 \
  --warmup 5 --duration 30 --interval 1
```

实际输出：

```text
MEASURE_READY elapsed=14s
MEASURE_CSV .local/measurements/20261114T153912Z-smoke-record2.csv
MEASURE_SAMPLES 29
MEASURE_DURATION 30s
MEASURE_SUMMARY cpu_delta_mean=18.9% rss_mean=206639KiB rss_max=261264KiB phys_footprint_mean=2202589KiB phys_footprint_max=2205696KiB
MEASURE_DONE
```

标记行为 `WALLPAPER_ACTIVE screen=0 size=(1920, 1080)`；进程在脚本结束后已不存在。采样期间 `rss_kib` 约 153–255 MiB，`phys_footprint_kib` 约 2.10 GiB，未见增长。上述数字只用于证明链路和 CSV 可用：这是编辑器调试构建、30 秒单次样本，不能作为候选 A 的能耗、内存或长期驻留结论。

其他验证：

- `bash -n scripts/measure-macos.sh` 通过。
- 就绪超时路径：`--ready-timeout 2` 退出 1，stderr 为 `MEASURE_FAILED: WALLPAPER_ACTIVE did not appear within 2s`，脚本启动的进程无残留。
- 无头启动 `scripts/godot-macos.sh Run --headless --quit-after 240` 退出 0，正常到达 `STARTUP_CHOICE_READY`；`--quit-after` 强制退出仍打印既有 6 个资源在用告警。
- `--headless --check-only --script res://scenes/main.gd` 退出 0。

## 限制

- 没有 `powermetrics`（需 sudo），因此没有整机功率、GPU 频率/占用、唤醒次数或能耗积分。
- 进程 CPU 不等于整机功耗：其他应用、亮度、风扇、显示器、内存压缩都会影响整机功率；本工具只能比较同一机器、同一负载下的进程行为。
- `ps %cpu` 的口径依平台实现而变；CSV 同时保留 `ps` 的 `%cpu`、累计 `time` 与差算 `cpu_delta_percent`，分析时应优先使用差算值并说明间隔漂移。`footprint` 每次调用也有少量开销，样本间隔可能略大于 `--interval`（本次 30 秒得到 29 点，`elapsed_s` 按实际整秒差计算 CPU 百分比）。
- `phys_footprint` 是单进程指标，不与整机内存或 GPU 显存等同。
- 本机只有单屏 3840×2160；未验证多屏、不同缩放、外接显示器、Spaces、全屏应用遮挡、锁屏/熄屏和屏幕保护。
- `--editor` 直接加载 `main.tscn`，跳过启动场景和首次画质页，测量从既有存档的暖启动开始；不能用于启动耗时结论。
- `.app` 模式走正常启动；若没有设置文件会停在首次画质页，脚本会以 `STARTUP_CHOICE_READY` 明确失败。现有 `.local/builds/macos/我有一片田.app` 早于本次改动，未用于本轮冒烟，需重新导出后才能测。
- 脚本以 TERM/KILL 结束进程，不经过产品退出流程；进入壁纸模式时既有逻辑已保存农场，但结束样本本身不验证退出保存。
- 未采集帧时间、GPU 时间、线程数、磁盘 I/O 或后台资源释放时机。
- 壁纸模式本身固定 30 帧并隐藏 HUD；窗口对照不是只差一个开关的纯净对照，而是两种实际运行形态的比较。

## 配对短测计划（已于 2026-11-15 执行，结果见上一节）

1. 固定条件：同一提交、同一构建、同一存档快照（每轮前恢复）、同一屏幕与缩放、静音、无其他前台应用、关闭屏幕保护与通知；记录窗口是否获得焦点和是否被遮挡。
2. 分组：A = `--dev-wallpaper`（桌面层、30 帧、隐藏 HUD）；B = 同一构建 `--editor` 直接运行主场景但不带开关（普通窗口、空闲、不操作）。两组都用同一相机、季节、时间与农场状态。
3. 采样：每组 `--warmup 120 --duration 300 --interval 5`，重复 3 对；顺序 A→B、B→A、A→B 交替，抵消温度、后台同步和内存压缩漂移。每对之间保留相同冷却时间。
4. 指标：以 `cpu_time_s` 差算的 CPU 百分比与 CPU 秒、`rss_kib`、`phys_footprint_kib` 的中位数和极值为主；同时记录进程是否存活、日志中的 `WALLPAPER_ACTIVE` 与任何失败信息。
5. 判定：报告每对差值和方向一致性，不用单轮或整机功率措辞；缺测项（GPU、功率、多屏）保持缺测，不把进程指标换算成瓦特。

## 未覆盖

- 正常启动场景交接后的自动进入路径未在本轮实测：本机缺少 `settings.json`，首次画质页会阻塞；本轮只验证了直接加载主场景。代码在 `current_scene` 交接后才调用既有 `_enter_wallpaper()`，`.app` 路径仍需在有设置文件的新构建上复核。
- 已执行 3 对短测；8 小时驻留、休眠/遮挡恢复和锁屏场景仍未执行。
- 未在导出包、Intel Mac、核显、多屏或不同 macOS 版本上验证。
- 未验证桌面层级下的实际遮挡与 `window_activity` 停绘制是否按预期影响样本。

## 关联

- 能效口径：[平台边界与低功耗验证方案](../../architecture/PLATFORM-ENERGY.md)；阶段计划 [M2 PLAN](PLAN.md) M2-05。
- 桌面嵌入实现与既有验收：[M2-01 macOS 桌面嵌入](RECORD-01-macos-embed.md)。
- 命令入口补充：[开发前准备 · macOS 壁纸测量入口](../../../development-setup.md#macos-壁纸测量入口2026-11-14)。
