# M11-02 · 组织解散接入世界权威

状态：切片实现（2026-11-16），未验收。范围：把已有纯规则 `OrganizationState.dissolve()` 接到 `HeadlessWorld.execute_organization()`，由负责人真正解散组织、按缴入比例把基金余额退还到每名缴入者的真实账户、关闭组织并移除基金行。不接界面按钮、模型或摘要推送。

前置记录：[M11-04 · 组织规则](RECORD-04-organizations.md)、[M11-08 · 组织权威接入](RECORD-08-organization-authority.md)、[M11-17 · 组织解散与资产清算](RECORD-17-organization-dissolve.md)、[M11-09 · 组织治理界面](RECORD-09-governance-panel.md)、[ADR-024 · 公共基金](../../decisions/ADR-024-public-funds.md)。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/world/headless_world.gd` | `execute_organization()` 新增 `dissolve` 动作与 `_dissolve_organization()`；按基金行与真实现金组装清算选项，把退款写进农场候选，再依次保存组织与基金文档；`organizations_view()` 增加 `status` 与 `closed_utc`。 |
| `Game/world/world_host.gd` | 组织动作白名单放行 `dissolve`；答复转发 `clearing`；补 `org_closed`/`already_closed`/`pending_spend`/`unowned_balance`/`balance_mismatch`/`history_full`/`time_regression` 文案。 |
| `Game/world/world_projection.gd` | 摘要 organizations 块的 `ORGANIZATION_ROW_KEYS` 增加 `status` 与 `closed_utc`，首屏即可区分已解散组织。 |
| `Game/farm/ledger_state.gd` | `RESERVED_EVENT_PREFIXES` 增加 `org_refund_`，玩家命令不能冒用退款分录 id。 |
| `Game/ui/governance_panel.gd` | 新增“解散组织”按钮与二次确认；已解散行标出“已解散”并禁用全部写按钮；`present_result()` 用权威 `clearing` 显示退款总额。 |
| `Game/scenes/main.gd` | 组织动作复用面板给出的 `command_id`（缺失时才新生成），答复改走 `present_result()`，把 `clearing` 交给面板。 |
| `tests/organization_authority_test.gd` | 新增解散、两个半提交恢复窗口与拒绝路径三组，149 项检查。 |
| `tests/fund_network_test.gd` | 新增重启后的真实 WSS 解散阶段。 |
| `tests/governance_panel_test.gd` | 新增解散按钮、确认/取消、关闭态与退款总额显示断言。 |
| `docs/2.0/milestones/M11/RECORD-20-organization-dissolve-authority.md` | 本记录。 |

未修改组织规则、基金规则、面板、字体或存档格式。

## 清算事实的来源

规则要求 `options` 恰好四键，权威按当前可核验事实填充：

| 键 | 来源 | 说明 |
|---|---|---|
| `command_id` | 连接层传入的命令 id | 重放键，写入组织文档的 `command_results`。 |
| `balance` | `farm.economy_cash(org_<org_id>)` | 组织公共账户的真实现金；没有基金行时余额必须为 0，否则规则以 `unowned_balance` 拒绝。 |
| `pending_spend` | 恒为 `0` | 当前缴入与支出都是同步提交：农场落盘、基金文档落盘或返回失败，没有异步队列。真正“在途”的只有半提交，由下一节的余额一致性检查拦住。 |
| `contributors` | 基金行的 `contributors` | 规则按累计缴入比例分配；没有基金行时为空表。 |

退款事件 id 为 `org_refund_<sha256(org_id|command_id|player_id)>`，与工资结算同构：只依赖命令身份，不依赖执行次数。

## 提交顺序与恢复

1. 规则在 `organizations` 副本上算出关闭后的候选与 `clearing {account_id, balance, refunds}`；
2. 在农场候选上逐笔 `economy_authority_pay(org_account → 缴入者)`，已有分录的退款直接跳过；
3. 有实际付款才保存农场、`farm.accept()` 并广播摘要；
4. 保存组织文档并替换活文档；
5. 从基金文档移除该组织的基金行并保存。

余额与真实现金不一致时只有一种解释被接受：上一次解散已经付完退款，但组织或基金文档没写完。此时按基金行余额重算同一份清算意图，并且要求每笔退款都已存在于账本；缺任何一笔都返回 `balance_mismatch`，绝不按旧账再付一次。

两个失败窗口：

- **组织文档写失败**（农场已退款、组织仍活跃）：重试时退款分录全部命中，只重新执行规则并补写组织与基金文档。
- **基金文档写失败**（组织已关闭、基金行仍在）：重试先查组织文档里同命令的解散记录，确认退款与关闭已落盘，再只移除基金行并返回 `duplicate=true`。

基金行在解散后从 `funds.json` 删除，因为基金规则要求 `balance + spent == 缴入合计`，而退款后账户现金为 0。已发生的缴入、支出与退款仍由经济账本分录完整保留，组织文档的 `command_results` 也保留本次 `clearing` 退款表。

## 视图与网络

- `organizations_view()` 的组织行新增 `status`（`active`/`closed`）与 `closed_utc`；成员与职位历史照常下发，客户端可以据此显示“已解散”。摘要 organizations 块使用同一份行白名单，因此打开面板时的首屏视图也带这两项。
- `WorldHost.organization_for_member()` 放行 `dissolve`，访客、匿名、只读与非法载荷的拒绝顺序不变。
- 组织答复在 `clearing` 存在时原样转发，网络调用方与直接调用得到同一份退款表。答复仍是 48 KiB 预算内的普通 JSON 文档。

## 界面

治理面板在管理行新增“解散组织”按钮，只有当前选中组织为活跃且本人是负责人时可点。点击只打开 `ConfirmationDialog`，确认后才发出恰好 `{org_id, command_id}` 两个键的意图；取消、Esc 或关闭面板都丢弃待发参数，不会生成第二个命令 id（`main.gd` 优先复用面板给出的 id）。

已解散的组织行显示“· 已解散”，成员与职位照常展示，加入、退出、任命、交接与解散全部禁用；缺少 `status` 键的旧行按活跃处理，不会因字段缺失而变成不可操作。

解散成功的答复如果带 `clearing`，状态区显示“已解散，退还 N 枚。”，N 只是把权威退款行相加（空表回退 `balance`）；面板不推导退款对象，也不本地判定负责人。没有 `clearing` 时显示中性成功文案，拒绝时保留权威自己的原因文本。

## 测试

```sh
perl -e 'alarm shift; exec @ARGV' 180 \
  /Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot \
  --headless --path Game --script "$PWD/tests/organization_authority_test.gd"
