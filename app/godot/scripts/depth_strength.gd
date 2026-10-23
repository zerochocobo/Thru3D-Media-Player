extends RefCounted
## Shared parallax scale: videos stop at 100%, photos retain their 200% range.
const MAX := 1.0
const PHOTO_MAX := 2.0 # photo_limit_gradient keeps 200% hole fills clean
const DEFAULT := 1.0
const VIDEO_DEFAULT := 0.5
const PHOTO_DEFAULT := 1.0
const STEP := 0.01

static func clamp_value(value: float, maximum: float = MAX) -> float:
	return snappedf(clampf(value, 0.0, maximum), STEP) if is_finite(value) else minf(DEFAULT, maximum)

static func remembered(value: float, maximum: float = MAX, fallback: float = DEFAULT) -> float:
	if not is_finite(value): return fallback
	var result := clamp_value(value, maximum)
	return result if result > 0.0 else fallback

static func load_preference(settings: ConfigFile, for_photo: bool) -> float:
	var fallback := PHOTO_DEFAULT if for_photo else VIDEO_DEFAULT
	var value: Variant = settings.get_value("photo" if for_photo else "video", "depth_strength", fallback)
	return remembered(float(value), PHOTO_MAX if for_photo else MAX, fallback) if value is float or value is int else fallback

## The first fifth covers 0..50% (the bottom snaps to off); the rest reaches
## the media-specific maximum linearly.
static func from_fraction(fraction: float, maximum: float = MAX) -> float:
	var f := clampf(fraction, 0.0, 1.0)
	return clamp_value(f * 2.5 if f < 0.2 else 0.5 + (f - 0.2) * ((maximum - 0.5) / 0.8), maximum)

static func to_fraction(value: float, maximum: float = MAX) -> float:
	var v := clamp_value(value, maximum)
	return v / 2.5 if v < 0.5 else 0.2 + (v - 0.5) / ((maximum - 0.5) / 0.8)
