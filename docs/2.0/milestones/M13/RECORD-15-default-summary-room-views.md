# M13-15 · 摘要默认携带单位/组织/基金/公共项目只读视图

日期：2026-11-16。状态：**本机无头切片完成，未验收**。范围：让 ADR-027 的默认摘要
（`project_summary()`）携带单位、组织、公共基金与公共项目四个只读视图块，使客户端不必
每次打开面板都另发一次 `state` 请求。关掉的是既有记录里反复出现的缺口：
[M11-08](../M11/RECORD-08-organization-authority.md)、
[M8-07](../M8/RECORD-07-public-fund-authority.md) 与 M12 单位/公共项目面板的“只能靠
`state` 请求刷新”。本切片不新增权威写入口，不改规则、存档格式、RPC 或面板。

前置：[ADR-027 · 摘要可见性](../../decisions/ADR-027-summary-visibility.md)、
[ADR-026 载荷上限](../../decisions/ADR-026-network-payload-limits.md)、
[M4-12 · 摘要投影](../M4/RECORD-12-summary-projection.md)。

## 边界

- 只修改 `Game/world/world_projection.gd` 与 `tests/world_projection_test.gd`，新增本文。
- 未修改 `Game/world/world_host.gd`：`_summary_document()` 已经把
  `WorldProjection.project_summary()` 的结果原样交给 `_send_summary()`，投影内容变化
  不需要发送端配合。
- 未修改 `Game/world/headless_world.gd`、`Game/scenes/**`、`Game/world/*member/client*`、
  `Game/ui/**`、`.github/**`、字体文件。
- 未新增消息类型、RPC、请求或持久化字段；四个视图继续由 `HeadlessWorld` 的
  `units_view()`、`organizations_view()`、`funds_view()`、`public_works_view()` 派生。
- 未把纠纷、决议、参与、交战等大体量文档放进摘要：这些视图有三级隐私与小窗口语义，
  继续走各自的 `state` 请求。

## 决定

1. **只加真正被面板使用的公开事实块。** 四块分别是战术名册、成员与职位、公共财政、
   公共项目预算；每行字段严格取自现有面板已经渲染的列，不新增字段。
2. **逐块裁剪但不切割行。** 每块要么整块发送，要么发送与权威视图相同的空形状
   （`{"units": []}` 等）。客户端因此可以无条件读取 `summary.units` 等键，无需判断
   “摘要比面板请求旧”的特殊形状。
3. **角色分级沿用视图自身的语义。** 四个权威视图都没有“按查看者不同的私密段”，所以
   member、visitor、相关成员得到同一批公开行（匿名成员也一样，它本来就能读到公开
   名册与 `state`）。只有不在 `WorldInvite.ROLES` 中的未知角色不发任何行；已加入会话
   不可能出现该值。
4. **确定性优先级。** 按 `OPTIONAL_VIEW_KEYS` 顺序（units → organizations → funds →
   public_works，战术名册优先、最不常变的公共项目最后）逐块尝试；只有“已接纳块 + 本块”
   的 JSON 仍不超过 `OPTIONAL_VIEW_BUDGET_BYTES`（16 KiB）时才接纳。放不下就跳过该块并
   继续尝试后面的小块，绝不截断行。
5. **48 KiB 仍是硬上限。** `_encode_document()` 仍决定最终能否上线：超预算压缩后仍超限时
   回具名 `payload_too_large` 拒绝，不发半份文档。投影内的 16 KiB 额度只是防止可选块挤掉
   可恢复快照。
6. **摘要里没有权威写入口。** 四块的行白名单不含 `commands`、`command_results`、
   `history`、`account_id`、`record_command_id`、`payload` 等派生命令或内部结构。

## 字段与形状

| 摘要键 | 数组键 | 行字段 | 来源 |
|---|---|---|---|
| `units` | `units` | `id, owner, kind, people, equipment, station, unfed_days` | `units_view()` |
| `organizations` | `organizations` | `id, name, created_utc, members, roles` | `organizations_view()` |
| `funds` | `funds` | `fund_id, org_id, keeper, balance, spent, contributors` | `funds_view()` |
| `public_works` | `projects` | `project_id, kind, parcel_id, funded, pledged, status, built_utc` | `public_works_view()` |

- 行按各自 id 升序排序，与权威视图一致。
- 缺失或不可用的块返回 `{"units": []}` 等空形状，不是缺键。
- `organizations` 不下发 `account_id` 与 `history`；`funds` 不下发 `history`；单位不下发
  `recruited_utc`、`record_command_id` 或命令记录。

