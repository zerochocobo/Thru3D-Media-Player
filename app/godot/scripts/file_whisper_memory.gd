extends "res://scripts/file_mode_memory.gd"
## Audio enhancement belongs to the original video identity, never global volume.

func _bank_path(bank: int) -> String:
	return directory.path_join("file_whisper_%d.json" % bank)

func _value_field() -> String: return "whisper"

func lookup(uri: String) -> Dictionary:
	var saved := super.lookup(uri)
	return _normalize_value(saved) if _valid_value(saved) else {}

func _valid_value(value: Variant) -> bool:
	if not value is Dictionary: return false
	if value.size() == 1 and value.has("level"):
		return valid_number(value.level, 2) # Migrate the original off/standard/strong records.
	return value.size() == 2 and value.get("enabled") is bool and valid_number(value.get("boost"), 50)

static func valid_number(value: Variant, maximum: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floorf(float(value)) and int(value) >= 0 and int(value) <= maximum

func _normalize_value(value: Dictionary) -> Dictionary:
	if value.has("level"):
		return {"enabled": int(value.level) > 0, "boost": 50 if int(value.level) == 2 else (32 if int(value.level) == 1 else 0)}
	return {"enabled": bool(value.enabled), "boost": int(value.boost)}
