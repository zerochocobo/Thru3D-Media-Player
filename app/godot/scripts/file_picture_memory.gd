extends "res://scripts/file_mode_memory.gd"
## The chosen video look. Source capabilities affect rendering, never the saved values.
const Grade := preload("res://scripts/color_grade.gd")
const SHARPNESS_DEFAULT := 0.5
const SHARPNESS_MAX := 2.0
const ANIME4K_TIER_DEFAULT := 1 # M

func _bank_path(bank: int) -> String:
	return directory.path_join("video_pictures_%d.json" % bank)

func _value_field() -> String: return "video_picture"

func _valid_value(value: Variant) -> bool:
	if not value is Dictionary or not value.get("picture_quality") is bool: return false
	for key in ["picture_sharpness", "picture_upscale", "picture_denoise"]:
		if not (value.get(key) is int or value.get(key) is float) or not is_finite(float(value[key])): return false
	# Absent in what versions before frame interpolation saved: off.
	if value.has("picture_interpolation") and not value.picture_interpolation is bool: return false
	# Absent before the plugins tab: Anime4K off, mode A, at its default tier. Its first test build kept the
	# mode in picture_anime4k (0 off, 1 to 3 the mode): read as on in that mode.
	if value.has("picture_anime4k") and not (value.picture_anime4k is bool or value.picture_anime4k is int or value.picture_anime4k is float): return false
	for key in ["picture_anime4k_mode", "picture_anime4k_tier"]:
		if value.has(key) and not (value[key] is int or value[key] is float): return false
	var grade: Variant = value.get("color_grade")
	return grade is Dictionary and grade.get("preset") in Grade.PRESETS and grade.get("custom") is Dictionary

func _normalize_value(value: Dictionary) -> Dictionary:
	var grade := Grade.new()
	grade.restore(value.color_grade)
	return {"picture_quality": value.picture_quality,
		"picture_sharpness": clampf(float(value.picture_sharpness), 0.0, SHARPNESS_MAX),
		"picture_upscale": clampi(int(value.picture_upscale), 0, 2),
		"picture_denoise": clampi(int(value.picture_denoise), 0, 3),
		"picture_interpolation": bool(value.get("picture_interpolation", false)),
		"picture_anime4k": bool(value.get("picture_anime4k", false)),
		"picture_anime4k_mode": clampi(int(value.get("picture_anime4k_mode", _first_build_mode(value))), 1, 3),
		"picture_anime4k_tier": clampi(int(value.get("picture_anime4k_tier", ANIME4K_TIER_DEFAULT)), 0, 3),
		"color_grade": grade.snapshot()}

## Anime4K's mode as its first test build saved it (picture_anime4k 1 to 3), or A.
static func _first_build_mode(value: Dictionary) -> int:
	var old: Variant = value.get("picture_anime4k")
	return int(old) if (old is int or old is float) and int(old) > 0 else 1

## A stored look, checked; anything malformed reads as none.
func clean(value: Variant) -> Dictionary:
	return _normalize_value(value) if _valid_value(value) else {}

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
	return key in ["picture_sharpness", "picture_quality", "picture_upscale", "picture_denoise", "picture_interpolation",
		"picture_anime4k", "picture_anime4k_mode", "picture_anime4k_tier",
		"grade_preset", "grade_reset", "grade_reset_page"] or Grade.DEFAULTS.has(key)

func edited(picture: Dictionary, key: String, value: Variant) -> Dictionary:
	var result := picture.duplicate(true)
	match key:
		"picture_quality", "picture_interpolation", "picture_anime4k": result[key] = bool(value)
		"picture_sharpness":
			if not is_finite(float(value)): return picture
			result[key] = float(value) / 100.0
		"picture_upscale", "picture_denoise", "picture_anime4k_mode", "picture_anime4k_tier": result[key] = int(value)
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
