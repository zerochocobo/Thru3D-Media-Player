extends RefCounted
## The auditorium experiment follows the engine build, never a saved preference.

static func enabled() -> bool:
	return OS.is_debug_build()

static func normalize_background(value: String) -> String:
	return "belfast" if value == "cinema" and not enabled() else value