## 验证

命令：

```sh
G=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 180 "$G" --headless --path Game \
  --script "$PWD/tests/world_projection_test.gd"
```

末行：

```text
WORLD_PROJECTION_TEST checks=258 failures=0 dir=.../world-projection-637254
```

同轮打印的度量：

```text
SUMMARY_WITH_VIEWS raw=44116 wire=44116 compressed=false
OPTIONAL_VIEW_BUDGET units_raw=18763 allowance=16384
PROJECTION_BUDGET raw=320594 wire=11210 compressed=true
```

覆盖：

| 用例 | 检查 |
|---|---|
| 空世界 | 四个键都以空数组出现，摘要仍能经 48 KiB 线预算编码 |
| 有内容的世界 | 单位/组织/基金/项目各一行，字段与权威视图逐项一致，内部字段缺席 |
| 角色 | member、visitor、相关成员匿名视角得到同一批行；未知角色得到空形状 |
| 块预算 | 64 支满长 id/驻地的单位块超出 16 KiB 额度，被整块舍弃；后面三块仍被接纳；接纳组合仍 ≤ 额度 |
| 48 KiB 边界 | 不可压缩的超限文档在 `WorldPayload.encode()` 以 `payload_too_large` 具名拒绝且无半份载荷 |
| 确定性 | 同一权威快照重复投影，四个块逐字节相同 |
| 无写入口 | 两套夹具的所有行都不含 `commands`/`command_results`/`history`/`account_id`/`record_command_id`/`payload` 等键 |

回归：

```text
HEADLESS_WORLD_RUNTIME_TEST checks=83 failures=0
WORLD_PAYLOAD_TEST checks=67 failures=0
WORLD_SNAPSHOT_TEST checks=33 failures=0
M4_SYNC_TEST checks=39 failures=0
M4_JOIN_TEST checks=67 failures=0
M4_SERVER_TEST checks=84 failures=0
UNIT_NETWORK_TEST checks=54 failures=0
WORLD_RATE_LIMIT_TEST checks=21 failures=0
WORLD_INVITE_TEST checks=33 failures=0
FONT_COVERAGE_TEST checks=1272 failures=0 missing=0
```

`world_projection.gd` 与测试均通过 `--headless --check-only`。

## 未覆盖

1. **真实 WSS 端到端。** 夹具直接读 `WorldHost._summary_document()` 与
   `WorldProjection.project_summary()`，没有真实会话、RPC 顺序或重连。
2. **真实预算边界。** 16 KiB 额度只由 64 单位构造块验证；组织 256 人、基金 256 缴入者、
   32 公共项目的组合上限没有逐个构造。
3. **客户端消费。** 现有面板仍按 `state` 请求刷新；本切片只保证摘要里有正确的只读块，
   没有把 `main.gd` 的面板改成读摘要（明确不在本切片范围），因此“少一次请求”的收益尚未
   体现在界面路径上。
4. **Windows 与真实跨机。** 只在 macOS 无头运行。
5. **大体量文档。** 纠纷、决议、参与、交战仍不进摘要，继续按需拉取。

## 需要后续切片

1. `Game/scenes/main.gd` 的 `_open_governance()`、`_open_units()`、`_open_funds()`、
   `_open_public_works()` 目前先展示上次视图再发 `state`；可改为先读
   `remote.member.state.<block>` 作为初始视图，`state` 仅在需要最新值或摘要缺块时发送。
   这需要同时确认“摘要缺块”与“空房间”的可区分性（当前二者形状相同，按设计不区分）。
2. 面板若要求“摘要块被预算裁剪”可见，需要一个只读标记（例如摘要顶层
   `views_complete: bool`）；本切片为避免新增协议字段没有加。
3. `world_host.gd` 的 `_send_summary()` 回退只删 `fields` 再压缩一次；若将来 16 KiB
   额度调大，可考虑先删 `public_works` 再重试。当前无需改动。

## 关联

- [M13 PLAN](PLAN.md) M13-01 跨系统整合。
- 字段矩阵与投影原则：[ADR-027](../../decisions/ADR-027-summary-visibility.md)。
- 摘要投影的实现与预算：[M4-12](../M4/RECORD-12-summary-projection.md)。
- 四个视图的原始边界：[M11-08](../M11/RECORD-08-organization-authority.md)、
  [M8-07](../M8/RECORD-07-public-fund-authority.md)、
  [M12-06](../M12/RECORD-06-unit-authority.md)。