```

结果：

```text
ORGANIZATION_AUTHORITY_TEST checks=149 failures=0
```

覆盖：

- 负责人缴入 30/90、支出 40 后解散，退款表为 20/60，两笔真实进入缴入者账户，组织账户归零；
- 非负责人解散被拒且不动现金；访客与只读权威被拒；余额漂移返回 `balance_mismatch` 且不动现金；
- 解散后组织视图为 `closed`、`closed_utc` 来自权威时钟，新成员加入返回 `org_closed`；
- 同命令重放返回 `duplicate` 且不二次退款，换命令返回 `already_closed`；
- 重启后组织仍为 `closed`、基金行仍不存在、退款金额仍在；
- 组织文档写失败后重试完成关闭且只退一次；基金文档写失败后重试只移除基金行；
- 没有基金的组织直接关闭，退款表为空；
- 面板只对负责人启用解散按钮，点击先弹确认、取消不发意图、确认后参数只有 `org_id` 与 `command_id`；
- 已解散行显示“已解散”，全部写按钮禁用，但成员与职位仍可见；
- `clearing` 的退款行合计显示在状态区，无 `clearing` 的成功与拒绝各有对应文案。

真实网络路径（`tests/fund_network_test.gd` 的解散阶段）：权威在重启后由负责人经 RPC 11/12 解散，答复携带 `clearing` 与 `closed` 状态，退款进入缴入者真实账户、组织账户归零、基金行从 sidecar 消失，同 id 重放返回 `duplicate` 且不再退款，换 id 返回 `already_closed`，全程 `total_cash` 不变。重启时权威时钟前移一小时，避免测试里“新命令早于已记录的历史行”触发 `time_regression`。

相关回归（最后一行）：

```text
FUND_NETWORK_TEST checks=110 failures=0
GOVERNANCE_PANEL_TEST checks=56 failures=0
M4_CLIENT_SCENE_TEST checks=42 failures=0
ORGANIZATION_DISSOLVE_TEST checks=146 failures=0
ORGANIZATION_STATE_TEST checks=139 failures=0
PUBLIC_FUND_TEST checks=225 failures=0
PUBLIC_FUND_AUTHORITY_TEST checks=211 failures=0
LEDGER_TEST checks=1841 failures=0
WORLD_PROJECTION_TEST checks=259 failures=0
HEADLESS_WORLD_RUNTIME_TEST checks=83 failures=0
HEADLESS_WORLD_TEST checks=14 failures=0
GOVERNANCE_PANEL_TEST checks=41 failures=0
FONT_COVERAGE_TEST checks=1272 failures=0 missing=0
```

## 未覆盖与限制

- 未跑真实共享世界里的“面板确认 → 权威解散 → 清算回显”端到端链路；面板测试是视图层直接调用，视觉未人工检查。
- 若进程在农场退款与组织/基金写盘之间退出，重新打开世界会因 `_funds_match_farm` 不一致返回 `load_funds_mismatch`。这是既有基金半提交风险（缴入与支出同样存在），本切片没有改变启动校验策略。（已由文末“重启后的退款半提交恢复”增补修复。）
- 基金历史在解散后随基金行消失，审计依赖经济账本分录与组织文档里的 `clearing`。
- 未验证 Windows 与多组织并发解散。

## 增补：重启后的退款半提交恢复（2026-11-16）

对抗审查确认原切片有两处恢复缺口：进程在“农场退款已落盘、组织或基金文档未写”
之间退出后，重启会因 `_funds_match_farm` 返回 `load_funds_mismatch` 而拒绝服务；
即使不重启，面板重试会生成新的命令 id，旧恢复分支只认原命令 id 派生的退款分录，
于是返回 `balance_mismatch` 并把整个基金子系统卡死。两处都已修复：

- 启动校验只额外接受一种不匹配：基金行余额大于账户现金、现金已为 0，且按同一
  结算规则算出的每笔退款都能在账本里找到 `org_refund_` 付款分录（从该组织账户
  付出、收款人与金额一致）。其它偏差（基金支出一半、现金还在别处）仍拒绝启动。
- 恢复扫描改用上述“同组织账户、同收款人、同金额”的分录证据，不再要求命令 id
  一致，因此面板新生成的命令 id 也能补完；正常付款路径仍写原派生 id 的分录。
- 组织已关闭而基金行仍在、进程尚未重启时，负责人仍可用任意新命令 id 只补完
  基金行移除；授权按关闭前的历史职位判定。已关闭且无基金行时仍返回
  `already_closed`。
- 启动时 `_finish_closed_dissolves()` 直接补完这类残留：组织已关闭、组织文档
  有清算记录、基金行仍在、组织账户现金为 0 时移除该行，不转账、不需要负责人
  在线、不依赖有界账本。补完在 `_funds_match_farm` **之前**执行，因此退款分录
  即使已被 512 条环形记录淘汰，也不会先以 `load_funds_mismatch` 拒绝启动；写盘
  失败拒绝启动并留下重试路径。因此客户端重启后无需再发解散命令，基金视图在
  加载完成时即已一致。
- 只读世界（退役快照）只把补完结果放进内存，不写 `funds.json`；`open()` 新增
  可选 `read_only` 参数，`WorldHost.configure()` 透传宿主已有的只读标记，保持
  “打开退役世界不改一个字节”的启动契约。
- 容忍半提交的判断下沉到 `_fund_balance_invariant`，只对“现金为 0 且每笔退款
  都有账本分录”的**该行**放行；其它组织的基金开立、缴入、支出不再被一支待恢复
  行整体阻塞（此前严格检查会把所有基金操作一起挡住）。
- 已关闭组织拒绝新基金开立与缴入（`org_closed`），避免残留行或已关闭组织的
  零余额基金被继续注入资金；历史行仍可读取。
- 删除基金行前要求组织账户现金为 0，避免把仍有现金的账户变成看不见的资金。
- 命令 id 的重复成功路径（重启后内存重放窗口为空）也校验历史负责人；补完成功
  后同样写入内存命令记录，同 id 再次调用返回 `duplicate` 成功。

测试 `ORGANIZATION_AUTHORITY_TEST` 从 149 增至 200 项，新增：组织写失败后重启
打开世界、用新 id 完成解散且只退一次，补完命令同 id 重放为 `duplicate`；待恢复
行存在时仍可创建另一组织并开立其基金；基金写失败后重启，加载即移除残留基金行、
后续解散返回 `already_closed` 且不二次退款；同一进程内对已关闭组织缴入返回
`org_closed`；零余额基金行写失败后重启同样被移除；只读世界在内存里补完且
`funds.json` 字节不变；把退款分录全部折进余额基线（等价于被环形账本淘汰）后，
已关闭组织仍能启动并移除残留行。回归：
`ORGANIZATION_DISSOLVE_TEST 146/0`、`PUBLIC_FUND_TEST 225/0`、
`PUBLIC_FUND_AUTHORITY_TEST 211/0`、`FUND_NETWORK_TEST 110/0`、
`FONT_COVERAGE_TEST 1272/0`。

仍未覆盖：账本是有限环形记录（512 条），在“农场已退款、组织文档写失败、组织
仍活跃”的窗口内，若退款分录被淘汰，证据消失，世界会回到拒绝补完的状态（不会
二次付款）；该窗口要 512 条新分录，当前未构造真实复现，也未新增独立的持久退款
标记。组织文档已关闭的窗口不受此限，补完先于总校验且不读分录。

## 增补：持久解散意图（2026-11-16）

上一节的退款证据仍依赖 512 条环形账本，上述未覆盖窗口会让组织解散在世界重启
时返回 `load_funds_mismatch`。现改为“先写意图、再动钱”：

- 组织文档新增可选顶层 `pending_dissolves`（每个组织至多一条，最多 64 条），
  在退款之前保存 `{command_id, actor, at_utc, balance, contributors}`。严格校验
  要求意图只出现在活动组织上、命令编号未被占用、时刻不早于既有历史、余额为正
  且能按缴入比例算出非空退款表。
- 退款是一次原子农场保存，因此组织账户现金只有“等于意图余额（未退）”与
  “为 0（已退）”两种状态。加载时 `_finish_pending_dissolves()` 先于基金总校验
  运行：未退则按意图退款，已退则直接关闭组织并移除基金行；两种情况都不查账本
  分录。关闭组织、清除意图与写入同命令清算记录在同一次组织保存里完成，随后
  才移除基金行。
- 只读世界只在内存里补完意图，不写组织、农场或基金文档。农场文档缺失却存在
  意图时拒绝启动（`recover_dissolves_missing_farm`），避免把新农场的 0 现金
  误读成“已退款”。
- 进程内尚未重启时，负责人用任意新命令 id 重试解散会先补完意图并返回清算表；
  其它组织命令会先补完意图再按关闭状态拒绝，基金开立/缴入/支出返回
  `pending_dissolve`，防止意图里的余额与缴入表过期。
- 基金余额不变式恢复为严格相等：退款半提交只由意图在加载时先补完，不再为
  “现金为 0、分录齐全”放行，删除了 `_ledger_refund_evidence` 与
  `_fund_row_refunded`。组织文档已关闭的残留基金行仍由
  `_finish_closed_dissolves()` 移除。

测试：`ORGANIZATION_AUTHORITY_TEST 230/0`（新增意图写失败不退款、关闭写失败后
同进程新 id 补完、意图期间基金操作被拒、退役只读补完不写盘且组织/基金字节
不变、退款分录淘汰后重启仍只退一次）；`ORGANIZATION_DISSOLVE_TEST 171/0`
（意图标记/完成/重放、JSON 往返、重复意图、命令冲突与各类篡改拒绝）。回归
`CHAIN_INTEGRATION_TEST 509/0`、`PUBLIC_FUND_AUTHORITY_TEST 242/0`、
`FUND_NETWORK_TEST 110/0`、`WORLD_TRANSFER_SIDECARS_TEST 153/0`、
`WORLD_PACKAGE_TEST 126/0`、`WORLD_TRANSFER_TEST 113/0`、
`HEADLESS_WORLD_RUNTIME_TEST 83/0`、`FONT_COVERAGE_TEST 1272/0 missing=0`。
