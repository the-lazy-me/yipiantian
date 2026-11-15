# M12-01 · 单位与补给（最小规则切片）

执行日期：2026-11-15。状态：切片完成，不表示 M12-01 或 M12 验收完成。前置：[M12 PLAN](PLAN.md)、[M12-02 · 参与制度](RECORD-02-participation.md)、[M12-03 · 交战与转移](RECORD-03-settlement.md)。

## 问题

M12-01 要求“有限护卫/民兵、装备、驻地、工资与粮草，先低频战略结算”，验收判据是“无资源不能无限招募，欠供有明确能力变化”。此前的参与制度与结算切片只有玩家、兵力和资源整数，没有单位名册、招募成本、装备、驻地、补给消耗或欠供后果。

本切片只建立可以独立验证的单位纯规则：输入名册文档、调用方提供的库存上下文和显式时刻，输出候选文档、招募成本或补给消耗。它不接网络、不写农场存档、不做 UI，也不扣真实资产。范围刻意小于 M12-01 的完整验收，目的是先冻结“一支单位怎样招募、吃什么、欠供后还剩多少战力”，再决定接入真实账本与权威落盘。

## 边界

- 新增 `Game/conflict/unit_state.gd` 与 `tests/unit_state_test.gd`。
- 未修改 `Game/conflict/participation_state.gd`、`Game/world/*`、`Game/farm/*`、`Game/ui/*`、`main.gd`、`.github/workflows`、`rules/*`、`docs/2.0/milestones/M12/PLAN.md`。
- 无 RNG、无系统时钟、无磁盘、无场景、无网络；所有写入口显式接收 `now_utc`，同一输入得到同一输出。
- 不读取 `FarmState`、`EconomyState`、`LedgerState` 或 `WorldHost`；现金与粮草只是调用方提供的只读库存上下文。
- 不实现战斗结算、真实资产扣除、存档、网络、UI、招募名额审批或组织权限。

## 规则形状

### 文档

```text
{
  world_id: String,
  sequence: int,
  last_upkeep_utc: float,            # -1 表示尚未结算过补给
  units: {
    "<unit_id>": {
      id, owner, kind, people, equipment, station,
      recruited_utc, unfed_days, record_command_id,
    },
  },
  commands: {
    "<command_id>": {
      payload: String,
      result: {
        kind: "recruit" | "disband",
        unit_id: String,
        cost: { cash: int, supplies: int },
      },
    },
  },
}
```

`valid()` 要求精确键集、最多 64 支单位、单支 1..500 人、装备枚举、id 长度 ≤128、驻地非空且 ≤64、时间和计数非负且有界、命令记录 ≤256。未知键一律拒绝，没有旧格式兼容分支。当前人数必须不超过招募 payload 中的人数（欠供只会减员），单位行与招募命令的 owner、kind、equipment、station、recruited_utc 必须一致；单位不能脱离 `commands` 中的招募记录存在。

### 目录与装备

| 兵种 | 每人招募现金 | 每人每日粮草 | 每人基础战力 |
|---|---:|---:|---:|
| `militia` | 2 | 1 | 10 |
| `guard` | 4 | 2 | 18 |

| 装备 | 战力系数 | 每人现金追加 |
|---|---:|---:|
| `none` | 10000 | 0 |
| `basic` | 11000 | 2 |
| `standard` | 12500 | 5 |
| `elite` | 15000 | 10 |

招募现金成本 = 每人兵种成本加装备追加，乘以人数；招募粮草要求 = 一支单位一天的粮草（集合期间的储备）。两项都由调用方库存上下文校验，不足分别返回 `insufficient_cash` / `insufficient_supply`。成功只返回新文档与 `cost`，不直接扣农场资产。

### 命令

