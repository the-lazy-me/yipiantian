extends SceneTree
## M10-04 居民角色权限矩阵。纯规则验证：不启动世界、不写存档、不接网络。
## 覆盖三角色白名单、越权、金额边界、窗口累计、未知输入、名册映射、
## 确定性，以及“叙事永远不授权”。

const Roles = preload("res://npc/npc_roles.gd")
const Roster = preload("res://npc/npc_roster.gd")
const FarmCommand = preload("res://farm/farm_command.gd")

const NPC_LIN: String = "npc_lin_shen"
const NPC_XU: String = "npc_xu_bo"
const NPC_ZHOU: String = "npc_a_zhou"
const NOW: float = 1800000000.0

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_mapping()
	_test_whitelists()
	_test_allowed_actions()
	_test_amount_bounds()
	_test_forbidden_actions()
	_test_time_and_window()
	_test_determinism()
	_test_narrative()
	_finish()


func _test_mapping() -> void:
	_expect(Roles.role_of(NPC_ZHOU) == Roles.MERCHANT, "阿舟担任商人")
	_expect(Roles.role_of(NPC_XU) == Roles.BANKER, "许伯担任银行家")
	_expect(Roles.role_of(NPC_LIN) == Roles.OFFICIAL, "林婶担任官员")
	_expect(Roles.role_of("npc_unknown") == "", "未知居民没有角色")
	_expect(Roles.role_of(42) == "", "非字符串居民 id 没有角色")
	_expect(Roles.resident_of(Roles.MERCHANT) == NPC_ZHOU, "商人角色反查回阿舟")
	_expect(Roles.resident_of(Roles.BANKER) == NPC_XU, "银行家角色反查回许伯")
	_expect(Roles.resident_of(Roles.OFFICIAL) == NPC_LIN, "官员角色反查回林婶")
	_expect(Roles.resident_of("trader") == "", "未知角色没有居民")
	_expect(Roles.RESIDENT_ROLES.size() == Roster.IDS.size(),
		"角色映射与名册人数一致")
	var complete: bool = true
	for resident_id: String in Roster.IDS:
		if not Roles.RESIDENT_ROLES.has(resident_id) \
				or not Roles.ROLE_NAMES.has(str(Roles.RESIDENT_ROLES[resident_id])):
			complete = false
	_expect(complete, "名册三人都有合法角色，没有遗漏或多余")
	for role: String in Roles.ROLE_NAMES:
		_expect(Roles.role_of(Roles.resident_of(role)) == role,
			"角色 " + role + " 与居民反查一致")


func _test_whitelists() -> void:
	var expected_merchant: Array = [
		FarmCommand.ACCOUNT_OPEN, FarmCommand.PAY, FarmCommand.MARKET_OPEN,
		FarmCommand.MARKET_PLACE, FarmCommand.MARKET_CANCEL, FarmCommand.MARKET_SHIP,
	]
	var expected_banker: Array = [
		FarmCommand.ACCOUNT_OPEN, FarmCommand.PAY, FarmCommand.BANK_OPEN,
	]
	var expected_official: Array = [
		FarmCommand.ACCOUNT_OPEN, FarmCommand.PAY, FarmCommand.GIFT,
	]
	_expect(_same_set(Roles.allowed_kinds(Roles.MERCHANT), expected_merchant),
		"商人白名单精确匹配市场动作")
	_expect(_same_set(Roles.allowed_kinds(Roles.BANKER), expected_banker),
		"银行家白名单精确匹配开户、付款与开业")
	_expect(_same_set(Roles.allowed_kinds(Roles.OFFICIAL), expected_official),
		"官员白名单精确匹配开户、付款与赠予")
	_expect(Roles.allowed_kinds("trader").is_empty(), "未知角色的白名单为空")
	_expect(_same_set(Roles.allowed_kinds(Roles.MERCHANT),
		Roles.allowed_kinds(Roles.MERCHANT)), "白名单查询是确定性的")
	var copy: Array[String] = Roles.allowed_kinds(Roles.MERCHANT)
	copy.clear()
	_expect(Roles.allowed_kinds(Roles.MERCHANT).size() == expected_merchant.size(),
		"调用者清空返回值不会改动规则表")
	var known: bool = true
	for role: String in Roles.ROLE_NAMES:
		for kind: String in Roles.allowed_kinds(role):
			if not kind in FarmCommand.KINDS:
				known = false
	_expect(known, "白名单只包含 FarmCommand 的既有 kind")
	var deliver: bool = false
	var borrow: bool = false
	var repay: bool = false
	var harvest: bool = false
	for role: String in Roles.ROLE_NAMES:
		if Roles.allowed_kinds(role).has(FarmCommand.MARKET_DELIVER):
			deliver = true
		if Roles.allowed_kinds(role).has(FarmCommand.LOAN_BORROW):
			borrow = true
		if Roles.allowed_kinds(role).has(FarmCommand.LOAN_REPAY):
			repay = true
		if Roles.allowed_kinds(role).has(FarmCommand.HARVEST):
			harvest = true
	_expect(not deliver, "权威扫描 market_deliver 不属于任何居民角色")
	_expect(not borrow, "贷款借款不由居民角色代发")
	_expect(not repay, "贷款还款不由居民角色代操作")
	_expect(not harvest, "农活 harvest 不在角色白名单内")


