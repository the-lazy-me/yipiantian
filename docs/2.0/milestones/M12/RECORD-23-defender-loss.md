# RECORD-23 · 交战防守方战损纯规则切片

状态：切片完成，未验收；只补 M12-03 中“防守方单位也承受战损”的纯规则部分，
不表示 M12-01、M12-03 或 M12 完成。日期：2026-11-16。前置：
[M12 PLAN](PLAN.md)、[RECORD-03 · 交战与转移](RECORD-03-settlement.md)、
[RECORD-05 · 单位与补给](RECORD-05-units.md)、
[RECORD-07 · 单位交战损失桥接](RECORD-07-unit-conflict.md)。

## 问题

[RECORD-07](RECORD-07-unit-conflict.md) 的桥接只把结算的 `outcome.losses`
写回进攻方参战单位，防守方在整场交战中人数完全不变。其“未覆盖”一节明确写着：
“没有双方不同伤亡公式、装备对战损的影响或斗志；防守方单位人数损失尚未建模”。
结果是防守方可以无限次被袭击而兵力不减，交战模型只有单向减员。

本切片补上可以独立验证的纯规则部分：防守方在有防守能力时也承担确定性的、
有上限的人数损失，且不改变结算契约、资源冻结、战利品或进攻方损失。

## 边界

- 只改 `Game/conflict/unit_conflict.gd` 与 `tests/unit_conflict_test.gd`；
  没有修改 `Game/world/**`（含 `conflict_settlement.gd`、`headless_world.gd`、
  sidecar 存储）、`Game/scenes/**`、`.github/**`、`Game/conflict/unit_state.gd`
  （另一并行代理正在修改它）。
- 不新增单位文档字段，不改 `unit_state.valid()` 的键集；候选文档形状与既有
  严格校验完全兼容。
- 无随机数、无系统时钟、无磁盘、无场景、无网络；`now_utc` 仍由调用方显式传入。
- 结算契约不变：`outcome` / `freeze` / `next_context` 原样返回；资源损失、
  战利品与销毁量仍只由 `conflict_settlement.gd` 计算。
- 失败路径仍只返回 `{ok:false, reason}`，不带候选文档，不修改输入。

## 决定

### 谁能承担防守战损

“有防守能力”定义为满足任一条：

- 兵种是 `guard`；
- 装备不是 `none`（`basic` / `standard` / `elite`）。

无装备民兵被视为不参与防守，不承担战损。理由：`militia` 是无装备的平民
武装，规范把它与本切片都未建模的“保护经营”区分开；只有 `guard` 或花钱买了
装备的单位才在规则上承担防守职责。未列在 `defender_units` 里的单位永远不参与。

### 损失比例与上限

```text
attacker_power = Σ capability(进攻方参战单位).power
defense_power  = Σ capability(防守方具备防守能力的参战单位).power
defense_people = Σ people(同上)

pressure_bps = attacker_power * 10000 / (2 * (attacker_power + defense_power))
bps          = min(pressure_bps, 2500)
defender_loss = defense_people * bps / 10000        # 整数向下取整
```

- 压力系数取进攻战力占双方战力之和的比例的一半：同战力时约 25%，进攻压倒
  性时逼近但不超过 50%，再被 `DEFENDER_LOSS_CAP_BPS = 2500` 压到最多 25%。
- 只依赖双方已参战单位的派生战力与人数，全部整数运算，无随机数；相同输入
  相同输出。
- 防守战损按与进攻方同一套 `_apply_losses` 规则分摊：按人数比例取整，余数按
  单位 id 升序补到仍有人数的单位；人数归零的单位从名册移除。
- 防守战损不会超过防守参战人数：`bps ≤ 2500` 且人数取整，打光只可能发生在
  极小队伍（`defense_people * bps / 10000` 天然有界）。
- 无防守能力（全为无装备民兵）时 `defender_loss = 0`，名册不变。

### 输出形状

成功结果新增一个键：

```text
defender_loss: int    # 本次交战落到防守单位的确定性人数损失
```

既有键（`ok` / `reason` / `duplicate` / `outcome` / `units` / `settlement` /
`projection`）语义与形状不变；`projection.defender.people` 仍是**全部**防守
参战人数，不因战损而改变。`headless_world.gd` 只读取 `outcome`、`settlement`
与 `units`，新增键不影响权威接线。

### 装备与斗志

- 装备损失：现有单位文档只有装备枚举，`unit_state.valid()` 要求单位行装备与
  招募 payload 完全一致；没有耐久、等级或降级字段。为此新增字段或“装备降级”
  会破坏招募记录一致性，且属于新装备系统，超出本切片范围。**未覆盖**。
