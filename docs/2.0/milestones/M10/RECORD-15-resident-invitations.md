# M10-04 · 居民邀约持久化与权威裁决

执行日期：2026-11-16。状态：切片完成，不表示 M10-04 或 M10 验收完成。前置：[M10 PLAN](PLAN.md)、[NPC 邀约规则](RECORD-09-invitations.md)、[社交动作写入记忆](RECORD-10-social-memory.md)、[居民社交接入权威](RECORD-12-resident-authority-social.md)、[居民只读视图](RECORD-13-resident-view.md)。

## 问题

RECORD-09 已有严格、可拒绝的邀约文档，RECORD-10 能把邀请结果写成有界记忆，RECORD-12 已把社交计划、关系和记忆接入 `HeadlessWorld` 与 `residents.json`，但邀约从未进入权威：规则选中 `invite` 时只当作一次普通社交动作立即改关系，没有可持久化的 pending 对象、没有下一轮的接受/拒绝裁决，也没有跨重启与重放保护。RECORD-13 的居民视图同样看不到邀约。

本切片把邀约接入权威：`residents.json` 信封新增有界 `invitations`，社交阶段选中 `invite` 时创建 pending 而不立即写关系；被邀请方在下一次结算按确定性的关系/人格规则接受或拒绝，结果写入当事人的有界记忆。资产、现金、货物、账户与权属零变化。

## 边界

- 修改 `Game/world/residents_store.gd`：信封新增 `invitations`、64 条容量、严格行形状、旧四键文档兼容。
- 修改 `Game/world/headless_world.gd`：`resident_invitations` 状态、加载/保存、pending 裁决阶段、社交阶段的 `invite` 分支、视图投影与每日上限。
- 新增 `tests/resident_invitation_authority_test.gd`，更新 `tests/resident_authority_social_test.gd`、`tests/resident_view_authority_test.gd`、`tests/resident_view_network_test.gd`；新增本记录。
- 未修改 `Game/npc/npc_invitation.gd`、`npc_social.gd`、`npc_social_memory.gd`、`npc_memory.gd`、`Game/ui/*`、`Game/scenes/*`、`tests/*panel*`、`.github/`、`PLAN.md`、`rules/`、农场存档格式或经济规则。
- 不接模型、不读系统时钟、不使用 RNG；结果只由显式 `at_utc`、持久关系文档和派生人格决定。

## 持久化格式

`residents.json` 信封从四键扩展为五键，`version` 仍为 1：

```text
{
  "version": 1,
  "world_id": "<world id>",
  "social": {...},                       # 既有 NpcSocial 文档
  "memories": {...},                     # 既有 NpcMemory 文档
  "invitations": {
    "<inv_id>": {
      "id": "<inv_id>",                  # 与键相同，由规则确定性派生
      "from": "npc_xu_bo",
      "to": "npc_a_zhou",
      "kind": "visit",                   # visit / meal / trade_talk
      "created_utc": 1800060010.0,
      "expires_utc": 1800063610.0,       # 严格晚于 created
      "status": "pending",               # pending 时恰好八键
      "command_id": "social_1234567890"  # 创建它的 act id
    },
    "<decided_id>": {
      # ... 同上八键 ...
      "status": "accepted",              # accepted / declined / expired / withdrawn
      "decided_utc": 1800060410.0,
      "reason": "accepted",              # 固定等于 status
    }
  }
}
```

- `invitations` 最多 `MAX_INVITATIONS = 64` 条；行形状复用 `NpcInvitation.valid()`：pending 七键、非 pending 九键，再额外要求非空且唯一的 `command_id`（≤128 字符）。去掉 `command_id` 后整体交给规则模块校验，因此派生 id、`from != to`、种类目录、时刻区间与 `reason == status` 都由既有规则保证。
- 旧文档没有 `invitations` 键时按空表加载；保存总是写五键。四键与五键之外的键集视为损坏。
- 容量、损坏、版本不是 1 或异世界仍拒绝启动，绝不覆盖原文件；保存仍为 `residents.pending.json` 写入、逐字节回读、再 rename。
- 社交、记忆与邀约在同一个 `save_state` 原子替换里落盘，不会出现只保存其中一部分。

