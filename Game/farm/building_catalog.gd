extends RefCounted
## Fixed homestead slots and the first housing blueprints.
##
## The first slice places buildings on named plots and tracks only their
## construction time. Materials, appearance and free placement are later
## slices, so this catalog stays pure data.

const SLOTS: Array[String] = ["yard_a", "yard_b", "yard_c", "yard_d", "yard_e", "yard_f"]
const SLOT_NAMES: Dictionary = {
	"yard_a": "甲号宅基",
	"yard_b": "乙号宅基",
	"yard_c": "丙号宅基",
	"yard_d": "丁号宅基",
	"yard_e": "戊号宅基",
	"yard_f": "己号宅基",
}
const BLUEPRINTS: Dictionary = {
	"cottage": {"name": "小屋", "build_seconds": 600.0},
	"workshop": {"name": "工坊", "build_seconds": 1200.0},
	"pavilion": {"name": "凉亭", "build_seconds": 300.0},
}


static func slot_names() -> Dictionary:
	# Every slot carries a display name; callers iterate SLOTS for the order.
	return SLOT_NAMES.duplicate()


static func name_of_slot(slot_id: String) -> String:
	return str(SLOT_NAMES.get(slot_id, ""))


static func definition(blueprint_id: String) -> Dictionary:
	# Unknown ids return an empty definition, like the crop catalog.
	var blueprint: Variant = BLUEPRINTS.get(blueprint_id)
	return blueprint.duplicate() if blueprint is Dictionary else {}


static func blueprint_ids() -> Array[String]:
	var result: Array[String] = []
	result.assign(BLUEPRINTS.keys())
	return result


static func duration(blueprint_id: String) -> float:
	return float(definition(blueprint_id).get("build_seconds", 0.0))
