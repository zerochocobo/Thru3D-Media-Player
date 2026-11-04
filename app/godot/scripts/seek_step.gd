extends RefCounted
## One global step for both controller hands, including remapped seek actions.
const KEY := "seek_step_seconds"
const DEFAULT := 10
const MIN := 3
const MAX := 30

static func normalize(value: Variant) -> int:
	if not (value is int or value is float) or not is_finite(float(value)): return DEFAULT
	return roundi(clampf(float(value), MIN, MAX))

static func seconds(settings: ConfigFile) -> int:
	return normalize(settings.get_value("video", KEY, DEFAULT))

static func milliseconds(settings: ConfigFile) -> int:
	return seconds(settings) * 1000