## 创建

`_apply_residents()` 的社交阶段调用既有 `NpcSocial.plan()`；当计划动作是 `invite` 时不再调用 `NpcSocial.apply()`：

1. 用社交动作 id 作为 `command_id`。表内已有该 command id 时返回 `duplicate`，不创建。
2. 以 `NpcInvitation.propose()` 在去掉 `command_id` 的文档上创建 pending；`from/to/kind` 来自计划动作，种类固定为 `visit`。
3. 派生 id、同 `(from,to,kind)` 未决去重、`duplicate_id` 与 64 条上限全部沿用规则模块。
4. 成功后才把候选表转为权威内存候选；本名居民本轮社交结束。pending 不写关系、不写记忆、不移动资产。

每日上限继续生效：滚动 24 小时内的社交动作数与**新建邀约数**之和达到 4 时，不再创建或执行新的社交动作。

## 裁决

每次结算在经济阶段之后、社交规划之前处理 pending：

1. `NpcInvitation.expire()` 把所有 `now_utc >= expires_utc` 的行转为 `expired`，`decided_utc = expires_utc`。过期不写记忆、不授予任何权属或资产。
2. 剩余 pending 中，`created_utc >= now_utc` 的（本轮刚创建）留到下一次结算；同一时刻重放不会立即裁决。其余按邀约 id 升序，由被邀请方 `to` 做确定性裁决：
   `affinity(to → from) + warmth(to) - suspicion(to) >= 0` 时接受，否则拒绝。
   关系取自真实社交文档，人格取自 `NpcPersonality.traits(to, world_seed)`；没有 RNG、模型或自由文本。
3. 通过 `NpcInvitation.accept()` / `decline()` 写时复制状态；随后把同一次决策投影为结构化事件，依次对 `from` 与 `to` 调用 `NpcSocialMemory.apply()`。适配层只为该状态对应的当事人写一行（接受写收件人、拒绝写发起人），另一方返回 `skipped: not_subject`。两边候选都成功才提交邀约状态与记忆。
4. 裁决不改关系文档。接受或拒绝都不授予财产、权属、账户或命令权限。

## 幂等与失败

- 同一 `command_id`（社交 act id）重放不会创建第二条邀约；行内 command id 的唯一性也由加载校验强制。
- 同一邀约一旦非 pending，不会再被裁决；决策记忆 id 为 `"sm_" + FNV-1a("invitation", 邀约 id, 居民 id)`，重复投递在适配层被判为 `duplicate`。
- 本轮刚创建（`created_utc == now_utc`）的 pending 不在同一时刻裁决，因此同一时刻重复扫描既不新建也不改状态。
- 重启后 pending 邀约、已决策行、`command_id`、社交冷却与关系原样恢复；同一时刻重放的扫描只做一次裁决。
- 保存顺序与 RECORD-12 一致：农场落盘后保存居民账本，再保存 `residents.json`。任一保存失败时不更新内存中的邀约/记忆文档；错误原因带 `save_resident_state_<kind>` 前缀。

## 视图

`residents_view(viewer)` 每名居民新增两个字段，原有字段不变：

```text
{
  "pending_invitations": 1,                    # 本人作为 from 或 to 的 pending 数
  "last_invitation": {                          # 本人参与、created_utc 最新的一条
    "from": "npc_xu_bo", "to": "npc_a_zhou",
    "status": "pending", "created_utc": 1800060010.0,
  },                                            # 没有邀约时为 {}
}
```

- 最近一条按 `created_utc` 取最大，同刻按邀约 id 升序打破平局。
- 不下发 `command_id`、`reason`、`expires_utc`、`decided_utc` 或任何自由文本；计数与投影都在只读路径上完成，不改变文档。

## 验证

```sh
cd /Volumes/Disk-1tb/yipiantian && \
perl -e 'alarm shift; exec @ARGV' 420 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/resident_invitation_authority_test.gd"
```

原始末行：

```text
RESIDENT_INVITATION_AUTHORITY_TEST checks=156 failures=0
```

回归原始末行：

