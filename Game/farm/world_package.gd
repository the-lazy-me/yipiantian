extends RefCounted
## 2.0 world package envelope: identity, time, money, versions, snapshot and decorations.
## Pure validation/serialization only. It never reads or writes the live v27
## save path; callers decide whether and where a validated package is stored.

const Farm = preload("res://farm/farm_state.gd")
const FarmStore = preload("res://farm/farm_store.gd")
const Decorations = preload("res://farm/decoration_state.gd")
const SocialState = preload("res://social/social_state.gd")
const NatureState = preload("res://farm/nature_state.gd")
const TerritoryState = preload("res://world/territory_state.gd")
const TerritoryStore = preload("res://world/territory_store.gd")
const OrganizationState = preload("res://world/organization_state.gd")
const OrganizationStore = preload("res://world/organization_store.gd")
const PublicFund = preload("res://world/public_fund.gd")
const FundStore = preload("res://world/fund_store.gd")
const PublicWorks = preload("res://world/public_works.gd")
const PublicWorksStore = preload("res://world/public_works_store.gd")
const UnitState = preload("res://conflict/unit_state.gd")
const UnitStore = preload("res://world/unit_store.gd")
const ParticipationState = preload("res://conflict/participation_state.gd")
const ParticipationStore = preload("res://world/participation_store.gd")
const ConflictSettlement = preload("res://world/conflict_settlement.gd")
const DisputeState = preload("res://world/dispute_state.gd")
const IntentState = preload("res://npc/npc_intent_state.gd")
const Memory = preload("res://npc/npc_memory.gd")
const NpcIntentStore = preload("res://npc/npc_intent_store.gd")
const ResolutionState = preload("res://world/resolution_state.gd")
# These stores own the authoritative envelope validation of the sidecars, so the
# package validates the same shape here instead of maintaining a second copy.
const ConflictStore = preload("res://world/conflict_store.gd")
const DisputesStore = preload("res://world/disputes_store.gd")
const ResidentsStore = preload("res://world/residents_store.gd")
const ResolutionsStore = preload("res://world/resolutions_store.gd")
const ResolutionEffects = preload("res://world/resolution_effects.gd")
const ResolutionEffectsStore = preload("res://world/resolution_effects_store.gd")

const FORMAT: String = "yipiantian.world"
## Version 2 adds the social document; version 3 carries the natural state
## (`seed`, `rules_version`) so a world moved to another machine keeps its
## weather history. Version 4 adds the `sidecars` document: the world-level
## documents that already live beside the farm save (cadastre, organizations,
## funds, public works, units, participation, conflicts, disputes, residents,
## resident intents, resolutions and their effects). Older packages still parse
## and are upgraded on read, so an existing export is never stranded: a package
## without the natural document uses the same fixed default seed a missing
## `nature.json` uses, and a package without `sidecars` means "this world had
## none".
const FORMAT_VERSION: int = 4
const MIN_FORMAT_VERSION: int = 1
# Package snapshots still use the v27 farm schema; reuse the existing version
# constant instead of maintaining a second copy.
const RULES_VERSION: int = FarmStore.VERSION
# A package carries the farm snapshot, decorations, social, nature and the
# sidecar documents. The largest legal documents are social (8 MiB), farm
# (2 MiB), conflicts (1 MiB), territory/residents (256 KiB each) and nine more
# 64 KiB documents, which totals about 12 MiB. The envelope gets 16 MiB so an
# export the save path accepts is never rejected here, while the bound stays a
# single constant checked before parsing.
const MAX_BYTES: int = 16777216
## The per-file byte caps mirror the owning store's read limit, so a package
## never carries a document the store would refuse as `too_large`. Every value
## is a bounded constant; the strictest is 64 KiB and the loosest 1 MiB.
static func sidecar_limit(name: String) -> int:
	match name:
		"territory.json":
			return TerritoryStore.MAX_BYTES
		"organizations.json":
			return OrganizationStore.MAX_BYTES
		"public_funds.json":
			return FundStore.MAX_BYTES
		"public_works.json":
			return PublicWorksStore.MAX_BYTES
		"units.json":
			return UnitStore.MAX_BYTES
		"participation.json":
			return ParticipationStore.MAX_BYTES
		"conflicts.json":
			return ConflictStore.MAX_BYTES
		"disputes.json":
			return DisputesStore.MAX_BYTES
		"residents.json":
			return ResidentsStore.MAX_BYTES
		"npc_intents.json":
			return NpcIntentStore.MAX_BYTES
		"resolutions.json":
			return ResolutionsStore.MAX_BYTES
		"resolution_effects.json":
			return ResolutionEffectsStore.MAX_BYTES
	return 0


