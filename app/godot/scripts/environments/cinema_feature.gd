extends RefCounted
## The explicitly labelled test auditorium is available in Debug and Release.

static func enabled() -> bool:
	return true

static func normalize_background(value: String) -> String:
	return "belfast" if value == "cinema" and not enabled() else value
