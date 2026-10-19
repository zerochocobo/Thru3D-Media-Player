extends "res://scripts/file_mode_memory.gd"
## Narration belongs to the original video, including its explicit Off choice.
const FIELDS := ["enabled", "profile", "voice_origin", "voice_id", "zh_voice", "en_voice", "ja_voice", "language", "line", "hide_subtitles", "duck", "volume", "offset", "voice_kind", "custom_voice"]
const Languages := preload("res://scripts/narration_languages.gd")

func _bank_path(bank: int) -> String:
	return directory.path_join("file_narration_%d.json" % bank)

func _value_field() -> String: return "narration"

func _valid_value(value: Variant) -> bool:
	if not value is Dictionary or value.size() not in [FIELDS.size(), FIELDS.size() - 2]: return false
	for key in FIELDS:
		if key in ["voice_kind", "custom_voice"]: continue
		if not value.has(key): return false
	if value.has("voice_kind") != value.has("custom_voice"): return false
	if value.get("voice_kind", "preset") not in ["preset", "custom"]: return false
	var custom: Variant = value.get("custom_voice", "")
	if not custom is String or (not custom.is_empty() and not valid_custom_voice(custom)): return false
	if not value.enabled is bool or not value.hide_subtitles is bool: return false
	if (value.language != "auto" and value.language not in Languages.NAMES) or value.voice_origin not in ["", "zh", "en", "ja"]: return false
	for key in ["profile", "voice_id", "zh_voice", "en_voice", "ja_voice"]:
		if not value[key] is String or value[key].length() > 32: return false
	for key in ["line", "duck", "volume", "offset"]:
		if not (value[key] is int or value[key] is float) or not is_finite(float(value[key])): return false
	return float(value.line) == floorf(float(value.line)) and int(value.line) in [0, 1, 2] and float(value.duck) >= 0 and float(value.duck) <= 100 \
		and float(value.volume) >= 0 and float(value.volume) <= 100 and absf(float(value.offset)) <= 2

func _normalize_value(value: Dictionary) -> Dictionary:
	var result := value.duplicate(true)
	result.line = int(result.line)
	result.voice_kind = str(result.get("voice_kind", "preset"))
	result.custom_voice = str(result.get("custom_voice", ""))
	return result

static func valid_custom_voice(value: String) -> bool:
	if not value.begins_with("custom:") or value.length() != 43: return false
	var uuid := value.substr(7)
	return uuid == uuid.to_lower() and uuid[8] == "-" and uuid[13] == "-" and uuid[18] == "-" and uuid[23] == "-" and uuid.replace("-", "").length() == 32 and uuid.replace("-", "").is_valid_hex_number(false)
