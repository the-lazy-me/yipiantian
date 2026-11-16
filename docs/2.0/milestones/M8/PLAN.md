# M8 · 银行、信用、保险与公共金融

状态：计划中，未验收。前置：M7 市场与完整账本。

## 阶段成果

提供可选择的资金和风险管理，形成 Living World Beta。

权威规格：[相关设计](../../systems/economy-finance.md)；统一证据标准：[质量门槛](../../09-QUALITY-GATES.md)。本页只维护实施范围与顺序。

## 实施步骤与工作包

### M8-01 · 建立双重记账

实施：账户、转账、冻结额、准备金与对账工具，所有分录绑定业务事件。

交付与验收：借贷平衡，重复转账返回原结果，恢复后账本一致。

记录：[RECORD-01-ledger](RECORD-01-ledger.md)（2026-11-15，切片完成，未验收；账户/商人/托管余额仍为唯一权威，开户、付款、商人预算、买单托管/释放、成交与运费写借贷分录，提供冻结/可用、准备金与对账工具，512 条有界日志与旧档期初检查点；贷款、存款、保险、公共基金与网络接入未覆盖）。决定：[ADR-014](../../decisions/ADR-014-double-entry-ledger.md)。

### M8-02 · 实现简单贷款

实施：有限期限、总费用、抵押范围、偿还和违约，保护基本住所与生活资源。

交付与验收：合同可提前查看；长离线不造成无限复利。

记录：[RECORD-02-loans](RECORD-02-loans.md)（2026-11-15，切片完成，未验收；一次性银行资本 2000、10–1000 COIN 本金、7/14/30 天期限、5% 固定费用、一笔在贷、一次结清与确定性逾期扫描；存款、复利、抵押、协商、核销、网络、UI 与 `FarmState` 封装未覆盖）。决定：[ADR-017](../../decisions/ADR-017-bank-loans.md)。

界面：[RECORD-02a-bank-panel](RECORD-02a-bank-panel.md)（2026-11-15，单机面板完成，未验收；银行状态与合同视图、实时报价、借款／还款、HUD 入口与主场景接线；共享世界只读、无美术与手柄全流程）。

### M8-03 · 实现保险

实施：承保、保费、免赔、限额、损失证据与唯一赔付。

交付与验收：已发生灾害不能追溯投保，同一损失不重复理赔。

记录：[RECORD-03-insurance](RECORD-03-insurance.md)（2026-11-15，调查完成，未实现；当前无可信损失证据，M8-03 阻塞于损失来源与风险信息定价）。决定：[ADR-022](../../decisions/ADR-022-insurance-loss-evidence.md)。

前置切片：[RECORD-03a-transport-loss](RECORD-03a-transport-loss.md)（2026-11-15，切片完成，未验收；发货显式声明运输风险，到达确定性判定，丢失写唯一 `transport_loss` 行到 `economy.losses`，货物销毁、现金不变、重复扫描不二次决议、256 行有界归档；无保单、保费、理赔、UI 与网络权限，世界扫描接线与定价仍未覆盖）。纯规则切片：[RECORD-15 · 保险纯规则](RECORD-15-insurance-rules.md)（2026-11-16，切片完成，未验收；保额=货值×80%、固定免赔 3 COIN、保费=保额×5%，同一损失由 `claim_<loss.sequence>` 唯一赔付，三道追溯投保闸门，保费与赔付都走 `Economy.pay` 因而 `issued` 与 `total_cash` 不变，池不足记 `pending`；未接世界权威、`FarmState`、UI、网络权限与真实损失联调，ADR-022 的「待赔损失不被归档淘汰」与可选保险定价套利仍未裁决）。可理赔查询：[RECORD-18 · 按损失查询可理赔保单](RECORD-18-insurance-claimable-policy.md)（2026-11-16，切片完成，未验收；`claimable_policy()` 只凭损失 id 回答哪张保单会被 `claim()` 接受，读写两条路径共用同一份 `_loss_claim_check()` 谓词，候选按 `policy_id` 升序确定性选择，已理赔损失在读取损失行之前就回答；未开共享投保写入口，权威自动理赔未接）。

### M8-04 · 接入公共基金

实施：合作社预算与公共建设支出使用独立账户和权限。

