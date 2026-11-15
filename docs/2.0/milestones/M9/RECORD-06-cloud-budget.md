# M9-04 · 云端模型预算、最小授权与回退规则

- 状态：切片已实现（2026-11-16），**M9-04 未验收**
- 范围：云端调用的显式授权开关、单请求/周期/并发硬预算、估算预留、真实用量结算、周期切换、有界事件日志，以及断网/额度耗尽时的确定性后端回退
- 不覆盖：真实云服务、真实计费、真实 tokenizer、任何网络与密钥、UI、调度器接线、Windows。本切片只接受调用方注入的用量与费用事件，不发起任何外部请求，也不产生任何费用

权威设计：[ADR-031](../../decisions/ADR-031-cloud-model-budget.md)；任务协议：[RECORD-02](RECORD-02-protocol.md)；调度器：[RECORD-03](RECORD-03-scheduler.md)；本地后端：[RECORD-04](RECORD-04-llama-backend.md)；可靠性：[RECORD-05](RECORD-05-reliability.md)；上层规格：[云端成本与隐私](../../06-AI-SYSTEM.md)；计划：[M9 PLAN](PLAN.md)。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/ai/model_budget.gd` | 新增。纯规则：`initial_state` / `authorize` / `settle` / `rollover` / `snapshot` / `valid`。写时复制，所有时刻与费用由调用方传入，无系统时钟、磁盘、网络或 RNG。 |
| `Game/ai/model_fallback.gd` | 新增。纯函数 `choose_backend(budget_state, now_utc, cloud_available, local_available)`，返回 `{backend, reason}`，不读任何全局。 |
| `tests/model_budget_test.gd` | 新增 225 项无头检查：授权→计费、重放、冲突、三类具名拒绝与状态不变、关闭云、失败退款、周期切换、日志有界、严格校验、快照、四种回退输入与 1000 次循环。 |
| `docs/2.0/decisions/ADR-031-cloud-model-budget.md` | 本切片的持久裁决（预留、退款、周期归属与回退优先级）。 |
| `docs/2.0/milestones/M9/RECORD-06-cloud-budget.md` | 本记录。 |
| `.github/workflows/rule-tests.yml` | 纯规则组登记 `model_budget_test`，加一行注释。 |

未修改 `Game/farm/**`、`Game/world/**`、`Game/scenes/**`、`Game/ui/**`、`Game/platform/**`、`Game/ai/model_task.gd`、`Game/ai/model_scheduler.gd`、`Game/ai/llama_cpp_backend.gd`、`docs/2.0/release/**`、其他里程碑目录或 `rules/project-context.md`。`Game/ai/*.gd.uid` 由 Godot 4.7.2 首次加载自动生成。

## 文档形状

```text
{
  config: {
    enabled: false,             # 云端授权开关，默认关闭
    period_seconds: 86400,      # 预算周期
    hard_limit: 1000,           # 每周期硬上限
    request_limit: 100,         # 单请求估算上限
    concurrency_limit: 2,       # 未结算预留并发上限
  },
  used: { period_start_utc: 0.0, cost: 0 },
  reservations: { "<request_id>": { estimate, period_start_utc, created_utc } },
  settled: { "<request_id>": {
    estimate, outcome, actual_usage, actual_cost, charged, at_utc } },
  events: [ { at_utc, kind, request_id, reason, amount } ],
  total_cost: 0,
}
```

所有金额都是抽象的非负安全整数，单位由调用方决定（分、厘或供应商积分）；切片不假设任何货币。`outcome` 只接受 `ok` / `failed` / `timeout` / `offline` / `cancelled`。

## 预算与退款语义

- **授权只占额度，不计已用**：`authorize` 把估计值写进预留表；剩余额度 = `hard_limit − used.cost − 所有预留估计值`。这保证并发请求不能越过硬预算，而不需要真实后端。
- **只有 `ok` 计费**：`settle` 在 `outcome=ok` 时把 `actual_cost` 加入本周期已用与 `total_cost`，其余四种结果一律 `charged=0`。理由：失败、超时、离线、取消都没有可归因的成功服务；把它们的估算值计入已用会让一次断网永久吞掉额度，并把“预算”变成“尝试次数”。`actual_cost` 仍写入 `settled` 行作为对账证据，因为真实供应商可能在超时后已经计费，接入真实云时应由适配器把该金额作为下一周期的人工对账或单独科目处理，而不是让规则层猜测。
- **实际费用可以越过估算与上限**：真实账单大于授权估计时按实际值全额记入（已用可能暂时超过 `hard_limit`），下一次 `authorize` 会因此返回 `over_budget`，直到周期切换。规则不截断真实费用，否则总账与供应商账单不一致。
- **重放不二次计费**：已结算 id 再 `settle` 返回首次结果（`duplicate=true`，不带新文档）；已预留/已结算 id 再 `authorize` 返回首次结果；换估计值复用同 id 返回 `command_conflict`。这使客户端安全重试，不会因为超时重发而扣两次。
- **已结算 id 重放优先于开关**：即使云在重试期间被关闭，同一 id 仍返回首次结果，避免把“已发生的调用”报告成“未授权”。
- **周期切换保留未结算预留**：`rollover` 清零 `used.cost`，但预留带着自己的 `period_start_utc` 进入新周期并继续占用额度与并发。否则跨周期边界前发出的请求可以在新周期再多开一批，等于绕过并发上限。未结算预留最终按真实结算时刻计入**结算时所在周期**，`settled.at_utc` 与 `total_cost` 保持可追溯。
- **过期周期拒绝新授权与结算**：`authorize` 在 `now_utc` 达到周期终点时返回 `period_elapsed`，要求调用方先 `rollover`；`settle` 同理，晚到的完成不能把费用记进已关闭的周期（先 rollover 会把它记入结算时所在周期）。模块不隐式切换周期，保持命令显式。
- **事件日志有界**：最多 256 条，按时间淘汰最旧；`settled` 最多 256 行同样是重放窗口，亦按时刻淘汰。超出后旧 id 会退化为 `unknown_request`，这是明确的有界语义，不是缺口。
- **不持久化**：本切片只产出文档，不写盘；持久化与重启重放留给宿主接入。

## 回退契约

`choose_backend` 的优先级固定：

```text
invalid_state / invalid_time        -> rules（原因同名）
enabled=false                       -> rules（cloud_disabled）
cloud_available=false               -> local（有本地后端）或 rules（cloud_unavailable）
now_utc >= 周期终点                 -> local/rules（period_elapsed）
已用+预留 >= 硬上限                 -> local/rules（budget_exhausted）
预留数 >= 并发上限                  -> local/rules（concurrency_full）
其余                                -> cloud（reason 为空）
```

云不可达优先于预算耗尽：调用方需要知道“断网”而不是“没钱”。回退函数只读传入的预算文档与两个布尔标记，不读全局、时钟或网络；同一组输入必定同一输出。

## 验证

命令：

```bash
G=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 300 "$G" --headless --path Game \
  --script "$PWD/tests/model_budget_test.gd"
```

原始末行（退出码 0）：

```text
MODEL_BUDGET_TEST checks=225 failures=0
```

覆盖要点：

| 要求 | 断言 |
|---|---|
| 授权→结算计费 | ok 计实际费用；已用、累计与落地行一致 |
| 重放不二次计费 | 重复 settle 返回首次 `charged`，不产生新文档 |
| 换估计值同 id | `command_conflict`，预留不变 |
| 三类硬拒绝 | `over_request_cap` / `over_budget` / `over_concurrency`，逐字段比对拒绝前后文档相等 |
| 云关闭 | `cloud_disabled`；关闭后重放已有 id 仍幂等 |
| 退款 | failed/timeout/offline/cancelled 均 `charged=0`、释放预留、后续额度可用 |
| 周期切换 | 已用归零、累计不清零、预留保留并记所属周期、跨周期预留仍占额度；关闭周期内结算被 `period_elapsed` 拒绝 |
| 事件日志有界 | 400 次授权/结算后恰为 256 条，最旧被淘汰 |
| `valid()` | 缺键、多键、负数、小数、超安全整数、非布尔开关、零周期、零并发、超量日志、非 ok 扣费、同 id 双表、超单请求估计、超并发预留、未来周期预留、累计小于周期已用 |
| 回退四态 | 未启用/断网/耗尽/正常各自确定后端；断网优先于耗尽；20 次重复一致 |
| 1000 次循环 | 跨多个周期后文档合法、日志/落地/预留有界、`total_cost` 精确等于逐条 ok 费用之和 |

回归：`FONT_COVERAGE_TEST 1273/0`（本切片新增的中文注释与文档均被现役字体覆盖，未新增字形）。

## 未覆盖与限制

- **未接入真实云服务**：没有任何 HTTP 客户端、密钥、供应商 SDK 或网络请求；`actual_usage`/`actual_cost` 完全由测试注入。
- **未产生任何费用**：测试中的金额是抽象整数，没有调用任何付费接口。
- **未接 UI**：`snapshot()` 已给出只读投影，但没有任何面板或入口展示预算与回退状态。
- **未与调度器接线**：`model_scheduler.gd` 保持只读参考，本切片不改它；真实适配器仍需在提交任务前后调用 `authorize`/`settle`，并在 `choose_backend` 返回非 cloud 时改走本地/规则路径。
- **未持久化**：文档不写盘，重启后没有跨启动预算；预算周期与账期一致性需要在宿主层定义。
- **未处理供应商超时已计费**：规则层只记录 `actual_cost` 证据，未实现人工对账、下一周期补记或争议流程。
- **未验证 Windows**：只在本机 macOS 上运行。
- **未校准真实成本**：费用单位、估算方法（token/字节/供应商报价）与周期长度都是实验值。

## 下一步

1. 在真实云适配器里把供应商的用量/账单事件转换为 `settle`，并确认估算值与实际值的偏差范围。
2. 定义预算文档的持久化位置与原子写入，接上重启恢复。
3. 在 UI 中展示剩余额度、当前后端与回退原因；断网/耗尽只做一次简短提示。
4. 调度器接线：提交前 `authorize`，完成后 `settle`，`choose_backend` 决定 local/rules。
