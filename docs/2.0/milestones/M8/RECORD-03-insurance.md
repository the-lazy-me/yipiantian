# M8-03 · 保险损失证据调查

状态：调查完成（2026-11-15），未实现；M8-03 阻塞于损失证据。范围：核查现有“价值减少”路径能否作为权威、耐久、可防重复的保险损失来源；给出最小前置切片与条件性保单设计。不涉及产品代码、规则、场景、UI、网络或存档修改。

权威设计：[ADR-022](../../decisions/ADR-022-insurance-loss-evidence.md)；上层规格：[经济与金融](../../systems/economy-finance.md)、[自然系统](../../systems/nature.md)、[M8 PLAN](PLAN.md)；前置：[ADR-009](../../decisions/ADR-009-disasters.md)、[ADR-013](../../decisions/ADR-013-limited-logistics.md)、[ADR-014](../../decisions/ADR-014-double-entry-ledger.md)、[ADR-017](../../decisions/ADR-017-bank-loans.md)。

## 结论

1. **没有一条现有路径同时满足“权威生成、逐笔耐久、可证明发生在投保之后、同一损失可唯一识别”。** M8-03 不能在不新增损失规则的情况下实现承保与赔付。
2. 最接近的是盗窃：`theft` 表随农场持久化，但只有每所有者每日 `lost` 聚合计数和每小偷最近一次时间戳；没有逐笔损失行，且货物只是转移到小偷口袋，不是价值销毁。它不能作为保险赔付依据。
3. 作物被毁/减产、在途丢失、贷款核销都没有实现；手续费销毁虽是真实销毁并有耐久分录，但属于自愿服务成本，不应承保。
4. 即使补上损失行，仍有一个产品级阻塞：自然事件由持久种子确定性派生，单机客户端可读种子，共享世界摘要也携带种子并本地推导；固定保费的可选保险可以被“只保即将受灾的对象”套利。必须先决定强制/合作保险、按已知日程定价，或让损失结果不可由客户端推导。
5. 建议的下一最小切片不是保险，而是“权威损失事件原语 + 一个真实损失来源”（见下文 P0）。本次不实现。

## 调查方法

- 读取 ADR-009/013/014/017、经济与金融、自然系统、M7 物流记录与 M8 压力记录。
- 读取 `Game/farm/farm_state.gd`、`market_state.gd`、`loan_state.gd`、`ledger_state.gd`、`economy_state.gd`、`nature_state.gd`、`v27_importer.gd` 的相关规则。
- 搜索并读取 `theft` 全链路：`FarmState._act()`、`_theft_record()`、`_valid_theft()`、`FarmCommand` 的收获/`set_theft`、`tests/player_theft_test.gd`。
- 运行现有只读夹具（无头 Godot 4.7.2，隔离进程）：`player_theft_test`、`m8_stress_test`、`disaster_test`、`market_logistics_test`。
- 未新建调查脚本；损失行形状由规则函数和快照校验直接核对。行号按本机 2026-11-15 工作树，仅用于定位。

## 价值减少路径逐条核对

