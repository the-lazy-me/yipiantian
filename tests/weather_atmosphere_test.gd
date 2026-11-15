extends SceneTree
## Weather presentation is a read-only input: the rain emitter and the clock's
## weather mood must follow the exposed nature view without touching farmland.
## This test needs no rendered frame and no main.tscn.

const WeatherMood = preload("res://presentation/weather_mood.gd")
const Weather = preload("res://presentation/weather_atmosphere.gd")

var checks: int = 0
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_rain_emitter()
	_test_clock_mood()
	_test_hud_text()
	await process_frame
	for failure: String in failures:
		push_error(failure)
	print("WEATHER_ATMOSPHERE_TEST checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _test_rain_emitter() -> void:
	var follow := Node3D.new()
	follow.name = "Follow"
	follow.position = Vector3(3.0, 0.0, 4.0)
	root.add_child(follow)
	var weather := Weather.new()
	weather.name = "Weather"
	root.add_child(weather)
	weather.configure(follow, 0.5)
	var rain: GPUParticles3D = weather.rain_particles()
	_expect(rain != null and rain.name == "Rain", "Rain node exists")
	if rain == null:
		return
	_expect(rain.amount > 0 and rain.amount <= 900 and rain.amount == Weather.MAX_PARTICLES,
		"Rain particle count is bounded (%d)" % rain.amount)
	_expect(rain.visibility_aabb.size.x > 0.0 and rain.visibility_aabb.size.y > 0.0,
		"Rain visibility AABB is set")
	_expect(is_equal_approx(weather.global_position.x, 3.0)
		and is_equal_approx(weather.global_position.y, 0.5 + Weather.BOX_EXTENT.y)
		and is_equal_approx(weather.global_position.z, 4.0),
		"Rain box follows the camera horizontally over the courtyard ground")
	_expect(not rain.emitting and not rain.visible and not weather.is_raining(),
		"Clear weather keeps the rain emitter inactive")
	_expect(not weather.set_weather("clear"), "Clear weather is a no-op on the default kind")
	_expect(not rain.emitting, "Re-applying clear does not start rain")

	var emitted: Array[String] = []
	weather.weather_changed.connect(func(kind: String) -> void: emitted.append(kind))
	_expect(weather.set_weather("cloudy"), "Cloudy is accepted as a weather change")
	_expect(not rain.emitting and not rain.visible, "Cloudy does not show rain")
	_expect(not weather.is_raining(), "Cloudy is not rain")
	var instance: int = rain.get_instance_id()
	_expect(weather.set_weather("rain"), "Rain is accepted as a weather change")
	_expect(rain.emitting and rain.visible and weather.is_raining(), "Rain emits and is visible")
	_expect(weather.rain_particles().get_instance_id() == instance,
		"Entering rain reuses the single emitter")
	_expect(not weather.set_weather("rain"), "Repeated rain is idempotent")
	_expect(weather.rain_particles().get_instance_id() == instance,
		"Repeated rain does not rebuild the emitter")
	var expected_changes: Array[String] = ["cloudy", "rain"]
	_expect(emitted == expected_changes, "The overcast hook fires once per real change")
	_expect(not weather.set_weather("storm"), "An unknown kind is a no-op")
	_expect(weather.get_weather() == "rain" and rain.emitting,
		"An unknown kind leaves the rain state untouched")
	_expect(weather.set_weather("clear"), "Returning to clear is a real change")
	_expect(not rain.emitting and not rain.visible, "Clear disables rain again")
	_expect(weather.rain_particles().get_instance_id() == instance,
		"Leaving rain reuses the same emitter")

	# A disaster hint is separate from the weather kind: a storm only thickens
	# rain that is already falling, and an unknown kind is a no-op.
	_expect(weather.get_disaster().is_empty(), "No disaster hint starts empty")
	_expect(weather.set_disaster("storm"), "A storm hint is accepted")
	_expect(weather.get_weather() == "clear" and not rain.emitting,
		"A storm hint under clear weather starts no rain and changes no kind")
	_expect(rain.amount == Weather.STORM_PARTICLES, "A storm raises the bounded particle count")
	_expect(not weather.set_disaster("storm"), "Repeating a storm hint is idempotent")
	_expect(not weather.set_disaster("flood"), "An unknown disaster hint is a no-op")
	_expect(weather.get_disaster() == "storm", "An unknown hint leaves the storm in place")
	_expect(weather.set_weather("rain"), "Rain can start while a storm hint is present")
	_expect(rain.emitting and rain.amount == Weather.STORM_PARTICLES,
		"Rain under a storm uses the denser emitter")
	_expect(weather.set_disaster("drought"), "A drought replaces the storm hint")
	_expect(rain.emitting and rain.amount == Weather.MAX_PARTICLES,
		"Drought leaves the normal rain density")
	_expect(weather.get_weather() == "rain", "Changing the disaster hint never changes the weather kind")
	_expect(weather.set_disaster(""), "The disaster hint can be cleared")
	_expect(weather.get_disaster().is_empty(), "Clearing the hint leaves no disaster")
	_expect(weather.set_weather("clear"), "The fixture returns to clear weather")
	weather.free()
	follow.free()


func _test_clock_mood() -> void:
	# day_night.gd preloads the shipped backdrop texture, so this fixture drives
	# the pure mood table with the same values the clock produces instead of
	# loading that scene script.
	var clear_day: Dictionary = WeatherMood.apply_weather(_clock_values(0.0, 1.25), "clear")
	var cloudy_day: Dictionary = WeatherMood.apply_weather(_clock_values(0.0, 1.25), "cloudy")
	var rain_day: Dictionary = WeatherMood.apply_weather(_clock_values(0.0, 1.25), "rain")
	_expect(float(cloudy_day.sun_energy) < float(clear_day.sun_energy),
		"Cloudy dims the sun at noon")
	_expect(float(rain_day.sun_energy) < float(cloudy_day.sun_energy),
		"Rain dims the sun more than cloudy")
	var clear_color: Color = clear_day.sun_color
	var rain_color: Color = rain_day.sun_color
	var clear_background: Color = clear_day.background
	var rain_background: Color = rain_day.background
	_expect(not rain_color.is_equal_approx(clear_color), "Rain cools the sun colour")
	_expect(clear_color != rain_color, "Clear and rain sun colours are distinct")
	_expect(float(rain_day.ambient_energy) > float(clear_day.ambient_energy),
		"Overcast raises the flat ambient fill")
	_expect(rain_background != clear_background, "Rain mutes the backdrop colour")

	var unknown: Dictionary = WeatherMood.apply_weather(_clock_values(0.0, 1.25), "storm")
	var untouched: Dictionary = _clock_values(0.0, 1.25)
	_expect(unknown == untouched, "An unknown kind changes no clock value")
	_expect(WeatherMood.mood_for("storm").is_empty(), "An unknown kind has no mood")
	var clear_mood: Dictionary = WeatherMood.mood_for("clear")
	_expect(float(clear_mood.sun_energy) == 1.0, "Clear mood is the identity")

	var clear_night: Dictionary = WeatherMood.apply_weather(_clock_values(1.0, 0.0), "clear")
	var rain_night: Dictionary = WeatherMood.apply_weather(_clock_values(1.0, 0.0), "rain")
	_expect(float(rain_night.sun_energy) >= 0.0 and float(rain_night.sun_energy) <= 1.3,
		"Night sun stays bounded in rain")
	_expect(float(rain_night.ambient_energy) > 0.0 and float(rain_night.ambient_energy) <= 1.0,
		"Night ambient stays readable and bounded in rain")
	_expect(is_finite(float(rain_night.ambient_energy))
		and is_finite(float(rain_night.sun_energy)),
		"Night values remain finite")
	_expect(absf(float(rain_night.sun_energy) - float(clear_night.sun_energy)) < 0.0001,
		"Rain scales by daylight, so the night sun is unchanged")

	_expect(WeatherMood.accepts("rain") and WeatherMood.accepts("clear"),
		"The mood table accepts the three real kinds")
	_expect(not WeatherMood.accepts("storm"), "The mood table refuses an unknown kind")


## The keys apply_weather reads, in the shape the clock samples every tick.
func _clock_values(night_weight: float, sun_energy: float) -> Dictionary:
	return {
		"night_weight": night_weight,
		"sun_energy": sun_energy,
		"ambient_energy": 0.115 if night_weight < 0.5 else 0.20,
		"sun_color": Color("fff8ed") if night_weight < 0.5 else Color("a8c5ed"),
		"ambient_color": Color("d8d2bc") if night_weight < 0.5 else Color("8da8cf"),
		"background": Color("dbe2df") if night_weight < 0.5 else Color("465c6c"),
		"sky_top": Color("88acc3") if night_weight < 0.5 else Color("26344d"),
		"sky_horizon": Color("ded8c2") if night_weight < 0.5 else Color("3b485e"),
		"backdrop_tint": Color.WHITE if night_weight < 0.5 else Color("354d69"),
		"water_color": Color("68a4a3") if night_weight < 0.5 else Color("254653"),
	}


func _test_hud_text() -> void:
	_expect(WeatherMood.hud_text("clear") == "天气：晴", "HUD line for clear")
	_expect(WeatherMood.hud_text("cloudy") == "天气：多云", "HUD line for cloudy")
	_expect(WeatherMood.hud_text("rain") == "天气：雨", "HUD line for rain")
	_expect(WeatherMood.hud_text("storm").is_empty(), "HUD line is empty for an unknown kind")
	_expect(WeatherMood.hud_text("rain", 10000.0, 6400.0) == "天气：雨 · 约 1 小时后变化",
		"HUD line adds the next change time when the nature view carries it")
	_expect(WeatherMood.hud_text("rain", -1.0, 6400.0) == "天气：雨",
		"HUD line omits a missing next change time")


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
