# M10-04 · 居民确定性对话接入世界权威与网络

执行日期：2026-11-16。状态：切片完成，不表示 M10-04 或 M10 验收完成。前置：[M10 PLAN](PLAN.md)、[居民确定性对话规则](RECORD-16-resident-dialogue.md)、[居民社交接入权威](RECORD-12-resident-authority-social.md)、[居民邀约持久化](RECORD-15-resident-invitations.md)、[居民只读视图](RECORD-13-resident-view.md)。

## 问题

RECORD-16 已经把“玩家说一类固定的话，居民如何确定性回应”冻结成无副作用规则，但规则层没有状态：`last_dialogue_utc`、`daily_affinity` 由调用方投影，成功后由谁写入没有落地。若把这三项交给客户端或每次现算，冷却、日上限和“同一句话只结算一次”都无法在重启后成立；若把可见事实交给客户端传，玩家就能用伪造行情让居民复述不存在的价格。

本切片把对话接入权威与网络：对话状态作为 `residents.json` 的有界新键持久化，世界在**同一次原子保存**里写关系增量、一条 `dialogue` 记忆与对话状态；可见事实由权威从真实农场与公开市场投影；RPC 29/30 用新增通道位区分写入与读取，写入要求成员角色与非只读。

## 边界

- 修改 `Game/world/residents_store.gd`：信封新增有界 `dialogues`，三字段行，旧四键/五键文档兼容，容量与上限校验。
- 修改 `Game/world/headless_world.gd`：`resident_dialogues` 状态、加载/保存、`execute_dialogue()`、`dialogues_view()`、关系与状态候选写入、内存重放窗口、会话内最近结果；`_social_context_for()` 只把名册居民当作自发社交对象。
- 修改 `Game/world/world_host.gd`：RPC 29 `dialogue_request` / 30 `_dialogue_reply`、48 KiB 预算、共用命令令牌桶、新增 `_reject` 通道位、`dialogue_for_member()` 权限门与中文原因。
- 修改 `Game/world/world_member.gd`、`Game/world/world_client.gd`：`dialogue_result` 信号、`request_dialogue()`、线上预算解码与转发。
- 新增 `tests/resident_dialogue_authority_test.gd`、`tests/resident_dialogue_network_test.gd`；更新 `tests/resident_authority_social_test.gd`（信封从五键断言改为六键）。
- 未修改 `Game/npc/npc_dialogue.gd`（规则与数值不变）、`Game/farm/**`、`Game/ui/**`、`Game/scenes/**`、`Game/world/world_hosting.gd`、`.github/`、`rules/`、任何 `PLAN.md`。
- 不接模型、不读系统时钟、不使用 RNG；时间只取 `authority_now_utc()`，结果只由真实关系文档、派生人格与投影事实决定。

## 持久化格式

`residents.json` 信封从五键扩展为六键，`version` 仍为 1：

```text
{
  "version": 1,
  "world_id": "<world id>",
  "social": {...},        # 既有 NpcSocial 文档（玩家对话增量写在这里）
  "memories": {...},      # 既有 NpcMemory 文档（对话记忆写在这里）
  "invitations": {...},   # 既有邀约表
  "dialogues": {
    "<player_id>": {
      "<npc_id>": {
        "last_dialogue_utc": 1800072010.0,  # 最近一次被接受对话的权威时刻
        "daily_affinity": 1,                # 该 UTC 日已从对话获得的关系增量
        "day_utc": 20834                    # 上面计数所属的 UTC 日序号
      }
    }
  }
}
```

