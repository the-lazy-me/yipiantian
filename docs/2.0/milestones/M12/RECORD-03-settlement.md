# M12-03 · 交战与转移（最小结算切片）

执行日期：2026-11-15。状态：切片完成，不表示 M12-03 或 M12 验收完成。前置：[M12 PLAN](PLAN.md)、[RECORD-02 · 参与制度](RECORD-02-participation.md)、[ADR-025 · 冲突参与](../../decisions/ADR-025-conflict-participation.md)。

## 问题

M12-03 要求“校验命令、冻结资源、结算唯一结果、扣除损失并发放真实战利品”，验收判据是“重试不重复战利品，反复袭击不能突破同目标上限”。此前的参与制度切片只保存文档内损失整数，没有资源冻结、扣除、战利品、目标预算或结算入口；M12-01（单位与补给）也尚未实现。

本切片只建立可以独立验证的结算纯规则：输入交战命令和只读上下文，输出唯一结果、冻结项列表与候选文档。它不接网络、不写农场存档、不做 UI，也不修改参与制度模块。范围刻意小于 M12-03 的完整验收，目的是先把“一次交战如何校验、扣多少、发多少、重试怎么办”固化为确定性规则，再决定接入真实资产与权威落盘。

## 边界

- 新增 `Game/world/conflict_settlement.gd` 与 `tests/conflict_settlement_test.gd`。
- 未修改 `Game/conflict/participation_state.gd`、`Game/farm/*`、`Game/ui/*`、`main.gd`、`.github/workflows`、`rules/project-context.md`。
- 无 RNG、无系统时钟、无磁盘、无场景、无网络；所有命令接收显式 `now_utc`，同一输入得到同一输出。
- 不读取 `FarmState`，不记录真实库存/余额；资源只是上下文中的整数。结算候选文档和 `freeze` 列表由调用方负责原子落盘。
- 目标上限与资源表由调用方按世界事实提供；本切片不校验地块归属、建筑归属或地契，也不从 `FarmState` 推导可掠夺资产。
- 复用 `Game/conflict/participation_state.gd` 的现成判定：结算前在副本上调用其 `engage` 做只读探测，取得和平、区域、窗口、同意、退战、离线上限和修订失效的结论；成功后再用真实损失写一条耐久交战行。本模块不复制参与规则。

## 契约

### 结算上下文

```text
context = {
  world_id: String,
  sequence: int,
  resources: { "<player>": { cash: int, supplies: int } },
  targets: {
    "<defender>|<parcel_id>": {
      key, target, parcel_id, lost, cap,
    },
  },
  participation: <ConflictParticipation 完整文档>,
  consumed: {
    "<command_id>": { payload, outcome, freeze },
  },
}
```

- `targets` 键由防守方与地块 id 拼成；没有地块时地块部分为空串。同一键的 `lost` 只由本模块的成功结算累加。
- `participation` 必须是 `Participation.valid()` 通过的完整文档，且 `world_id` 与上下文一致。
- `consumed` 是耐久命令表，保存首次结果与冻结项；重试据此回放。

### 命令

```text
command = {
  id, attacker, defender, target_parcel?, troops, x, z,
  defender_online, at_utc,
}
```

`id`、双方玩家、`troops`、协调、在线标记和时间是必需字段；`target_parcel` 可省略。`x`、`z`、`defender_online` 是对建议契约的扩展：参与制度的 `engage` 需要位置与离线标记，结算层不另造一套区域/离线上限规则。

### 结果

```text
{
  ok, reason, duplicate,
  outcome: {
    command_id, attacker, defender, target, parcel_id, troops, x, z,
    defender_online, at_utc, losses, taken_cash, taken_supplies,
    spoils, spoils_cash, spoils_supplies, destroyed, supply_cost,
    target_lost_before, target_lost_after, target_cap,
    window_id, participation_loss_before, participation_cap,
  },
  freeze: [ { owner, resource, amount, command_id, reason } ],
  next_context,
}
```

失败时 `outcome` 为空、`freeze` 为空、`next_context` 等于输入且不修改任何资源。`freeze` 记录调用方需要落盘的冻结项：进攻方出征消耗与防守方被扣损失。重复提交同 payload 回放首次 `outcome` 与 `freeze`，`next_context` 保持输入不变，不重复扣资源或发放战利品。

### 原因表

