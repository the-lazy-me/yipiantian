extends RefCounted
## M10-01 stable resident personality baseline. Pure rules: no RNG, clock, disk,
## scene or network access.
##
## Five fixed dimensions are derived from `npc_id` + `world_seed` with an FNV-1a
## hash of the exact strings. The same pair always yields the same integers;
## another world seed may yield a different profile. Nothing here stores the
## result, so a reload cannot silently reroll a resident's character.
##
## The values are preferences only. They never grant resources, permissions or
## narrative facts; M10-01 consumes them as rule-layer weights.

const OwnerIds = preload("res://farm/owner_id.gd")

const DILIGENCE: String = "diligence"
const WARMTH: String = "warmth"
const SUSPICION: String = "suspicion"
const CURIOSITY: String = "curiosity"
const GENEROSITY: String = "generosity"

const TRAITS: Array[String] = [DILIGENCE, WARMTH, SUSPICION, CURIOSITY, GENEROSITY]
const LABELS: Dictionary = {
	DILIGENCE: "勤勉",
	WARMTH: "温和",
	SUSPICION: "多疑",
	CURIOSITY: "好奇",
	GENEROSITY: "慷慨",
}

const MIN_VALUE: int = 0
const MAX_VALUE: int = 100
const VALUE_COUNT: int = 101
const MAX_SAFE_INTEGER: int = 9007199254740991
const HASH_OFFSET: int = 2166136261
const HASH_PRIME: int = 16777619
const HASH_MASK: int = 0xFFFFFFFF


## Deterministic profile. `world_seed` is a non-negative safe integer; the
## caller passes a float only when it came back from JSON normalization.
static func traits(npc_id: Variant, world_seed: Variant) -> Dictionary:
	if not OwnerIds.valid(npc_id):
		return {"ok": false, "reason": "invalid_npc_id", "traits": {}}
	if not _valid_seed(world_seed):
		return {"ok": false, "reason": "invalid_seed", "traits": {}}
	var seed_value: int = int(world_seed)
	var values: Dictionary = {}
	for index: int in TRAITS.size():
		var trait_name: String = TRAITS[index]
		var digest: int = _hash([
			"npc_personality_v1", str(seed_value), str(npc_id), trait_name, str(index),
		])
		values[trait_name] = digest % VALUE_COUNT
	return {
		"ok": true, "reason": "", "npc_id": str(npc_id),
		"world_seed": seed_value, "traits": values,
	}


## Strict shape check for a profile returned by `traits()`. Exactly five known
## integer dimensions in 0..100; floats, unknown keys and missing keys are
## refused so a malformed profile cannot steer rule weights.
static func valid(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var profile: Dictionary = value
	if profile.size() != TRAITS.size():
		return false
	for trait_name: String in TRAITS:
		if not profile.has(trait_name):
			return false
		var amount: Variant = profile[trait_name]
		if not amount is int:
			return false
		if int(amount) < MIN_VALUE or int(amount) > MAX_VALUE:
			return false
	return true


## Short Chinese reading of a valid profile. The text is deterministic and
## display-only; callers must not parse it back into rules.
static func describe(value: Variant) -> Dictionary:
	if not valid(value):
		return {"ok": false, "reason": "invalid_traits", "text": ""}
	var profile: Dictionary = value
	var readings: Array[String] = []
	for trait_name: String in TRAITS:
		readings.append("%s%d" % [str(LABELS[trait_name]), int(profile[trait_name])])
	var phrases: Array[String] = [
		_band(int(profile[DILIGENCE]), "勤勉", "疏懒", "作息平常"),
		_band(int(profile[WARMTH]), "温和", "冷淡", "待人平常"),
		_band(int(profile[SUSPICION]), "多疑", "信任他人", "谨慎"),
		_band(int(profile[CURIOSITY]), "好奇", "安于旧例", "偶尔尝试"),
		_band(int(profile[GENEROSITY]), "慷慨", "惜物", "量入为出"),
	]
	return {
		"ok": true, "reason": "",
		"text": "、".join(readings) + "。" + "，".join(phrases) + "。",
	}


static func _band(value: int, high: String, low: String, middle: String) -> String:
	if value >= 67:
		return high
	if value <= 33:
		return low
	return middle


static func _valid_seed(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number >= 0.0 and number <= float(MAX_SAFE_INTEGER) \
		and number == floorf(number)


## FNV-1a over the UTF-8 bytes of every part, with a separator round so
## ("ab","c") and ("a","bc") cannot meet. Masking every step keeps the value in
## 32 bits and makes the result independent of platform word width.
static func _hash(parts: Array[String]) -> int:
	var digest: int = HASH_OFFSET
	for part: String in parts:
		for byte: int in part.to_utf8_buffer():
			digest = (digest ^ byte) & HASH_MASK
			digest = (digest * HASH_PRIME) & HASH_MASK
		digest = (digest ^ 0xFF) & HASH_MASK
		digest = (digest * HASH_PRIME) & HASH_MASK
	return digest
