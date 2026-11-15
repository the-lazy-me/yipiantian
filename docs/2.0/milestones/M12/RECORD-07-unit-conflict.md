# M12-01 / M12-03 交叉 · 单位交战损失桥接（最小切片）

执行日期：2026-11-15。状态：切片完成，不表示 M12-01、M12-03 或 M12 验收完成。前置：[M12 PLAN](PLAN.md)、[RECORD-02 · 参与制度](RECORD-02-participation.md)、[RECORD-03 · 交战与转移](RECORD-03-settlement.md)、[RECORD-05 · 单位与补给](RECORD-05-units.md)。

## 问题

M12-01 已有单位名册、人数、装备与派生战力；M12-03 已有单次交战结算、资源冻结和唯一结果。两者之间没有桥接：结算只知道抽象 `troops` 和资源整数，不知道这些兵力来自哪些单位，也不会把交战损失写回单位人数。直接各自接入权威会让“谁参战、损失记到哪支单位、重试是否重复减员”分散在多个入口。

本切片只建立可以独立验证的纯规则桥接：输入已有单位文档、参与制度、结算上下文和显式请求，输出候选单位文档与结算结果。它不重复实现参与窗口、损失公式、战利品或守恒规则，也不扣现金、不写农场、不发放战利品。

## 边界

- 新增 `Game/conflict/unit_conflict.gd` 与 `tests/unit_conflict_test.gd`。
- 未修改 `Game/conflict/unit_state.gd`、`Game/conflict/participation_state.gd`、`Game/world/conflict_settlement.gd`、`Game/farm/*`、`Game/ui/*`、`main.gd`、`WorldHost`、`HeadlessWorld`、`.github/workflows`、`rules/project-context.md`、M12 `PLAN.md`。
- 无 RNG、无系统时钟、无磁盘、无场景、无网络；`now_utc` 显式传入，同一输入得到同一输出。
- 写入口写时复制；失败只返回 `{ok:false, reason}`，不带候选文档，也不修改任何输入。
- 不读取 `FarmState`、经济账本或农场存档；单位文档不携带现金/物资。

## 请求与投影

```text
request = {
  id,
  attacker, defender,
  attacker_units: [unit_id, ...],
  defender_units: [unit_id, ...],
  resources: {
    "<attacker>": { cash, supplies },
    "<defender>": { cash, supplies },
  },
  x, z, defender_online, at_utc,
  target_parcel?,                 # 可选
}
```

- `attacker_units` / `defender_units` 必须非空、无重复、不能跨方重复，且每个 id 必须存在并属于对应一方 `owner`；否则分别返回 `empty_units` / `duplicate_unit` / `unknown_unit` / `not_owner`。
- 单位列表在桥接层复制后按 id 升序排列，不修改请求或单位文档。
- 投影：

```text
troops = Σ 参战单位 people
power  = Σ capability(unit).power
```

- 结算命令使用 `troops = Σ people`；`power` 只随结果返回，不参与损失计算，因为既有结算命令没有战力字段。
- 现金/物资不由单位文档推导，也不能凭空生成。`resources` 必须恰好覆盖进攻方与防守方两条 `{cash, supplies}` 非负整数行；新结算时把它们写入结算上下文副本的对应行。资源不足、负值、缺行、多余键都返回 `invalid_resources`。
- 参与资格、区域、窗口、同意、退战、离线上限与目标累计完全交给 `conflict_settlement.gd`；桥接层不复制这些规则。
- 分离的 `participation_document` 只用于严格校验与世界一致性；结算实际读取 `settlement_context.participation`。因此回放时传入首次的参与制度文档也不会覆盖上下文里已推进的耐久交战行。

## 损失分摊规则

