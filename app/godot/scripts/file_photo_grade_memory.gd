extends "res://scripts/file_mode_memory.gd"
## Each image keeps its own colour grade (a ColorGrade snapshot); the picture's pixels are never changed.
const Grade := preload("res://scripts/color_grade.gd")

func _bank_path(bank: int) -> String:
	return directory.path_join("photo_grades_%d.json" % bank)

func _value_field() -> String: return "grade"

# Graded photos are far more numerous than graded videos.
func _limit() -> int: return 512

func _max_bytes() -> int: return 1048576

func _valid_value(value: Variant) -> bool:
	if not value is Dictionary or value.size() != 2 or not value.get("preset") in Grade.PRESETS: return false
	var custom: Variant = value.get("custom")
	if not custom is Dictionary or custom.size() != Grade.DEFAULTS.size(): return false
	for key in Grade.DEFAULTS:
		var number: Variant = custom.get(key)
		if not (number is int or number is float) or not is_finite(float(number)): return false
	return true

func _normalize_value(value: Dictionary) -> Dictionary:
	var custom := {}
	for key in Grade.DEFAULTS: custom[key] = Grade.clean(key, value.custom[key])
	return {"preset": str(value.preset), "custom": custom}
