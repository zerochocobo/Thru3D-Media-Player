extends RefCounted
## Foreground scale: how the depth is shared between near and far (native near_foreground.h).
## Global like the convergence (DepthPosition), independent of disparity strength.
const KEY := "depth_foreground"
const TITLE := "3D foreground scale"
const HINT := "How depth is shared between near and far. Right: people and nearby things get more depth and the background flattens. Left: the background gets deeper and the foreground flattens. 0: default."
const LIMITS := Vector3(-100, 100, 5)

static func normalize(value: Variant) -> float:
	if not (value is float or value is int) or not is_finite(float(value)): return 0.0
	return snappedf(clampf(float(value), LIMITS.x, LIMITS.y), LIMITS.z)

## The bridge's -1..1 scale (an exponent of 2^scale on the near map).
static func scale(value: Variant) -> float:
	return normalize(value) / LIMITS.y

static func load_value(settings: ConfigFile) -> float:
	return normalize(settings.get_value("video", KEY, 0.0))

static func row(value: Variant, key: String = KEY) -> Dictionary:
	return {"key": key, "value": normalize(value), "slider": true, "span": LIMITS,
		"unit": "", "decimals": 0, "signed": true, "reset_value": 0.0, "hint": HINT}