- 行内**恰好三个字段**；`last_dialogue_utc` 与 `day_utc` 必须自洽（`day_utc == floor(last_dialogue_utc / 86400)`，`last_dialogue_utc == 0` 时豁免），否则整份文档按损坏拒绝。时刻与计数范围复用 `NpcMemory.MAX_SAFE_INTEGER` 与 `NpcDialogue.MAX_DAILY_AFFINITY`。
- 外键必须是合法 owner id（`OwnerIds.valid`，排除 `@world` 等保留名），内键必须是名册居民 id。因此每名玩家最多 `NpcRoster.IDS.size()` 行，不能为任意 id 留状态。
- `MAX_DIALOGUE_PLAYERS = 64`。超过即 `load_resident_state_corrupt` 拒绝启动；写入时表已满则拒绝本次对话（`invalid_state`），不淘汰其他玩家。
- `MAX_BYTES` **保持 262144 不变**。理由：对话行只有三个标量，最多 64 × 3 行，不随对话次数增长；现有三行关系、三名居民各 64 条记忆与 64 条邀约仍远低于该上限。扩大容量没有现实边界支撑。
- 旧文档兼容：四键（无 `invitations`）与五键（无 `dialogues`）都按空表加载，版本仍为 1；保存总是写六键。打开旧文档**不改写**文件。

### 为什么重放窗口不进信封

同一 command id 的首次回复只保存在内存（`MAX_DIALOGUE_RESULTS = 64`，按 `at_utc` 再按 command id 淘汰最旧）。跨重启的重试不需要持久日志：

1. 首次成功后 `last_dialogue_utc` 已落盘，仍在 600 秒冷却内的任何重试都会得到 `cooldown`，零副作用；
2. 记忆 id 由 `command_id + npc_id + player_id` 经两轮 FNV-1a 派生（`dlg_<16 hex>`），若确有跨重启且已过冷却的同 id 请求，重复记忆会被 `_resident_memory_has()` 判为 `duplicate`，同样不二次增长关系。

把 64 条命令日志写进严格信封的收益是“跨重启同 id 返回原回复正文”，但规则回复完全确定，且当前没有 UI 依赖旧回复原文；因此不加这个键，避免信封再次扩张。

## 权威执行

`execute_dialogue(actor, npc_id, category, command_id, is_member)` 的拒绝顺序：`not_open` → `disabled` → `invalid_player` → `invalid_npc` → `invalid_category` → `invalid_command` → 重放 → 人格档案 → 规则层原因（`cooldown` / `low_affinity` / `not_inclined` / `invalid_*`）。

成功路径：

1. 关系取真实社交文档投影（`PEER_KEYS` 形状），时间取 `authority_now_utc()`，日累计按 UTC 日惰性归零（与偷菜日切同为 `floor(t / 86400)`）。
2. `visible` 由权威投影：`market_price` 取最近一笔真实公开成交的成交价（超过 `MAX_VISIBLE_PRICE` 不传），`work_recorded` 取是否有任何地块种着作物。客户端传入的 `visible`、时间、关系或日累计一律不参与计算。
3. 规则层通过后，在**社交、记忆、对话三份候选副本**上分别写入：关系 `affinity += delta` 并推进 `last_utc`；追加一条 `kind = dialogue` 的记忆（复用 `NpcMemory` 的有界淘汰）；写入对话行三字段。
4. 三个候选都通过各自的严格校验后才 `save_state()` 一次。保存失败时三份活文档都不替换，返回 `save_resident_state_<kind>`，记忆与关系保持原样。
5. 成功后记录首次回复并返回固定形状结果；关系容量满返回 `dialogue_capacity`。

`is_member` 参数只为与 `execute_resolution` 保持同一入口形状：写入权限、只读状态与角色门由 `WorldHost` 在调用前判定，只读投影走 `dialogues_view()`。

`_social_context_for()` 新增名册过滤：玩家与居民的关系行与居民之间的关系行共用 `social` 文档，若不限制，居民会把玩家当作自发拜访/赠礼对象。过滤后居民的自发社交仍只在名册内部进行，玩家对话只改变“居民对这名玩家的态度”。

## 网络

| RPC | 方向 | 名称 | 说明 |
|---|---|---|---|
| 29 | 客户端 → 权威 | `dialogue_request(payload)` | JSON `{request_id, action, args}`；`action` 为 `state` 或 `say` |
| 30 | 权威 → 客户端 | `_dialogue_reply(request_id, payload)` | 预算编码后的结果文档，含 `state` |

