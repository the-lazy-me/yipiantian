# M4-10 · 共享世界经济面板接线

执行日期：2026-11-15。状态：切片完成，不表示 M4 或验收完成。前置：[M4-09 经济命令](RECORD-09-economy-commands.md)，权限与扫描见 [ADR-019](../../decisions/ADR-019-economy-command-permissions.md)。

## 问题

M4-09 让权威接受经济命令，但市场与银行面板仍在共享世界一律只读，成员无法下单、发货、开市或借贷。面板需要在成员和访客之间分流，并且只发意图：费用、余额、在贷笔数和撮合结果仍由权威判定。

## 实现

| 文件 | 改动 |
|---|---|
| `Game/scenes/main.gd` | 按角色启用写按钮；市场/银行意图转为 `make_market_*`、`make_loan_*`、`make_bank_open`；固定 id 开户/开市；回执按 `reason_text` 显示中文；经济命令不再本地回放 |
| `Game/ui/market_panel.gd` | 沿用 `read_only` 视图事实；新增 `auto_delivery`，共享世界隐藏手动交付并说明自动入袋 |
| `Game/ui/bank_panel.gd` | 沿用 `read_only` 视图事实，文案改由 main 按角色给出 |
| `tests/market_panel_test.gd` | 覆盖 member 可写、visitor 只读、共享世界无手动交付 |
| `tests/bank_panel_test.gd` | 覆盖 member 可写、visitor 只读 |
| `tests/farm_command_test.gd` | 十种经济命令的精确键集、身份键排除与载荷原样断言 |

### 角色行为

- `remote.member.role == "member"` 且有 `player_id`：面板可写，按钮分别发出下单、撤单、发货、开市、借款、还款意图。
- `visitor`：只读，显示“访客只能查看市场和银行，不能下单、发货、开市或借贷。”
- 匿名成员（无 `player_id`）：只读，显示“还没有玩家身份，暂时不能进行经济操作。”
- 单机路径不变：直接调用 `farm_state.*`，仍由本地规则校验并保存。
- 面板不判断余额、库存、托管、路线或期限；报价仍只调用 `Loans.quote`。

### 开户与开市

- 打开市场或银行面板时，若本地镜像缺少本人 `granted` 账户，提交一次固定 id `account-open-<player_id>` 的 `make_account_open`。
- 市场面板在账户回执成功后补发一次 `market-merchant` 的 `make_market_open`；两条命令不并行，避免第二条因 `stale_precondition` 被拒。
- 银行由成员点击“开市”提交固定 id `bank-open` 的 `make_bank_open`。
- 固定 id 命令按首次提交的时间原样保留，重试回放同一载荷（`duplicate=true`），不会因新时间触发 `command_conflict`。权威明确拒绝后丢弃保留，允许下次用新时间重试。

### 市场交付

- 共享世界的“交付到达货物”按钮隐藏，面板提示“货物到达后由世界自动入袋，无需手动交付。”
- 权威时钟每秒补扫 `market_deliver`；客户端不提交手动交付。

### 回执与错误

- 经济命令的成功或失败回执不再调用 `_apply_remote_command`；钱包、订单、合同和余额只由随后的权威摘要刷新，不做乐观修改。
- 其他成员的 `change` 广播若为经济命令则直接跳过：广播不含费用和扫描计数，重放会与摘要重复应用。
- 失败优先显示权威附带的 `reason_text`；缺失时回退到市场/贷款中文原因表。
- `duplicate=true` 且 `ok=true` 视为确认，不当作失败。
- 离线或未连接时提交失败显示“还没有连上世界，这次操作没有发出去。”
- 手动刷新按钮在共享世界调用 `request_summary()`，不自结算到期、逾期或交付。

## 验证

```sh
GODOT=/Volumes/Disk-1tb/tools/godot-4.7.2/editor/Godot.app/Contents/MacOS/Godot
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game --audio-driver Dummy --script "$PWD/tests/bank_panel_test.gd"
```

原始末行：

```text
BANK_PANEL_TEST checks=41 failures=0
MARKET_PANEL_TEST checks=39 failures=0
FARM_COMMAND_TEST checks=136 failures=0
M4_ECONOMY_COMMANDS_TEST checks=137 failures=0 dir=/Volumes/Disk-1tb/yipiantian/.local/verification/m4-economy-commands-314548
```

场景冒烟：

```sh
perl -e 'alarm shift; exec @ARGV' 300 "$GODOT" --headless --path Game --audio-driver Dummy --quit-after 2400
```

结果：退出码 `0`，输出 `STARTUP_COMPLETE`；无脚本解析或运行错误。退出期仍有既有噪声：

```text
ERROR: 1 RID allocations of type 'N13RendererDummy15MaterialStorage11DummyShaderE' were leaked at exit.
WARNING: 12 ObjectDB instances were leaked at exit (run with `--verbose` for details).
```

## 未覆盖

- UI 意图与 `make_*` 命令载荷已测；main 的共享世界点击回合未做独立端到端夹具，权威收单由 M4-09 夹具覆盖。未声称已完成端到端点击验证。
- 未在真实跨平台硬件上验证；本记录只有 macOS 本机回路。
- 两次快速点击可产生两个不同命令 id，面板未做防抖；权威按订单/贷款规则拒绝多余操作。
- 银行“开市”在开户回执到达前点击可能收到一次 `stale_precondition`，刷新后可重试。
