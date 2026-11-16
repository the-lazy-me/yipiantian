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
| `tests/organization_authority_test.gd` | 新增解散、两个半提交恢复窗口与拒绝路径三组，149 项检查。 |
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
- 没有基金的组织直接关闭，退款表为空。

相关回归（最后一行）：

```text
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

- 治理面板没有“解散组织”入口；网络答复已带 `clearing`，但界面暂不显示退款明细。摘要块与权威视图都已携带 `status`/`closed_utc`，面板尚未据此渲染。
- 若进程在农场退款与组织/基金写盘之间退出，重新打开世界会因 `_funds_match_farm` 不一致返回 `load_funds_mismatch`。这是既有基金半提交风险（缴入与支出同样存在），本切片没有改变启动校验策略。
- 基金历史在解散后随基金行消失，审计依赖经济账本分录与组织文档里的 `clearing`。
- 未验证 Windows、真实网络 UI 点按与多组织并发解散。
