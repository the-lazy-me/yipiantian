# M9-03 · 单队列模型调度

状态：已实现（2026-11-15），未验收。范围：可注入后端、懒加载、单队列串行、队列上限、任务期限、取消、闲置卸载、资源边界与完全关闭。不包含真实模型加载、真实推理、线程/异步后端、网络、云预算、UI 或游戏世界接入。

权威设计：[ADR-020](../../decisions/ADR-020-model-task-scheduling.md)；任务协议：[RECORD-02](RECORD-02-protocol.md)；上层规格：[NPC、商人与混合 AI](../../06-AI-SYSTEM.md)；计划：[M9 PLAN](PLAN.md)。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/ai/model_scheduler.gd` | 新增。`extends RefCounted`，注入后端对象；`submit`/`poll`/`cancel`/`set_enabled`/`unload`/`status`；显式 `now_utc`，无引擎时钟、场景或网络。 |
| `tests/model_scheduler_test.gd` | 新增 64 项无头检查：假后端驱动的懒加载、串行、队列满、超时、取消、闲置卸载/重载、资源边界、加载失败、后端错误、完全关闭。 |
| `docs/2.0/decisions/ADR-020-model-task-scheduling.md` | 本切片的持久裁决。 |
| `docs/2.0/milestones/M9/RECORD-03-scheduler.md` | 本记录。 |

未修改 `Game/farm/*`、`Game/world/*`、`Game/scenes/*`、`Game/ui/*`、`.github/**`、`rules/**`、任何 `PLAN.md`、`decisions/README.md` 或其它测试。`Game/ai/*.gd.uid` 由 Godot 4.7.2 首次加载自动生成。

## 后端接口

调度器只依赖四个鸭子类型方法：

```text
load() -> bool | Dictionary | void    # void 视为成功；Dictionary 读取 ok
generate(task) -> Dictionary
unload() -> void
loaded() -> bool
```

`generate` 返回：

```text
{ok: true, response: <JSON string | Dictionary>}   # 本次完成
{ok: true, pending: true}                          # 仍在运行
{ok: false, reason: "..."}                         # 后端错误
```

测试使用进程内 `FakeBackend`，不加载权重、不联网、不创建线程。真实后端只实现了协议接口，尚未接入。

## 数值与默认值

```text
DEFAULT_QUEUE_LIMIT        8（等待队列，不含在跑任务）
MAX_QUEUE_LIMIT            64
DEFAULT_IDLE_UNLOAD_SECONDS 60
DEFAULT_MAX_CANCELLED_IDS  256
MAX_CANCELLED_IDS          1024
```

- 队列上限只计等待中的任务；在跑任务不计入 `queue_limit`，但计入 `pending()`。
- 取消集合有界；超出时按插入顺序淘汰最旧 id，避免长期运行无限增长。
- 超时阈值来自任务自身的 `deadline_utc`；调度器不另设固定秒数。
- 所有配置都在构造时注入；非法值回退默认值（非整数、越界、负数）。

## 状态与接口

```text
Scheduler.new(backend, world_id, state_version, options)   # enabled/queue_limit/idle_unload_seconds/max_cancelled_ids
submit(task, now_utc)       # 协议边界检查后入队；满返回 queue_full
poll(now_utc)               # 每次最多推进一个状态转换
cancel(cancel_id, now)      # 清掉匹配的排队任务并停止在跑任务
set_enabled(value, now)     # false 立即 disabled、清队、卸载
unload(now)                 # 仅在空闲时手动卸载，否则 busy
is_cancelled / cancelled_ids / pending / status
```

`poll` 的返回状态：

```text
idle         没有排队、未加载或未到闲置阈值
unloaded     闲置达到阈值并卸载
queued       submit 成功
waiting      有任务在跑（可能刚启动或仍在 pending）
completed    响应通过协议并被接收为 suggestion
rejected     协议拒绝（原因来自 model_task.gd）
timeout      在跑任务达到 deadline
expired      排队任务在启动前达到 deadline
load_failed  后端 load 失败
backend_error generate 返回非字典或 ok=false
disabled     enabled=false
```

## 行为规则

1. **懒加载**：`submit` 不加载；第一次真正启动任务时才调用 `load()`。取消一个尚未启动的排队任务不会触发加载；`enabled=false` 时加载次数为零。
2. **单队列串行**：同一时刻最多一个 `_in_flight`；`generate` 返回 `pending` 后，后续 `poll` 只返回 `waiting`，不会再次调用 `generate`，直到任务完成、超时或被取消。
3. **超时**：在跑任务 `now_utc >= deadline_utc` 时标记 `timeout`，清除在跑状态；下一次 `poll` 才启动下一个任务。排队任务在启动前到期返回 `expired`，不调用 `generate`。
4. **取消**：匹配 `cancel_id` 的排队任务被移除；在跑任务被停止轮询并清除。已完成的 `generate` 结果在协议层仍受取消集合拒绝（`accepted=false, reason="cancelled"`）。取消本身不会再触发 `generate`。
5. **闲置卸载**：没有排队和在跑任务时，`now_utc - last_activity_utc >= idle_unload_seconds` 触发 `unload()`；`loaded()==false`。卸载后的新任务重新 `load()`。`last_activity_utc` 在加载/启动生成时更新。
6. **完全关闭**：`set_enabled(false)` 清空队列、丢弃在跑状态、把被清任务的 `cancel_id` 记入取消集合，并在已加载时卸载；之后所有 `submit`/`poll` 立即返回 `disabled`。调度器与世界规则无依赖，世界规则照常运行。
7. **失败与重试**：`load` 失败会调用 `unload()` 清理半加载状态并只让当前任务失败；后续任务会再次尝试加载。`generate` 返回 `ok=false` 或非字典只让当前任务失败。本切片没有自动重试、退避或重试次数配置。
8. **资源边界**：`submit` 复用 `ModelTask.validate`，未知类型、跨世界、状态版本不匹配、已过期、已取消、上下文 >8192 字节、输出上限越界等都在入队前拒绝，绝不进入后端。
9. **建议而非行动**：完成结果经 `ModelTask.accept` 解析后只返回 `suggestion`；调度器不写入世界、不执行模型建议、不保存历史。

## 测试

运行命令（本机 Godot 4.7.2）：

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/model_scheduler_test.gd"
```

原始末行：

```text
MODEL_SCHEDULER_TEST checks=64 failures=0
```

覆盖：

- `enabled=false`：submit/poll 均 `disabled`，加载与生成次数为 0；纯世界规则（贷款报价）仍可运行；重新启用后恢复懒加载；再次关闭卸载并清队。
- 懒加载只发生一次；串行执行；在跑期间再次 poll 不新增 `generate`。
- 队列上限 2：第三个任务 `queue_full`，释放槽位后接受；任务按 FIFO 完成。
- 在跑任务恰在 deadline 超时，之后才启动下一个；排队任务启动前过期且不调用生成；非法时钟拒绝。
- 取消在跑任务后不立即生成，下一次 poll 才启动下一个；取消排队任务不生成；非法/未知取消 id；取消集合有界淘汰。
- 闲置 59 秒保持加载、60 秒卸载；卸载后新任务重新加载；手动空闲卸载、重复卸载、忙碌时拒绝。
- 未知上下文键、超长上下文、未知类型、输出上限越界、跨世界、状态版本不匹配、过期、已取消任务均在入队前拒绝，后端生成次数为 0。
- 缺少后端接口；加载失败清理；后续任务重试加载；后端 `ok=false` 与非字典结果；`status()` 边界字段。

## 与现有规则/未来接入的交互风险

- **轮询而非线程**：本切片用同步 `generate` + `pending` 模拟在跑状态；真实推理若在独立线程或进程中运行，需要后续把完成/失败回调接入 `poll`，并保证同一任务最多一次完成。当前 `cancel` 只能让调度器不再轮询；它不能中止后端已经开始的推理，真实后端需要自己的 abort/终止路径。
- **时间单调性**：所有 `now_utc` 由调用方提供。非单调时钟会让闲置卸载和超时判断失真；接入时应使用同一时间源。
- **队列语义**：`queue_limit` 不含在跑任务；若未来要求总资源上限，应把在跑任务计入或另设并发上限。
- **无持久化**：取消集合、队列和在跑状态都在内存；重启后丢失。协议层仍会拒绝过期/跨版本任务，但不会保留取消记录。
- **建议未执行**：调度器不调用任何世界命令；后续接入必须由规则层重新校验预算、权限、库存、距离、合同与状态版本。
- **默认 8/60/256/8192**：都是实验边界，尚未由真实 M4/Windows 实测或玩家体验校准。

## 未覆盖与无法断言

- 真实 llama.cpp/MLX 后端、权重加载、内存/耗时、GPU 竞争、能耗、Windows 实机、macOS 与 Windows 双平台验证。
- 真实异步/线程/进程调度、后端 abort、完成回调、并发上限、重试与退避策略。
- 云路径、费用预留、实际用量与硬预算（M9-04）；恶意提示、模型崩溃、长回复与深度休眠（M9-05）。
- GUI、存档/会话恢复、FarmState 或场景接入；当前没有游戏运行路径调用该调度器。
- `pending` 只在假后端中验证；真实后端从未返回该状态，真实超时行为无法断言。
- 世界规则独立于调度器只在测试中用一个纯规则调用证明；完整游戏在关闭 AI 时的行为仍需 M9-05 验收。
