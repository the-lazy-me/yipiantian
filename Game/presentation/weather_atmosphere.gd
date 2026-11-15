extends Node3D
## Weather presentation only. Gameplay, saves and the network never read this
## node, and this node never changes farm settlement.
##
## Rain is a small procedural particle box that follows the camera over the
## courtyard. The overcast response is the `weather_changed` hook: the scene
## forwards it to day_night.gd, which blends the same kind into the existing
## clock and season palette. No lighting is authored or overwritten here.

signal weather_changed(kind: String)

const DisasterMood = preload("res://presentation/disaster_mood.gd")
const KINDS: Array[String] = ["clear", "cloudy", "rain"]
# Bounded cost: one emitter, one draw pass, no allocation per frame.
const MAX_PARTICLES: int = 700
# A storm keeps the same emitter and only asks it for more streaks.
const STORM_PARTICLES: int = 900
const BOX_EXTENT := Vector3(26.0, 10.0, 26.0)
const STREAK_SIZE := Vector2(0.018, 0.34)
const RAIN_AABB := AABB(Vector3(-26.0, -34.0, -26.0), Vector3(52.0, 46.0, 52.0))

var kind: String = "clear"
## A disaster hint never changes `kind`; it only lets an already-raining sky
## thicken its streaks. Warnings are HUD-only and never reach this node.
var disaster_kind: String = ""
var _follow: Node3D
var _ground_y: float = 0.0
var _rain: GPUParticles3D


func configure(follow: Node3D, ground_y: float = 0.0) -> void:
	_follow = follow
	_ground_y = ground_y
	if _rain == null:
		_build_rain()
	_place_over_follow()


## Applying an unknown kind or the current kind changes nothing, so a per-tick
## caller never rebuilds the emitter or re-applies the lighting mood.
func set_weather(next: String) -> bool:
	if not KINDS.has(next) or next == kind:
		return false
	kind = next
	_apply_rain()
	weather_changed.emit(kind)
	return true


func get_weather() -> String:
	return kind


## Applies an optional current disaster kind. Empty clears the hint; unknown
## values and repeats are no-ops. This never calls `set_weather`.
func set_disaster(next: String) -> bool:
	if not DisasterMood.accepts(next) or next == disaster_kind:
		return false
	disaster_kind = next
	_apply_rain()
	return true


func get_disaster() -> String:
	return disaster_kind


func is_raining() -> bool:
	return kind == "rain"


func rain_particles() -> GPUParticles3D:
	return _rain


func _build_rain() -> void:
	var streak := QuadMesh.new()
	streak.size = STREAK_SIZE
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.72, 0.80, 0.86, 0.42)
	# Keep the streak upright while it faces the camera; a full billboard would
	# tilt it toward a top-down farm view and lose the falling line.
	material.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.disable_receive_shadows = true
	streak.material = material

	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = BOX_EXTENT
	process.direction = Vector3(0.12, -1.0, 0.0)
	process.spread = 3.0
	process.initial_velocity_min = 14.0
	process.initial_velocity_max = 18.0
	process.gravity = Vector3(0.0, -4.0, 0.0)
	process.scale_min = 0.8
	process.scale_max = 1.2

	_rain = GPUParticles3D.new()
	_rain.name = "Rain"
	_rain.amount = MAX_PARTICLES
	_rain.lifetime = 1.2
	_rain.preprocess = 0.6
	_rain.fixed_fps = 30
	_rain.interpolate = true
	_rain.local_coords = false
	_rain.emitting = false
	_rain.visible = false
	_rain.visibility_aabb = RAIN_AABB
	_rain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rain.process_material = process
	_rain.draw_pass_1 = streak
	_apply_rain()


func _apply_rain() -> void:
	var raining: bool = kind == "rain"
	if _rain != null:
		_rain.amount = STORM_PARTICLES if disaster_kind == "storm" else MAX_PARTICLES
		# The emitter only enters the tree while it can rain. Clear and cloudy
		# sessions therefore compile no particle shader at all, and leaving rain
		# stops the system in the same frame.
		if raining and _rain.get_parent() == null:
			add_child(_rain)
		elif not raining and _rain.get_parent() != null:
			remove_child(_rain)
		_rain.visible = raining
		_rain.emitting = raining
	set_process(raining)


## The emitter follows the camera horizontally but stays just above the
## courtyard ground, so a high panorama camera still rains over the farm.
func _place_over_follow() -> void:
	if _follow == null or not is_instance_valid(_follow):
		return
	global_position = Vector3(_follow.global_position.x, _ground_y + BOX_EXTENT.y, _follow.global_position.z)


func _process(_delta: float) -> void:
	_place_over_follow()


func _exit_tree() -> void:
	# Drop the particle material and draw pass before the scene frees the node;
	# this releases the compiled particle shader with the scene instead of at
	# process exit. An emitter parked outside the tree (clear/cloudy) is ours to
	# free, because the parent no longer owns it.
	var rain := _rain
	_rain = null
	if rain == null:
		return
	rain.emitting = false
	rain.visible = false
	rain.draw_pass_1 = null
	rain.process_material = null
	if rain.get_parent() == null:
		rain.free()
