# ADR-025 · 冲突参与：档位、声明修订、同意与损失上限

- 状态：采纳（2026-11-15），M12-02 规则切片实现完成；未验收
- 关联：[M12-02 参与制度记录](../milestones/M12/RECORD-02-participation.md)、[M12 PLAN](../milestones/M12/PLAN.md)、[领土政治、私兵与有限 PvP](../systems/politics-conflict-law.md)、[ADR-023](ADR-023-land-cadastre.md)

## 背景

M12-02 要求落实“和平/有限冲突、区域、窗口、同意、退战延迟、离线保护与损失上限”，验收判据是“同一攻击在和平房拒绝；房主不能静默扩大风险”。M12-01（单位与补给）和 M12-03（交战结算与战利品）尚未实现，也没有任何冲突权威文档。

设计规格（`politics-conflict-law.md`）已经给出边界：

- 至少提供和平与有限冲突两种房间制度；和平制度拒绝攻击。
- 有限冲突只在公开区域、明确时间窗和参与同意范围内生效。
- 冲突前显示可损失资产、最大损失、退出方式与生效延迟。
- 退出不能撤销已确认的单次交战；等待期内损失仍受原上限约束。
- 房主改变制度需预告并重新取得风险同意，默认不同意者保留和平地位。
- 离线成员按房间规则进入保护或托管防守。

本切片只建立可以独立验证的参与制度纯规则，不接网络、存档、UI，也不实现单位、招募、战利品和真实资产扣除。目标是在不改动 `Game/farm/*`、`Game/world/*`、`Game/ui/*` 的前提下，把上述约束固化为一个确定性的、可序列化、可严格校验的规则文档。

## 决定

### 1. 两种档位：peace 是默认，limited 不自带风险

`regime.tier` 只有 `peace` 与 `limited`：

- `peace` 是全新房间的默认值，`revision=0`，无声明、无区域、无窗口、无预算。任何 `engage` 都以稳定原因 `peace` 拒绝；`declare_participation` 也以 `peace` 拒绝。
- `limited` 本身不会打开风险。房主必须同时发布 `higher_risk=true` 的显式声明，带 `declaration_id`、声明者、声明时刻、生效时刻、区域、窗口和两个损失上限；缺任一项则返回 `risk_not_declared` 或 `invalid_regime`。`limited` 但未声明更高风险、或声明为空，文档 `valid()` 直接判非法。

这样“房间是有限的”与“某块区域本次确实开放风险”是两个独立事实，避免把档位当作隐式授权。

### 2. 声明是耐久记录，且每次修订都作废旧同意

`regime` 保存 `revision`、`declaration_id`、`declared_by`、`declared_utc`、`effective_utc`、`higher_risk`、`area_ids`、`window_ids`、`loss_cap`、`offline_loss_cap`、`command_id`，因此声明本身可审计、可重放。

关键规则：任何一次成功声明都会把 `revision` 递增，而 `participant.consent_revision` 必须等于当前 `revision` 才算有效。由此：

- 房主改档位、扩大区域/窗口、提高上限，都会让所有旧同意立刻失效；
- 已同意者的角色标记在下次显式 `declare_participation` 时被清空，只剩本次声明的角色；上一修订的攻击者身份不会悄悄复活；
- 即使房主原样重发同一份声明，也仍然递增修订号，参与者必须重新确认。

这是“房主不能静默扩大风险”的直接实现：扩大风险必须换来新的、可追溯的同意记录，而不是沿用旧同意。降回 `peace` 同样是一次新修订，此后所有攻击重新被拒，历史损失和交战行保留。

已知取舍：房间每次修改制度都要全员重新同意，对高频微调不友好；这是首版有意选择的安全侧默认，正式上线前是否引入“只对扩大部分重新同意”的细分留给后续裁决。

### 3. 区域与窗口沿用可核验的整数语义

- 区域是包含端点的整数格矩形 `{id, min_x, min_z, max_x, max_z}`，坐标 `0..4096`，与 ADR-023 地籍一致；`min_x <= max_x`、`min_z <= max_z`。
- 窗口是半开区间 `[start_utc, end_utc)`，`end > start`。端点相接的窗口（`10:00` 结束、`10:00` 开始）不重叠，边界时刻归后一个窗口。
- 当前生效范围（`regime.area_ids` / `window_ids`）内部不得自重叠，因此一个坐标/时刻至多命中一个区域/窗口，判定唯一。单次声明内部重叠会在写入前被拒绝（`overlapping_areas` / `overlapping_windows`）。
- 复用旧 id 时边界必须完全一致（`area_conflict` / `window_conflict`），不允许同名改形。

历史行不会无限累积：每次成功声明后会清理既不在当前生效范围、也不被任何耐久交战引用的区域与窗口行。仍能解释已结算交战的区域/窗口必须保留，否则完整性校验会失败。

### 4. 同意：进攻方显式声明角色，防守方本人同意

`participant = {participant, attacker, defender, consent_revision, consent_utc, consent_command_id, withdraw_utc, withdraw_effective_utc, withdraw_command_id}`。`declare_participation(role)` 由玩家自己发起，`role` 只有 `attacker` / `defender`。