| 路径 | 代码位置 | 是否有耐久逐笔事件行 | 能否证明发生在投保之后 | 能否防同一损失重复理赔 | 判定 |
|---|---|---|---|---|---|
| 作物被毁/减产 | `Game/farm/farm_state.gd:1156` `_settle_cell_environment()`；`:1209` `weather_growth_factor()`；`:1246` `_moisture_after_disaster()`；`:1025` `_act()` | 否。灾害只改 `moisture`；作物只延迟成熟，收获固定 1 篮 | 无损失事件，无法证明 | 无损失，无赔付键 | 不可用 |
| 在途丢失/损坏 | `Game/farm/market_state.gd:899` `ship()`；`:972` `deliver()`；`:80-82` 状态常量 | 否。状态只有 `in_transit`/`delivered`；ADR-013 明确无丢失/损坏/拒收/取消 | 无损失事件 | 无损失 | 不可用 |
| 盗窃 | `Game/farm/farm_state.gd:1058-1108`；`:1389` `_theft_record()`；`:1397` `_valid_theft()` | **聚合行**：`{enabled, day, lost, last}`；`lost` 每日最多 3；`last[actor]` 仅最近一次时间；下一 UTC 日首次盗窃时整体重置 | 只能证明“当天有丢失”或“某小偷最近一次”；重置后无法定位具体损失 | 无 `loss_id`、无货物/格子/数量行，无法做唯一赔付键 | 不可用 |
| 贷款逾期坏账 | `Game/farm/loan_state.gd:240-261` `settle()`；`:288` `outstanding_principal()` | 否。只把 `open` 改 `overdue`，不写分录、不核销、不扣押 | 无已实现损失 | 无损失 | 不可用 |
| 成交/运费销毁 | `Game/farm/market_state.gd:940-946` 运费；`:20-21` 成交费；`Game/farm/ledger_state.gd:67-68` | 是。`shipping_fee`/`trade` 分录与成交/发货行 | 可以做时间证明 | 可分录唯一，但性质不是意外损失 | 不承保 |
| 厨房/动物消耗、赠送、出售、篮子 | `Game/farm/farm_state.gd:882-921`；`Kitchen.act`、`Companions.act` | 部分是玩家操作结果，无独立损失行；赠礼/出售是转移 | 不适用 | 不适用 | 不承保 |
| 拆除/布局调整 | `Game/farm/farm_state.gd` `demolish()`、`apply_layout()` | 用户主动操作；占用格不能删除 | 不适用 | 不适用 | 不承保 |
| 市场价格变化 | 无事件；`EconomyCatalog.base_price` 是静态参考价 | 否 | 不适用 | 不适用 | 不承保 |

### 作物与灾害

- `weather_growth_factor()` 的注释与实现都明确：干燥只会让生长倍率降为 `0.5`，作物只会更晚成熟；“收获上限和 1 篮产量永远不变”。
- `_moisture_after_disaster()` 只对 `drought` 减 1/8、对 `storm` 加 1/4，未知种类直接忽略。
- `disaster_test` 明确断言“A mature batch survives long offline disasters intact”“A crop keeps growing through disasters instead of dying”“The protected mature batch still yields exactly one basket”。
- 因此“减产”在当前模型里没有字段可表达：要么新增品质/数量，要么把 1 篮直接变成 0（销毁），后者与 ADR-009 决策 3 和“不直接清空或销毁成熟产出”冲突。

### 在途物流

- `ship()` 在同一候选内扣货、扣 2 COIN 运费、销毁费用并写 `in_transit` shipment；`deliver()` 在 `arrive_utc <= now` 时把数量加回口袋并写 `delivery_<sequence>`。
- `SHIPMENT_STATUSES` 只有 `in_transit`、`delivered`；ADR-013 明确“不提供中途取消、拒收、丢失或退款”，并把承运人、风险路线和保险排除在切片外。
- 在途行是资产而不是损失：它有 `owner/good/quantity/origin/destination/depart_utc/arrive_utc`，但没有 `lost` 终态，也没有价值锁定字段。

### 盗窃专项

`_theft_record()` 的完整形状是：

```text
theft[player_id] = {
  enabled: bool,
  day: int,          # 当前 UTC 日序号；跨日首次盗窃时重置
  lost: int,         # 当天被偷次数，0..MAX_THEFT_PER_DAY (3)
  last: {thief_id: at_utc}   # 每个小偷最近一次时间；下一 UTC 日首次盗窃时重置
}
```

成功盗窃在同一候选内做的事：

```text
格子清空
小偷袋子 +1 篮（reward_crop_id，固定 reward_amount = 1）
world.harvested[reward_crop_id] += 1
theft[owner].lost += 1
theft[owner].last[thief] = now_utc
```

没有写入：`loss_id`、被偷作物、field/cell、每次损失的时间、每次损失的数量行、命令 id 或 actor 的逐笔关联。`lost` 的最大值是 3，且下一天第一次盗窃就会把 `lost` 和 `last` 清空。世界 `harvested` 仍然 +1，说明权威统计把被偷的作物当作正常收获，损失只存在于所有者视角的聚合计数里。命令层的 `command_results` 虽然有 `reward_crop_id`、`reward_amount` 和 `changed_fields`，但只有 64 条、结果不含格子、也不标记“这次是盗窃还是授权收获”；它不能补成耐久损失证据。

更关键的是，盗窃没有销毁世界价值：作物仍在小偷的 `bags` 里。保险赔付会让保险基金向所有者转移现金，但世界中没有任何货物消失；这等于用保费补贴一次转移，并可被所有者开启偷菜后用小号自导自演。

### 贷款与费用

