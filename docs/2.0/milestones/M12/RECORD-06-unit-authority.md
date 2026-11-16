# M12-01 · 单位接入世界权威（切片）

执行日期：2026-11-15。状态：切片完成，不表示 M12-01 或 M12 验收完成。前置：[M12 PLAN](PLAN.md)、[RECORD-05 · 单位与补给规则](RECORD-05-units.md)。

## 问题

RECORD-05 只有纯规则：给定名册、库存上下文与显式时刻，回答招募成本、补给消耗、逃兵和派生战力。它没有持久化、没有连接身份、没有资产扣减，也没有网络入口，因此“无资源不能无限招募”和“欠供有明确能力变化”只在规则测试里成立；权威重启后不存在任何单位。

本切片把同一份纯规则接到世界权威，解决三件事：谁可以招募/解散、招募与补给如何扣真实资产、名册与喂食结果如何在重启后仍然成立。它不实现战斗、行军、装备升级或 UI。

## 边界

- 新增 `Game/world/unit_store.gd`、`tests/unit_authority_test.gd` 与本记录。
- 修改 `Game/world/headless_world.gd`（加载、只读视图、权威操作入口、资产结算）、`Game/world/world_host.gd`（成员 RPC、权限与回复）、`Game/world/world_member.gd` 与 `Game/world/world_client.gd`（请求/答复代理）。
- `Game/conflict/unit_state.gd` 未修改：目录、装备、招募、解散、补给、逃兵、战力与严格校验保持原样，所有单位规则继续由它回答。
- 未修改 `world_server.gd`、`FarmCommand`、`WorldProjection`、农场格式、场景或 UI；未新增顶层农场键或协议版本。农场仍为格式 27，`PROTOCOL_VERSION` 仍为 1。
- 现金与粮草的读写只调用 `FarmState` / `EconomyState` / `LedgerState` 的既有公开 API；没有给农场文档增加新键，也没有修改其内部规则。

## RPC 与频道

| 频道 | 方向 | 名称 | 说明 |
|---|---|---|---|
| 13 | 成员 → 权威 | `unit_request(payload)` | `{request_id, action, args}`；动作是 `recruit` / `disband` / `upkeep` / `state` |
| 14 | 权威 → 成员 | `_unit_reply(request_id, payload)` | 携带 `{ok, action, unit_id, duplicate, reason, reason_text, state}`；`state` 是权威单位视图 |

频道核查：世界会话现有 RPC 使用 0（`join`）、1（`_join_reply`）、2（`command_result`）、3（`submit`）、4（`request_summary`）、6（`catch_up`）、7（`social_request`）、8（`_social_reply`）、9（`territory_request`）、10（`_territory_reply`）、11（`organization_request`）、12（`_organization_reply`）。频道 5 仍未使用，但单位沿用组织之后的下一个连续空位 13/14；全仓库 `Game/`、`tests/` 中检索 `"reliable", 13` / `"reliable", 14` 无其它占用。

请求与答复都受 48 KiB 线上预算（`WorldPayload.WIRE_BUDGET_BYTES`）：请求超长直接回可见 `payload_too_large`；答复在 `rpc_id` 之前编码，超预算时同样回可见拒绝。单位请求与 `submit`、`social_request`、`territory_request`、`organization_request` 共用命令令牌桶。`WorldClient` 的 `WireMember` 在频道 14 先做预算解码再交给基类，损坏载荷不会进入单位视图。

## 持久化

`Game/world/unit_store.gd`：

- 文件 `units.json`，与 `territory.json`、`organizations.json`、居民账本同级；信封为 `{version: 1, state: {...}}`。
- `state` 必须通过 `UnitState.valid()` 的严格校验（精确键集、名册与命令互相引用、人数/装备/时间/上限）。
- 缺失返回 `{ok: true, kind: "missing", state: UnitState.initial_state(world_id)}`，即空名册。
- 版本不匹配返回 `unsupported`；解析失败、空文件、超过 64 KiB 或文档不合法返回 `corrupt`。
- 保存先写 `units.pending.json`，回读逐字节比对后再 rename 到主文件；保存前执行同一份 `valid()`，因此不会写出下一次加载会拒绝的文档。
- `HeadlessWorld.open()` 加载失败返回 `load_units_<kind>` 并拒绝启动；文档的 `world_id` 与世界不一致返回 `load_units_world_mismatch`。损坏、未知键或版本不支持的文件不会被空名册覆盖。

