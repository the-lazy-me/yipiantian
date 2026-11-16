# M11-02 · 组织解散与资产清算纯规则

执行日期：2026-11-16。状态：切片完成，不表示 M11-02 或 M11 验收完成。前置：[M11 PLAN](PLAN.md)、[RECORD-04 · 组织规则](RECORD-04-organizations.md)、[RECORD-08 · 组织权威接入](RECORD-08-organization-authority.md)、[ADR-024 · 公共基金](../../decisions/ADR-024-public-funds.md)。

## 问题

RECORD-04 与 RECORD-08 的“未覆盖”都写明没有组织解散：最后一名成员不能离开、负责人必须先交接，组织只能一直存在。M11 的集成验收却要覆盖“组织解散”，而基金余额由 `Game/world/public_fund.gd` 管理、权威侧 `headless_world.gd` 已有支出路径。若直接把解散塞进权威，会把“什么算未结算支出”“退款给谁”“记录怎么保留”一起固化。

本切片只补纯规则：负责人解散组织后，文档进入 `closed`，成员与历史行全部保留；资产清算只返回**意图**——应把多少余额按什么顺序退给谁——不移动任何钱、不读基金文档、不接触权威。

## 边界

- 修改 `Game/world/organization_state.gd`、`tests/organization_state_test.gd`；新增 `tests/organization_dissolve_test.gd` 与本记录；在 `docs/2.0/milestones/M11/PLAN.md` 的 M11-02 段补一行链接。
- 未修改 `Game/world/headless_world.gd`、`Game/world/world_host.gd`、`Game/world/organization_store.gd`、`Game/world/public_fund.gd`、`Game/farm/**`、`Game/scenes/**`、`Game/ui/**`、`Game/platform/**`、`.github/**`、字体文件。
- 无 RNG、无系统时钟、无磁盘、无场景、无网络；所有入口显式传入 `now_utc`，所有写入口返回候选文档。
- 不调用 `PublicFund`、`Economy` 或 `Ledger`；不创建账户、不记分录、不检查余额。`options` 里的余额与缴入是调用方投影的外部事实。

## 文档形状

组织行新增四个键，顶层新增命令窗口：

```text
organizations = {
  "organizations": {
    "<org_id>": {
      ...,
      "status": "active" | "closed",
      "closed_utc": 0.0,              # active 时恒为 0
      "closed_by": "",                # active 时恒为空
      "history": [
        {"kind": "created", "actor": "<player_id>", "target": "", "at_utc": ...},
        {"kind": "joined" | "left", "actor": "<player_id>", "target": "", "at_utc": ...},
        {"kind": "appointed" | "handover", "actor": "<player_id>",
         "target": "<player_id>", "at_utc": ...},
        {"kind": "dissolved", "actor": "<player_id>", "target": "", "at_utc": ...},
      ],
    }
  },
  "command_results": {
    "<command_id>": {
      "payload": "dissolve:<sha256 小写十六进制>",
      "result": {
        "ok": true, "reason": "", "organization_id": "<org_id>",
        "clearing": {
          "account_id": "org_<org_id>", "balance": 100,
          "refunds": [{"player_id": "<player_id>", "amount": 60}],
        },
      },
    }
  },
}
```

`STATE_KEYS` 变为两键精确集合，组织行与历史行也都是精确键集。旧文档（只有 `organizations`、组织行没有状态/历史）会被 `valid()` 拒绝，这是当前早期阶段允许的格式调整，不新增迁移分支。

## 决定

### 1. 解散只关闭，不删除

`dissolve()` 把 `status` 置为 `closed`，写 `closed_utc` / `closed_by`，并在 `history` 末尾追加 `dissolved` 行。组织行、成员表、职位、`account_id` 和历史前序行全部保留。

理由：组织资产身份与成员关系是审计事实。删除组织行会让“谁曾属于哪个组织、账户最后归谁”永久丢失，也会让已发出的支出记录失去上下文。关闭状态足以表达“不再接受操作”。

### 2. 只有当前负责人可以解散

授权沿用现有职位表：必须是成员（否则 `not_member`），且当前职位为 `leader`（否则 `not_leader`）。干事虽有 `can_spend`，也不能解散。这里不新增权限位，避免“能花钱”被误读成“能关账户”。

### 3. 前置条件：没有在途支出授权

`options.pending_spend > 0` 返回 `pending_spend`。理由：在途支出意味着权威已经承诺付款，若此时关闭账户，付款可能落在已关闭的组织上，形成无法解释的扣款。把“未结算”作为调用方投影的计数，规则层不猜基金实现；权威接线时可以把它映射为公共基金 `history` 中未完成的支出或命令窗口中的待结算记录。

