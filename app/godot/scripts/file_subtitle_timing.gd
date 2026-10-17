extends "res://scripts/file_mode_memory.gd"
## Independent per-video timing; never stored in the global subtitle appearance.
const MAX_DELAY := 10.0
const STEP := 0.1

static func delay(value: float) -> float:
	return clampf(snappedf(value, STEP), -MAX_DELAY, MAX_DELAY) if is_finite(value) else 0.0

static func slider_row(value: float, source_uri: String, subtitle_key: String = "") -> Dictionary:
	return {"key": "subtitle_delay", "value": delay(value), "slider": true,
		"span": Vector3(-MAX_DELAY, MAX_DELAY, STEP), "unit": " s", "signed": true,
		"reset_value": 0.0, "reset_when_changed": true, "source_uri": source_uri, "subtitle_key": subtitle_key, "nudge_step": STEP}

static func track_key(track: Dictionary) -> String:
	if track.is_empty(): return ""
	var filename := str(track.get("source_file", ""))
	if bool(track.get("external", false)) and not filename.is_empty(): return ("file:" + filename).sha256_text()
	# Embedded tracks have no sibling file; retain their identity within this video.
	return JSON.stringify([track.get("id", 0), track.get("title", ""), track.get("language", ""), track.get("codec", ""), track.get("external", false)]).sha256_text()

func for_track(uri: String, key: String, inherit_legacy: bool = false) -> float:
	var saved := lookup(uri)
	if key.is_empty(): return float(saved.get("delay_seconds", 0.0))
	if saved.get("tracks", {}).has(key): return float(saved.tracks[key])
	return float(saved.get("delay_seconds", 0.0)) if inherit_legacy and not saved.has("tracks") else 0.0

func remember_track(uri: String, key: String, seconds: float) -> bool:
	var saved := lookup(uri)
	saved.delay_seconds = delay(seconds)
	if not key.is_empty():
		if key.length() != 64 or not key.is_valid_hex_number(false): return false
		var tracks: Dictionary = saved.get("tracks", {})
		tracks.erase(key); tracks[key] = delay(seconds)
		while tracks.size() > 32: tracks.erase(tracks.keys()[0])
		saved.tracks = tracks
	return remember(uri, saved)

func _bank_path(bank: int) -> String:
	return directory.path_join("file_subtitle_timing_%d.json" % bank)

func _value_field() -> String: return "timing"
func _max_bytes() -> int: return 1048576 # 128 videos, each with up to 32 independent subtitle corrections.

func _valid_value(value: Variant) -> bool:
	if not value is Dictionary or value.size() < 1 or value.size() > 2: return false
	var seconds: Variant = value.get("delay_seconds")
	if not valid_seconds(seconds): return false
	if value.size() == 1: return true
	if not value.get("tracks") is Dictionary or value.tracks.size() > 32: return false
	for key in value.tracks:
		if not key is String or key.length() != 64 or not key.is_valid_hex_number(false) or not valid_seconds(value.tracks[key]): return false
	return true

static func valid_seconds(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and absf(float(value)) <= MAX_DELAY

func _normalize_value(value: Dictionary) -> Dictionary:
	var result := {"delay_seconds": delay(float(value.delay_seconds))}
	if value.has("tracks"):
		result.tracks = {}
		for key in value.tracks: result.tracks[key] = delay(float(value.tracks[key]))
	return result
