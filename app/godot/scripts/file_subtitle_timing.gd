extends "res://scripts/file_mode_memory.gd"
## Independent per-video timing; never stored in the global subtitle appearance.
const MAX_DELAY := 10.0
const STEP := 0.1

static func delay(value: float) -> float:
	return clampf(snappedf(value, STEP), -MAX_DELAY, MAX_DELAY) if is_finite(value) else 0.0

static func slider_row(value: float, source_uri: String) -> Dictionary:
	return {"key": "subtitle_delay", "value": delay(value), "slider": true,
		"span": Vector3(-MAX_DELAY, MAX_DELAY, STEP), "unit": " s", "signed": true,
		"reset_value": 0.0, "reset_when_changed": true, "source_uri": source_uri, "nudge_step": STEP}

func _bank_path(bank: int) -> String:
	return directory.path_join("file_subtitle_timing_%d.json" % bank)

func _value_field() -> String: return "timing"

func _valid_value(value: Variant) -> bool:
	if not value is Dictionary or value.size() != 1: return false
	var seconds: Variant = value.get("delay_seconds")
	return (seconds is float or seconds is int) and is_finite(float(seconds)) and absf(float(seconds)) <= MAX_DELAY

func _normalize_value(value: Dictionary) -> Dictionary:
	return {"delay_seconds": delay(float(value.delay_seconds))}