- `Loans.settle()` 只在 `due_utc <= now` 且 `open` 时置 `overdue`；注释明确“No entry, no fee, no asset movement”。`outstanding_principal()` 仍把逾期合同计为银行资产。
- `trade` 与 `shipping_fee` 是自愿支付的服务成本，已有耐久分录；但承保它们会让玩家用保费换回手续费，且分录日志有 512 条上限，不适合作为长期理赔依据。

## 可复现实验

### 1. 盗窃夹具

```bash
/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path /Volumes/Disk-1tb/yipiantian/Game \
  --script /Volumes/Disk-1tb/yipiantian/tests/player_theft_test.gd
```

实际输出：

```text
Godot Engine v4.7.2.stable.official.ed1daf0bf - https://godotengine.org
FARM_SAVE stage=complete version=27
PLAYER_THEFT_TEST checks=128 failures=0
```

该夹具证明了：成功盗窃后所有者 `lost` +1、小偷袋子 +1、格子清空、跨日上限重置、落盘往返保留 `lost`。它**没有**任何逐笔损失行断言；测试辅助函数 `_lost()` 只读取 `snapshot().theft[owner].lost`（`tests/player_theft_test.gd:372-376`）。这正是“耐久聚合存在、逐笔损失不存在”的可执行证据。

### 2. M8 压力夹具的赔付边界

```bash
/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path /Volumes/Disk-1tb/yipiantian/Game \
  --script /Volumes/Disk-1tb/yipiantian/tests/m8_stress_test.gd
```

实际输出（末行与赔付场景）：

```text
SCENARIO no_payout insurance=absent claims=0 payout_entries=0 new_entries_on_default=0 issued_delta=0 cash_delta=0 status_only=yes
M8_STRESS_TEST checks=882 failures=0
```

该场景确认：逾期扫描不写新分录、不发行、不增加账户/银行现金；`economy` 没有 `insurance`/`claims` 键，合同没有赔付字段，`reserve_statement` 的 `claims` 仍为 0（`tests/m8_stress_test.gd:498-560`）。

### 3. 灾害与物流回归

```bash
.../Godot --headless --path Game --script tests/disaster_test.gd
.../Godot --headless --path Game --script tests/market_logistics_test.gd
```

实际输出：

```text
DISASTER_TEST checks=247 failures=0
MARKET_LOGISTICS_TEST checks=174 failures=0
```

灾害夹具断言成熟批次在长期离线灾害后仍完整并恰好产出 1 篮；物流夹具只覆盖两态 shipment 和确定性交付。两者都不存在损失行。

## 建议的下一最小切片（不实现）

按 ADR-022，推荐先做 **P0-A：运输风险损失**，而不是直接做保单：

1. 给 shipment 增加显式风险声明和 `lost` 终态；默认和平路线不变，风险路线必须在发货前展示最大损失。
2. 在到达扫描中由权威生成唯一 `transport_loss` 损失行，写入 `economy.losses`；损失时间用原因窗口起止，不用扫描时刻；价值按发货时锁定的参考价和数量计算。
3. 同一候选写 shipment `status/lost_utc/loss_id`、货物 `lost` 计数和损失行；重复扫描 no-op。
4. 货物守恒增加 `lost` 终点；现金在损失时不变；农场格式仍为 27，不新增农场顶层键。
5. 仍然不做保单、保费、理赔或保险现金。

如果产品坚持先做灾害作物保险，则走 **P0-B：风险模式作物损失**，并先修订 ADR-009；温和模式保持“只改湿度、不毁作物”不变。不要把“未浇水就减产”作为默认温和模式规则，否则会把浇水变成每天必须的操作，并破坏既有承诺。

## 未覆盖

- 没有实现或原型验证任何损失行、风险运输、风险模式、保单、理赔或保险账户；本记录只做代码调查和现有夹具复跑。
- 没有用真实存档或共享世界会话验证；所有夹具都是隔离的纯规则状态。
- 没有验证 Windows、CI、网络权威、客户端 UI 或 Windows 实机；本轮只在本机 macOS 无头运行。
- 没有决定可选保险的定价/风险信息模型。当前种子可由客户端推导，这是产品级阻塞；需要在实现 M8-03 前单独裁决。
- 没有评估品质/数量模型、作物价格扩展、身份抗女巫、保险准备金率或理赔队列上限；这些都属于 P0 之后的独立切片。
