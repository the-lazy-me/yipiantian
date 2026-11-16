extends SceneTree
## 摘要只读块的纯规则测试：从成员摘要里取一块，缺摘要/缺块/空块一律返回空
## 数组，行顺序保持、行是深拷贝。不挂场景、不读美术资源，可进规则组。
##
## 末行：SUMMARY_BLOCK_TEST checks=N failures=M

const SummaryBlock = preload("res://scenes/summary_block.gd")

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run()


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func _run() -> void:
	# 正常块：两行按摘要里的顺序返回，字段原样保留。
	var summary: Dictionary = {
		"units": {"units": [
			{"id": "u-b", "kind": "guard", "people": 2},
			{"id": "u-a", "kind": "scout", "people": 1},
		]},
	}
	var rows: Array = SummaryBlock.summary_block(summary, "units", "units")
	_check(rows.size() == 2, "normal block keeps both rows")
	_check(str(rows[0].get("id", "")) == "u-b", "row order preserved (first)")
	_check(str(rows[1].get("id", "")) == "u-a", "row order preserved (second)")
	_check(int(rows[0].get("people", 0)) == 2, "row fields preserved")

	# public_works 用 `projects` 作为数组键。
	var works: Dictionary = {"public_works": {"projects": [{"project_id": "p-1"}]}}
	_check(SummaryBlock.summary_block(works, "public_works", "projects").size() == 1,
		"public works maps projects key")

	# 缺块、块形状不对、数组键缺失或类型不对都返回空数组。
	_check(SummaryBlock.summary_block({}, "units", "units").is_empty(),
		"missing block is empty")
	_check(SummaryBlock.summary_block({"units": []}, "units", "units").is_empty(),
		"array block is empty")
	_check(SummaryBlock.summary_block({"units": {"units": []}}, "units", "units").is_empty(),
		"empty array is empty")
	_check(SummaryBlock.summary_block({"units": {}}, "units", "units").is_empty(),
		"missing array key is empty")
	_check(SummaryBlock.summary_block({"units": {"units": "no"}}, "units", "units").is_empty(),
		"non-array rows is empty")
	_check(SummaryBlock.summary_block({"units": {"units": [1, "two"]}}, "units",
		"units").is_empty(), "non-dictionary rows are skipped")

	# 摘要本身不是字典或为 null 时同样不崩。
	_check(SummaryBlock.summary_block(null, "units", "units").is_empty(),
		"null summary is empty")
	_check(SummaryBlock.summary_block([], "units", "units").is_empty(),
		"array summary is empty")
	_check(SummaryBlock.summary_block("summary", "units", "units").is_empty(),
		"string summary is empty")
	_check(SummaryBlock.summary_block(7, "units", "units").is_empty(),
		"int summary is empty")

	# 深拷贝：改返回的数组与行，不改变传入摘要。
	var source: Dictionary = {
		"funds": {"funds": [
			{"fund_id": "f-1", "contributors": ["a"], "balance": 10},
		]},
	}
	var copied: Array = SummaryBlock.summary_block(source, "funds", "funds")
	copied.append({"fund_id": "f-2"})
	var copied_row: Dictionary = copied[0]
	copied_row["balance"] = 999
	var copied_names: Array = copied_row["contributors"]
	copied_names.append("b")
	var original_rows: Array = (source["funds"] as Dictionary)["funds"]
	_check(original_rows.size() == 1, "returned array is a deep copy")
	_check(int((original_rows[0] as Dictionary)["balance"]) == 10,
		"returned row is a deep copy")
	_check(((original_rows[0] as Dictionary)["contributors"] as Array).size() == 1,
		"nested row values are deep copied")

	for failure: String in failures:
		push_error(failure)
	print("SUMMARY_BLOCK_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