余额为正但没有登记者（`contributors` 为空或合计为 0）返回 `unowned_balance`：没有可确定的收款人，宁可拒绝解散也不把钱留给无人账户。

时间早于最后一条历史行返回 `time_regression`；关闭组织再次解散返回 `already_closed`。

### 4. 清算只返回意图

`dissolve()` 返回 `clearing = {account_id, balance, refunds}`：

- 退款按 `contributors`（成员累计缴入）比例分配，整数除法向下取整；
- 余数按 `player_id` 升序逐个补 1；
- 退款行按 `player_id` 升序排列，零额行省略；
- 退款合计严格等于 `balance`；余额为 0 时退款表为空。

`account_id` 取组织声明的账户，不接受调用方另指账户。余额上限 1,000,000、单人缴入上限 1,000,000、最多 256 名缴入者，乘积保持在 64 位整数安全范围内。规则不读基金余额、不校验账户是否存在，也不写任何金额。

### 5. 关闭后的操作一律具名拒绝

`join`、`leave`、`appoint`、`transfer_leadership`、`authorize_spend` 对 `closed` 组织返回 `org_closed`。`role_of()` 对关闭组织返回空串，因此任何复用它的授权路径都不会把历史职位当成当前权限；展示历史请用新增的只读 `historic_role_of()`。

`valid()` 要求关闭组织仍恰好有一名负责人：成员表是历史快照，负责人数量不变量继续成立。

### 6. 重放按摘要，窗口有界

只有成功的解散写入顶层 `command_results`，最多 64 条（组织上限也是 64，每个组织只解散一次，一一对应）。payload 是规范请求（缴入者按 id 排序）的 `dissolve:<sha256>` 摘要，而不是逐字参数：请求最多含 256 名缴入者，逐字保存会让侧车轻易超过 64 KiB。

同一 command id 同 payload 返回首次结果并标记 `duplicate`，换 payload 返回 `command_conflict`；因此同参数不同字典顺序仍然重放，改余额、改时刻或改缴入都会冲突。`valid()` 反向要求“关闭组织恰好一条成功记录”，活动组织不得带记录，避免读取方把“已关闭但没有清算意图”当成合法。

### 7. 历史行严格校验

- `created` 必须是首行且 `at_utc == created_utc`，不得重复；
- `joined`、`left`、`dissolved` 的 `target` 必须为空；
- `appointed`、`handover` 的 `target` 必须是另一名合法玩家；
- 历史时间不得倒退；
- 关闭组织的最后一行必须是 `dissolved`，且其 actor/at_utc 与 `closed_by`/`closed_utc` 一致；
- 活动组织不得出现 `dissolved` 行、`closed_by` 或非零 `closed_utc`。

因此不存在“`valid()` 通过但读取方误判”的组合：状态、关闭字段、最后一行与命令记录四处互相锁定。`role_of()` 对关闭组织返回空串也是这条纪律的一部分：既有读取方 `HeadlessWorld._org_spend_permission()` 用它判断支出权，若它继续返回历史职位，关闭组织就会被读成“仍可支出”。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/world/organization_state.gd` | 新增 `STATUSES`、历史行、关闭字段、命令窗口、`dissolve()`、`historic_role_of()`、`_valid_*` 与关闭态拒绝 |
| `tests/organization_dissolve_test.gd` | 新增 146 项检查 |
| `tests/organization_state_test.gd` | 手工组织行夹具补状态/历史键，原有 139 项断言不变 |
| `docs/2.0/milestones/M11/PLAN.md` | M11-02 段补一行实现记录链接 |
| `docs/2.0/milestones/M11/RECORD-17-organization-dissolve.md` | 本记录 |

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/organization_state_test.gd"
perl -e 'alarm shift; exec @ARGV' 180 "$GODOT" --headless --path Game \
  --script "$PWD/tests/organization_dissolve_test.gd"
perl -e 'alarm shift; exec @ARGV' 240 "$GODOT" --headless --path Game \
  --script "$PWD/tests/organization_authority_test.gd"
perl -e 'alarm shift; exec @ARGV' 240 "$GODOT" --headless --path Game \
  --script "$PWD/tests/world_package_sidecars_test.gd"
```

原始末行：

