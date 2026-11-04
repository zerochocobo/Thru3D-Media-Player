extends RefCounted
## Display-only, per-eye ratios. Source dimensions, stereo packing and decoder PAR stay intact.
const PRESETS := ["original", "9:16", "1:1", "4:3", "16:10", "16:9", "2:1", "21:9"]
const RATIOS := {"9:16": 9.0 / 16.0, "1:1": 1.0, "4:3": 4.0 / 3.0, "16:10": 1.6,
	"16:9": 16.0 / 9.0, "2:1": 2.0, "21:9": 21.0 / 9.0}
const FIELDS := ["video_aspect_preset", "video_aspect_factor"]
const LIMITS := Vector3(0.5, 2.0, 0.001)

static func valid(value: Dictionary) -> bool:
	if value.has(FIELDS[0]) and value[FIELDS[0]] not in PRESETS: return false
	if value.has(FIELDS[1]):
		var factor: Variant = value[FIELDS[1]]
		if not (factor is float or factor is int) or not is_finite(float(factor)) \
			or float(factor) < LIMITS.x or float(factor) > LIMITS.y: return false
	return true

static func display_ratio(source: float, preset: String, factor: float) -> float:
	return float(RATIOS.get(preset, source)) * factor

static func slider_fraction(factor: float) -> float:
	return (log(clampf(factor, LIMITS.x, LIMITS.y)) / log(2.0) + 1.0) * 0.5

static func slider_value(fraction: float) -> float:
	if absf(fraction - 0.5) < 0.005: return 1.0
	return clampf(snappedf(pow(2.0, clampf(fraction, 0.0, 1.0) * 2.0 - 1.0), LIMITS.z), LIMITS.x, LIMITS.y)

static func choices() -> Array:
	var result: Array = []
	for preset in PRESETS:
		result.append({"value": preset, "label": "Original ratio" if preset == "original" else preset})
	return result
