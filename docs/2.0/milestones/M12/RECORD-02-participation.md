# M12-02 · 冲突参与制度（最小切片）

执行日期：2026-11-15。状态：切片完成，不表示 M12-02 或 M12 验收完成。前置：[M12 PLAN](PLAN.md)、[ADR-023 · 地籍](../../decisions/ADR-023-land-cadastre.md)、[ADR-025 · 冲突参与](../../decisions/ADR-025-conflict-participation.md)。

## 问题

M12-02 要求“和平/有限冲突、区域、窗口、同意、退战延迟、离线保护与损失上限”，验收判据是“同一攻击在和平房拒绝；房主不能静默扩大风险”。此前没有任何冲突权威文档、参与状态或损失累计规则；M12-01（单位与补给）和 M12-03（交战与转移）都未开始。

本切片只建立可以独立验证的参与制度纯规则：不接网络、存档、UI，也不实现单位、招募、战利品或真实资产扣除。范围刻意小于 M12-02 的完整验收，目的是先冻结“谁可以在何时何地、经谁同意、承担多少损失”的判定，再决定接入方式。

## 边界

- 新增 `Game/conflict/participation_state.gd` 与 `tests/conflict_participation_test.gd`。
- 未修改 `Game/farm/*`、`Game/world/*`、`Game/ui/*`、`main.gd`、`.github/workflows`、`rules/project-context.md`、`docs/2.0/decisions/README.md`。
- 无 RNG、无系统时钟、无磁盘、无场景、无网络；所有命令接收显式 `at_utc`，同一输入得到同一输出。
- 不读取 `FarmState`，不记录真实库存/余额，不冻结资源，不发放战利品。

## 实现

### 文档形状

```text
conflict = {
  world_id: String,
  host: String,
  sequence: int,
  regime: {
    tier, revision, declaration_id, declared_by, declared_utc, effective_utc,
    higher_risk, area_ids, window_ids, loss_cap, offline_loss_cap, command_id,
  },
  areas:    { area_id:   { id, min_x, min_z, max_x, max_z } },
  windows:  { window_id: { id, start_utc, end_utc } },
  caps:     { revision:  { loss_cap, offline_loss_cap } },
  participants: { player: participant },
  losses:   { "target|window_id": { target, window_id, amount } },
  engagements: { command_id: engagement },
  command_results: { command_id: { payload, result } },
}
```

### 档位

- `peace`：全新房间的默认档位，`revision=0`，无声明、无区域、无窗口、无预算。所有 `engage` 与 `declare_participation` 被拒。
- `limited`：只有房主同时发布 `higher_risk=true` 的显式声明后才开放风险。声明必须带声明 id、声明者、声明时刻、生效时刻、非空区域与窗口，以及 `0 < offline_loss_cap <= loss_cap`。`limited` 无声明返回 `risk_not_declared`。

### 命令

- `declare_regime(state, world_id, actor, declaration, command_id, declared_utc)`
  - 只有 `host` 可调用（`not_host`）；声明时间必须严格晚于当前声明（`time_regression`）。
  - 成功即 `revision += 1`，所有旧同意失效。
  - 单次声明内部区域重叠返回 `overlapping_areas`，窗口重叠返回 `overlapping_windows`；任一失败都不写入任何行。
  - 复用已有区域/窗口 id 时边界必须一致（`area_conflict` / `window_conflict`）。
  - 同一命令 id 重发同一声明回放（`duplicate=true`）；同 id 换声明返回 `command_conflict`；不同 id 重发同一 `declaration_id` 返回 `declaration_conflict`。
  - 成功声明后清理既不在当前生效范围、也不被任何耐久交战引用的区域与窗口行。
- `declare_participation(state, world_id, actor, role, command_id, at_utc)`
  - `role` 只有 `attacker` / `defender`；和平档 `peace`；未声明更高风险 `risk_not_declared`。
  - 同意绑定当前 `revision`。修订变化后再次声明只保留本次角色，上一修订的另一个角色不会复活。
  - 退战等待期内返回 `withdrawal_pending`；生效后重新声明会清除退战标记。
  - 在拒绝路径上不修改参与者行（内部先复制再写回）。
