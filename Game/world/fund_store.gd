extends RefCounted
## Versioned storage for the world's public fund document. Funds live in their
## own sidecar instead of the v27 farm document: the farm schema has an exact
## key-count contract shared with the importer, while fund membership, keeper
## and spend history are world-level facts with their own lifecycle (M8-04).
##
## The authoritative world is the only writer. A save goes to a pending file, is
## read back and compared, and only then replaces the main document, so a crash
## cannot leave a fund table that was never fully written. A document that
## exists but cannot be validated stops the authority instead of being replaced
## by an empty table.

const PublicFund = preload("res://world/public_fund.gd")

const VERSION: int = 1
const MAX_BYTES: int = 65536
const MAIN: String = "public_funds.json"
const PENDING: String = "public_funds.pending.json"

## 缴入/支出先写农场现金、后写基金文档。农场已提交而进程在第二次写入前退出时，
## 余额总校验会拒绝启动，账本补写路径也走不到。信封层的 `pending` 意图把“这条
## 命令准备付款”的原参数先落盘；启动时按农场账本是否有对应分录决定补写基金
## 文档还是丢弃意图，既不丢失资金，也不二次转账。
const INTENT_ACTION_CONTRIBUTE: String = "contribute"
const INTENT_ACTION_SPEND: String = "spend"
const INTENT_KEYS: Array[String] = [
	"command_id", "action", "actor", "fund_id", "amount", "project_id", "payload", "at_utc",
]
const MAX_INTENT_PAYLOAD_LENGTH: int = 2048
const MAX_INTENT_FIELD_LENGTH: int = 128

var directory: String
var _filesystem: DirAccess


func _init(save_directory: String) -> void:
	directory = ProjectSettings.globalize_path(save_directory).simplify_path()
	var root: String = directory
	while root != root.get_base_dir():
		root = root.get_base_dir()
	_filesystem = DirAccess.open(root)


## Returns {ok, kind, state, pending}. A missing document is a legal empty fund
## table, not a failure: a world that has never opened a fund simply has none.
func load_state() -> Dictionary:
	if not _safe_paths():
		return _failure("unsafe_path")
	var path: String = _path(MAIN)
	if not FileAccess.file_exists(path):
		var fresh: Dictionary = PublicFund.empty()
		if not PublicFund.valid(fresh):
			return _failure("invalid_state")
		return {"ok": true, "kind": "missing", "state": fresh, "pending": {}}
	var read: Dictionary = _read(path)
	if not read.ok:
		return read
	if int(read.document.get("version", -1)) != VERSION:
		return _failure("unsupported")
	var state: Variant = read.document.get("state")
	if not state is Dictionary or not PublicFund.valid(state):
		return _failure("corrupt")
	var pending: Variant = read.document.get("pending", {})
	if not valid_pending(pending):
		return _failure("corrupt")
	return {"ok": true, "kind": "loaded", "state": PublicFund.normalize(state),
		"pending": pending}


## Saves only a document that passes the same validation a load performs, so a
## caller cannot write a fund table the next load will refuse. A non-empty
## `pending` intent rides in the same envelope atomically with `state`.
func save_state(state: Dictionary, pending: Dictionary = {}) -> Dictionary:
	if not PublicFund.valid(state) or not valid_pending(pending):
		return _failure("invalid_state")
	if not _safe_paths():
		return _failure("unsafe_path")
	var create_error: Error = OK if _filesystem.dir_exists(directory) \
		else _filesystem.make_dir_recursive(directory)
	if create_error != OK:
		return _failure("create_directory", create_error)
	var text: String = _document_text(state, pending)
	if text.to_utf8_buffer().size() > MAX_BYTES:
		return _failure("too_large")
	var staged: Dictionary = _write_verified(_path(PENDING), text)
	if not staged.ok:
		return staged
	var replace_error: Error = _filesystem.rename(_path(PENDING), _path(MAIN))
	if replace_error != OK:
		return _failure("replace_main", replace_error)
	return {"ok": true, "kind": "saved"}


