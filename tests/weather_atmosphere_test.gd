extends SceneTree
## Weather presentation is a read-only input: the rain emitter and the clock's
## weather mood must follow the exposed nature view without touching farmland.
## This test needs no rendered frame and no main.tscn.

const DayNight = preload("res://atmosphere/day_night.gd")
const Weather = preload("res://presentation/weather_atmosphere.gd")
const HUD = preload("res://scenes/farm_hud.gd")

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
	weather.free()
	follow.free()


func _test_clock_mood() -> void:
	var clear_day: Dictionary = DayNight.apply_weather(DayNight.sample_hour(12.0), "clear")
	var cloudy_day: Dictionary = DayNight.apply_weather(DayNight.sample_hour(12.0), "cloudy")
	var rain_day: Dictionary = DayNight.apply_weather(DayNight.sample_hour(12.0), "rain")
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

	var unknown: Dictionary = DayNight.apply_weather(DayNight.sample_hour(12.0), "storm")
	var untouched: Dictionary = DayNight.sample_hour(12.0)
	_expect(unknown == untouched, "An unknown kind changes no clock value")
	_expect(DayNight.mood_for("storm").is_empty(), "An unknown kind has no mood")
	var clear_mood: Dictionary = DayNight.mood_for("clear")
	_expect(float(clear_mood.sun_energy) == 1.0, "Clear mood is the identity")

	var clear_night: Dictionary = DayNight.apply_weather(DayNight.sample_hour(0.0), "clear")
	var rain_night: Dictionary = DayNight.apply_weather(DayNight.sample_hour(0.0), "rain")
	_expect(float(rain_night.sun_energy) >= 0.0 and float(rain_night.sun_energy) <= 1.3,
		"Night sun stays bounded in rain")
	_expect(float(rain_night.ambient_energy) > 0.0 and float(rain_night.ambient_energy) <= 1.0,
		"Night ambient stays readable and bounded in rain")
	_expect(is_finite(float(rain_night.ambient_energy))
		and is_finite(float(rain_night.sun_energy)),
		"Night values remain finite")
	_expect(absf(float(rain_night.sun_energy) - float(clear_night.sun_energy)) < 0.0001,
		"Rain scales by daylight, so the night sun is unchanged")

	var day := DayNight.new()
	root.add_child(day)
	_expect(day.get_weather() == "clear", "A clock starts in clear weather")
	_expect(not day.set_weather("storm"), "The clock refuses an unknown kind")
	_expect(day.get_weather() == "clear", "A refused kind does not change the clock")
	_expect(day.set_weather("rain"), "The clock accepts rain")
	_expect(not day.set_weather("rain"), "Repeated rain on the clock is idempotent")
	_expect(day.get_weather() == "rain", "The clock keeps the applied kind")
	_expect(day.set_weather("clear"), "The clock returns to clear")
	day.free()


func _test_hud_text() -> void:
	_expect(HUD.weather_text("clear") == "天气：晴", "HUD line for clear")
	_expect(HUD.weather_text("cloudy") == "天气：多云", "HUD line for cloudy")
	_expect(HUD.weather_text("rain") == "天气：雨", "HUD line for rain")
	_expect(HUD.weather_text("storm").is_empty(), "HUD line is empty for an unknown kind")
	_expect(HUD.weather_text("rain", 10000.0, 6400.0) == "天气：雨 · 约 1 小时后变化",
		"HUD line adds the next change time when the nature view carries it")
	_expect(HUD.weather_text("rain", -1.0, 6400.0) == "天气：雨",
		"HUD line omits a missing next change time")


func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