1. 调 `ConflictSettlement.settle(working_context, command, now_utc)`；失败原因原样透传。成功时 `outcome.losses` 是本次交战中进攻方兵力的损失，防守方在同一结算里承担的是现金与物资损失（`freeze` / `taken_*`），不是人数损失。
2. 只把 `outcome.losses` 映射到进攻方参战单位；防守方参战单位保持不变。本切片不另设伤亡公式，也不把同一数值再摊到防守方凭空制造减员。
3. 分摊只遍历请求列出的进攻方单位，未参战单位不受影响：

```text
total = Σ 进攻方参战单位 people
share_i = total_loss * people_i / total        # 整数向下取整
remainder = total_loss - Σ share_i
```

4. 余数按单位 id 升序补到仍有人数的单位，优先最小 id；某单位补到人数为 0 后，剩余部分顺延给下一支。因此“余数给 id 最小的单位”在最小单位容量不足时不会产生负人数。
5. `total_loss >= total` 时进攻方参战单位全部从名册移除；否则逐单位写入 `people - loss`，归零单位移除。
6. 只修改候选单位文档的 `units` 与 `sequence`；不追加招募/解散命令，不写歼灭事件，不扣现金、不写农场、不发放战利品。结算返回的 `freeze`、`outcome`、`next_context` 原样放在 `settlement` 中，由权威落资产。

返回：

```text
{
  ok, reason, duplicate,
  outcome,        # 结算 outcome
  units,          # 候选单位文档
  settlement,     # settle() 的完整返回，原样
  projection: { attacker: {...}, defender: {...} },
}
```

## 幂等

- 新结算时把显式 `resources` 覆盖到结算上下文副本；命令 id 已在 `consumed` 时保留输入上下文，不回退首次结算后的资源状态。
- 同 id 同结算 payload 由结算层回放首次 `outcome` / `freeze`；桥接层用同一 `outcome` 重新映射损失，因此重发首次单位文档会得到相同候选。`duplicate=true`。
- 同 id 改变兵力、时间、位置等使结算 payload 不同的请求返回 `duplicate_command`。
- 限制：结算 payload 不含单位 id 列表。改变单位组成但保持总人数不变时，结算层无法区分。桥接层也没有额外持久化位置，不能自行记录该指纹。
- 限制：回放应重发首次单位文档。若调用方已应用候选文档再回放，桥接层无法从输入区分“已应用”，会按同一 `outcome` 再次映射。

## 原因表

| 原因 | 含义 |
|---|---|
| `invalid_units` | 单位文档未通过 `unit_state.valid()`，或单位 id/列表形状非法，或候选文档校验失败 |
| `invalid_participation` | 参与制度文档未通过 `Participation.valid()` |
| `invalid_request` | 请求非字典、缺/多键、id 非法、单位列表非数组 |
| `invalid_attacker` / `invalid_defender` | 玩家 id 非法或为 `public` |
| `same_player` | 进攻方与防守方相同 |
| `empty_units` | 任一方单位列表为空 |
| `duplicate_unit` | 同一方或跨方重复列出单位 id |
| `invalid_resources` | 资源不是恰好覆盖双方的非负整数行 |
| `wrong_world` | 单位文档、参与制度与结算上下文世界不一致 |
| `unknown_unit` / `not_owner` | 单位不存在，或不属于请求指定的一方 |
| `invalid_context` | 结算上下文不合法 |
| 结算原因 | `peace_time`、`no_consent`、`stale_window`、`target_cap`、`insufficient_resources`、`duplicate_command` 等由结算层原样透传 |

失败路径都不返回 `units`。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/conflict/unit_conflict.gd` | 新增纯规则桥接：请求校验、单位投影、结算调用、确定性损失分摊、幂等回放 |
| `tests/unit_conflict_test.gd` | 新增夹具，82 项检查 |
| `docs/2.0/milestones/M12/RECORD-07-unit-conflict.md` | 本记录 |

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian
perl -e 'alarm shift; exec @ARGV' 180 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/unit_conflict_test.gd"
```

原始末行：

```text
UNIT_CONFLICT_TEST checks=82 failures=0
```

回归原始末行：