## The envelope version is the owning store's own `VERSION`, so a store that
## bumps its format cannot be carried under an older package shape by accident.
static func sidecar_version(name: String) -> int:
	match name:
		"territory.json":
			return TerritoryStore.VERSION
		"organizations.json":
			return OrganizationStore.VERSION
		"public_funds.json":
			return FundStore.VERSION
		"public_works.json":
			return PublicWorksStore.VERSION
		"units.json":
			return UnitStore.VERSION
		"participation.json":
			return ParticipationStore.VERSION
		"conflicts.json":
			return ConflictStore.VERSION
		"disputes.json":
			return DisputesStore.VERSION
		"residents.json":
			return ResidentsStore.VERSION
		"npc_intents.json":
			return NpcIntentStore.VERSION
		"resolutions.json":
			return ResolutionsStore.VERSION
		"resolution_effects.json":
			return ResolutionEffectsStore.VERSION
	return 0
## The strict filename whitelist of the `sidecars` document. A file that is not
## in this list is never exported and is refused on import.
const SIDECAR_FILES: Array[String] = [
	"territory.json", "organizations.json", "public_funds.json",
	"public_works.json", "units.json", "participation.json", "conflicts.json",
	"disputes.json", "residents.json", "npc_intents.json", "resolutions.json",
	"resolution_effects.json",
]
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
const ENVELOPE_KEYS_V3: Array[String] = [
	"format", "format_version", "rules_version",
	"world_id", "farm_id", "player_id", "device_id",
	"exported_at_utc_seconds", "committed_sequence", "money", "snapshot",
	"decorations", "social", "nature",
]
const ENVELOPE_KEYS_V4: Array[String] = [
	"format", "format_version", "rules_version",
	"world_id", "farm_id", "player_id", "device_id",
	"exported_at_utc_seconds", "committed_sequence", "money", "snapshot",
	"decorations", "social", "nature", "sidecars",
]
## Sidecar documents whose state names the world. The other whitelisted files
## carry no world identity at all, so they can only be checked structurally.
const SIDECAR_STATE_WORLD_FILES: Array[String] = [
	"territory.json", "units.json", "participation.json", "conflicts.json",
]
## Sidecar documents whose world identity is the envelope's `world_id`.
const SIDECAR_ENVELOPE_WORLD_FILES: Array[String] = [
	"disputes.json", "residents.json", "resolutions.json",
	"resolution_effects.json",
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
	var text: String = canonical_text(result.package, true)
	# A package the reader would reject as `too_large` must never be written, so
	# the writer checks the same bound the reader does.
	if text.to_utf8_buffer().size() > MAX_BYTES:
		return _failure("too_large")
	return {
		"ok": true,
		"kind": "serialized",
		"text": text,
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
	# a v2 package has no natural state, a v3 package must carry both, and a v4
	# package must also carry the sidecar dictionary. A v4 package without the
	# dictionary is corrupt, but an older version is never read as carrying one:
	# the absence of the key means "this world had no sidecar files", which is a
	# fact this parser preserves instead of inventing empty documents.
	var expected_keys: Array[String] = ENVELOPE_KEYS_V1
	if version == 2:
		expected_keys = ENVELOPE_KEYS_V2
	elif version == 3:
		expected_keys = ENVELOPE_KEYS_V3
	elif version == 4:
		expected_keys = ENVELOPE_KEYS_V4
	if not _has_exact_keys(package, expected_keys):
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
	# A package that predates the natural document upgrades to the same fixed
	# default seed a missing nature.json uses; it is never resampled.
	var nature: Dictionary = NatureState.default_snapshot()
	if version >= 3:
		var nature_value: Variant = package.get("nature")
		var nature_state := NatureState.new()
		if not nature_value is Dictionary or not nature_state.restore_snapshot(nature_value):
			return _failure("invalid_nature")
		nature = nature_state.snapshot()
	# A package that predates the sidecar document upgrades to "this world had no
	# world-level sidecars"; it is never turned into a fresh empty one, because a
	# missing file and an empty file are different facts on disk.
	var sidecars: Dictionary = {}
	if version >= 4:
		var sidecars_result: Dictionary = validate_sidecars(package.get("sidecars"), str(package.world_id))
		if not sidecars_result.ok:
			return sidecars_result
		sidecars = sidecars_result.sidecars
	return {
		"ok": true,
		"kind": "valid",
		"package": _canonical(package, farm_snapshot, decorations.snapshot(), social, nature, sidecars),
	}


static func _canonical(package: Dictionary, snapshot: Dictionary, decorations: Dictionary,
		social: Dictionary, nature: Dictionary, sidecars: Dictionary) -> Dictionary:
	var money: Dictionary = package.money
	return {
		# Reading an older package upgrades it; a canonical package is always
		# emitted in the current version with the social, natural and sidecar
		# documents.
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
		"nature": nature,
		"sidecars": sidecars,
	}


## The sidecar dictionary is keyed by the exact file name on disk. Only files
## that already exist in the live save may appear; an absent file stays absent
## instead of becoming an empty document, because "no cadastre yet" and "an
## empty cadastre" are different facts.
static func validate_sidecars(value: Variant, world_id: String) -> Dictionary:
	if not value is Dictionary:
		return _failure("invalid_sidecars")
	var documents: Dictionary = value
	var checked_documents: Dictionary = {}
	for name_value: Variant in documents:
		if not name_value is String or not str(name_value) in SIDECAR_FILES:
			return _failure("unknown_sidecar")
		var name: String = str(name_value)
		var document_value: Variant = documents[name_value]
		if not document_value is Dictionary:
			return _sidecar_failure("invalid_sidecar", name)
		# The per-document cap is checked before shape validation so an overlong
		# document is named as such instead of being reported as a shape error.
		var document: Dictionary = document_value
		var limit: int = sidecar_limit(name)
		if limit <= 0:
			return _sidecar_failure("unknown_sidecar", name)
		if canonical_text(document, true).to_utf8_buffer().size() > limit:
			return _sidecar_failure("sidecar_too_large", name)
		var checked: Dictionary = _validate_sidecar_document(name, document, world_id)
		if not checked.ok:
			return _sidecar_failure(str(checked.kind), name)
		checked_documents[name] = checked.document
	# 效果文档必须与同包的决议文档一致。`_validate_sidecar_document()` 一次只看
	# 一份文档，所以交叉检查只能放在循环之后；缺任一份时不检查，因为“没有效果”
	# 和“没有决议”都是合法事实，由各自的存在性表达。
	if checked_documents.has("resolution_effects.json") \
			and checked_documents.has("resolutions.json"):
		var effects_state: Variant = checked_documents["resolution_effects.json"].get("state")
		var resolutions_state: Variant = checked_documents["resolutions.json"].get("state")
		if not effects_state is Dictionary or not resolutions_state is Dictionary \
				or not ResolutionEffects.consistent(effects_state, resolutions_state):
			return _sidecar_failure("invalid_sidecar", "resolution_effects.json")
	return {"ok": true, "sidecars": checked_documents}


## The single world identity the sidecar documents name, or an empty string
## when none of them carries one. Documents that name different worlds are a
## failure: a package must never merge two worlds into one.
static func sidecar_world(documents: Dictionary) -> Dictionary:
	var world: String = ""
	for name: String in SIDECAR_FILES:
		if not documents.has(name):
			continue
		var document: Variant = documents[name]
		if not document is Dictionary:
			return _sidecar_failure("invalid_sidecar", name)
		var candidate: Variant = null
		if name in SIDECAR_STATE_WORLD_FILES:
			var state: Variant = (document as Dictionary).get("state")
			if not state is Dictionary:
				return _sidecar_failure("invalid_sidecar", name)
			candidate = (state as Dictionary).get("world_id")
		elif name in SIDECAR_ENVELOPE_WORLD_FILES:
			candidate = (document as Dictionary).get("world_id")
		else:
			continue
		if not candidate is String or str(candidate).is_empty():
			return _sidecar_failure("invalid_sidecar", name)
		if world.is_empty():
			world = str(candidate)
		elif world != str(candidate):
			return _sidecar_failure("sidecar_world_mismatch", name)
	return {"ok": true, "world_id": world}


## Shape checks mirror each store's load path: the same envelope keys and
## version, the same state rule validator, and the same world identity. Journal
## entries (`commands`, `applied`, `enforcement`, `invitations`) are checked with
## the owning store's own validators when it has one, so this layer never
## invents a second copy of those rules.
static func _validate_sidecar_document(name: String, document: Dictionary, world_id: String) -> Dictionary:
	var version_key: Variant = document.get("version")
	if not _valid_nonnegative_int(version_key):
		return _failure("invalid_sidecar")
	if int(version_key) != sidecar_version(name):
		return _failure("unsupported_sidecar")
	match name:
		"territory.json":
			var checked: Dictionary = _state_envelope(document, TerritoryState.valid)
			if not checked.ok:
				return checked
			var world_check: Dictionary = _check_sidecar_world(checked.state, world_id)
			if not world_check.ok:
				return world_check
		"organizations.json":
			var checked: Dictionary = _state_envelope(document, OrganizationState.valid)
			if not checked.ok:
				return checked
		"public_funds.json":
			var checked: Dictionary = _state_envelope(document, PublicFund.valid)
			if not checked.ok:
				return checked
		"public_works.json":
			var checked: Dictionary = _state_envelope(document, PublicWorks.valid)
			if not checked.ok:
				return checked
		"units.json":
			var checked: Dictionary = _state_envelope(document, UnitState.valid)
			if not checked.ok:
				return checked
			var world_check: Dictionary = _check_sidecar_world(checked.state, world_id)
			if not world_check.ok:
				return world_check
		"participation.json":
			var checked: Dictionary = _state_envelope(document, ParticipationState.valid)
			if not checked.ok:
				return checked
			var world_check: Dictionary = _check_sidecar_world(checked.state, world_id)
			if not world_check.ok:
				return world_check
		"conflicts.json":
			if not _has_keys_subset(document,
					["version", "state", "applied", "voided"]):
				return _failure("invalid_sidecar")
			var checked: Dictionary = _state_envelope(document, ConflictSettlement.valid_context,
				["version", "state", "applied", "voided"])
			if not checked.ok:
				return checked
			var applied_value: Variant = document.get("applied", {})
			if not applied_value is Dictionary \
					or not ConflictStore._valid_applied(applied_value, checked.state.get("consumed", {})):
				return _failure("invalid_sidecar")
			if not ConflictStore._valid_voided(document.get("voided", [])):
				return _failure("invalid_sidecar")
			var world_check: Dictionary = _check_sidecar_world(checked.state, world_id)
			if not world_check.ok:
				return world_check
		"disputes.json":
			if not _has_keys_subset(document, ["version", "world_id", "state", "commands", "enforcement"]):
				return _failure("invalid_sidecar")
			var checked: Dictionary = _state_envelope(document, DisputeState.valid,
				["version", "world_id", "state", "commands", "enforcement"])
			if not checked.ok:
				return checked
			if not DisputesStore._valid_commands(document.get("commands", [])) \
					or not DisputesStore._valid_enforcement(
						document.get("enforcement", {}), checked.state):
				return _failure("invalid_sidecar")
			var world_check: Dictionary = _check_sidecar_text_world(document.get("world_id"), world_id)
			if not world_check.ok:
				return world_check
		"residents.json":
			# The store accepts three envelopes: four keys (before invitations),
			# five keys (before dialogues) and the current six. Any other key set
			# is corrupt. The state shape follows the same rule.
			if not ResidentsStore._envelope_keys_valid(document):
				return _failure("invalid_sidecar")
			var world_check: Dictionary = _check_sidecar_text_world(document.get("world_id"), world_id)
			if not world_check.ok:
				return world_check
			# A package is a frozen document, so memory entries are validated at
			# the latest representable time: no entry is "in the future" relative
			# to the package itself. `from_document` is the store's own read path.
			var memories: Dictionary = Memory.from_document(
				document.get("memories"), float(MAX_SAFE_INTEGER))
			if not memories.ok or str(memories.document.get("world_id", "")) != world_id:
				return _failure("invalid_sidecar")
			var state_value: Dictionary = {
				"social": document.get("social"),
				"memories": document.get("memories"),
				"invitations": document.get("invitations", {}),
			}
			if document.has("dialogues"):
				state_value["dialogues"] = document.get("dialogues")
			if not ResidentsStore.valid_state(state_value, world_id, float(MAX_SAFE_INTEGER)):
				return _failure("invalid_sidecar")
		"npc_intents.json":
			var checked: Dictionary = _state_envelope(document, IntentState.valid)
			if not checked.ok:
				return checked
		"resolutions.json":
			# The resolution store requires exactly these four envelope keys.
			if not _has_exact_keys(document, ["version", "world_id", "state", "commands"]):
				return _failure("invalid_sidecar")
			var checked: Dictionary = _state_envelope(document, ResolutionState.valid,
				["version", "world_id", "state", "commands"])
			if not checked.ok:
				return checked
			if not ResolutionsStore._valid_commands(document.get("commands")):
				return _failure("invalid_sidecar")
			var world_check: Dictionary = _check_sidecar_text_world(document.get("world_id"), world_id)
			if not world_check.ok:
				return world_check
		"resolution_effects.json":
			# The effect store requires exactly three envelope keys.
			if not _has_exact_keys(document, ["version", "world_id", "state"]):
				return _failure("invalid_sidecar")
			var checked: Dictionary = _state_envelope(document, ResolutionEffects.valid,
				["version", "world_id", "state"])
			if not checked.ok:
				return checked
			var world_check: Dictionary = _check_sidecar_text_world(document.get("world_id"), world_id)
			if not world_check.ok:
				return world_check
		_:
			return _failure("unknown_sidecar")
	return {"ok": true, "document": document}


static func _state_envelope(document: Dictionary, validator: Callable,
		allowed_keys: Array[String] = ["version", "state"]) -> Dictionary:
	if not _has_keys_subset(document, allowed_keys):
		return _failure("invalid_sidecar")
	var state: Variant = document.get("state")
	if not state is Dictionary or not validator.call(state):
		return _failure("invalid_sidecar")
	return {"ok": true, "state": state}


static func _check_sidecar_world(state: Dictionary, world_id: String) -> Dictionary:
	return _check_sidecar_text_world(state.get("world_id"), world_id)


static func _check_sidecar_text_world(value: Variant, world_id: String) -> Dictionary:
	if not value is String or str(value) != world_id:
		return _failure("sidecar_world_mismatch")
	return {"ok": true}


static func _has_keys_subset(value: Dictionary, allowed: Array[String]) -> bool:
	for key: Variant in value:
		if not key is String or not str(key) in allowed:
			return false
	return true


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
		# `:` is legal in a package identifier but not in a Windows file name,
		# and the id becomes part of the world backup directory name.
		if not letter and not digit and code != 95 and code != 45 and code != 46:
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


static func _sidecar_failure(kind: String, name: String) -> Dictionary:
	return {"ok": false, "kind": kind, "sidecar": name}
