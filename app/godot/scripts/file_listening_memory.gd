extends "res://scripts/file_mode_memory.gd"
## Only activation belongs to the video; language/translation remain global.
func _bank_path(bank: int) -> String: return directory.path_join("file_listening_%d.json" % bank)
func _value_field() -> String: return "listening"
func _valid_value(value: Variant) -> bool:
	return value is Dictionary and value.size() == 1 and value.get("enabled") is bool
func _normalize_value(value: Dictionary) -> Dictionary: return {"enabled": value.enabled}
