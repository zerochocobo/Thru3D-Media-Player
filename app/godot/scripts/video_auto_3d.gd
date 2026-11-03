extends RefCounted
## One video-only preference shared by the library and playback settings.
const TITLE := "2D to 3D by default"
const HINT := "Convert flat videos to 3D by default; unrecognized VR videos may need a manual playback mode change."

static func load_enabled(settings: ConfigFile) -> bool:
	return bool(settings.get_value("video", "auto_3d", false))

static func choice(enabled: bool) -> Dictionary:
	return {"key": "video_auto_3d", "value": enabled, "choices": [
		{"value": false, "label": "Off", "hint": HINT}, {"value": true, "label": "On", "hint": HINT}]}
