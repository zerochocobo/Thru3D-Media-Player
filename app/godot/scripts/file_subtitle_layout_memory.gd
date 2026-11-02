extends "res://scripts/file_mode_memory.gd"
## Presentation preference only; subtitle tracks, timing and global styles keep their own stores.
func _bank_path(bank: int) -> String: return directory.path_join("file_subtitle_layout_%d.json" % bank)
func _value_field() -> String: return "subtitle_layout"
func _valid_value(value: Variant) -> bool:
	return value is Dictionary and value.size() == 1 and value.get("below_screen") is bool
func _normalize_value(value: Dictionary) -> Dictionary: return {"below_screen": value.below_screen}
