# M8-02a · 单机银行与贷款面板

状态：已实现（2026-11-15），未验收。范围：单机银行／贷款面板、银行与合同视图、实时报价、借款／还款意图、HUD 入口、主场景接线与共享世界只读。不包含规则改动、网络权限、美术资源或 Windows 实机验证。

权威规则：[ADR-017](../../decisions/ADR-017-bank-loans.md)；前置记录：[M8-02 规则银行与简单贷款](RECORD-02-loans.md)、[M7-06 市场界面](../M7/RECORD-06-market-panel.md)。

## 改动

| 文件 | 内容 |
|---|---|
| `Game/ui/bank_panel.gd` | 新增。银行状态摘要（是否开市、现金、资本、未结清本金、已收费用、我的现金）、合同列表（本金／费用／合计／到期／状态）、7/14/30 天期限与本金输入、实时报价、开市／借款／还款／刷新／收起按钮；只发出 `open_requested`、`borrow_requested`、`repay_requested`、`refresh_requested`、`closed` 意图信号，不修改规则状态。 |
| `Game/scenes/farm_hud.gd` | 底栏「市场」旁新增文字按钮「银行」与 `bank_requested` 信号；底栏宽度从 760 调到 864 以容纳新增入口。 |
| `Game/scenes/main.gd` | 接线面板；单机打开时先跑 `economy_settle_loans`，再用固定 id 补一次开户（`bank-account-<owner>`）与开行（`bank-open`）；借款／还款各自使用唯一命令 id，成功后才保存并重新取视图；失败只更新文案；共享世界只读；面板打开期间屏蔽世界输入，Esc／右键关闭。 |
| `tests/bank_panel_test.gd` | 新增 34 项视图与意图检查。 |

未新增规则、依赖、网络消息或美术资源；农场格式、贷款规则与存档形状未改。面板复用现有 `FarmTheme` 字体，因此测试属美术场景夹具。

## 行为

- 视图整份替换。报价直接调用 `Loans.quote(principal, term, now)`，费用、合计与到期都来自规则模块，面板不自行算费。
- 未开市时借款按钮禁用并显示「尚未开市」；开市后显示真实银行现金、资本、未结清本金与已收费用，借款按钮可用。
- 合同列表显示全部合同并标注「我／他人」；只有本人的 `open`／`overdue` 合同出现「还款」按钮，其他合同和已结清合同没有操作。
- 单机首次打开用固定 id 补一次开户与 2000 COIN 银行资本；两者都是耐久幂等标记，重复打开不会二次发行。失败只提示，不阻止面板以实际状态打开。
- 打开与刷新都执行确定性逾期扫描；有合同变为 `overdue` 时保存并显示中文提示。
- 借款／还款失败只显示中文原因，不乐观修改余额或合同列表；成功后才保存，保存失败保留界面状态并交给既有存储恢复流程。
- 共享世界（`remote != null`）：本切片当时只读，不提交任何命令、按钮禁用。后续 [M4-09 经济命令](../M4/RECORD-09-economy-commands.md)（ADR-019）已把 `bank_open`/`loan_borrow`/`loan_repay` 接进共享世界，`main.gd` 的联机分支改发同一组命令并等权威摘要，证据见 `M4_ECONOMY_COMMANDS_TEST`；访客仍是只读并显示访客原因文案。
- Esc／右键关闭面板并恢复镜头与世界输入，与市场面板一致。

## 实测输出

```
BANK_PANEL_TEST checks=34 failures=0
MARKET_PANEL_TEST checks=31 failures=0
```

真实场景冒烟 `--path Game --audio-driver Dummy --quit-after 2400` 退出码 0：

```
STARTUP_COMPLETE
ERROR: 1 RID allocations of type 'N13RendererDummy15MaterialStorage11DummyShaderE' were leaked at exit.
```

`DummyShaderE` 是强制退出的既有噪声；本机冒烟未出现脚本错误或解析错误。冒烟未做点击级银行操作，因此命令路径由视图夹具与既有 `loan_test` 分别覆盖，没有端到端点击证据。

## 双平台 CI

2026-11-15，`7f05397` 的 rule-tests run 43688308623 双平台通过：

```text
macOS   bank_panel_test skipped=no-art
macOS   rule fixtures: 64 listed, 7 skipped for missing art
Windows bank_panel_test skipped=no-art
Windows rule fixtures: 64 listed, 7 skipped for missing art
```

面板夹具预加载主题字体，清理检出没有 LFS 美术，因此按既有规则跳过；它的 34 项检查只在本机有美术时运行。

## 未覆盖

- **共享世界写命令**：权威侧的银行／贷款权限已在 [M4-09](../M4/RECORD-09-economy-commands.md) 落地，但客户端面板尚未接线，共享世界仍只读。
- **美术与实机**：入口是文字按钮，没有图标或场景内银行外观；未在 Windows 实机运行。
- **手柄／键盘全流程**：只验证了按钮与信号的视图夹具，没有手柄、Tab 导航或完整键盘操作验收。
- **真实玩家数据**：夹具直接构造视图，冒烟使用既有开发存档；没有用真实玩家存档复测借款与还款。

## 依赖说明

借款规则要求借款人已开户（`granted`）。为了让从未打开过市场的单机玩家也能使用银行，打开面板时会用 `bank-account-<owner>` 这个固定 id 补一次既有的一次性开户（120 COIN，与市场同一发行入口），不是新的货币来源。
