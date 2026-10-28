extends "res://scripts/file_mode_memory.gd"
const Timing := preload("res://scripts/file_subtitle_timing.gd")
const CHOICES := [
	{"value": "auto", "label": "Automatic"},
	{"value": "windows-949", "label": "Korean (CP949)"},
	{"value": "GB18030", "label": "Chinese (GBK)"},
	{"value": "Big5", "label": "Chinese (Big5)"},
	{"value": "windows-31j", "label": "Japanese (Shift-JIS)"},
	{"value": "UTF-8", "label": "UTF-8"},
	{"value": "UTF-16LE", "label": "UTF-16LE"},
	{"value": "UTF-16BE", "label": "UTF-16BE"},
	{"value": "windows-1252", "label": "Western (Windows-1252)"},
]
static func valid_choice(value: Variant) -> bool:
	return value is String and CHOICES.any(func(choice): return choice.value == value)

static func row(track: Dictionary, uri: String) -> Dictionary:
	if not track.get("external", false) or not track.has("encoding"): return {}
	var options: Array = []
	var current: Dictionary = {}
	for choice in CHOICES:
		var value := {"encoding": choice.value, "source_uri": uri, "track_id": int(track.id), "subtitle_key": Timing.track_key(track)}
		options.append({"label": choice.label, "value": value})
		if choice.value == track.encoding: current = value
	return {"key": "subtitle_encoding", "value": current, "choices": options, "dropdown": true}

func for_track(uri: String, key: String) -> String: return str(lookup(uri).get(key, "auto"))
func remember_track(uri: String, key: String, encoding: String) -> bool:
	if key.length() != 64 or not key.is_valid_hex_number(false) or not valid_choice(encoding): return false
	var saved := lookup(uri)
	saved.erase(key)
	saved[key] = encoding
	while saved.size() > 32: saved.erase(saved.keys()[0])
	return remember(uri, saved)
func _bank_path(bank: int) -> String: return directory.path_join("file_subtitle_encoding_%d.json" % bank)
func _value_field() -> String: return "subtitle_encoding"
func _max_bytes() -> int: return 1048576
func _valid_value(value: Variant) -> bool:
	if not value is Dictionary or value.size() > 32: return false
	for key in value:
		if not key is String or key.length() != 64 or not key.is_valid_hex_number(false) or not valid_choice(value[key]): return false
	return true
func _normalize_value(value: Dictionary) -> Dictionary: return value.duplicate()
