extends RefCounted
## Pure disaster-presentation data: the read-only HUD copy and the extra visual
## mood a drought or storm may layer on top of the weather mood.
##
## Kept free of preloads, nodes, clocks and saves on purpose. day_night.gd owns
## the lights and weather_atmosphere.gd owns the rain emitter; both are
## art-dependent in their consumers, so rule fixtures load this file directly.
## Unknown, empty or expired input returns an empty result instead of throwing.

const KINDS: Array[String] = ["drought", "storm"]
const LABELS: Dictionary = {"drought": "干旱", "storm": "暴雨"}
## Visual moods compose after the weather mood in day_night.gd. They only apply
## when they cannot contradict the current weather kind: rain already owns a wet
## scene, so drought adds no warmth there; a storm only thickens rain that is
## actually falling instead of painting a stormy sky under clear weather.
const MOODS: Dictionary = {
	"drought": {
		"sun_energy": 1.10, "ambient_energy": 1.0,
		"sun_color": Color("ffd9a0"), "sun_color_mix": 0.22,
		"backdrop": Color("f0dfc2"), "backdrop_mix": 0.12,
		"water": Color("7da49a"), "water_mix": 0.08,
	},
	"storm": {
		"sun_energy": 0.88, "ambient_energy": 1.03,
		"background": Color("7d888f"), "background_mix": 0.12,
		"backdrop": Color("aab4b8"), "backdrop_mix": 0.10,
	},
}


## True for the two kinds and for the empty "no disaster" value.
static func accepts(kind: String) -> bool:
	return kind.is_empty() or KINDS.has(kind)


static func label(kind: String) -> String:
	return str(LABELS.get(kind, ""))


## The single HUD line and the optional visual kind. The current disaster wins
## over a warning; a warning never changes the scene. Expired events are treated
## as absent so a stale summary cannot keep a label alive past its end.
static func describe(disaster: Variant, warning: Variant, now_utc: float) -> Dictionary:
	var result: Dictionary = {"text": "", "kind": "", "severity": 0, "warning": false}
	if not is_finite(now_utc) or now_utc < 0.0:
		return result
	var current: Dictionary = _valid_event(disaster, now_utc, true)
	if not current.is_empty():
		var text: String = "灾害：%s" % label(str(current.get("kind", "")))
		var ends: float = _number_or(current.get("ends_utc"), -1.0)
		if ends > 0.0:
			text += "（持续至 %s）" % _format_utc(ends)
		result.text = text
		result.kind = str(current.get("kind", ""))
		result.severity = int(current.get("severity", 0))
		return result
	var upcoming: Dictionary = _valid_event(warning, now_utc, false)
	if not upcoming.is_empty():
		var text: String = "预警：%s" % label(str(upcoming.get("kind", "")))
		var lead: float = _lead_seconds(upcoming, now_utc)
		if lead >= 0.0:
			text += " 约 %d 小时后" % maxi(1, ceili(lead / 3600.0))
		result.text = text
		result.kind = str(upcoming.get("kind", ""))
		result.severity = int(upcoming.get("severity", 0))
		result.warning = true
	return result


## The HUD hides the line when no event is loaded or the copy is empty; callers
## and the scene share this one decision so a headless fixture can verify it.
static func hud_visible(text: String, loaded: bool) -> bool:
	return loaded and not text.is_empty()


## Blends a disaster's small visual cue into values the clock already produced
## from its season and weather. Mutates and returns the caller's dictionary.
static func apply_visual(values: Dictionary, kind: String, weather_kind: String) -> Dictionary:
	var mood: Dictionary = MOODS.get(kind, {})
	if mood.is_empty():
		return values
	if kind == "drought" and weather_kind == "rain":
		return values
	if kind == "storm" and weather_kind != "rain":
		return values
	var daylight: float = clampf(1.0 - float(values.get("night_weight", 0.0)), 0.0, 1.0)
	values.sun_energy = float(values.sun_energy) * lerpf(1.0, float(mood.sun_energy), daylight)
	if mood.has("ambient_energy"):
		values.ambient_energy = float(values.ambient_energy) * lerpf(1.0, float(mood.ambient_energy), daylight)
	if mood.has("sun_color"):
		var sun_color: Color = values.sun_color
		values.sun_color = sun_color.lerp(mood.sun_color, float(mood.sun_color_mix) * daylight)
	if mood.has("background"):
		var background: Color = values.background
		values.background = background.lerp(mood.background, float(mood.background_mix) * daylight)
	if mood.has("backdrop"):
		var backdrop: Color = values.backdrop_tint
		values.backdrop_tint = backdrop.lerp(mood.backdrop, float(mood.backdrop_mix) * daylight)
	if mood.has("water") and values.has("water_color"):
		var water: Color = values.water_color
		values.water_color = water.lerp(mood.water, float(mood.water_mix) * daylight)
	return values


## Shape check plus expiry. `current` events must cover now; warnings must start
## in the future. Missing optional times are allowed, malformed ones are refused.
static func _valid_event(event: Variant, now_utc: float, current: bool) -> Dictionary:
	if not event is Dictionary or event.is_empty():
		return {}
	var data: Dictionary = event
	var kind: String = str(data.get("kind", ""))
	if not KINDS.has(kind):
		return {}
	if not _event_is_valid(data, now_utc, current):
		return {}
	return data


static func _lead_seconds(event: Dictionary, now_utc: float) -> float:
	if event.has("starts_utc"):
		if not _is_number(event.get("starts_utc")):
			return -1.0
		var starts: float = float(event.get("starts_utc"))
		if not is_finite(starts) or starts <= now_utc:
			return -1.0
		return starts - now_utc
	if event.has("lead_seconds") and _is_number(event.get("lead_seconds")):
		var lead: float = float(event.get("lead_seconds"))
		if is_finite(lead) and lead >= 0.0:
			return lead
	return -1.0


## A known kind is not enough: an event whose recorded lifetime is already over
## is stale and must produce no line. Returning {} for malformed times keeps a
## broken summary from showing nonsense.
static func _event_is_valid(data: Dictionary, now_utc: float, current: bool) -> bool:
	if data.has("starts_utc"):
		if not _is_number(data.get("starts_utc")):
			return false
		var starts: float = float(data.get("starts_utc"))
		if not is_finite(starts) or starts < 0.0:
			return false
		if current and starts > now_utc:
			return false
		if not current and starts <= now_utc:
			return false
	if data.has("ends_utc"):
		if not _is_number(data.get("ends_utc")):
			return false
		var ends: float = float(data.get("ends_utc"))
		if not is_finite(ends) or ends <= now_utc:
			return false
	return true


static func _is_number(value: Variant) -> bool:
	return value is int or value is float


static func _number_or(value: Variant, fallback: float) -> float:
	if not _is_number(value):
		return fallback
	var number: float = float(value)
	return number if is_finite(number) else fallback


## UTC because the whole simulation timeline is UTC; no local timezone is read.
static func _format_utc(seconds: float) -> String:
	var parts: Dictionary = Time.get_datetime_dict_from_unix_time(int(seconds))
	return "%02d-%02d %02d:%02d UTC" % [
		int(parts.get("month", 1)), int(parts.get("day", 1)),
		int(parts.get("hour", 0)), int(parts.get("minute", 0)),
	]