## 写盘前的容量预判。农场提交不可回退，基金文档若因上限写不下，余额会永久停在
## 半提交状态；调用方必须先问这里，再动农场现金。
static func fits(state: Dictionary, pending: Dictionary = {}) -> bool:
	if not PublicFund.valid(state) or not valid_pending(pending):
		return false
	return _document_text(state, pending).to_utf8_buffer().size() <= MAX_BYTES


static func valid_pending(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	if value.is_empty():
		return true
	var intent: Dictionary = value
	if intent.size() != INTENT_KEYS.size():
		return false
	for key: String in INTENT_KEYS:
		if not intent.has(key):
			return false
	var command_id: Variant = intent.get("command_id")
	if not command_id is String or str(command_id).is_empty() \
			or str(command_id).length() > MAX_INTENT_FIELD_LENGTH:
		return false
	var action: Variant = intent.get("action")
	if action != INTENT_ACTION_CONTRIBUTE and action != INTENT_ACTION_SPEND:
		return false
	var actor: Variant = intent.get("actor")
	if not actor is String or str(actor).is_empty() \
			or str(actor).length() > MAX_INTENT_FIELD_LENGTH:
		return false
	var fund_id: Variant = intent.get("fund_id")
	if not fund_id is String or str(fund_id).is_empty() \
			or str(fund_id).length() > MAX_INTENT_FIELD_LENGTH:
		return false
	var amount: Variant = intent.get("amount")
	if not (amount is int or amount is float):
		return false
	var number: float = float(amount)
	if not is_finite(number) or number != floorf(number) or number <= 0.0:
		return false
	var project: Variant = intent.get("project_id")
	if not project is String or str(project).length() > MAX_INTENT_FIELD_LENGTH:
		return false
	var payload: Variant = intent.get("payload")
	if not payload is String or str(payload).is_empty() \
			or str(payload).length() > MAX_INTENT_PAYLOAD_LENGTH:
		return false
	var at_utc: Variant = intent.get("at_utc")
	if not (at_utc is int or at_utc is float) or not is_finite(float(at_utc)) \
			or float(at_utc) < 0.0:
		return false
	return true


static func _document_text(state: Dictionary, pending: Dictionary = {}) -> String:
	var document: Dictionary = {"version": VERSION, "state": state}
	if not pending.is_empty():
		document["pending"] = pending
	return JSON.stringify(document, "\t")


func _write_verified(path: String, text: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _failure("io")
	file.store_string(text)
	file.flush()
	var error: Error = file.get_error()
	file.close()
	if error != OK:
		return _failure("io", error)
	if FileAccess.get_file_as_string(path) != text:
		return _failure("verify")
	return {"ok": true, "kind": "written"}


func _read(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _failure("io")
	var length: int = file.get_length()
	if length <= 0 or length > MAX_BYTES:
		file.close()
		return _failure("corrupt")
	var text: String = file.get_as_text()
	var read_error: Error = file.get_error()
	file.close()
	if read_error != OK and read_error != ERR_FILE_EOF:
		return _failure("io")
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return _failure("corrupt")
	return {"ok": true, "kind": "read", "document": json.data}


func _safe_paths() -> bool:
	# An absolute path below a real parent; a missing directory is legal because
	# save_state creates it. No ancestor or sidecar may be a symbolic link: the
	# pending write must never follow one to another file.
	if not directory.is_absolute_path() or directory.get_base_dir() == directory \
			or _filesystem == null:
		return false
	var cursor: String = directory
	while cursor != cursor.get_base_dir():
		if _filesystem.is_link(cursor):
			return false
		cursor = cursor.get_base_dir()
	if not _filesystem.dir_exists(directory):
		return not FileAccess.file_exists(directory)
	return not _filesystem.is_link(_path(MAIN)) \
		and not _filesystem.is_link(_path(PENDING))


func _path(filename: String) -> String:
	return directory.path_join(filename)


static func _failure(kind: String, error: Error = OK) -> Dictionary:
	var result: Dictionary = {"ok": false, "kind": kind}
	if error != OK:
		result["error"] = error
	return result