单位操作在 `HeadlessWorld.execute_unit()` 中执行。招募只把操作者从连接解析出来，载荷里的 `owner` 不参与授权；命令 id 同时是单位 id。同一 command id 的重试复用首次记录的时刻（从 commands payload 读回），因此不会因为权威时钟前进而被规则判成 `command_conflict`。解散和招募都先复制文档，写盘成功后才替换活文档。

## 资产语义

### 现金

- 招募成本由 `UnitState.recruit()` 计算，字段为 `{cash, supplies}`。
- 现金通过 `FarmState.economy_pay("unit_pay_<command_id>", actor, "@world", cash, now)` 从操作者账户转入 `@world` 账户；这是真实的玩家到公共账户转账，不是凭空销毁，也不改变发行量。
- 初始经济文档没有预先创建 `@world` 账户。候选农场写盘前按空账户（`cash: 0, granted: false`）补齐；0 现金不改变 `total_cash == issued`，也不需要账本分录。真正转账仍由 `economy_pay` 写入平衡分录。
- 账本事件 id 由完整招募载荷派生：`unit_pay_<sha256(command_id|owner|kind|people|equipment|station)>`。同命令 id、同载荷的重试命中同一笔分录；同价换兵种或改人数/装备/驻地会得到不同事件 id，不能冒领已扣的现金与粮草。
- 结果保持 `total_cash == issued`；测试在招募前后分别核对总额与发行量。
- 现金成本转给 `@world` 后不再属于个人；本切片没有规定公共账户的后续支出路径。

### 粮草

- 粮草只从操作者（招募）或单位所有者（补给）的口袋里扣。可用量是该 owner 的 `economy_goods()` 中 `EconomyCatalog.goods_ids()` 六种商品的合计。
- 扣除严格按 `EconomyCatalog` 的目录顺序（greens、spinach、radish、carrot、celery、garlic）逐项取最小值，一旦凑够成本就停止；不会为凑数改扣别的玩家的口袋。
- 招募所需的粮草是规则返回的 `cost.supplies`（一支单位一天的储备）；不足时规则返回 `insufficient_supply`，农场与单位文档都不写。
- 补给按 owner 分组结算：每名 owner 用自己口袋的粮草调用一次 `UnitState.upkeep()`，再合并各组的消耗、逃兵与受影响明细。这样同一 owner 名下多支单位仍按单位 id 升序分配，而不同 owner 的粮草不会互相串用，保持“从各 owner 口袋扣除”。
- 补给不产生现金变化；`last_upkeep_utc` 与 `sequence` 只在单位文档里推进。

## 跨文档事务

招募同时改两份文档：农场（现金账户、口袋粮草）与单位名册。顺序固定为：

1. 规则在副本上验证并生成单位候选；
2. 在农场副本上执行转账、扣粮；
3. 保存农场；
4. 农场保存成功后才保存单位文档；
5. 两份都成功后才替换活对象。

失败处理：

- 农场保存失败：单位文档不写，内存不变，返回 `save_<kind>`，可安全重试。
- 农场保存成功、单位保存失败：接受同一农场候选（内存与磁盘一致），返回 `save_units_<kind>`；单位文档仍为旧版本。重试时若口袋已因扣款而不足，`unit_pay_<完整载荷摘要>` 账本分录（金额、付款方、`@world` 收款方三方匹配）被当作“农场侧已提交”的持久标记，只补写单位文档，不再二次扣款；换载荷的重试不会命中该标记，因此不能借恢复路径少扣粮。这与 RECORD-06 居民账本“接受农场候选、如实返回保存失败”的选择一致：先让内存追平已落盘的农场，再让下一次请求补齐另一份文档。
- 若单位文档已经写入而农场尚未保存，本切片不会出现这种状态：顺序是农场先写。
- 解散只改单位文档，失败返回 `save_units_<kind>`，名册不变。
- 补给可能同时改农场（扣粮）与单位文档（逃兵/欠供天数）。同样先保存农场、再保存单位；单位保存失败时农场已扣粮并按磁盘接受，单位候选不生效。补给没有独立的 durable command id，因此这条失败路径只能保证内存与磁盘一致，不能保证下一次结算不再次扣粮；该残留已在“未覆盖”中说明。
- 补给结算时间取权威时钟的整秒（`floor`）。规则用精确时间戳判断“同一时刻”，权威入口再要求距上次结算跨过完整一天（`UnitState.UPKEEP_PERIOD_SECONDS`）：同一秒内的重复请求与当天更晚的请求都返回 `settled_this_tick`，不会按秒扣粮。