func _test_allowed_actions() -> void:
	var merchant: Dictionary = _submit(Roles.MERCHANT, FarmCommand.MARKET_PLACE, 100, 0)
	_expect(bool(merchant.ok) and str(merchant.reason) == "",
		"商人可在单笔上限内挂单")
	_expect(int(merchant.remaining) == 700, "成功结果给出窗口剩余额度")
	var banker: Dictionary = _submit(Roles.BANKER, FarmCommand.BANK_OPEN, 0, 0)
	_expect(bool(banker.ok), "银行家可开业，无金额动作传 0")
	var official: Dictionary = _submit(Roles.OFFICIAL, FarmCommand.GIFT, 50, 0)
	_expect(bool(official.ok), "官员可在上限内赠予公共物资")
	var cancel: Dictionary = _submit(Roles.MERCHANT, FarmCommand.MARKET_CANCEL, 0, 0)
	_expect(bool(cancel.ok), "无金额的撤单动作在 0 数量下通过")
	var open_account: Dictionary = _submit(Roles.MERCHANT, FarmCommand.ACCOUNT_OPEN, 0, 0)
	_expect(bool(open_account.ok), "开户动作在 0 数量下通过")


func _test_amount_bounds() -> void:
	_expect(bool(_submit(Roles.MERCHANT, FarmCommand.PAY, 200, 0).ok),
		"商人金额恰好等于单笔上限时通过")
	_expect(str(_submit(Roles.MERCHANT, FarmCommand.PAY, 201, 0).reason)
		== "limit_per_call", "商人金额超过单笔上限一点即拒绝")
	_expect(bool(_submit(Roles.BANKER, FarmCommand.PAY, 1000, 0).ok),
		"银行家金额恰好等于单笔上限时通过")
	_expect(str(_submit(Roles.BANKER, FarmCommand.PAY, 1001, 0).reason)
		== "limit_per_call", "银行家金额超过单笔上限一点即拒绝")
	_expect(bool(_submit(Roles.OFFICIAL, FarmCommand.PAY, 100, 0).ok),
		"官员金额恰好等于单笔上限时通过")
	_expect(str(_submit(Roles.OFFICIAL, FarmCommand.PAY, 101, 0).reason)
		== "limit_per_call", "官员金额超过单笔上限一点即拒绝")
	var exact: Dictionary = _submit(Roles.MERCHANT, FarmCommand.PAY, 200, 600)
	_expect(bool(exact.ok) and int(exact.remaining) == 0,
		"窗口累计恰好等于上限时通过且剩余为 0")
	_expect(str(_submit(Roles.MERCHANT, FarmCommand.PAY, 200, 601).reason)
		== "limit_window", "窗口累计超过上限一点即拒绝")
	_expect(bool(_submit(Roles.MERCHANT, FarmCommand.MARKET_CANCEL, 0, 800).ok),
		"已用满窗口后无金额动作仍可通过")
	_expect(str(_submit(Roles.MERCHANT, FarmCommand.MARKET_CANCEL, 1, 800).reason)
		== "limit_window", "已用满窗口后任何正数量都拒绝")
	_expect(str(_submit(Roles.MERCHANT, FarmCommand.PAY, 1, 900).reason)
		== "limit_window", "窗口累计本身越界时拒绝")
	_expect(str(_submit(Roles.MERCHANT, FarmCommand.PAY, -1, 0).reason)
		== "invalid_amount", "负金额被拒绝")
	_expect(str(_submit(Roles.MERCHANT, FarmCommand.PAY, 1.5, 0).reason)
		== "invalid_amount", "小数金额被拒绝")
	_expect(str(_submit(Roles.MERCHANT, FarmCommand.PAY, "100", 0).reason)
		== "invalid_amount", "字符串金额被拒绝")
	_expect(str(_submit(Roles.MERCHANT, FarmCommand.PAY, NAN, 0).reason)
		== "invalid_amount", "非有限金额被拒绝")
	_expect(str(_submit(Roles.MERCHANT, FarmCommand.PAY, 100, -1).reason)
		== "invalid_amount", "负的窗口累计被拒绝")
	_expect(str(_submit(Roles.MERCHANT, FarmCommand.PAY, 100, 0.5).reason)
		== "invalid_amount", "小数窗口累计被拒绝")
	_expect(str(_submit(Roles.MERCHANT, FarmCommand.PAY,
		float(Roles.MAX_SAFE_INTEGER) + 1.0, 0).reason) == "invalid_amount",
		"超过安全整数范围的金额被拒绝")


