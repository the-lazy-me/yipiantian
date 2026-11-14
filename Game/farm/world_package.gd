extends RefCounted
## 2.0 world package envelope: identity, time, money, versions, snapshot and decorations.
## Pure validation/serialization only. It never reads or writes the live v27
## save path; callers decide whether and where a validated package is stored.

const Farm = preload("res://farm/farm_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const SocialState = preload("res://social/social_state.gd")

const FORMAT: String = "yipiantian.world"
## Version 2 adds the social document. Version 1 packages still parse and are
## upgraded on read, so an existing export is never stranded.
const FORMAT_VERSION: int = 2
const MIN_FORMAT_VERSION: int = 1
# Package snapshots still use the v27 farm schema; reuse the existing version
# constant instead of maintaining a second copy.
const RULES_VERSION: int = FarmStore.VERSION
const MAX_BYTES: int = 1048576
# JSON numbers stay exact only up to this bound.
const MAX_SAFE_INTEGER: int = 9007199254740991
const MAX_IDENTIFIER_LENGTH: int = 64
const MAX_CURRENCY_LENGTH: int = 16
const ENVELOPE_KEYS_V1: Array[String] = [
	"format", "format_version", "rules_version",
	"world_id", "farm_id", "player_id", "device_id",
	"exported_at_utc_seconds", "committed_sequence", "money", "snapshot",
	"decorations",
]
const ENVELOPE_KEYS_V2: Array[String] = [
	"format", "format_version", "rules_version",
	"world_id", "farm_id", "player_id", "device_id",
	"exported_at_utc_seconds", "committed_sequence", "money", "snapshot",
	"decorations", "social",
]
const MONEY_KEYS: Array[String] = ["currency", "minor_units"]


static func parse(text: String) -> Dictionary:
	if text.is_empty():
		return _failure("corrupt")
	if text.to_utf8_buffer().size() > MAX_BYTES:
		return _failure("too_large")
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return _failure("corrupt")
	var result: Dictionary = validate(json.data)
	if not result.ok:
		return result
	return {"ok": true, "kind": "parsed", "package": result.package}


static func serialize(package: Dictionary) -> Dictionary:
	var result: Dictionary = validate(package)
	if not result.ok:
		return result
	return {
		"ok": true,
		"kind": "serialized",
		"text": canonical_text(result.package, true),
		"package": result.package,
	}


static func canonical_text(value: Variant, pretty: bool = false) -> String:
	# JSON.stringify sorts dictionary keys recursively, so input dictionary
	# order cannot change the hash or the emitted bytes.
	return JSON.stringify(value, "\t" if pretty else "", true, false)


static func validate(package: Dictionary) -> Dictionary:
	if package.get("format") != FORMAT:
		return _failure("unknown_format")
	# Godot's JSON parser returns integral numbers as floats, so version and
	# amount checks accept any finite integral number and canonicalize to int.
	var format_version: Variant = package.get("format_version")
	if not _valid_nonnegative_int(format_version):
		return _failure("invalid_format_version")
	var version: int = int(format_version)
	if version < MIN_FORMAT_VERSION:
		return _failure("unsupported_format")
	if version > FORMAT_VERSION:
		return _failure("newer_format")
	# The key set is the version contract: a v1 package has no social document,
	# and a v2 package must carry one.
	if not _has_exact_keys(package, ENVELOPE_KEYS_V1 if version == 1 else ENVELOPE_KEYS_V2):
		return _failure("corrupt")
	var rules_version: Variant = package.rules_version
	if not _valid_nonnegative_int(rules_version):
		return _failure("invalid_rules_version")
	if int(rules_version) < RULES_VERSION:
		return _failure("unsupported_rules")
	if int(rules_version) > RULES_VERSION:
		return _failure("newer_rules")
	for field: String in ["world_id", "farm_id", "player_id", "device_id"]:
		if not valid_identifier(package[field]):
			return _failure("invalid_identifier")
	if not _valid_nonnegative_int(package.exported_at_utc_seconds):
		return _failure("invalid_time")
	if not _valid_nonnegative_int(package.committed_sequence):
		return _failure("invalid_sequence")
	if not _valid_money(package.money):
		return _failure("invalid_money")
	var snapshot: Variant = package.snapshot
	if not snapshot is Dictionary:
		return _failure("invalid_snapshot")
	var farm := Farm.new()
	if not farm.restore_snapshot(snapshot):
		return _failure("invalid_snapshot")
	var decorations_value: Variant = package.decorations
	if not decorations_value is Dictionary:
		return _failure("invalid_decorations")
	var decorations := Decorations.new()
	if not decorations.restore_snapshot(decorations_value):
		return _failure("invalid_decorations")
	var farm_snapshot: Dictionary = farm.snapshot()
	if not Farm.Kitchen.placement_valid(farm_snapshot.kitchen, decorations.snapshot()):
		return _failure("invalid_decorations")
	var social: Dictionary = SocialState.initial_state()
	if version >= 2:
		var social_value: Variant = package.get("social")
		if not social_value is Dictionary or not SocialState.valid(social_value):
			return _failure("invalid_social")
		social = social_value
	return {
		"ok": true,
		"kind": "valid",
		"package": _canonical(package, farm_snapshot, decorations.snapshot(), social),
	}


static func _canonical(package: Dictionary, snapshot: Dictionary, decorations: Dictionary,
		social: Dictionary) -> Dictionary:
	var money: Dictionary = package.money
	return {
		# Reading an older package upgrades it; a canonical package is always
		# emitted in the current version with the social document present.
		"format": FORMAT,
		"format_version": FORMAT_VERSION,
		"rules_version": int(package.rules_version),
		"world_id": package.world_id,
		"farm_id": package.farm_id,
		"player_id": package.player_id,
		"device_id": package.device_id,
		"exported_at_utc_seconds": int(package.exported_at_utc_seconds),
		"committed_sequence": int(package.committed_sequence),
		"money": {
			"currency": money.currency,
			"minor_units": int(money.minor_units),
		},
		"snapshot": snapshot,
		"decorations": decorations,
		"social": SocialState.canonical(social),
	}


static func _has_exact_keys(value: Dictionary, expected: Array[String]) -> bool:
	if value.size() != expected.size():
		return false
	for key: String in expected:
		if not value.has(key):
			return false
	return true


static func valid_identifier(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	if text.is_empty() or text.length() > MAX_IDENTIFIER_LENGTH:
		return false
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		var letter: bool = (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
		var digit: bool = code >= 48 and code <= 57
		if not letter and not digit and code != 95 and code != 45 and code != 46 and code != 58:
			return false
	return true


static func _valid_nonnegative_int(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 and number <= float(MAX_SAFE_INTEGER) and number == floorf(number)


static func _valid_money(value: Variant) -> bool:
	if not value is Dictionary or not _has_exact_keys(value, MONEY_KEYS):
		return false
	var money: Dictionary = value
	if not _valid_currency(money.currency):
		return false
	return _valid_nonnegative_int(money.minor_units)


static func _valid_currency(value: Variant) -> bool:
	if not value is String:
		return false
	var text: String = value
	if text.is_empty() or text.length() > MAX_CURRENCY_LENGTH:
		return false
	for index: int in text.length():
		var code: int = text.unicode_at(index)
		if code < 65 or code > 90:
			return false
	return true


static func _failure(kind: String) -> Dictionary:
	return {"ok": false, "kind": kind}