## 权限

- 身份只来自连接：`WorldHost.unit_for_member()` 用 `_members` 判断是否入册、用 `_players` 解析操作者；`args` 里的 `actor` / `owner` 永不参与授权。`unit_id` 只在解散时表示目标单位。
- 读取：`state` 对所有已入册连接开放，包括访客与匿名成员；视图只含 `id` / `owner` / `kind` / `people` / `equipment` / `station` / `unfed_days`，按 id 排序，不含命令记录。
- 写入：要求成员角色（`WorldInvite.MEMBER`）、非只读权威、非空玩家身份。拒绝原因按顺序具名：
  - 未入册：`not_a_member`
  - 访客：`forbidden`
  - 匿名成员：`no_player`
  - 迁移中/只读权威：`read_only`
  - 未知动作：`unknown_action`
  - 空命令 id：`invalid_command`
- 规则层继续给出 `insufficient_cash`、`insufficient_supply`、`unknown_unit`、`not_owner`、`capacity`、`invalid_kind`、`invalid_people`、`invalid_equipment`、`invalid_station`、`time_regression`、`command_conflict` 等具名拒绝。
- 解散只有单位所有者本人可以执行：规则用命令里的 owner（连接身份）与名册行比对，非所有者得到 `not_owner`。
- 补给是全局战略结算，任何具名成员都可以触发；它不改变任何人的现金，只按各 owner 自己的口袋扣粮并结算逃兵。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
cd /Volumes/Disk-1tb/yipiantian
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/unit_authority_test.gd"
```

原始末行：

```text
UNIT_AUTHORITY_TEST checks=224 failures=0
```

真实网络测试原始末行：

```text
UNIT_NETWORK_TEST checks=57 failures=0
```

回归原始末行：

```text
UNIT_STATE_TEST checks=182 failures=0
CHAIN_INTEGRATION_TEST checks=509 failures=0
M4_SERVER_TEST checks=84 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/m4-server-298922
TERRITORY_AUTHORITY_TEST checks=69 failures=0
ORGANIZATION_AUTHORITY_TEST checks=200 failures=0
M4_CLIENT_SCENE_TEST checks=42 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/m4-client-scene-316598
```

覆盖：

| 用例 | 检查 |
|---|---|
| 存储 | 缺失为空名册且有效、携带世界 id；写入后重载名册与世界一致；64 KiB 常量；未知顶层键与畸形文档在写盘前拒绝 |
| 招募资产 | 成员通过权威招募；载荷 `owner` 被忽略；真实现金从操作者转入 `@world`；`total_cash` 与 `issued` 不变且仍相等；粮草按目录顺序从 greens 扣到 spinach；名册立即落盘 |
| 幂等 | 同命令 id 重放返回 `duplicate`；不二次扣现金或粮草、不改名册；同 id 换兵种 `command_conflict` |
| 资产不足 | 无账户 `insufficient_cash`；有现金无粮草 `insufficient_supply`；拒绝后农场快照与名册逐字节不变；不创建单位文档 |
| 解散与权限 | 非 owner `not_owner`；未知单位 `unknown_unit`；owner 解散成功并移出名册；重放幂等；访客 `forbidden` 且可读；匿名 `no_player`；未入册 `not_a_member`；未知动作；空命令 id；只读 `read_only` 且仍可读 |
| 重启 | 重开权威后单位、所有者、兵种、人数、装备、驻地与招募命令仍在；`@world` 付款仍在 |
| 补给 | 同一 tick 内 A 欠供 5 人逃兵、欠供 1 天、战力下降；B 足量不动；A/B 各自口袋扣粮互不串用；现金总额不变；同秒重复请求 `settled_this_tick` 且不再扣粮；跨过完整一天后重新结算；同一天更晚的另一秒仍返回 `settled_this_tick` 且不扣粮、不改补给时钟 |
| 付款重试 | 农场已付款、名册缺失时，完整载荷绑定的 `unit_pay_` 分录补写单位且不二次扣现金/粮草；同价换兵种的重试不命中该分录、返回 `insufficient_supply` 且不创建单位 |
| 工资两阶段 | 第一阶段单位写失败不付款；第二阶段农场付款后清除待付记录失败，单位时钟只推进一次、账本只有一笔分录；随后解散单位再重试，只清除待付记录、不二次付款 |
| 写时复制 | 粮草不足与非法驻地都不改变活名册、活农场；不写盘 |
| 坏文档 | `units.json` 损坏、版本不支持、属于另一个世界均拒绝启动且不覆盖原文件；直接无头打开得到空且有效的名册 |
| 真实网络 | `unit_network_test` 启动真实 authority，以成员码经 WSS 频道 13/14 完成 state/recruit/重放/disband/upkeep；访客只读、匿名写入拒绝；超 48 KiB 请求回 `payload_too_large` 且连接继续可用 |

## 未覆盖

- 战斗、行军、驻防、伤亡与战利品：单位仍只是名册行，不参与 M12-03 的 `ConflictSettlement`；`station` 只是字符串，不校验地籍、建筑或真实位置。
- 工资与持续现金消耗：只有一次性招募现金和每日粮草，没有欠薪、士气或按小时折算。**工资已由 [RECORD-24 增补](RECORD-24-unit-wages.md) 接入权威**（`wage` 动作、账本幂等分录与面板入口）；士气与按小时折算仍未做。
- 装备变更：装备只在招募时确定，没有升级、更换、损坏或缴获。
- 网络 UI 与场景：没有单位面板、招募/解散入口、补给按钮或逃兵提示；`WorldMember` / `WorldClient` 只提供请求方法与信号。单位不进入 `WorldProjection` / 摘要广播，客户端只能通过 `state` 请求或操作答复刷新。
- 单位文档保存失败的彻底幂等：招募有完整载荷绑定的 `unit_pay_` 账本标记兜底；补给仍是农场先扣粮、单位后写盘，若单位写盘失败且进程退出，下一次调用可能再次扣粮。当前没有为粮草引入第二个持久结算标记。
- 补给节奏：任何具名成员都能触发补给，没有权威定时扫描；权威入口限制为每完整一天最多结算一次，因此重复调用不会按秒消耗粮草，但触发时刻仍由调用者决定。
- 命令窗口：招募/解散记录达到 256 条后规则返回 `capacity`；没有归档、淘汰或跨窗口幂等测试。
- 身份可信：player id 不是密码学凭据；`@world` 账户只由权威写入，没有玩家侧支出入口。
- 只在 macOS 无头模式验证；未在 Windows 实机或 CI 运行，未做并发双权威写入验证。真实 WSS 路径由 `unit_network_test` 覆盖，但答复侧 48 KiB 预算与带逃兵的线上 `upkeep` 未单独构造。

## 关联

- 阶段计划：[M12 PLAN](PLAN.md)；规则切片：[RECORD-05 · 单位与补给](RECORD-05-units.md)。
- 同形接线参考：[M11-02 组织接入世界权威](../M11/RECORD-08-organization-authority.md)、[M11 地籍接入](../M11/RECORD-02-cadastre-authority.md)。
- 资产与账本：`Game/farm/farm_state.gd` 的 `economy_pay` / `economy_goods` / `bag`，`Game/farm/economy_state.gd` 的 `@world` 账户，`Game/farm/ledger_state.gd` 的平衡分录。
- 存储与严格校验参考：`Game/world/territory_store.gd`、`Game/world/organization_store.gd`。