- 进攻方必须持有当前修订的 `attacker` 同意，否则 `attacker_not_consented`。
- 防守方必须持有当前修订的 `defender` 同意，否则 `target_not_participating`。从未同意者保留和平地位，这与规格“默认不同意者保留和平地位”一致。
- 同一玩家可以同时持有两个角色，角色独立记录。
- `public`、`@world`、空串等非玩家 id 一律 `invalid_player`。

### 5. 离线保护用更小的上限

`engage` 接收显式 `defender_online` 布尔值。防守方离线时使用 `offline_loss_cap`，在线时使用 `loss_cap`；文档要求 `0 < offline_loss_cap <= loss_cap`。因此离线不会因为无人值守而被无限掠夺，也不会高于在线额度。

“离线”只是结算输入，不改变同意状态：离线的已同意防守方仍是合法目标，只是预算更小。损失按 `(target, window_id)` 累计，在线与离线攻击共享同一累计行，因此不能先打到在线上限再换离线额度继续打。超限返回稳定原因 `loss_cap_exceeded`，并附带 `window_id`、当前累计 `loss_total` 与本次适用 `cap`，失败不写任何字段。

### 6. 退战延迟

`withdraw` 记录 `withdraw_utc`，`withdraw_effective_utc` 严格等于 `withdraw_utc + WITHDRAWAL_DELAY_SECONDS`（本切片固定 3600 秒）。规则：

- 生效前：双方仍可发起并结算新交战（但离线上限照常生效）；不允许用新的同意命令中途取消已宣布的退战（`withdrawal_pending`）。
- 到生效时刻：进攻方的新攻击返回 `attacker_withdrawn`；针对该防守方的新攻击返回 `target_withdrawn`。
- 生效后可以重新 `declare_participation` 显式加入，退战标记被清除。
- 已确认的交战是耐久事实：退战不会回滚其损失行、区域、窗口或交战记录，等待期内已结算的损失仍计入该窗口上限。

### 7. 幂等、确定性与严格校验

- 所有命令接收显式 `at_utc`；无 RNG、无系统时钟、无磁盘、无场景、无网络。
- `command_results` 是 64 条有界窗口，重复命令 id 且 payload 一致时回放首次结果（`duplicate=true`），payload 不同返回 `command_conflict`。
- 耐久守卫不依赖命令窗口：`engagements[command_id]` 保存交战事实，`participant.consent_command_id` / `withdraw_command_id` 保存同意与退战 id。命令窗口淘汰后重放仍幂等；篡改参数则 `command_conflict`。
- 失败命令不修改任何字段；`declare_participation` 在复制出的参与者行上计算，避免在拒绝路径上提前改写状态。
- `valid()` 严格校验键集合、类型、id、坐标、时间、上限关系、修订号单调性、退战延迟精确值、参与者修订不超过当前修订、区域的几何关系、窗口的半开关系、`losses` 与已结算交战求和一致、每次交战的 `cap` 与对应修订 `caps` 行一致、命令结果与其 payload 同世界且同对象，以及 `command_results` 中的交战命令必须有对应耐久交战行。无旧格式兼容分支，不提供迁移器。
- `caps` 按修订号保存各版本上限，使旧交战在后续修订后仍能校验自己的 `cap`；只保留当前修订与仍被交战引用的修订行。

### 8. 不采用的做法

- **不把风险写进档位默认值**：`limited` 若自动允许攻击，就等于房主一次点击即扩大全员风险，违反验收判据。
- **不做“一次同意永久有效”**：房主可先取得宽泛同意再逐步扩大范围，这正是要防止的静默扩大。
- **不让退战即时生效**：即时退战会把等待期损失甩给对手，且可被用来规避已安排的交战。延迟与“不撤销已确认交战”一起保证双方在窗口内的责任可预测。
- **不把离线保护做成免疫**：零上限会让离线成为无成本免战；本切片用更小但非零的额度表达“受损有限”。
- **不让防守方未同意就可被攻击**：与“默认不同意者保留和平地位”冲突。
- **不接农场资产**：本切片只记录规则层损失数值，不做真实扣除、冻结或战利品。接入会实质改变资产守恒语义，应由 M12-03 单独裁决。

## 后果

- 新增 `Game/conflict/participation_state.gd` 与 `tests/conflict_participation_test.gd`，本机结果 `CONFLICT_PARTICIPATION_TEST checks=257 failures=0`。
- 未修改 `Game/farm/*`、`Game/world/*`、`Game/ui/*`、`main.gd`、`.github/workflows`、`rules/project-context.md`。
- 损失目前只是文档内整数，不绑定农场库存、账户、建筑或地契；没有资产扣除、冻结或战利品发放。
- 没有网络、存档 sidecar、UI 或权威命令入口；`M12-03` 才决定是否以及如何把这些规则接入真实资源。
- 已知缺口：反作弊/身份可信（现有 `player_id` 只是声明）、多房间隔离、跨房间复制套利、组织/职位代行、公告预览、退战细分、损失数值与经济账本的对应关系、Windows/CI 证据。

## 复审触发条件

出现以下任一情况时重开本裁决：接入农场资产或经济账本、引入单位/补给/战利品、把制度变更改为部分重新同意、允许托管防守或组织代行、需要多房间同时冲突、需要窗口外 `withdraw` 幂等、或位置/窗口/上限的数量边界不再满足真实世界。