func _test_forbidden_actions() -> void:
	_expect(str(_submit(Roles.MERCHANT, FarmCommand.LOAN_BORROW, 100, 0).reason)
		== "forbidden_kind", "商人不能借款")
	_expect(str(_submit(Roles.BANKER, FarmCommand.MARKET_PLACE, 100, 0).reason)
		== "forbidden_kind", "银行家不能挂市场单")
	_expect(str(_submit(Roles.OFFICIAL, FarmCommand.MARKET_OPEN, 0, 0).reason)
		== "forbidden_kind", "官员不能开市")
	_expect(str(_submit(Roles.MERCHANT, FarmCommand.HARVEST, 0, 0).reason)
		== "forbidden_kind", "居民角色不能通过角色矩阵提交农活")
	_expect(str(_submit(Roles.MERCHANT, "launder", 0, 0).reason)
		== "forbidden_kind", "未知 kind 一律拒绝")
	_expect(str(_submit("trader", FarmCommand.PAY, 1, 0).reason) == "unknown_role",
		"未知角色优先返回 unknown_role")
	_expect(str(_submit(42, FarmCommand.PAY, 1, 0).reason) == "unknown_role",
		"非字符串角色返回 unknown_role")
	_expect(bool(_submit(Roles.MERCHANT, FarmCommand.PAY, 1, 0).ok)
		and str(_submit(Roles.BANKER, FarmCommand.MARKET_PLACE, 1, 0).reason)
		== "forbidden_kind", "同一动作在不同角色下得到不同准入结果")


func _test_time_and_window() -> void:
	_expect(str(_submit_at(Roles.MERCHANT, FarmCommand.PAY, 1, 0, -1.0,
		Roles.WINDOW_DAY).reason) == "invalid_time", "负时间被拒绝")
	_expect(str(_submit_at(Roles.MERCHANT, FarmCommand.PAY, 1, 0, NAN,
		Roles.WINDOW_DAY).reason) == "invalid_time", "非有限时间被拒绝")
	_expect(str(_submit_at(Roles.MERCHANT, FarmCommand.PAY, 1, 0, "now",
		Roles.WINDOW_DAY).reason) == "invalid_time", "非数值时间被拒绝")
	_expect(str(_submit_at(Roles.MERCHANT, FarmCommand.PAY, 1, 0, NOW,
		"week").reason) == "unknown_window", "未知窗口被拒绝")
	_expect(str(_submit_at(Roles.MERCHANT, FarmCommand.PAY, 1, 0, NOW,
		3600).reason) == "unknown_window", "非字符串窗口被拒绝")
	_expect(int(Roles.window_bucket(0.0, Roles.WINDOW_DAY).bucket) == 0,
		"0 时刻属于第 0 个日窗口")
	_expect(int(Roles.window_bucket(86399.0, Roles.WINDOW_DAY).bucket) == 0,
		"日窗口最后一秒仍属于第 0 桶")
	_expect(int(Roles.window_bucket(86400.0, Roles.WINDOW_DAY).bucket) == 1,
		"跨过日边界进入第 1 桶")
	_expect(int(Roles.window_bucket(3599.0, Roles.WINDOW_HOUR).bucket) == 0,
		"小时窗口最后一秒仍属于第 0 桶")
	_expect(int(Roles.window_bucket(3600.0, Roles.WINDOW_HOUR).bucket) == 1,
		"跨过小时边界进入第 1 桶")
	_expect(str(Roles.window_bucket(-1.0, Roles.WINDOW_DAY).reason) == "invalid_time",
		"分桶拒绝非法时间")
	_expect(str(Roles.window_bucket(0.0, "week").reason) == "unknown_window",
		"分桶拒绝未知窗口")
	var result: Dictionary = _submit(Roles.MERCHANT, FarmCommand.PAY, 10, 0)
	_expect(int(result.bucket) == int(Roles.window_bucket(NOW, Roles.WINDOW_DAY).bucket),
		"准入结果携带与分桶入口一致的窗口桶")


