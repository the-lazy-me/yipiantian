# M12-05 · 不参战体验验证（切片）

执行日期：2026-11-16。状态：切片完成，不表示 M12-05 或 M12 验收完成。前置：[RECORD-12 · 交战权威接入](RECORD-12-conflict-authority.md)、[RECORD-14 · 交战真实网络](RECORD-14-conflict-network.md)。

## 目的

M12-05 要求验证“不参战体验”：普通农户、商队、弱小组织与攻击者在和平与有限冲突下的实际结果，恢复成本与骚扰路径，以及和平生活、保护区和基础住所是否被越权转移。本切片用 `HeadlessWorld` 直连（无网络、无 UI）构造真实账户、真实招募单位与真实规则文档，度量单次与反复交战的资源变化，并逐项断言零变化路径。

## 实现

新增 `tests/non_participation_experience_test.gd`，沿用 `conflict_authority_test.gd` 的直连夹具：

- 每个场景使用独立目录，产物在 `.local/verification/non-participation-<usec>/`；
- 账户经 `economy_open_account`，物资经真实农场快照写入，单位经 `execute_unit("recruit")`；
- 制度经 `execute_participation`，交战经 `execute_conflict("engage", ..., defender_online)`；
- 组织、公共基金、公共项目经 `execute_organization` / `execute_fund` / `execute_public_works`；
- 庄园地块经 `claim_territory`，建筑经 `farm.build`，均使用生产入口；
- 权威时钟冻结在 `START`，退战场景显式推进到生效之后。

未改动交战测量路径的生产代码；切片内另外修正了结算层的拒绝原因名（见“缺陷”第 1 条）。

## 覆盖

| 要求 | 断言 |
|---|---|
| 1 和平档 | 显式和平制度下，攻击农户与商队（真实单位）均返回 `peace`；farm/units/participation/conflicts 四类文档字节不变；三方现金与物资零变化 |
| 2 有限冲突但农户未同意 | 房主声明 limited、攻击者已同意、防守农户未同意；engage 返回 `no_consent`；四类文档与双方资产零变化 |
| 3 已同意、离线防守 | 进攻 50 人、`offline_loss_cap=20`；单次损失 20 不超过离线上限，累计 20 不超过 100 目标上限；`destroyed == supply_cost + losses - spoils`；双方现金+物资减少量 == `destroyed`；现金发行量不变；参与文档记录耐久损失 |
| 4 反复袭击 | 同一目标两轮各 50，累计 100 后第三轮返回 `target_cap`；四类文档、双方物资与未投入单位零变化 |
| 5 退战延迟 | 防守方 withdraw 后、生效前（剩余窗口 3600 秒）仍可被攻击，记录损失；推进权威时钟到生效后 1 秒，同一目标被 `no_consent` 拒绝，文档与资产零变化 |
| 6 弱小组织 | 目标玩家所属组织账户 `org_coop_weak` 现金 30、基金余额 30、`public_works.json` 字节均不变；仅目标玩家自己的现金/物资按 outcome 变化；无关第三方资产不变；现金守恒 |
| 7 出征粮草不足 | 进攻方有单位但远征物资为 0；结果返回 `insufficient_supply` 被拒绝，文档与资产零变化 |
| 8 基础住所/地块 | B 已认领 `parcel_01` 并建有 `yard_a` 小屋；交战后 `territory.json` 字节不变、地块仍属 B、建筑表与所有者不变；除 `economy`/`bags` 外的完整农场快照不变 |

## 测量

### 单次离线袭击（要求 3）

| 项目 | 数值 |
|---|---|
| 进攻兵力 | 50（militia） |
| 离线上限 | 20 |
| 防守方资源损失 `losses` | 20（现金 4 + 物资 16） |
| 目标累计损失 | 20 / 100 |
| 进攻方出征粮草 `supply_cost` | 50 |
| 战利品 `spoils` | 10（现金 2 + 物资 8） |
| `destroyed` | 60 |
| 防守恢复成本（现金+物资损失） | 20 |
| 进攻净收益（战利品 − 出征粮草） | −40 |
| 防守方现金 | 4 → 0 |
| 防守方物资 | 90 → 74 |
| 进攻方现金 | 20 → 22 |
| 进攻方物资 | 150 → 108 |
| 双方现金+物资减少 | 60 == `destroyed` |

### 反复袭击（要求 4）