```text
UNIT_STATE_TEST checks=182 failures=0
CONFLICT_SETTLEMENT_TEST checks=140 failures=0
```

覆盖矩阵：

| 用例 | 检查 |
|---|---|
| 正常交战 | 合法结算；输入单位/上下文/参与制度/请求逐字节不变；损失受参与窗口上限约束；兵力等于参战人数和；capability 汇总双方战力；资源投影；进攻方按比例分摊、防守方不减员；未参战单位不变；序列推进；候选文档有效；结算结果原样返回 |
| 余数规则 | 进攻方 100/50 人承担 100 损失：66/33 后余数 1 给最小 id，得到 67/33；防守方 120/80 人保持 120/80 |
| 打光 | 进攻方参战单位人数不足时全部消失；同侧未参战单位与防守方单位保留 |
| 守卫 | 非 owner（双方）；未知单位；空列表（双方）；同方/跨方重复；非字典、多键、缺键请求；非法进攻方、自攻；资源缺行/负值/多余键；非数组单位列表；非法单位/参与/上下文文档；拒绝均无候选且单位不变 |
| 拒绝透传 | 和平 `peace_time`；未同意 `no_consent`；窗口外 `stale_window`；显式资源不足 `insufficient_resources`；拒绝不修改单位 |
| 幂等 | 同 id 同 payload `duplicate`、结果/冻结项/候选一致；同 id 改时间或改兵力 `duplicate_command`；冲突不修改输入 |
| 确定性 | 同输入逐字节相同；单位列表顺序不影响分摊 |
| JSON 往返 | 候选文档往返仍有效；用往返文档与首次 `next_context` 在第二窗口继续交战；单位消失与剩余人数正确 |
| 写时复制 | 成功与全部失败路径都不修改输入文档 |

## 未覆盖

- 网络与权威接线：没有 sidecar 存储、`HeadlessWorld` 加载/保存、`WorldHost` 命令入口、成员/访客门、客户端方法或 RPC。
- 真实资产扣除：不扣现金、粮草或库存，不读取 `FarmState` / 经济账本；`freeze` 与 `next_context` 只交给调用方。
- 战利品发放：不发放、不运输、不入库；战利品与销毁量仍由结算结果描述。
- UI：没有参战单位选择、损失预览、战报或候选文档落盘确认界面。
- 战斗模型：没有独立胜负、双方不同伤亡公式、装备对战损的影响或士气；防御方单位人数损失尚未建模，资源损失仍由结算的 `freeze` 承担。
- 单位组成幂等：结算 payload 不含单位 id 列表；同 id 改变组成但总人数不变无法识别。
- 已应用回放：桥接层无额外持久状态，无法识别调用方是否已应用候选文档。
- 歼灭事件：被打光单位只从名册移除，没有独立伤亡/歼灭记录或战报。
- 命令记录：桥接损失不写入 `commands`，只推进 `sequence`；名册上限、补给时刻与欠供状态不受影响。
- 存档：不进入农场文档；没有 sidecar 位置、版本、原子写、损坏恢复或重启幂等测试。
- 组织与代行：`owner` 仍是声明式 player id，不校验组织、职位或离线代行。
- 多房间：单文档单世界；跨房间共享单位与预算未处理。
- 身份可信：所有 id 都不是密码学凭据。
- 只在本机 macOS 无头模式验证；未在 Windows/CI 运行。

## 关联

- 单位与补给：[RECORD-05 · 单位与补给](RECORD-05-units.md)。
- 参与制度：[RECORD-02 · 参与制度](RECORD-02-participation.md)、[ADR-025 · 冲突参与](../../decisions/ADR-025-conflict-participation.md)。
- 交战结算：[RECORD-03 · 交战与转移](RECORD-03-settlement.md)。
- 规格：[领土政治、私兵与有限 PvP](../../systems/politics-conflict-law.md)。
- 阶段计划：[M12 PLAN](PLAN.md)。
