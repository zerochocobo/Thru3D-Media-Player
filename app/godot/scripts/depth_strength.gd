extends RefCounted
## Shared parallax scale. Video boost extends the normal 100% rail to 200%; photos keep their own mapping.
const MAX := 1.0
const VIDEO_MAX := 2.0
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

## Video 100% became the former 50% (2026-10-30). A video strength saved on the old scale is
## doubled once (at most 100%) so the chosen parallax stays the same. True when settings changed.
const VIDEO_SCALE := 2
static func migrate_video_scale(settings: ConfigFile) -> bool:
	if int(settings.get_value("video", "depth_strength_scale", 1)) >= VIDEO_SCALE: return false
	var value: Variant = settings.get_value("video", "depth_strength") if settings.has_section_key("video", "depth_strength") else null
	if (value is float or value is int) and is_finite(float(value)) and float(value) > 0.0:
		settings.set_value("video", "depth_strength", clamp_value(float(value) * 2.0))
	settings.set_value("video", "depth_strength_scale", VIDEO_SCALE)
	return true

static func load_preference(settings: ConfigFile, for_photo: bool) -> float:
	var fallback := PHOTO_DEFAULT if for_photo else VIDEO_DEFAULT
	var value: Variant = settings.get_value("photo" if for_photo else "video", "depth_strength", fallback)
	return remembered(float(value), PHOTO_MAX if for_photo else VIDEO_MAX, fallback) if value is float or value is int else fallback

## Video uses the whole track linearly for 0..100%. Photos retain their wider
## range: the first fifth covers 0..50%, then the rest reaches 200% linearly.
static func from_fraction(fraction: float, maximum: float = MAX) -> float:
	var f := clampf(fraction, 0.0, 1.0)
	if maximum == MAX: return clamp_value(f, maximum)
	return clamp_value(f * 2.5 if f < 0.2 else 0.5 + (f - 0.2) * ((maximum - 0.5) / 0.8), maximum)

static func to_fraction(value: float, maximum: float = MAX) -> float:
	var v := clamp_value(value, maximum)
	if maximum == MAX: return v
	return v / 2.5 if v < 0.5 else 0.2 + (v - 0.5) / ((maximum - 0.5) / 0.8)
