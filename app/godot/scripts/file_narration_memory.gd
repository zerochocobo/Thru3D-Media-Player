extends "res://scripts/file_mode_memory.gd"
## Narration belongs to the original video, including its explicit Off choice.
const FIELDS := ["enabled", "profile", "voice_origin", "voice_id", "zh_voice", "en_voice", "ja_voice", "language", "line", "hide_subtitles", "duck", "volume", "offset"]

func _bank_path(bank: int) -> String:
	return directory.path_join("file_narration_%d.json" % bank)

func _value_field() -> String: return "narration"

func _valid_value(value: Variant) -> bool:
	if not value is Dictionary or value.size() != FIELDS.size(): return false
	for key in FIELDS:
		if not value.has(key): return false
	if not value.enabled is bool or not value.hide_subtitles is bool: return false
	if value.language not in ["zh", "en", "ja", "auto"] or value.voice_origin not in ["", "zh", "en", "ja"]: return false
	for key in ["profile", "voice_id", "zh_voice", "en_voice", "ja_voice"]:
		if not value[key] is String or value[key].length() > 32: return false
	for key in ["line", "duck", "volume", "offset"]:
		if not (value[key] is int or value[key] is float) or not is_finite(float(value[key])): return false
	return float(value.line) == floorf(float(value.line)) and int(value.line) in [0, 1, 2] and float(value.duck) >= 0 and float(value.duck) <= 100 \
		and float(value.volume) >= 0 and float(value.volume) <= 100 and absf(float(value.offset)) <= 2

func _normalize_value(value: Dictionary) -> Dictionary:
	var result := value.duplicate(true)
	result.line = int(result.line)
	return result