- `recruit(state, stock, command, now_utc)`
  - 命令键集固定为 `id, owner, kind, people, equipment, station`；未知键、非法 id、`public` 所有者、未知兵种/装备、空驻地、非整数人数均返回具名原因。
  - 招募命令 id 同时就是单位 id。`commands` 保存首次 payload 与结果：同 id 同 payload 重试回放且不重复招募，同 id 换 payload（包括不同 `now_utc`）返回 `command_conflict`。回放判定先于时间校验，因此后续补给推进后仍可安全重试旧命令。
  - 名册达到 64 支后新招募返回 `capacity`，不淘汰旧单位；库存校验在容量之后，失败不修改输入。
  - 招募时刻早于 `last_upkeep_utc` 返回 `time_regression`。
- `disband(state, command, now_utc)`
  - 命令键集 `id, unit_id, owner`；未知单位 `unknown_unit`，所有者不符 `not_owner`。
  - 写时复制并追加耐久命令记录；同 id 同 payload 回放，换 payload 冲突。时间倒退同样拒绝。
- `upkeep(state, stock, now_utc)`
  - 按单位 id 字典序分配调用方提供的粮草；每支单位需要 `人数 × 每人每日粮草`。只扣到可用数量为止，实际消耗由返回的 `consumed` 交给调用方落账。
  - 同一时刻重复调用返回 `status = "settled_this_tick"`，消耗与逃兵均为 0，文档不变；更早时刻返回 `time_regression`。
  - 写入时推进 `last_upkeep_utc` 与 `sequence`，但每次招募、解散、补给都只复制文档，绝不修改输入。

### 欠供与战力

出现缺口时，逃兵数按比例向上取整：

```text
deserters = ceil(people × shortfall / required)
```

存活人数归零的单位从名册移除；存活单位累计 `unfed_days`。再次足量补给会把 `unfed_days` 清零。

`capability(state, unit_id)` 不缓存，按以下整数万分比公式派生：

```text
power = base_power_per_person × people × equipment_bps × penalty_bps / 100000000
penalty_bps = 10000 - min(unfed_days × 2500, 7500)
```

因此欠供一天即下降 25%，最多下降 75%；配合减员，欠供后战力必须明确低于足量状态。未知单位返回 `unknown_unit`，文档非法返回 `invalid_state`。

### 不变量

- 招募不能凭空产生资源：只返回成本，真实扣减由调用方完成；现金或粮草不足时拒绝。
- 名册有上限，人数有上限；超过上限是拒绝，不是静默淘汰。
- 同一命令 id 至多产生一次效果；记录与单位行互相校验，不能伪造无来源的单位或 disband 记录。
- 同一时刻至多扣一次补给；时间只能前进。
- 粮草分配顺序固定，同一输入逐字节相同。
- 失败路径不返回候选文档，也不修改输入。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/conflict/unit_state.gd` | 新增纯规则模块：目录、装备、招募、解散、补给、欠供、派生战力、严格校验 |
| `tests/unit_state_test.gd` | 新增夹具，182 项检查 |
| `docs/2.0/milestones/M12/RECORD-05-units.md` | 本记录 |

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian
perl -e 'alarm shift; exec @ARGV' 180 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/unit_state_test.gd"
```

原始末行：

```text
UNIT_STATE_TEST checks=182 failures=0
```

覆盖矩阵：

