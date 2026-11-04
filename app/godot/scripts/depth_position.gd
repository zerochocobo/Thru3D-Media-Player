extends RefCounted
## User offset from the existing screen plane, independent of disparity strength.
const KEY := "depth_position"
const TITLE := "3D position"
const HINT := "Left: into screen. Right: out of screen. 0: default."
const LIMITS := Vector3(-100, 100, 5)

static func normalize(value: Variant) -> float:
	if not (value is float or value is int) or not is_finite(float(value)): return 0.0
	return snappedf(clampf(float(value), LIMITS.x, LIMITS.y), LIMITS.z)

static func convergence(value: Variant) -> float:
	return 0.35 - normalize(value) * 0.003

static func load_value(settings: ConfigFile, for_photo: bool = false) -> float:
	return normalize(settings.get_value("photo" if for_photo else "video", KEY, 0.0))

static func row(value: Variant, key: String = KEY) -> Dictionary:
	return {"key": key, "value": normalize(value), "slider": true, "span": LIMITS,
		"unit": "", "decimals": 0, "signed": true, "reset_value": 0.0, "hint": HINT}
