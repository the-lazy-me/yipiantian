extends RefCounted
## Pure weather-presentation data: the overcast mood table, its blend into the
## values the clock already computed, and the one-line player copy.
##
## Kept free of preloads and nodes on purpose. day_night.gd owns the lights and
## weather_atmosphere.gd owns the rain emitter; both are art-dependent, so the
## rule fixtures load this file instead of a scene script. Nothing here reads a
## clock, a save or the network.

const KINDS: Array[String] = ["clear", "cloudy", "rain"]
const MOODS: Dictionary = {
	"clear": {
		"sun_energy": 1.0, "ambient_energy": 1.0,
		"sun_color": Color.WHITE, "sun_color_mix": 0.0,
		"ambient_color": Color.WHITE, "ambient_color_mix": 0.0,
		"background": Color.WHITE, "background_mix": 0.0,
		"sky_flat": 0.0, "sky_top": Color.WHITE, "sky_top_mix": 0.0,
		"sky_horizon": Color.WHITE, "sky_horizon_mix": 0.0,
		"backdrop": Color.WHITE, "backdrop_mix": 0.0,
		"water": Color.WHITE, "water_mix": 0.0,
	},
	"cloudy": {
		"sun_energy": 0.55, "ambient_energy": 1.06,
		"sun_color": Color("d5dde0"), "sun_color_mix": 0.40,
		"ambient_color": Color("cbd4d5"), "ambient_color_mix": 0.25,
		"background": Color("c7cecc"), "background_mix": 0.30,
		"sky_flat": 0.35, "sky_top": Color("c4cdcd"), "sky_top_mix": 0.20,
		"sky_horizon": Color("c8cfcd"), "sky_horizon_mix": 0.25,
		"backdrop": Color("d6dbd8"), "backdrop_mix": 0.22,
		"water": Color("7f9c9c"), "water_mix": 0.15,
	},
	"rain": {
		"sun_energy": 0.30, "ambient_energy": 1.10,
		"sun_color": Color("aebfca"), "sun_color_mix": 0.65,
		"ambient_color": Color("a9b9c2"), "ambient_color_mix": 0.40,
		"background": Color("8f9ba0"), "background_mix": 0.55,
		"sky_flat": 0.65, "sky_top": Color("9daab0"), "sky_top_mix": 0.45,
		"sky_horizon": Color("9aa7ab"), "sky_horizon_mix": 0.55,
		"backdrop": Color("b6c0c3"), "backdrop_mix": 0.45,
		"water": Color("5f7d86"), "water_mix": 0.40,
	},
}
const LABELS: Dictionary = {"clear": "晴", "cloudy": "多云", "rain": "雨"}


static func accepts(kind: String) -> bool:
	return KINDS.has(kind)


## Read-only mood table for one weather kind; empty for an unknown kind.
static func mood_for(kind: String) -> Dictionary:
	return MOODS.get(kind, {})


## Blends a weather mood into values already produced by the clock and season.
## Every change is scaled by daylight so the night keeps its readable floor.
## Mutates and returns the caller's dictionary; the clock samples a fresh one
## every tick.
static func apply_weather(values: Dictionary, kind: String) -> Dictionary:
	var mood: Dictionary = mood_for(kind)
	if kind == "clear" or mood.is_empty():
		return values
	var daylight: float = clampf(1.0 - float(values.get("night_weight", 0.0)), 0.0, 1.0)
	values.sun_energy = float(values.sun_energy) * lerpf(1.0, float(mood.sun_energy), daylight)
	values.ambient_energy = float(values.ambient_energy) * lerpf(1.0, float(mood.ambient_energy), daylight)
	var sun_color: Color = values.sun_color
	var ambient_color: Color = values.ambient_color
	var background: Color = values.background
	var sky_top: Color = values.sky_top
	var sky_horizon: Color = values.sky_horizon
	var backdrop_tint: Color = values.backdrop_tint
	var water_color: Color = values.water_color
	values.sun_color = sun_color.lerp(mood.sun_color, float(mood.sun_color_mix) * daylight)
	values.ambient_color = ambient_color.lerp(mood.ambient_color, float(mood.ambient_color_mix) * daylight)
	values.background = background.lerp(mood.background, float(mood.background_mix) * daylight)
	# Flatten the sky gradient first, then shift its hue toward the overcast tone.
	sky_top = sky_top.lerp(sky_horizon, float(mood.sky_flat) * daylight)
	values.sky_top = sky_top.lerp(mood.sky_top, float(mood.sky_top_mix) * daylight)
	values.sky_horizon = sky_horizon.lerp(mood.sky_horizon, float(mood.sky_horizon_mix) * daylight)
	values.backdrop_tint = backdrop_tint.lerp(mood.backdrop, float(mood.backdrop_mix) * daylight)
	values.water_color = water_color.lerp(mood.water, float(mood.water_mix) * daylight)
	return values


static func label(kind: String) -> String:
	return str(LABELS.get(kind, ""))


## The single HUD line. Empty for an unknown kind, and the next-change clause is
## omitted unless a genuine future instant is known.
static func hud_text(kind: String, next_change_utc: float = -1.0, now_utc: float = -1.0) -> String:
	var name: String = label(kind)
	if name.is_empty():
		return ""
	var text: String = "天气：%s" % name
	if is_finite(next_change_utc) and is_finite(now_utc) and now_utc >= 0.0 and next_change_utc > now_utc:
		var hours: int = maxi(1, ceili((next_change_utc - now_utc) / 3600.0))
		text += " · 约 %d 小时后变化" % hours
	return text