```text
NPC_INVITATION_TEST checks=159 failures=0
RESIDENT_AUTHORITY_SOCIAL_TEST checks=138 failures=0
RESIDENT_VIEW_AUTHORITY_TEST checks=157 failures=0
RESIDENT_VIEW_NETWORK_TEST checks=258 failures=0
RESIDENT_LONG_RUN_TEST checks=13494 failures=0
```

覆盖矩阵：

| 用例 | 检查 |
|---|---|
| 默认关闭 | 视图返回 `disabled`；结算返回 `disabled`；不创建 `residents.json`；内存邀约表为空 |
| 创建 | 真实结算产生 1 条 pending；行是严格八键；from/to/kind/TTL/created 正确；id 是规则派生 id；command id 非空；表通过严格校验 |
| 创建不改关系/资产 | 创建前后发起人关系快照逐字节相同；pending 不写记忆；现金、货物、成交、发行量不变；账本仍平衡 |
| 视图新增字段 | 发起人与被邀请方 `pending_invitations=1`，旁观者为 0；`last_invitation` 恰好四键且内容正确；视图不含 `command_id` |
| 接受 | affinity 极高时确定性接受；`decided_utc` 为裁决时刻；`reason=accepted`；收件人获得“接受了”记忆，发起人无同一记忆行；资产零变化 |
| 拒绝 | affinity 极低时确定性拒绝；`reason=declined`；发起人获得“拒绝”记忆，收件人无同一记忆行；资产零变化 |
| 过期 | 到达 TTL 后转 `expired`，`decided_utc=expires_utc`；双方都没有该邀约的决策记忆；资产零变化 |
| 重放 | 同一时刻再结算不产生第二条邀约，也不裁决刚创建的 pending，所有文档与资产逐字节不变；下一次结算只裁决一次；再次同刻结算 `changed=false`；command id 唯一 |
| 重启 | pending、关系、冷却、记忆按字节恢复；重启后同刻重放不创建第二条；重启后裁决写一条当事人记忆；再次同刻结算无变化 |
| 容量 | 64 条合法并可加载；65 条以 `load_resident_state_corrupt` 拒绝启动；重复 command id 以同一具名原因拒绝；表已满时结算不创建第 65 条 |
| 旧文档 | 四键文档可加载，缺失的邀约键按空表；打开时不改写文件 |
| 世界隔离 | 异世界信封返回 `load_resident_state_world_mismatch`，原文件不被覆盖 |
| 损坏 | 非严格邀约行返回 `load_resident_state_corrupt`，不覆盖原文件 |

## 未覆盖

- **UI**：没有邀约列表、角标、接受/拒绝按钮或通知；本切片只到权威视图字段。
- **玩家发起**：邀约仍只由居民规则发起；没有玩家命令、访客入口或权限门。
- **撤回**：规则模块与记忆适配层支持 `withdrawn`，但权威没有产生撤回命令的入口，因此本切片没有真实撤回链路。
- **模型决策**：没有提示词、自然语言、模型摘要或模型参与接受/拒绝；规则只有固定枚举与数值阈值。
- **真实拜访**：接受不生成场景、镜头、餐食、摊位或交易，也不扣款、不移动货物；`meal` / `trade_talk` 只存在于规则模块，权威固定映射为 `visit`。
- **关系联动**：接受或拒绝不改 affinity、赠礼次数或冷却；只有社交动作继续写关系。
- **Windows**：只在 macOS 无头模式验证，未覆盖 Windows 路径、文件系统或实机。
- **写失败注入**：实现沿用 pending+回读+rename 与“保存失败不更新内存”的顺序，但本切片没有注入磁盘写失败演练该分支。
- **多权威并发**：未验证两个权威同时写同一目录的邀约竞争。

## 关联

- [M10 PLAN](PLAN.md)
- [NPC 邀约规则](RECORD-09-invitations.md)
- [社交动作与邀约结果写入记忆](RECORD-10-social-memory.md)
- [居民社交接入世界权威](RECORD-12-resident-authority-social.md)
- [居民只读视图](RECORD-13-resident-view.md)
- [居民采购接入世界权威](RECORD-06-resident-sweep.md)