- `withdraw(state, world_id, actor, command_id, at_utc)`
  - 只有当前参与者可退战；`withdraw_effective_utc = withdraw_utc + WITHDRAWAL_DELAY_SECONDS`（3600 秒）。
  - 等待期内再次退战或重新加入均返回 `withdrawal_pending`；生效后再次退战返回 `already_withdrawn`。
- `engage(state, world_id, attacker, target, x, z, at_utc, amount, defender_online, command_id)`
  - 依次校验命令、时间、正数损失、双方合法玩家、非自攻、坐标范围、世界 id。
  - 依次校验档位（`peace`）、更高风险声明（`risk_not_declared`）、生效时刻（`regime_not_effective`）、区域（`area_not_declared`）、窗口（`outside_window`）、进攻方同意（`attacker_not_consented` / `attacker_withdrawn`）、防守方同意（`target_not_participating` / `target_withdrawn`）、累计上限（`loss_cap_exceeded`）。
  - 成功写入一条耐久 `engagements` 行与一条 `losses` 累计行，并使 `sequence += 1`。
  - 幂等不依赖命令窗口：`command_results` 淘汰后，`engagements` 行仍可回放；参数不一致返回 `command_conflict`。

### 查询与校验

- `loss_total(state, target, window_id)`：该目标在该窗口的累计损失。
- `area_at(state, x, z)` / `window_at(state, at_utc)`：当前生效范围内的唯一命中，未命中返回空串。
- `consent_active(state, player, role, at_utc)`：当前修订下角色同意存在且未生效退战。
- `valid(value)`：严格校验键集合、类型、id、坐标、时间、上限关系、修订单调、退战延迟精确值、区域/窗口几何、`losses` 与交战求和一致、每次交战 `cap` 与对应修订 `caps` 行一致、命令结果与 payload 同世界同对象、交战命令必须有耐久交战行。无旧格式兼容分支。
- `normalize(state)`：仅在 `valid()` 通过后把 JSON 数字还原为整数/浮点/布尔。

### 不变量

- 和平房拒绝一切攻击；同一攻击请求在和平与有限房得到不同结果，但同一房内结果确定。
- `limited` 无显式更高风险声明时既不接受参与也不接受攻击。
- 房主每次修改制度都递增修订；旧同意自动失效，风险不能静默扩大。
- 当前生效范围内一个坐标/时刻至多命中一个区域/窗口；重复命中在写入前被拒。
- 同一目标同一窗口的累计损失不超过 `loss_cap`；离线时不超过更小的 `offline_loss_cap`。
- 退战不撤销已确认交战；等待期内新交战仍结算，生效后新命令被拒。
- 同一命令 id 至多结算一次；命令窗口淘汰后仍幂等。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/conflict/participation_state.gd` | 新增纯规则模块：档位、声明、同意、退战、区域/窗口、累计上限、严格校验 |
| `tests/conflict_participation_test.gd` | 新增夹具，257 项检查 |
| `docs/2.0/decisions/ADR-025-conflict-participation.md` | 新增裁决：档位、修订式同意、离线上限、退战延迟、不接资产 |
| `docs/2.0/milestones/M12/RECORD-02-participation.md` | 本记录 |

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game \
  --script "$PWD/tests/conflict_participation_test.gd"
```

原始末行：

```text
CONFLICT_PARTICIPATION_TEST checks=257 failures=0
```

覆盖矩阵：

