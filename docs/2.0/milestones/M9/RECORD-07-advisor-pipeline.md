# M9-G1 · 建议组合层（调度 / 预算 / 回退）

状态：切片已实现（2026-11-16），未验收。范围：把已经存在但从未组合的 `model_scheduler.gd`、`model_budget.gd`、`model_fallback.gd` 串成一条"只产建议、不写世界"的调用管线，对外只返回结构化提案。不包含真实模型、网络、云服务、密钥、UI、世界权威接线、持久化或 Windows 验证。

权威设计：[ADR-020](../../decisions/ADR-020-model-task-scheduling.md)、[ADR-031](../../decisions/ADR-031-cloud-model-budget.md)；任务协议：[RECORD-02](RECORD-02-protocol.md)；调度器：[RECORD-03](RECORD-03-scheduler.md)；本地后端：[RECORD-04](RECORD-04-llama-backend.md)；可靠性：[RECORD-05](RECORD-05-reliability.md)；云预算与回退：[RECORD-06](RECORD-06-cloud-budget.md)；计划：[M9 PLAN](PLAN.md)。

## 缺口与决策

RECORD-03 与 RECORD-06 都写明"未与调度器接线"，`Game/` 内没有任何调用点把三个模块组合起来。本切片补上的正是这一层组合，并保持三个既有模块的公共契约不动（未修改任何既有 ai 模块）。

| 决定 | 理由 |
|---|---|
| 顺序固定为 `choose_backend` → `authorize`（仅云端）→ `submit` → 一次 `poll` | 本地/规则路径不该留下无法解释的云端预留；回退规则本身要读预算文档与可用性。先选后端再决定是否需要额度，比"先无条件授权再回退"少一条不一致路径。 |
| 本层不调用 `settle`，返回的 `budget.charged` 恒为 0 | 一次建议调用没有真实用量可结算；费用属于调用方拿到供应商结果后的动作。把 `settle` 留在本层会迫使组合层猜测 `outcome`，等于伪造账目。 |
| `budget.state` 返回候选文档副本 | 调用方决定是否保存；两个并发请求各拿自己的候选，互不影响；不读盘也不写盘。 |
| 真实后端经注入的 `Callable` 获取，签名 `(kind, request) -> Object` | 本层不创建进程、不加载权重、不联网。provider 允许返回 `null` 或不合鸭子类型的对象，此时拒绝并给出具名原因。 |
| 真实默认注入为空 `Callable()` | 没有 provider 时云端路径返回 `backend_unavailable`，规则路径照常给出"没有建议"。 |
| 请求字段严格白名单 | 与 `model_task.gd` 的上下文白名单纪律一致；未知字段直接拒绝，避免调用方把命令或隐藏状态塞进请求。 |
| `prompt` 只落到 `visible_context.message` | 复用协议的上下文校验与 8192 字节上限；请求本身不进入任务文档。 |
| 本层不导入 `Game/world/**`、不持有世界文档 | 返回字典里没有 `state`、`command`、`action` 一类键，测试对键集做精确断言。 |

## 接口

```text
ModelAdvisor.new(provider: Callable = Callable())
advise(request: Dictionary, now_utc: float) -> Dictionary
```

请求：

```text
{
  id: String, type: "intent"|"dialogue"|"summary",
  prompt: String,                       # 非空，成为 visible_context.message
  context: Dictionary,                  # 可选，15 个白名单字段，不得含 message
  world_id: String, state_version: String, deadline_utc: float,
  budget: <Budget 文档>,                # Budget.valid 必须通过
  estimate: int,                        # >=1，仅云端路径用于预留
  cloud_available: bool, local_available: bool,
  backend_preference: "auto"|"local_first",   # 可选
  scheduler_options: {enabled, queue_limit, idle_unload_seconds,
                      max_cancelled_ids},       # 可选，透传给调度器
}
```

返回键集精确为：

```text
{ok, status, reason, detail, backend, request_id, budget, scheduler, suggestion}
budget    = {authorized, estimate, charged, remaining, state}
scheduler = {status, task_id}
```

- `status`：`proposed` / `no_suggestion` / `rejected`。
- `proposed` ⇔ `ok=true`，`reason` 为空，`suggestion` 非空。
- `no_suggestion`：本层能给出确定结论，但这次没有可采纳的建议（额度耗尽、周期过期、云未授权、无回退后端、云端异步未完成）。
- `rejected`：请求、预算或调度边界拒绝了这次调用（含 `backend_unavailable`、`budget_denied`、`duplicate_request`、`scheduler_*`）。
- `suggestion` 只可能是 `{intent, confidence, reason, state_version}` 或 `{text}`，已由 `ModelTask.accept` 解析；永远不包含命令。