func _test_determinism() -> void:
	var first: Dictionary = _submit(Roles.MERCHANT, FarmCommand.PAY, 100, 300)
	var second: Dictionary = _submit(Roles.MERCHANT, FarmCommand.PAY, 100, 300)
	_expect(JSON.stringify(first) == JSON.stringify(second),
		"相同参数得到完全相同的结果")
	var same_bucket: Dictionary = _submit_at(Roles.MERCHANT, FarmCommand.PAY, 100, 300,
		NOW + 3600.0, Roles.WINDOW_DAY)
	_expect(JSON.stringify(first) == JSON.stringify(same_bucket),
		"同一日窗口内的不同时刻不改变准入结果")
	var next_day: Dictionary = _submit_at(Roles.MERCHANT, FarmCommand.PAY, 100, 300,
		NOW + 86400.0, Roles.WINDOW_DAY)
	_expect(bool(next_day.ok) and int(next_day.bucket) == int(first.bucket) + 1,
		"进入下一个日窗口后桶号递增且判定不变")
	var refused_a: Dictionary = _submit(Roles.BANKER, FarmCommand.LOAN_BORROW, 1, 0)
	var refused_b: Dictionary = _submit(Roles.BANKER, FarmCommand.LOAN_BORROW, 1, 0)
	_expect(JSON.stringify(refused_a) == JSON.stringify(refused_b),
		"拒绝结果同样是确定性的")


func _test_narrative() -> void:
	var merchant: Dictionary = Roles.claim_from_narrative(Roles.MERCHANT,
		"我把市场的一半所有权转让给你")
	_expect(not bool(merchant.ok) and str(merchant.reason) == "not_authority",
		"商人的叙事宣言不能授予权属")
	_expect(not bool(merchant.authority) and bool(merchant.proposal_only),
		"叙事结果明确标注无权威、仅提案")
	var banker: Dictionary = Roles.claim_from_narrative(Roles.BANKER,
		"批准一笔无需偿还的贷款")
	_expect(str(banker.reason) == "not_authority", "银行家的叙事批准无效")
	var official: Dictionary = Roles.claim_from_narrative(Roles.OFFICIAL,
		"我任命自己为银行家")
	_expect(str(official.reason) == "not_authority", "官员的叙事任命不能改变角色")
	_expect(str(Roles.claim_from_narrative("trader", "我有权付款").reason)
		== "not_authority", "未知角色的叙事同样不获得权限")
	_expect(str(Roles.claim_from_narrative(Roles.MERCHANT, 42).reason)
		== "not_authority", "非字符串声明同样不获得权限")
	_expect(str(Roles.claim_from_narrative(Roles.MERCHANT, FarmCommand.MARKET_PLACE).reason)
		== "not_authority", "即使声明的是白名单动作也不授权")
	var result: Dictionary = Roles.claim_from_narrative(Roles.OFFICIAL, "收税")
	_expect(not result.has("granted") and not result.has("allowed_kinds"),
		"叙事返回不携带任何权限授予")
	for role: String in Roles.ROLE_NAMES:
		var claimed: Dictionary = Roles.claim_from_narrative(role, "全部权属归我")
		_expect(not bool(claimed.ok) and not bool(claimed.authority),
			"角色 " + role + " 的叙事永远不构成授权")


func _submit(role: Variant, kind: Variant, amount: Variant, spent: Variant) -> Dictionary:
	return _submit_at(role, kind, amount, spent, NOW, Roles.WINDOW_DAY)


func _submit_at(role: Variant, kind: Variant, amount: Variant, spent: Variant,
		now_utc: Variant, window: Variant) -> Dictionary:
	return Roles.may_submit(role, kind, amount, spent, now_utc, window)


func _same_set(left: Array, right: Array) -> bool:
	if left.size() != right.size():
		return false
	for item: Variant in left:
		if not right.has(item):
			return false
	return true


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
	print(("PASS " if condition else "FAIL ") + message)


func _finish() -> void:
	for failure: String in failures:
		push_error(failure)
	print("NPC_ROLES_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