| 用例 | 检查 |
|---|---|
| 空文档 | 空名册合法；`last_upkeep_utc=-1`；JSON 往返有效；未知单位/非法文档查询战力被拒；空名册可推进补给且不耗粮 |
| 招募成功 | 成本、人数、装备、驻地、招募时刻、`record_command_id` 入库；民兵/护卫/精英战力与成本；同文档继续招募；输入逐字节不变 |
| 招募拒绝 | 非字典/字符串/多键/缺键命令；空与超长 id；空或 `public` 所有者；未知兵种；零/负/小数/字符串/超限人数；未知装备；空、非法字符、超长驻地；负/非有限时间；缺键/负值/多键库存；现金不足；粮草不足；失败无 `state` |
| 上限 | 单支 500 人可招募；64 支满名册有效；第 65 支 `capacity` 且拒绝不修改名册 |
| 幂等 | 同 id 同 payload 回放成本与单位 id；回放不重复招募；同 id 换人数或换时间 `command_conflict`；冲突无 `state`；补给推进后旧招募命令仍回放且不修改文档 |
| 足量补给 | `fed`；消耗等于人数×每日粮草；不吞掉多余库存；无逃兵；欠供天数清零；战力不变；补给时刻入库 |
| 欠供 | `shortfall`；只扣可用粮草；按比例逃兵；受影响单位明细；人数、欠供天数与战力下降；持续断粮后单位移除且无法查询 |
| 分配顺序 | 两支部队按 id 升序分配；前一支部队存活，后一支部队断粮移除 |
| 同刻幂等 | `settled_this_tick`；消耗/逃兵为 0；文档不变；时间倒退 `time_regression`；下一时刻继续扣粮；补给后不能补做更早招募 |
| 解散 | 非所有者 `not_owner`；未知单位 `unknown_unit`；多键/缺键拒绝；成功移除并返回单位；回放幂等；同 id 换 payload 冲突；补给推进后旧解散命令仍回放；补给后不能补做更早解散 |
| 写时复制 | 招募、补给、解散成功与失败均不修改输入；失败无 `state`；欠供修改不泄漏到调用方文档 |
| 文档校验 | 未知/缺失文档键；世界 id；序列；补给时刻哨兵；单位行未知/缺失键、id、owner、兵种、人数、装备、驻地、时间、欠供天数、记录命令 id；缺招募记录；命令记录未知/缺失键；payload/成本/结果类型/结果单位篡改；伪造空记录；已解散单位复活；无招募来源的解散记录 |
| JSON 与确定性 | 往返后继续招募；同一招募/补给输入输出逐字节相同；逃兵明细一致 |

## 未覆盖

- 工资：本切片只收一次性招募现金和每日粮草，没有持续现金工资、欠薪判定或欠薪对士气的影响。
- 真实资产：现金与粮草只是上下文整数；不扣 `FarmState` 库存、经济账户或账本，不生成记账分录；成本与消耗由调用方落账。
- 网络与权威接线：没有 sidecar 存储、`HeadlessWorld` 加载/保存、`WorldHost` 命令入口、成员/访客门、客户端方法或 RPC。
- 存档：不进入农场文档；没有 sidecar 位置、版本、原子写、损坏恢复或重启幂等测试。
- 战斗与移动：没有行军、驻防、交战、伤亡、战利品或单位参战；`station` 只是字符串，不校验地籍、建筑或真实位置。
- 装备变更：装备只在招募时确定，没有升级、更换、损坏或缴获。
- 补给粒度：补给按文档级 tick 结算，所有单位同刻进食；没有逐单位不同补给时刻、按小时/半天折算或离线多日批量补算。
- 组织与权限：`owner` 只是声明式 player id，不校验组织、职位、负责人或离线代行；`public` 不能拥有单位。
- 名额与审批：没有招募名额、许可、人口或组织预算。
- 命令记录上限 256，达到后新招募/解散返回 `capacity`；没有淘汰、归档或跨窗口幂等测试。饿散单位只留下招募记录，没有独立伤亡/解散事件。
- 身份可信：所有 id 都不是密码学凭据。
- 只在本机 macOS 无头模式验证；未在 Windows/CI 运行。

## 关联

- 规格：[领土政治、私兵与有限 PvP](../../systems/politics-conflict-law.md)。
- 阶段计划：[M12 PLAN](PLAN.md)。
- 相邻切片：[M12-02 · 参与制度](RECORD-02-participation.md)、[M12-03 · 交战与转移](RECORD-03-settlement.md)。
- 结构参考：`Game/conflict/participation_state.gd` 的纯规则与严格校验写法；`Game/world/conflict_settlement.gd` 的写时复制、具名原因与耐久命令表写法；`Game/farm/farm_command.gd` 的 command id / payload 回放思路（未引用该模块）。
