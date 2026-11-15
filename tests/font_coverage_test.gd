extends SceneTree
## UI font fixture: every non-ASCII character in shipped Game text resources must
## have a glyph in the bundled Huiwen Mincho subset, so mixed words never fall
## back to a system font. Directories named `.godot` are skipped.

const FONT_PATH: String = "res://art/ui/fonts/汇文明朝体.ttf"
const TEXT_EXTENSIONS: Array[String] = [
	"gd", "tscn", "tres", "json", "godot", "csv", "txt", "md",
]

var checks: int = 0
var failures: int = 0
var missing: Array[String] = []
var files: int = 0
var _codepoints: Dictionary = {}
var _read_errors: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var font := FontFile.new()
	var load_error: Error = font.load_dynamic_font(FONT_PATH)
	if load_error != OK:
		failures += 1
		push_error("FontFile.load_dynamic_font(%s): %s" % [FONT_PATH, error_string(load_error)])
	else:
		_scan("res://")
		var codepoints: Array = _codepoints.keys()
		codepoints.sort()
		for codepoint: int in codepoints:
			if codepoint <= 127:
				continue
			checks += 1
			if not font.has_char(codepoint):
				failures += 1
				missing.append("%s(U+%04X)" % [String.chr(codepoint), codepoint])
	for path: String in _read_errors:
		failures += 1
		push_error("unreadable text resource: " + path)
	for failure: String in missing:
		push_error("missing glyph: " + failure)
	print("FONT_COVERAGE_TEST checks=%d failures=%d missing=%d" % [
		checks, failures, missing.size(),
	])
	quit(0 if failures == 0 else 1)


func _scan(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		_read_errors.append(dir_path)
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		var path: String = dir_path.path_join(entry)
		if dir.current_is_dir():
			if entry != ".godot" and not entry.begins_with("."):
				_scan(path)
		elif TEXT_EXTENSIONS.has(entry.get_extension()):
			files += 1
			var file := FileAccess.open(path, FileAccess.READ)
			if file == null:
				_read_errors.append(path)
			else:
				var text: String = file.get_as_text()
				for index: int in text.length():
					_codepoints[text.unicode_at(index)] = true
		entry = dir.get_next()
	dir.list_dir_end()
