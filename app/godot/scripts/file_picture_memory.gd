extends "res://scripts/file_mode_memory.gd"
## The chosen video look. Source capabilities affect rendering, never the saved values.
const Grade := preload("res://scripts/color_grade.gd")
const SHARPNESS_DEFAULT := 0.5
const SHARPNESS_MAX := 2.0

func _bank_path(bank: int) -> String:
	return directory.path_join("video_pictures_%d.json" % bank)

func _value_field() -> String: return "video_picture"

func _valid_value(value: Variant) -> bool:
	if not value is Dictionary or not value.get("picture_quality") is bool: return false
	for key in ["picture_sharpness", "picture_upscale", "picture_denoise"]:
		if not (value.get(key) is int or value.get(key) is float) or not is_finite(float(value[key])): return false
	var grade: Variant = value.get("color_grade")
	return grade is Dictionary and grade.get("preset") in Grade.PRESETS and grade.get("custom") is Dictionary

func _normalize_value(value: Dictionary) -> Dictionary:
	var grade := Grade.new()
	grade.restore(value.color_grade)
	return {"picture_quality": value.picture_quality,
		"picture_sharpness": clampf(float(value.picture_sharpness), 0.0, SHARPNESS_MAX),
		"picture_upscale": clampi(int(value.picture_upscale), 0, 2),
		"picture_denoise": clampi(int(value.picture_denoise), 0, 3),
		"color_grade": grade.snapshot()}

func load_defaults(settings: ConfigFile) -> Dictionary:
	var grade := Grade.new()
	grade.restore(settings.get_value("video", "color_grade", {}))
	var sharpness := float(settings.get_value("video", "picture_sharpness", SHARPNESS_DEFAULT))
	var upscale: Variant = settings.get_value("video", "picture_upscale", 0)
	return _normalize_value({"picture_quality": bool(settings.get_value("video", "picture_quality", grade.uses_curves())),
		"picture_sharpness": sharpness if is_finite(sharpness) else SHARPNESS_DEFAULT,
		"picture_upscale": (2 if upscale else 0) if upscale is bool else int(upscale),
		"picture_denoise": int(settings.get_value("video", "picture_denoise", 0)), "color_grade": grade.snapshot()})

static func is_adjustment(key: String) -> bool:
	return key in ["picture_sharpness", "picture_quality", "picture_upscale", "picture_denoise",
		"grade_preset", "grade_reset", "grade_reset_page"] or Grade.DEFAULTS.has(key)

func edited(picture: Dictionary, key: String, value: Variant) -> Dictionary:
	var result := picture.duplicate(true)
	match key:
		"picture_quality": result[key] = bool(value)
		"picture_sharpness":
			if not is_finite(float(value)): return picture
			result[key] = float(value) / 100.0
		"picture_upscale", "picture_denoise": result[key] = int(value)
		_:
			var grade := Grade.new()
			grade.restore(result.color_grade)
			match key:
				"grade_preset": grade.select(str(value))
				"grade_reset": grade.reset_custom()
				"grade_reset_page":
					if not grade.reset_page(int(value)): return picture
				_:
					if not Grade.DEFAULTS.has(key): return picture
					var clean := Grade.clean(key, value)
					if is_equal_approx(clean, float(grade.values(true)[key])): return picture
					grade.adjust(key, clean)
			result.color_grade = grade.snapshot()
	return _normalize_value(result)

func clear_picture(uri: String) -> bool:
	if not Privacy.settings_allowed(uri): return false
	if Privacy.protected_uri(uri):
		# An empty private field is read as absent by the same vault API.
		return Privacy.private_remember(uri, directory.get_file() + "/" + _value_field(), {})
	var key := entry_key(uri)
	return not entries.has(key) or purge_keys([key])