| 用例 | 检查 |
|---|---|
| 和平档 | 默认档位、无声明、无范围、无预算；攻击 `peace`；参与 `peace`；查询为空；拒绝后文档不变 |
| 声明校验 | 非房主 `not_host`；错误世界 `wrong_world`；空/负/非有限命令与时间；非字典声明；`limited` 无风险声明；无区域/无窗口；零上限；离线上限高于总上限；区域重叠；单次声明窗口重叠；区域几何反转/越界；重复区域 id；生效早于声明；peace 带范围；任一失败不写入 |
| 声明耐久 | 修订递增、声明者/时刻/范围/上限入库；区域/窗口查询含端点与半开边界；重放幂等；同 id 换声明 `command_conflict`；同声明换 id `declaration_conflict`；时间回退 |
| 范围判定 | 生效前 `regime_not_effective`；区域外 `area_not_declared`；窗口外 `outside_window`；窗口端点归下一窗口；未同意进攻/防守方被拒、自攻、零/负/小数损失、负/越界坐标、错误世界 |
| 同意 | 非法角色、`public`、非参与者退战；进攻方同意；防守方同意；同意绑定修订；同意前不可回溯；重放幂等与冲突 |
| 离线上限 | 离线用较小上限；累计到上限后拒绝 `loss_cap_exceeded` 并返回饱和 total/cap；在线补到总上限；同一窗口在线+离线共享累计；不同窗口/目标独立 |
| 修订 | 新声明作废旧同意；旧同意行保留；重新同意后可交战；交战记录修订号；同窗口跨修订累计；相同范围重发也要重新同意；降回 peace 拒绝攻击、保留损失与必要范围行、清理无引用行 |
| 退战 | 记录与生效时刻；延迟内仍结算；等待期不可重新加入或重复退战；边界时刻生效；进攻方 `attacker_withdrawn`；防守方 `target_withdrawn`；已确认交战不回滚；生效后可重新加入 |
| 幂等 | 同 id 回放 `duplicate`；篡改金额 `command_conflict`；命令窗口清空后仍幂等；耐久行篡改坐标冲突；新 id 正常结算；窗口淘汰后同意/退战/声明 id 不能跨对象复用 |
| 文档校验 | 缺键/多键；世界/host/sequence；档位/风险/上限/范围；区域/窗口行被篡改；参与者修订/角色/退战延迟；交战修订/坐标/窗口/金额/上限/累计；损失行与求和；伪造命令结果；伪造耐久交战缺失 |
| 序列化 | JSON 往返仍有效；`normalize` 还原数字；伪造提高上限、扩大区域、改写在线标记、伪造同意、缩短窗口均被拒 |
| 确定性 | 同一命令序列生成逐字节相同文档；脚本序列损失与交战数精确；窗口外新命令被拒；空文档与首次声明边界 |

## 未覆盖

- 网络与权威接线：没有 sidecar 存储、`HeadlessWorld` 加载/保存、`WorldHost` 命令入口、成员/访客角色门、客户端方法或 RPC。
- 存档：不进入农场 v27 文档；没有 sidecar 位置、版本、原子写、损坏恢复或重启幂等测试。
- 真实资产：损失只是文档内整数，不扣库存/余额、不冻结资源、不发战利品；与 `FarmState`、经济账本、地契、建筑均无关联。资产守恒语义留给 M12-03。
- 单位与招募：没有护卫/民兵、装备、驻地、工资或粮草（M12-01）。
- 可玩性验证：没有普通农户、商队、弱小组织与攻击者场景观察（M12-05）。
- 组织与代行：没有组织、职位、负责人离线代行或托管防守。
- 多房间：单文档单房间；跨房间复制套利、双房间共享玩家预算未处理。
- 公告预览：没有向参与者展示即将生效的风险、可损失资产与退出方式的 UI。
- 身份可信：`player_id` 仍是声明式 id，不是密码学凭据。
- 声明/同意/退战的窗口外幂等：这三类文档字段只保存每位参与者**当前**的 command id（`regime.command_id` / `consent_command_id` / `withdraw_command_id`）。被后续同类命令取代、且已从 64 条 `command_results` 窗口淘汰的旧 id，再次提交时不会回放，而是按新命令执行（声明会重新递增修订并要求重新同意；同意会重写 consent 并可能撤销已生效的退战；退战会重新计时）。这是有意保留的限制：保存全部历史 id 会让文档无界增长。已结算交战的 `engagements[command_id]` 是耐久行，不受此限制。权威层对未知 id 使用当前时钟，因此规则层的时间回退护栏不会命中。
- 声明 `effective_utc` 只是记录并参与判定，不自动调度：本切片没有后台推进，只在收到显式时间时检查。
- `WITHDRAWAL_DELAY_SECONDS` 固定为 3600 秒，不能按房间配置。
- 只在本机 macOS 无头模式验证；未在 Windows/CI 运行。

## 关联

- 裁决：[ADR-025 · 冲突参与](../../decisions/ADR-025-conflict-participation.md)。
- 规格：[领土政治、私兵与有限 PvP](../../systems/politics-conflict-law.md)。
- 阶段计划：[M12 PLAN](PLAN.md)。
- 坐标语义参考：[ADR-023 · 地籍](../../decisions/ADR-023-land-cadastre.md)。
- 结构参考：`Game/world/territory_state.gd` 的纯规则与严格校验写法。