交付与验收：负责人换人不丢账，越权支出拒绝。
调查：[RECORD-04 · 公共基金调查](RECORD-04-public-funds.md)（2026-11-15，调查完成，当时无可执行支出路径；后续切片补足，见下）。决定：[ADR-024](../../decisions/ADR-024-public-funds.md)。
实现记录（纯规则切片，不表示 M8-04a/M8-04 完成）：[RECORD-06 · 公共项目与基金规则](RECORD-06-public-fund-implementation.md)，补足 RECORD-04 指出的公共支出 sink；固定成本项目、承诺/退回/建成与基金缴入、keeper 支出、换届保留余额均已成规则。接入权威的切片：[RECORD-07 · 公共基金接入世界权威](RECORD-07-public-fund-authority.md)：`public_funds.json` sidecar、组织成员开立、真实现金缴入 `org_<org_id>`、keeper 支出到 `@world`、余额与账户不变式、RPC 15/16；普通支付不能直接转入组织账户。界面：[RECORD-08 · 公共基金面板](RECORD-08-public-fund-panel.md)（2026-11-16，切片完成，未验收；权威基金视图按 fund id 排序显示，开立/缴入/支出/换届入口，换届二次确认，Esc/焦点归属，整份视图替换与权威拒绝文案；真实点按、窄屏与 Windows 未验证）。真实网络：[RECORD-09 · 公共基金真实网络测试](RECORD-09-public-fund-network.md)（2026-11-16，切片完成，未验收；真实 WSS 频道 15/16 覆盖开立/缴入/支出/换届/访客只读/超预算/重启重放；两个客户端同时在线与 Windows 未验证）。公共项目权威：[RECORD-10 · 公共项目接入世界权威](RECORD-10-public-works-authority.md)（2026-11-16，切片完成，未验收；`public_works.json` sidecar、`open/pledge/release/build`、RPC 21/22、build 由组织基金真实支出并写入 `fund_spend_pw_spend_<id>` 分录、重启后只补项目不二次支出、访客只读）。真实网络：[RECORD-11 · 公共项目真实网络测试](RECORD-11-public-works-network.md)（2026-11-16，切片完成，未验收；真实 WSS 21/22 覆盖开立/承诺/退回/基金建成/幂等/重启/访客只读/超预算；Windows 日志断言跳过）。界面：[RECORD-12 · 公共项目面板](RECORD-12-public-works-panel.md)（2026-11-16，切片完成，未验收；“公建”入口，项目列表与登记/承诺/退回/基金建成，只转发权威请求并显示拒绝原因；未做真实网络 UI 联调与截图）。三面板真实网络联调（与参与、交战一起验证）：[M12 RECORD-16](../M12/RECORD-16-panels-network.md)（2026-11-16，切片完成，未验收；真实 WSS 21/22 下项目登记、承诺与组织基金建成经面板控件完成并刷新，访客拒绝原因原样显示）。仍未接地图地块选择与建成后的建筑视觉。建成视觉切片：[RECORD-13 · 公共项目建成视觉](RECORD-13-public-works-visual.md)（2026-11-16，切片完成，未验收；`Game/scenes/environment/public_works_view.gd` 把 `built` 项目按地块→宅基 slot→世界位姿的既有契约放置程序化标记，整份替换不叠加，未绑定地块跳过；仍无地图选点、美术精修与避让）。登记地块选择切片：[RECORD-14 · 公共项目登记地块选择](RECORD-14-public-works-parcel-picker.md)（2026-11-16，切片完成，未验收；面板登记行新增 `ParcelChoice` 下拉，从权威地籍 id 去重排序后写入既有 `ParcelId` 文本，请求形状不变；仍未做三维地图选点）。

### M8-05 · 进行压力模拟

实施：集中提款、歉收、坏账和赔付高峰，观察资金来源与恢复。

前置切片（存款纯规则）：[RECORD-16 · 银行存款与准备金拒绝](RECORD-16-deposits.md)（2026-11-16，切片完成，未验收；`Game/farm/deposit_state.gd` 以本金存入/取款把真实现金转入转出 `bank.cash`，存款负债进入 `reserve_statement().claims`，银行现金等式扩展为 `capital - loans + fees + deposits`，`bank.cash` 不足时取款返回 `insufficient_reserve` 且余额不变；不付利息，未接命令/UI/网络，旧文档无 `deposits` 键按空表读取）。决定：[ADR-030](../../decisions/ADR-030-bank-deposits.md)。命令接线：[RECORD-17 · 存取款命令](RECORD-17-deposit-commands.md)（2026-11-16，切片完成，未验收；`bank_deposit`/`bank_withdraw` 两个 economy 命令进 `KINDS` 与成员权限表，命令键集精确为 `{id,kind,amount,at_utc}`、任何身份字段拒绝，业务边界仍只由存款规则判定；权威通用 economy 分支自动生效，UI、摘要投影与耐久重放守卫未覆盖）。

交付与验收：准备金不足有规则处理，不暗中增发；拒绝金融仍可正常生活。

记录：[RECORD-05-stress](RECORD-05-stress.md)（2026-11-15，模拟已执行，未验收；坏账与银行准备金、集中提款、歉收与商人流动性、60 天长离线、拒绝金融仍可生活，以及“当前无自动赔付”的边界确认；当时未覆盖的存款挤兑与存款负债已由 RECORD-16 补上纯规则部分，保险赔付高峰、网络权威与真实墙钟长时运行仍未覆盖）。

## 集成验收

Q2/Q5/Q7；迁移、并发和崩溃情形下债权/债务/资金成套恢复。

## 回退与边界

暂停新授信与承保，继续履行已有合同；不能靠删债权修复账本。

不涉及真实资金、投资收益承诺或金融产品销售。

执行顺序、优先级与证据格式遵循[里程碑通用约定](../README.md)；本阶段尚无实际验收记录。

返回[路线图](../../03-ROADMAP.md)或[总索引](../../00-INDEX.md)。
