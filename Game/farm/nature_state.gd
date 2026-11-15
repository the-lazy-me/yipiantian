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
##
## Disasters are a second, independent derivation over the same block grid. A
## disaster lasts exactly one block and only changes soil moisture (FarmState
## applies it); it never adds a mode, a persisted field or a second growth
## multiplier.

const RULES_VERSION: int = 2
# Version 1 documents (written by M6-01/M6-02 before disasters existed) are
# read with the unchanged weather derivation and upgraded on the next save.
# This is the only accepted older version; it is not a general migration path.
const LEGACY_RULES_VERSION: int = 1
# JSON numbers remain exact only up to this bound.
const MAX_SEED: int = 9007199254740991
const DEFAULT_SEED: int = 20261115
const DAY_SECONDS: float = 86400.0
const DAY_START_SECONDS: float = 6.0 * 3600.0
const NIGHT_START_SECONDS: float = 18.0 * 3600.0
# Four weather blocks per real day; the boundary coincides with UTC midnight.
const WEATHER_SECONDS: float = 6.0 * 3600.0
const BLOCKS_PER_DAY: int = 4
# Experimental agricultural season length: four one-week seasons per cycle.
const SEASON_DAYS: int = 7
const SEASON_SECONDS: float = float(SEASON_DAYS) * DAY_SECONDS
const SEASON_IDS: Array[String] = ["spring", "summer", "autumn", "winter"]
const WEATHER_KINDS: Array[String] = ["clear", "cloudy", "rain"]
# M6-03 disasters. Only two kinds exist in the gentle mode; severity is display
# metadata and does not scale the moisture delta.
const DISASTER_KINDS: Array[String] = ["drought", "storm"]
const DISASTER_WINDOW_DAYS: int = 5
const DISASTER_BLOCKS_PER_WINDOW: int = DISASTER_WINDOW_DAYS * BLOCKS_PER_DAY
# Bounded look-ahead for next_disaster_at(); about two months of blocks.
const DISASTER_SEARCH_BLOCKS: int = 60 * BLOCKS_PER_DAY
const DISASTER_MAX_SEVERITY: int = 3

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
	var version: int = int(data.rules_version)
	# Version 1 is the one explicit upgrade path: the weather hash is unchanged,
	# so the same seed keeps the same weather history. Only the disaster layer
	# becomes available for blocks settled after the upgrade; already-settled
	# farm state keeps its stored baselines and is never recomputed. snapshot()
	# always emits RULES_VERSION, so the next save rewrites the document.
	if version != RULES_VERSION and version != LEGACY_RULES_VERSION:
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


## The disaster covering `utc_seconds`, or {} when none does. A disaster is one
## complete 6-hour block aligned with the weather grid, so it introduces no new
## advance segmentation point. Returns {} for invalid input.
func disaster_at(utc_seconds: float) -> Dictionary:
	if not valid_time(utc_seconds):
		return {}
	var day_index: int = int(floorf(utc_seconds / DAY_SECONDS))
	var block_index: int = int(floorf(utc_seconds / WEATHER_SECONDS))
	var window_index: int = day_index / DISASTER_WINDOW_DAYS
	var event: Dictionary = _disaster_for_window(window_index)
	if event.is_empty() or int(event.block_index) != block_index:
		return {}
	var start: float = float(block_index) * WEATHER_SECONDS
	return {
		"kind": str(event.kind),
		"start_utc": start,
		"end_utc": start + WEATHER_SECONDS,
		"severity": int(event.severity),
	}


## Start of the next block at which a disaster begins strictly after the block
## covering `utc_seconds`; -1 when the bounded look-ahead finds none or the
## input is invalid. A warning is this instant equals the current block's end.
func next_disaster_at(utc_seconds: float) -> float:
	if not valid_time(utc_seconds):
		return -1.0
	var block_index: int = int(floorf(utc_seconds / WEATHER_SECONDS))
	for offset: int in range(1, DISASTER_SEARCH_BLOCKS + 1):
		var at: float = float(block_index + offset) * WEATHER_SECONDS
		if not disaster_at(at).is_empty():
			return at
	return -1.0


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


## The single disaster candidate for a 5-day window, or {}. Only even windows
## are eligible: because a window is 20 blocks, this makes consecutive events
## at least 21 blocks (5.25 days) apart even when both sit at window edges. So
## two disasters can never share a 5-day window and spacing exceeds the stated
## minimum. The whole decision is seed + window index; no persisted event list.
func _disaster_for_window(window_index: int) -> Dictionary:
	if window_index < 0 or window_index % 2 != 0:
		return {}
	var value: int = _disaster_hash(window_index)
	# Two out of three eligible windows host an event.
	if value % 3 == 0:
		return {}
	var block_in_window: int = (value >> 8) % DISASTER_BLOCKS_PER_WINDOW
	var block_index: int = window_index * DISASTER_BLOCKS_PER_WINDOW + block_in_window
	return {
		"block_index": block_index,
		"kind": DISASTER_KINDS[(value >> 5) % DISASTER_KINDS.size()],
		"severity": 1 + (value >> 13) % DISASTER_MAX_SEVERITY,
	}


func _disaster_hash(window_index: int) -> int:
	# Independent of the weather LCG: a bit-mixing hash keeps the disaster
	# sequence stable across processes without changing weather derivation.
	# Every intermediate stays below 2**64, so no platform overflow is involved.
	var value: int = (window_index * 2) & 0xFFFFFFFF
	value = (value ^ (value >> 16)) & 0xFFFFFFFF
	value = (value * 0x45D9F3B) & 0xFFFFFFFF
	value = (value ^ (value >> 16)) & 0xFFFFFFFF
	value = (value * 0x45D9F3B) & 0xFFFFFFFF
	value = (value ^ (value >> 16)) & 0xFFFFFFFF
	value = (value ^ _seed ^ (_seed >> 17)) & 0xFFFFFFFF
	value = (value * 1103515245 + 12345) & 0xFFFFFFFF
	return (value ^ (value >> 13)) & 0xFFFFFFFF


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