- 请求与答复共用 `DIALOGUE_MAX_PAYLOAD = WorldPayload.WIRE_BUDGET_BYTES`（48 KiB）；超预算与答复编码超限都走 `_reject(..., on_dialogue_channel = true)`，不再静默丢弃。
- 与命令共用同一个令牌桶（`RATE_KIND_COMMAND`，突发 20、每秒回填 1）；限流拒绝也走对话通道。
- 未加入的连接不进入处理链；`state` 对已加入的成员、访客都能读，但只返回本人状态；`say` 要求 `MEMBER` 角色、非只读、具名玩家。客户端身份只取连接声明的玩家 id，载荷里的 `viewer`/`actor` 被忽略。
- 客户端 `request_dialogue()` 在未加入或成员节点缺失时返回 false，不假装已发出；`dialogue_result` 信号与既有 `residents_result`/`resolutions_result` 同构。

## 隐私分级

| 读者 | `state` 读取 | `say` 写入 | 可见内容 |
|---|---|---|---|
| 具名成员 | 允许 | 允许 | 仅本人对三名居民的关系、对话时刻、日累计、冷却与本次会话最近 8 条本人回复 |
| 具名访客 | 允许 | `forbidden` | 同上，但本人从未对话过，通常全零 |
| 匿名连接 | 返回 `available=false` 的空视图 | `no_player` | 无玩家行 |
| 未加入连接 | RPC 直接忽略 | RPC 直接忽略 | 无 |

- 每名玩家只能看到自己的对话行；另一名玩家的 id、对话时刻、日累计与冷却永不序列化到答复里。
- `recent` 只含 `{command_id, npc_id, category, reply_kind, tone, affinity_delta, at_utc}`，不含 `visible` 事实、记忆摘要或关系原文。
- 视图不含 `cash`、`accounts`、`bag`、`goods` 或任何资产/权属字段。

## 验证

权威：

```sh
cd /Volumes/Disk-1tb/yipiantian && \
perl -e 'alarm shift; exec @ARGV' 300 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/resident_dialogue_authority_test.gd"
```

原始末行：

```text
RESIDENT_DIALOGUE_AUTHORITY_TEST checks=170 failures=0
```

网络（真实 `world_server.gd --residents` + loopback WSS）：

```sh
cd /Volumes/Disk-1tb/yipiantian && \
perl -e 'alarm shift; exec @ARGV' 420 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/resident_dialogue_network_test.gd"
```

原始末行：

```text
RESIDENT_DIALOGUE_NETWORK_TEST checks=69 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/resident-dialogue-network-319076
```

回归原始末行：

```text
NPC_DIALOGUE_TEST checks=169 failures=0
RESIDENT_AUTHORITY_SOCIAL_TEST checks=139 failures=0
RESIDENT_INVITATION_AUTHORITY_TEST checks=156 failures=0
RESIDENT_VIEW_AUTHORITY_TEST checks=157 failures=0
RESIDENT_VIEW_NETWORK_TEST checks=258 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/resident-view-network-314956
RESIDENT_LONG_RUN_TEST checks=13494 failures=0
```

覆盖矩阵（权威）：