```text
ORGANIZATION_STATE_TEST checks=139 failures=0
ORGANIZATION_DISSOLVE_TEST checks=146 failures=0
ORGANIZATION_AUTHORITY_TEST checks=84 failures=0
WORLD_PACKAGE_SIDECARS_TEST checks=79 failures=0 root=/Volumes/Disk-1tb/yipiantian/.local/verification/world-package-sidecars-468770
FONT_COVERAGE_TEST checks=1272 failures=0 missing=0
```

字体：本切片新增的代码与测试文案只使用字体子集内汉字，也不修改字体文件。

覆盖：

| 用例 | 检查 |
|---|---|
| 负责人解散 | 关闭状态、关闭人与时刻、成员与职位保留、账户 id 不变、历史首行仍为创建、末行记录解散、命令记录与答复一致、输入文档不变 |
| 权限拒绝 | 干事/普通成员 `not_leader`、陌生人 `not_member`、未知组织、非法 actor、非法时间、早于创建 `time_regression`、再次解散 `already_closed`、拒绝不改文档 |
| 前置条件 | 在途支出 `pending_spend`；正余额无缴入者或缴入合计为 0 `unowned_balance`；选项非字典/缺键/多键、空或超长命令 id、非法余额/在途数/缴入表、畸形文档、非法组织 id 均具名拒绝 |
| 清算意图 | 三等分余数落到最小 id；缴入顺序不影响结果；零余额无退款；零缴入成员无退款行；最大余额与单人上限下总额严格守恒 |
| 重放 | 同 id 同 payload `duplicate` 且不二次关闭；改余额、改时刻 `command_conflict`；同参数不同字典顺序仍重放；不同文档可复用 id；窗口只存一条 |
| 关闭后 | 加入/退出/指派/交接/支出全部 `org_closed` 且不改文档；可另建新组织而旧行保持关闭 |
| 严格文档 | JSON 往返有效；未知顶层/组织/历史/命令/退款键；未知状态；第二创建行；创建行时间不符；带 target 的加入行；指派行自指；关闭行缺失、actor 或时间不符；关闭字段为空/为零/早于创建；活动组织带关闭字段或解散记录；命令记录指向他组织、失败结果、带 reason、账户不符、余额与退款不符、退款乱序/重复/零额/非法收款人；命令数超限 |
| 确定性 | 同一解散序列生成相同文档；库命令不修改调用方文档；成功与拒绝结果可重复 |

## 未覆盖

- **未接权威/网络/界面**：`HeadlessWorld`、`WorldHost`、RPC、`organizations_view()`、治理面板都不认识 `status`/`history`/`command_results`；没有删除或解散入口，也没有把 `clearing` 回传给客户端。
- **未移动任何钱**：不清算真实账户、不改公共基金余额、不调用 `pay`/`Ledger`、不检查基金或账户是否存在。`balance`、`pending_spend`、`contributors` 全部由调用方投影，规则不验证其真实性。
- **未定义在途支出的数据来源**：本切片只接受计数。接线时需决定它来自公共基金历史、命令窗口还是两者合并，并保证解散与付款不会并发穿过同一账户。
- **未定义退款失败语义**：若真实付款在扫描后、写入前失败，本切片没有回滚或重试模型；权威接线必须把“先清算后关闭”或“先关闭后逐笔付款”的失败路径写清楚，并保证重放不会重复付款。
- **未处理基金与组织状态不一致**：组织关闭后基金 sidecar 仍可能存在；没有冻结基金、没有残留余额报警、没有 `funds` 与 `organizations` 的交叉一致性校验。
- **未接入摘要与存储校验**：`organizations.json` 的 64 KiB 预算与 `Organization.valid()` 共用，因此新形状会被同一处验收；但世界包、迁移、备份的交叉检查与 UI 渲染未验证。
- **未覆盖负责人离线接管**：解散仍要求负责人在线并显式发起；没有自动接管、强制解散或官府裁决。
- **未覆盖多组织成员成本**：历史行有界 256，频繁加入/退出可能提前触发 `history_full`；没有归档或压缩策略。
- 只在本机 macOS 无头模式验证；未在 Windows、CI 或真实多人世界里验证。

## 关联

- 阶段计划：[M11 PLAN](PLAN.md)。
- 规则与权威：[RECORD-04 · 组织规则](RECORD-04-organizations.md)、[RECORD-08 · 组织权威接入](RECORD-08-organization-authority.md)。
- 账户与基金边界：[ADR-024 · 公共基金](../../decisions/ADR-024-public-funds.md)；余额与账户实现见 `Game/world/public_fund.gd`。
- 存储与严格校验参考：`Game/world/organization_store.gd`、`Game/world/territory_state.gd`。