| 项目 | 数值 |
|---|---|
| 第 1 轮损失 | 50（目标累计 50） |
| 第 2 轮损失 | 50（目标累计 100） |
| 第 3 轮 | 拒绝 `target_cap`，资产不变 |

### 退战延迟（要求 5）

| 项目 | 数值 |
|---|---|
| 退战延迟 | 3600 秒 |
| 生效前剩余窗口 | 3600 秒 |
| 生效前交战 | 成功，损失 10 |
| 生效后交战 | 拒绝 `no_consent`，资产不变 |

### 弱小组织（要求 6）

| 项目 | 数值 |
|---|---|
| 组织账户 `org_coop_weak` | 30 → 30 |
| 公共基金余额 | 30 → 30 |
| 公共项目文档 | 字节不变 |
| 目标玩家现金 | 80 → 70 |
| 目标玩家物资 | 45 → 45 |
| 夺取 | 现金 10、物资 0 |
| 无关第三方 | 资产不变 |

### 粮草不足（要求 7）

权威返回 `insufficient_supply`；文档与资产均零变化。

### 住所与地块（要求 8）

地块 `parcel_01` 与建筑 `yard_a`（cottage）在交战后仍属防守玩家；`territory.json` 字节不变；除 `economy` / `bags` 外完整农场快照不变。因此交战只冻结现金与物资，不转移宅基或建筑。

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/non_participation_experience_test.gd"
```

原始末行：

```text
NON_PARTICIPATION_EXPERIENCE_TEST checks=156 failures=0
```

## 缺陷

### 1. 进攻方粮草不足的原因名与规格不一致（已修复）

- 规格（M12-05 任务）：拒绝原因应为 `insufficient_supply`。
- 初次实测：`insufficient_resources`。
- 根因：`Game/world/conflict_settlement.gd` 的 `settle()` 在同一常量 `REASON_INSUFFICIENT_RESOURCES` 上合并了两类拒绝：
  - 进攻方 `supplies < supply_cost`（真正属于出征粮草不足）；
  - 防守方现金+物资为 0，无法产生非零损失。
  交战入口 `_conflict_rule_reason()` 原样透传，因此调用方无法区分“我方没粮”和“对方没东西可抢”；`world_host.gd` 的拒绝文案表本来已有 `insufficient_supply` 条目，只是结算层从未返回它。
- 修复：新增 `REASON_INSUFFICIENT_SUPPLY = "insufficient_supply"`，进攻方粮草分支返回它；`REASON_INSUFFICIENT_RESOURCES` 只保留给“防守方无资源”。农场提交路径 `_apply_conflict_farm()` 原本就使用 `insufficient_supply`，语义一致。
- 验证：`CONFLICT_SETTLEMENT_TEST 140/0`、`CONFLICT_AUTHORITY_TEST 276/0`、`CONFLICT_NETWORK_TEST 117/0`、`NON_PARTICIPATION_EXPERIENCE_TEST 156/0`。

### 2. 观察：结算损失被映射为进攻方减员

不是本次新增的失败，但测量中可见：进攻方投入 50 人、守方离线损失 20 资源，`UnitConflict` 随后把 `outcome.losses=20` 映射为进攻方减员 20。该行为由 `unit_conflict.gd` 的既有桥接与 `conflict_authority_test.gd` 的既有断言锁定，超出 M12-05 “不参战体验”范围，本次未改动，仅记录为后续模型复核项。

## 未覆盖

- 真实玩家体验与玩法满意度：本切片是规则层测量，不证明农户主观上“感到安全”，也不评价骚扰路径是否有趣。
- UI：交战面板、参与面板、状态提示与错误文案的端到端体验未在本切片验证。
- 真实网络：本切片直连 `HeadlessWorld`，未经过 RPC 19/20；网络路径见 RECORD-14。
- Windows：未在目标环境运行；目录、文件字节比较与时钟推进仅在本机 macOS 验证。
- 多窗口循环、跨窗口累计损失复位、保护区范围外/内的坐标边界未穷举。
- 长时间反复袭击与离线防守方重新上线后的上限切换未覆盖。

## 关联

- 权威：[RECORD-12 · 交战权威接入](RECORD-12-conflict-authority.md)。
- 网络：[RECORD-14 · 交战真实网络](RECORD-14-conflict-network.md)。
- 参与制度：[RECORD-09 · 参与制度权威](RECORD-09-participation-authority.md)。
- 阶段计划：[M12 PLAN](PLAN.md)。
