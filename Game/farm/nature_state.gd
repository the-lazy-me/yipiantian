extends RefCounted
## Deterministic natural-time rules. No scene, clock, disk or network access.
##
## One UTC instant is the only authority. Three interpretations are derived
## from it and never become separate clocks:
## - daylight: a fixed 24 hour civil cycle, with 06:00-18:00 UTC treated as day.
##   No location, system timezone or real weather service is consulted; the
##   window is a world convention, not local solar time.
## - agricultural time: the existing growth clock, which is 1:1 with UTC in
##   this slice. It is named here so a day/night or season change cannot be
##   mistaken for a second growth clock.
## - season: a fixed-length label cycle. Its length is an M6 experiment knob,
##   not a growth modifier yet.
##
## Weather blocks tile the timeline with equal length. Each block's kind comes
## from a stable hash of the persisted seed and the block index, so a reload
## derives the same event instead of sampling a new one. A save without a seed
## document uses DEFAULT_SEED, which keeps old development saves deterministic
## until the seed is written on the next save.

const RULES_VERSION: int = 1
# JSON numbers remain exact only up to this bound.
const MAX_SEED: int = 9007199254740991
const DEFAULT_SEED: int = 20261115
const DAY_SECONDS: float = 86400.0
const DAY_START_SECONDS: float = 6.0 * 3600.0
const NIGHT_START_SECONDS: float = 18.0 * 3600.0
# Four weather blocks per real day; the boundary coincides with UTC midnight.
const WEATHER_SECONDS: float = 6.0 * 3600.0
# Experimental agricultural season length: four one-week seasons per cycle.
const SEASON_DAYS: int = 7
const SEASON_SECONDS: float = float(SEASON_DAYS) * DAY_SECONDS
const SEASON_IDS: Array[String] = ["spring", "summer", "autumn", "winter"]
# M6-02 will consume rain; disasters remain out of scope for M6-01.
const WEATHER_KINDS: Array[String] = ["clear", "cloudy", "rain"]

var _seed: int = DEFAULT_SEED


func _init(initial_seed: int = DEFAULT_SEED) -> void:
	assert(valid_seed(initial_seed), "Nature requires an exact nonnegative seed")
	_seed = initial_seed


func get_seed() -> int:
	return _seed


func snapshot() -> Dictionary:
	return {"seed": _seed, "rules_version": RULES_VERSION}


func restore_snapshot(data: Dictionary) -> bool:
	# Exact shape: the seed and the rules version are the whole persisted state.
	# A future rules version is refused instead of silently deriving different
	# history from the same seed.
	if data.size() != 2 or not data.has("seed") or not data.has("rules_version"):
		return false
	if not valid_seed(data.seed) or not _integral(data.rules_version):
		return false
	if int(data.rules_version) != RULES_VERSION:
		return false
	_seed = int(data.seed)
	return true


static func default_snapshot() -> Dictionary:
	return {"seed": DEFAULT_SEED, "rules_version": RULES_VERSION}


static func create_seed() -> int:
	# 7 bytes carry enough entropy for 53 exact JSON bits; zero is a legal seed.
	var bytes: PackedByteArray = Crypto.new().generate_random_bytes(7)
	var value: int = 0
	for byte: int in bytes:
		value = (value << 8) | byte
	return value & 0x1FFFFFFFFFFFFF


## The weather block covering `utc_seconds`. Returns {} for invalid input.
func weather_at(utc_seconds: float) -> Dictionary:
	if not valid_time(utc_seconds):
		return {}
	var index: int = int(floorf(utc_seconds / WEATHER_SECONDS))
	var start: float = float(index) * WEATHER_SECONDS
	return {
		"index": index,
		"kind": _weather_kind(index),
		"start_utc": start,
		"end_utc": start + WEATHER_SECONDS,
	}


## Start of the block after the one covering `utc_seconds`; INF when invalid.
## The end instant of a block already belongs to the next block, so at a
## boundary this returns the end of the new block.
func next_weather_at(utc_seconds: float) -> float:
	var weather: Dictionary = weather_at(utc_seconds)
	if weather.is_empty():
		return INF
	return float(weather.end_utc)


## The real 24 hour cycle at this instant: day starts at 06:00 UTC and night
## at 18:00 UTC. Returns {} for invalid input.
func daylight_at(utc_seconds: float) -> Dictionary:
	if not valid_time(utc_seconds):
		return {}
	var day_index: int = int(floorf(utc_seconds / DAY_SECONDS))
	var second_of_day: float = utc_seconds - float(day_index) * DAY_SECONDS
	var is_daylight: bool = second_of_day >= DAY_START_SECONDS and second_of_day < NIGHT_START_SECONDS
	return {
		"day_index": day_index,
		"second_of_day": second_of_day,
		"is_daylight": is_daylight,
		"phase": "day" if is_daylight else "night",
	}


## The existing growth clock is 1:1 with UTC, so its day is the UTC day.
## Returns -1 for invalid input.
func agricultural_day_at(utc_seconds: float) -> int:
	if not valid_time(utc_seconds):
		return -1
	return int(floorf(utc_seconds / DAY_SECONDS))


## Fixed-length season label at this instant. Returns {} for invalid input.
func season_at(utc_seconds: float) -> Dictionary:
	if not valid_time(utc_seconds):
		return {}
	var season_index: int = int(floorf(utc_seconds / SEASON_SECONDS))
	var cycle: int = season_index % SEASON_IDS.size()
	var day_index: int = int(floorf(utc_seconds / DAY_SECONDS))
	return {
		"id": SEASON_IDS[cycle],
		"index": cycle,
		"season_index": season_index,
		"day_in_season": day_index - season_index * SEASON_DAYS,
	}


func _weather_kind(index: int) -> String:
	# A small fixed LCG keeps derivation identical across processes and engines
	# without relying on Variant hashing. All intermediate values stay below
	# 2**63, so no platform-dependent overflow is involved.
	var value: int = (index + 1) & 0xFFFFFFFF
	value = (value * 1103515245 + 12345) & 0x7FFFFFFF
	value = (value * 1103515245 + 12345) & 0x7FFFFFFF
	value = (value * 1103515245 + 12345) & 0x7FFFFFFF
	value = (value ^ _seed ^ (_seed >> 17)) & 0x7FFFFFFF
	value = (value * 1103515245 + 12345) & 0x7FFFFFFF
	return WEATHER_KINDS[value % WEATHER_KINDS.size()]


static func valid_seed(value: Variant) -> bool:
	if not _integral(value):
		return false
	var number: float = float(value)
	return number >= 0.0 and number <= float(MAX_SEED)


static func valid_time(value: float) -> bool:
	# The same exactness bound as other persisted JSON numbers; it also keeps the
	# block index inside a safe integer range.
	return is_finite(value) and value >= 0.0 and value <= float(MAX_SEED)


static func _integral(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number: float = float(value)
	return is_finite(number) and number == floorf(number)