| 原因 | 含义 |
|---|---|
| `invalid_context` | 上下文形状、资源、目标预算或参与制度不合法 |
| `invalid_command` | 命令不是字典、缺/多字段、id 为空、在线标记非布尔 |
| `invalid_attacker` / `invalid_defender` | 玩家 id 非法或为 `public` |
| `same_player` | 进攻方与防守方相同 |
| `invalid_troops` | 兵力不是正整数或超过上限 |
| `invalid_position` | 坐标不是 `0..4096` 整数 |
| `invalid_time` / `future_time` | 时间非法，或命令晚于当前时刻 |
| `invalid_target` / `unknown_target` | 地块 id 非法，或没有对应目标预算行 |
| `invalid_participation` | 参与制度视图不可用或探测失败原因无法归类 |
| `peace_time` | 命令时刻房间处于和平档 |
| `no_consent` | 进攻方/防守方未同意，或退战已生效 |
| `insufficient_supply` | 进攻方物资不足以支付出征消耗 |
| `insufficient_resources` | 防守方没有可损失资源 |
| `target_cap` | 同目标上限或参与制度窗口上限已耗尽 |
| `duplicate_command` | 同 id 已结算但 payload 不同，或参与制度耐久行已占用该 id |
| `stale_window` | 命令超龄、不在声明窗口内，或制度尚未生效 |
| `capacity` | 已消费命令表达到上限 |

## 规则

### 校验顺序

1. 上下文必须通过 `valid_context()`；`now_utc` 必须是有限非负时间。
2. 命令形状、枚举、双方玩家、兵力、坐标、在线标记和时间严格校验。
3. 同 id 已在 `consumed` 且 payload 相同则回放；payload 不同返回 `duplicate_command`。同 id 已在参与制度耐久行中也返回 `duplicate_command`。
4. `at_utc > now_utc` 返回 `future_time`；`now_utc - at_utc > COMMAND_MAX_AGE_SECONDS` 返回 `stale_window`。
5. 目标键必须存在且行内防守方/地块一致；`lost >= cap` 返回 `target_cap`。
6. 进攻方物资必须至少覆盖出征消耗，否则 `insufficient_supply`。
7. 在参与制度副本上调用 `engage(amount=1)` 做只读探测；和平、区域、窗口、同意、退战、离线上限和修订失效由该调用判定。失败原因按原因表折叠。
8. 实际损失同时受四个上限约束：投入兵力、同目标剩余上限、参与制度该窗口剩余上限、防守方实际资源。
9. 用真实损失在全新参与制度副本上调用 `engage`，记录耐久交战行；成功后写候选文档、冻结项与已消费命令。

### 确定性与资产守恒

- 出征消耗：`supply_cost = troops * SUPPLY_COST_PER_TROOP`，本切片固定为 1。
- 原始损失：`raw_loss = troops * LOSS_PER_TROOP`，本切片固定为 1。
- 实际损失：`losses = min(raw_loss, target_remaining, participation_remaining, available)`。
- 扣减顺序固定为先现金后物资；`taken_cash = min(losses, defender_cash)`，`taken_supplies = losses - taken_cash`。
- 战利品：按现金与物资分别取 `SPOILS_BPS=5000`（一半，向下取整），因此 `spoils <= losses`。
- 销毁量：`destroyed = supply_cost + losses - spoils`。
- 资源变化：进攻方 `cash += spoils_cash`、`supplies -= supply_cost - spoils_supplies`；防守方 `cash -= taken_cash`、`supplies -= taken_supplies`。
- 守恒：结算前后双方现金+物资总量之差严格等于 `destroyed`；所有资源保持非负。
- 目标累计与参与制度记账同时前进：`target.lost += losses`，参与制度该窗口损失累计 `+= losses`。

### 幂等与冻结

- `consumed` 以命令 id 为耐久键；回放返回首次 `outcome`，不重新执行资源变化。
- `freeze` 按命令 id 幂等，重复落盘不会产生第二次冻结或战利品。
- 参与制度耐久行与结算 `consumed` 行互相校验：`valid_context()` 要求每条已消费命令都能在参与制度中找到同 id、同坐标、同时间、同损失、同窗口的交战行。
- `valid_context()` 还要求每个目标的 `lost` 等于已消费结果中该目标损失之和、`sequence >= consumed.size()`、资源为非负整数、目标 `lost <= cap`、`cap > 0`。

### 常量与边界