具名原因：

```text
invalid_request / invalid_budget / budget_denied / duplicate_request
no_backend / backend_unavailable / cloud_disabled / budget_exhausted
period_elapsed / scheduler_rejected / scheduler_disabled
scheduler_load_failed / scheduler_backend_error / scheduler_waiting
```

`detail` 保留原始模块的稳定原因（如 `over_budget`、`over_request_cap`、`boom`），便于调用方区分同一大类下的具体边界。

## 注入与副作用

- provider 只被调用一次，参数是 `backend_kind` 与请求的深拷贝；provider 构造后端应当无副作用。
- 后端对象只需满足调度器的鸭子类型：`load / generate / unload / loaded`，可选 `poll / abort`。
- 本层不读磁盘、不读引擎时钟、不起线程、不发网络请求、不写任何文件或世界文档。
- 没有新增配置文件、环境变量或全局单例。

## 验证

命令：

```bash
G=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 180 "$G" --headless --path Game \
  --script "$PWD/tests/model_advisor_test.gd"
```

原始末行（退出码 0）：

```text
MODEL_ADVISOR_TEST checks=251 failures=0
MODEL_SCHEDULER_TEST checks=72 failures=0
MODEL_BUDGET_TEST checks=225 failures=0
FONT_COVERAGE_TEST checks=1272 failures=0 missing=0
```

`tests/model_fallback_test.gd` 在仓库中不存在；回退规则的 4 种输入与 1000 次循环断言一直放在 `tests/model_budget_test.gd` 的 `_test_fallback` / `_test_long_run` 里（RECORD-06 的改动表也这样记录），本次复跑即该文件。

覆盖要点：

| 要求 | 断言 |
|---|---|
| 正常路径 | 云端授权后 `proposed`，预留 30、剩余 970、`charged=0`、`budget.state` 合法且只含本次预留；懒加载一次、生成一次；提示进入 `visible_context.message` |
| 本地路径 | 断网且本地可用时选 `local`，不碰云端预算，剩余额度不变；`local_first` 同样不预留 |
| 预算不足 | 已用+预留达硬上限返回 `no_suggestion/budget_exhausted`；单请求超过上限与超过单请求上限返回 `budget_denied` 且 `detail` 具名；周期过期返回 `period_elapsed` |
| 无可用后端 | 云关闭或断网且无本地返回 `no_suggestion`；provider 缺失或对象接口不全返回 `rejected/backend_unavailable`，已产生的预留候选仍合法 |
| 调度拒绝 | `scheduler_options.enabled=false` 返回 `scheduler_disabled`；后端 `ok=false` 返回 `scheduler_backend_error` 且 `detail=boom`；异步 `pending` 返回 `scheduler_waiting` 且无建议 |
| 并发互不影响 | 共享同一输入文档的两次请求各得自己的候选（剩余 970 / 960）；沿用第一份候选时累计为 930、预留 2；修改返回的候选不污染后续调用；同一 id 重放授权返回 `duplicate_request` |
| 严格键集 | 成功、缺字段、非字典、非法预算四类返回的顶层/预算块/调度块键集逐一精确比对；建议只能是意图或文本键集 |
| 无世界路径 | 递归收集全部键名，断言不出现 `command`/`actions`/`mutate`/`write`/`save`/`file`/`path` 等；顶层没有 `state` 键 |

字体回归：新增中文注释只使用现役字体内已有字形（初版用到的"估"字不在子集内，已改写用字，未改字体文件）。最终复跑结果即上表 `FONT_COVERAGE_TEST checks=1272 failures=0 missing=0`。

## 未覆盖与限制

- **无真实云**：没有供应商客户端、密钥、HTTP、计费或重试；`cloud` 路径的全部“后端”仍是注入的假对象。
- **无 UI**：没有任何面板展示提案、剩余额度或回退原因；调用入口尚未接到游戏运行路径。
- **无权威接线**：建议不会被写成权威事件或世界命令；调用方仍需重新校验权限、库存、距离、合同与状态版本。
- **无持久化**：`budget.state` 只在内存中回传，重启后没有预算或预留；取消集合与队列也随对象销毁。
- **只推进一次**：云端异步后端返回 `pending` 时本层返回 `scheduler_waiting`，后续 `poll` 需调用方自行持有调度器；本层不保存跨调用的在跑状态。
- **无真实模型**：未加载权重、未测吞吐/内存/能耗，未在 Windows 实机验证。
- **费用未校准**：`estimate` 完全由调用方给出，没有 tokenizer 或价格表；`charged` 恒为 0 由调用方结算。