| 用例 | 检查 |
|---|---|
| 默认关闭 | 返回 `disabled`；不创建 `residents.json`；内存对话表为空；视图不可用 |
| 成功 | 固定 +1；关系增长与报告增量一致；对话行恰好三字段且时刻/日序号正确；恰好一条 `dialogue` 记忆；文件通过严格校验；第二名玩家独立计数 |
| 冷却与重放 | 冷却内拒绝且关系、记忆、对话状态与文件逐字节不变；同 command id 重放返回首次回复且不二次写；换参数返回 `command_conflict` |
| 日上限与日切 | 达到 `MAX_DAILY_AFFINITY` 后道歉增量为 0 并报告 `capped_reason = daily`；跨 UTC 日后重新从 0 计数 |
| 可见事实 | 真实成交后问行情返回 `reply_market_recorded` 且 `fact_refs.market_price` 等于真实成交价；同一请求夹带伪造 `visible` 时结果不变且 `fact_refs` 不含伪造字段；视图 `recent` 不回显 `visible` |
| 重启 | 关系、记忆、对话状态按字节恢复；冷却继续生效；同 id 重试不增长关系 |
| 容量/旧文档/损坏 | 五键旧文档可加载且按空表；升级后保存写 `dialogues`；超 64 名玩家、非名册内键、行字段不符、时刻与日序号不自洽、损坏与异世界均拒绝启动且不覆盖文件 |
| 保存失败 | 目录被占导致保存失败时返回 `save_resident_state_*`，关系、记忆、对话状态都不变，文件不存在；修复后同一 command id 可重试成功 |
| 拒绝 | 未知类别 `invalid_category`、非名册居民 `invalid_npc`、非法/保留玩家 `invalid_player`、非法命令 id `invalid_command`；低关系邀约 `low_affinity` 且不建对话行 |
| 视图隐私 | 成员只看到本人行；另一名玩家全零、`recent` 为空、答复里不出现其 id；未加入 `not_a_member`；匿名无行 |

覆盖矩阵（网络）：

| 用例 | 检查 |
|---|---|
| 成员 | 读状态、问候成功（固定 +1、固定模板、记忆摘要、状态回落）；冷却内第二次被拒；同 id 重放标记 duplicate；无连接丢失 |
| 访客 | 访客角色；可读；写入 `forbidden` 且带中文文案 |
| 匿名 | 写入 `no_player`；读取无对话状态 |
| 隐私 | 第二名成员看不到第一名的关系与对话时刻；状态 JSON 不含第一名 id |
| 预算/限流 | 50 KB 请求得到 `payload_too_large` 与中文文案；连发触发 `rate_limited`；两者之后连接都继续可用 |
| 重启 | 关系、对话时刻、日累计保留；冷却继续拒绝；`residents.json` 在重启加载时不改写 |

## 未覆盖

- **UI**：没有对话面板、输入框、`reply_kind` 到中文正文的映射或冷却倒计时显示；本切片只到权威结果与视图字段。
- **模型**：没有提示词、自然语言生成、意图分类或模型摘要；类别与模板仍是固定枚举。
- **跨重启重放原文**：重放窗口只在内存；重启后同 id 的旧请求不会返回首次回复正文，而是按冷却/重复记忆处理。
- **关系负向变化**：本章类别增量非负；关系只增不减。
- **`invite` 真实拜访**：仍只产生口头“会考虑”，不创建 `NpcInvitation`、不移动场景。
- **多权威并发**：未验证两个权威同时写同一目录的对话状态竞争。
- **Windows**：只在 macOS 无头模式验证，未覆盖 Windows 路径或实机。
- **迁移回滚**：六键文档在旧版本（只接受五键）会按损坏拒绝启动；当前阶段不承诺旧版本向后读取新文档。
- **世界包 sidecar**：`Game/farm/world_package.gd` 的 `residents.json` 结构校验仍只接受四键/五键信封，尚未放行 `dialogues`。带对话状态的居民文档若经世界导出/导入会被判为 `invalid_sidecar`。该文件不在本切片授权范围内（同一时间由另一任务修改），需要后续在该层补上第六键并同步包测试。

## 关联

- [M10 PLAN](PLAN.md)
- [居民确定性对话规则](RECORD-16-resident-dialogue.md)
- [居民社交接入世界权威](RECORD-12-resident-authority-social.md)
- [居民邀约持久化与权威裁决](RECORD-15-resident-invitations.md)
- [居民只读视图](RECORD-13-resident-view.md)
- [有界记忆](RECORD-01-memory.md)