- `COMMAND_MAX_AGE_SECONDS = 3600`；超过一小时的历史命令不再结算。
- `MAX_TROOPS = 1000000`，`MAX_COORD = 4096`，`MAX_RESOURCES = 256`，`MAX_TARGETS = 256`，`MAX_CONSUMED = 1024`。
- 命令 payload 有界；`valid_context()` 拒绝多余键、负数、非整数、非法 id、世界不一致和篡改过的结果/冻结项。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/conflict_settlement_test.gd"
```

原始末行：

```text
CONFLICT_SETTLEMENT_TEST checks=140 failures=0
```

覆盖矩阵：

| 用例 | 检查 |
|---|---|
| 首次结算 | 上下文有效；输入不被修改；损失、战利品、出征消耗、销毁量、目标累计、窗口与参与上限；冻结项；候选资源；参与制度耐久行；候选文档有效 |
| 和平与同意 | 和平 `peace_time`；进攻方未同意、防守方未同意、退战生效均为 `no_consent`；拒绝不写损失 |
| 时间 | 未来 `future_time`；超龄 `stale_window`；等于年龄上限仍可结算；声明窗口外、制度生效前均为 `stale_window`；非法/非有限当前时刻 |
| 同目标上限 | 单次被上限压低；耗尽后 `target_cap`；拒绝不重复扣资源；其他目标独立；三次反复袭击停在上限 |
| 参与上限与离线 | 参与总上限压低损失；耗尽后拒绝；离线上限更小；离线耗尽后在线补打；在线与离线共享累计 |
| 窗口 | 两个窗口分别记账；同目标预算跨窗口共享；第三窗口不能突破 |
| 资源 | 进攻方物资不足；防守方零资源；现金不足时先扣现金再扣物资；战利品按资源种类取半；非负；总量守恒 |
| 幂等 | 同 id 同 payload 回放且不重复扣资源/发战利品/写交战行；同 id 换 payload 冲突；参与制度耐久 id 冲突 |
| 确定性 | 同输入逐字节相同；结果与冻结项一致 |
| 非法形状 | 非字典/字符串/空命令；缺字段/多字段/空 id；非法双方、自攻；零/负/小数/字符串/超限兵力；负/越界坐标；负/非有限时间；非布尔在线标记；非法地块；未知目标；非字典/空上下文 |
| 文档校验 | 空值/字符串；多键/缺键；负资源；世界不一致；缺失参与制度；目标超上限/零上限/键不一致；伪造结果损失、目标累计、序列、payload、冻结项、参与交战行；参与制度历史交战不在结算表时仍有效 |
| JSON 往返 | 候选文档往返仍有效；往返后继续结算；目标累计继续前进；旧命令仍可幂等回放且不重复扣除 |

## 未覆盖

- 网络与权威接线：没有 sidecar 存储、`HeadlessWorld` 加载/保存、`WorldHost` 命令入口、成员/访客门、客户端方法或 RPC。
- 存档：结算上下文不进入农场 v27 文档；没有 sidecar 位置、版本、原子写、损坏恢复或重启幂等测试。
- 真实资产：资源仍是上下文整数，不读取 `FarmState`、经济账本、库存或建筑；冻结项只描述由调用方落盘的锁，不实际锁定账户。
- 地块与建筑归属：`target_parcel` 只是目标预算键，不校验地契、建筑或实际可掠夺资产；目标行由调用方提供。
- 单位与招募：没有护卫/民兵、装备、驻地、工资或粮草（M12-01）；`troops` 只是规则层整数。
- 战利品规则：比例固定为 50%，不能按房间或资产类型配置；没有战利品上限、运输或入库损耗。
- 可玩性验证：没有普通农户、商队、弱小组织与攻击者场景观察（M12-05）。
- 组织与代行：没有组织、职位、负责人离线代行或托管防守。
- 多房间：单文档单世界；跨房间复制套利与共享预算未处理。
- 身份可信：`player_id` 仍是声明式 id，不是密码学凭据。
- 目标上限来源：上限由调用方写入 `targets`；没有从地籍、建筑价值或房间规则自动生成，也没有修订/重置流程。
- 已消费命令表上限为 1024；达到后返回 `capacity`，不淘汰旧行。参与制度同样有 1024 条交战上限，两者一致但不自动归档。
- 命令时间语义：`at_utc` 必须是一小时内的命令；迟到提交、补算和离线批量结算未覆盖。
- 只在本机 macOS 无头模式验证；未在 Windows/CI 运行。

## 关联

- 参与制度：[RECORD-02 · 参与制度](RECORD-02-participation.md)、[ADR-025 · 冲突参与](../../decisions/ADR-025-conflict-participation.md)。
- 规格：[领土政治、私兵与有限 PvP](../../systems/politics-conflict-law.md)。
- 阶段计划：[M12 PLAN](PLAN.md)。
- 结构参考：`Game/conflict/participation_state.gd` 的纯规则、严格校验与具名失败写法；`Game/world/territory_state.gd` 的纯规则文档风格。