- 斗志：单位文档没有斗志字段；`unfed_days` 只表示欠供，借用它会改变补给
  语义。状态上唯一相近的“能力系数”（`capability()` 的 `equipment_bps` /
  `penalty_bps`）都是派生值，不落地。**未覆盖**。

## 覆盖矩阵

| 要求 | 测试证据 |
|---|---|
| 防守方有人 | `有防守能力的防守方可以结算`、护卫按比例下降、同侧另一护卫按比例分摊、`带防守战损的候选文档仍有效` |
| 防守方无人（无防守能力） | `无防守能力的防守方仍然可以结算`、`无防守能力时防守战损为 0`、`全部无装备民兵保持原人数` |
| 损失上限 | `上限内按比例取整`、`单场防守战损不超过防守人数的 25%`、`上限后防守单位仍有 75 人` |
| 不超过防守方现有兵力 | `5 人防守在 25% 上限下损失 1 人`、`损失不会超过防守方现有兵力`、`防守战损不超过防守方现有兵力` |
| 进攻方结果不变 | `进攻方损失仍由结算给出`、`进攻方损失不变`、`进攻方第二支单位损失不变`、`结算冻结项交给权威落资产` |
| 确定性重放 | `相同输入得到相同的防守战损`、`战损数值确定`、`候选名册逐字节相同`、`回放得到相同战损`、`回放得到相同候选名册` |
| 非法输入具名拒绝 | 既有守卫与拒绝透传断言全部保留（`not_owner`、`unknown_unit`、`empty_units`、`duplicate_unit`、`invalid_units`、`invalid_participation`、`invalid_context`、`invalid_request`、`invalid_resources`、`peace_time`、`no_consent`、`stale_window`、`insufficient_supply`、`duplicate_command`） |
| 既有 M12-03 断言 | 原 82 项断言未改，全部仍通过；测试总数从 82 增至 117 |

## 验证

实际运行命令（末行即证据）：

```sh
cd /Volumes/Disk-1tb/yipiantian && perl -e 'alarm shift; exec @ARGV' 180 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/unit_conflict_test.gd"
```

```text
UNIT_CONFLICT_TEST checks=117 failures=0
```

回归：

```text
CONFLICT_AUTHORITY_TEST checks=276 failures=0
CHAIN_CONFLICT_INTEGRATION_TEST checks=512 failures=0
FONT_COVERAGE_TEST checks=1272 failures=0 missing=0
NON_PARTICIPATION_EXPERIENCE_TEST checks=156 failures=0
```

字体：本切片新增中文注释未引入子集外汉字；记录文字统一使用 `防守`（不再写
`防御`）与 `斗志`。`font_coverage_test` 的 1272 项来自当前工作区全部文本，
本切片未修改字体文件。

## 未覆盖

- 装备战损：文档没有装备耐久/等级字段，`valid()` 要求单位行与招募记录装备
  一致；不新增整套装备系统，因此装备损失不建模。
- 斗志：文档没有斗志字段，`unfed_days` 不能借用；斗志变化不建模。
- 防守方胜负与撤退：结算没有独立胜负，防守战损不依赖或产生胜负；撤战、
  追击、俘虏不存在。
- 权威接线：`headless_world.gd` 的 `unit_plan` 目前只记录进攻方单位；本切片
  返回的 `units` 已包含防守方变化，但权威侧持久化防守单位变更、半提交恢复
  与重复提交验证属于后续接线切片，本切片未改 `Game/world/**`。
- 离线与保护：`defender_online` 不影响防守战损；没有离线托管防守或保护期
  免战损。
- 资源与战利品：仍完全由结算决定，防守战损不额外扣现金、物资或发放战利品。
- UI：没有战报、伤亡预览或防守损失展示。
- 存档与网络：不进入 sidecar，不接 RPC；未在 Windows/CI 运行，只在本机
  macOS 无头模式验证。

## 关联

- 单位交战桥接：[RECORD-07 · 单位交战损失桥接](RECORD-07-unit-conflict.md)。
- 交战结算：[RECORD-03 · 交战与转移](RECORD-03-settlement.md)。
- 单位与补给：[RECORD-05 · 单位与补给](RECORD-05-units.md)。
- 权威接线：[RECORD-12 · 交战权威接入](RECORD-12-conflict-authority.md)。
- 规格：[领土政治、私兵与有限 PvP](../../systems/politics-conflict-law.md)。
