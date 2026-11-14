extends SceneTree
## M3-04: deterministic multi-world headless experiment entry.
## Two runs with the same seeds must produce identical world summaries, and the
## printed aggregate must not leak a real filesystem path.

const START: float = 1800000000.0

var checks: int = 0
var failures: Array[String] = []
var test_root: String


func _initialize() -> void:
	var project_root: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	test_root = project_root.get_base_dir().path_join(
		".local/verification/world-lab-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(test_root)
	var first: Dictionary = _run_lab("first")
	var second: Dictionary = _run_lab("second")
	_check_lab(first, "first")
	_check_lab(second, "second")
	_expect_repeatable(first, second)
	for failure: String in failures:
		push_error(failure)
	print("WORLD_LAB_TEST checks=%d failures=%d root=%s" % [checks, failures.size(), test_root])
	quit(0 if failures.is_empty() else 1)


func _run_lab(label: String) -> Dictionary:
	var directory: String = test_root.path_join(label)
	DirAccess.make_dir_recursive_absolute(directory)
	var project: String = ProjectSettings.globalize_path("res://").simplify_path().trim_suffix("/")
	var runner: String = project.path_join("world/headless_runner.gd")
	var output: Array = []
	var arguments: Array[String] = [
		"--headless", "--path", project, "--script", runner, "--",
		"--data-dir=" + directory, "--worlds=3", "--seed=11", "--advance-seconds=9000",
		"--commands=sow:field_01:cell_01:greens@0;water:field_01:cell_01@60;harvest:field_01:cell_01@9000",
	]
	var status: int = OS.execute(OS.get_executable_path(), arguments, output, true)
	# OS.execute may batch several lines into one array element, so split the
	# combined stream instead of assuming one element per printed line.
	var combined: String = ""
	for line: Variant in output:
		combined += str(line) + "\n"
	var text: String = ""
	for line: String in combined.split("\n"):
		if line.begins_with("HEADLESS_WORLDS "):
			text = line.trim_prefix("HEADLESS_WORLDS ")
	var parsed: Dictionary = {}
	if not text.is_empty():
		var json := JSON.new()
		if json.parse(text) == OK and json.data is Dictionary:
			parsed = json.data
	parsed["_status"] = status
	parsed["_raw"] = combined
	parsed["_directory"] = directory
	return parsed


func _check_lab(lab: Dictionary, label: String) -> void:
	_expect(int(lab.get("_status", -1)) == 0, label + ": the lab exits successfully")
	_expect(bool(lab.get("ok", false)) and lab.get("failures", []).is_empty(), label + ": aggregate reports no failures")
	_expect(int(lab.get("worlds", 0)) == 3, label + ": one aggregate covers three worlds")
	var results: Array = lab.get("results", [])
	_expect(results.size() == 3, label + ": three world summaries are reported")
	var seeds: Array[int] = []
	for entry: Dictionary in results:
		_expect(bool(entry.get("ok", false)), label + ": each world completes: " + str(entry.get("index", -1)))
		_expect(int(entry.get("committed_sequence", 0)) == 3, label + ": each world commits three commands")
		_expect(int(entry.get("inventory", {}).get("greens", 0)) == 1, label + ": each world harvests exactly one crop")
		seeds.append(int(entry.get("seed", 0)))
		var directory: String = str(entry.get("data_directory", ""))
		_expect(directory.begins_with(".local/verification/"), label + ": world paths are repository-relative labels")
		_expect(FileAccess.file_exists(str(lab.get("_directory", "")).path_join("world-%02d" % int(entry.get("index", 0))).path_join("farm.json")),
			label + ": each world has its own isolated save")
	var unique: Dictionary = {}
	for value: int in seeds: unique[value] = true
	_expect(unique.size() == 3, label + ": each world gets a distinct derived seed")
	_expect(int(lab.get("root_children", -1)) == 0, label + ": no scene node is instantiated")
	var raw: String = str(lab.get("_raw", ""))
	var home: String = OS.get_environment("HOME")
	_expect(home.is_empty() or not raw.contains(home), label + ": the aggregate does not print the home directory")


func _expect_repeatable(first: Dictionary, second: Dictionary) -> void:
	var left: Array = first.get("results", [])
	var right: Array = second.get("results", [])
	if left.size() != right.size():
		_expect(false, "Repeat run has the same number of worlds")
		return
	for index: int in left.size():
		_expect(_world_signature(left[index]) == _world_signature(right[index]),
			"Repeat run reproduces world %d exactly" % index)


static func _world_signature(entry: Dictionary) -> String:
	return JSON.stringify([
		int(entry.get("seed", 0)),
		entry.get("inventory", {}),
		entry.get("harvested", {}),
		int(entry.get("committed_commands", 0)),
		int(entry.get("committed_sequence", 0)),
		entry.get("next_event_utc", null),
		int(entry.get("segments", 0)),
	])


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		print("FAIL " + message)
