extends RefCounted
## Video and web 2D to 3D: at the picture's left and right edges the depth is held inside a cone around
## the screen plane (native/rvm/near_edge_fade.h), so the parallax is zero at the frame: nothing in front
## of the screen is cut by the frame at a different place in each eye, and the edge column no longer
## repeats where an eye would read past the picture. One preference shared by the library and playback
## settings, followed by the browser. Edge stretching only, like steady edges.
const KEY := "depth_edge_fade"
## Off until it has been judged in the headset (2026-11-24).
const DEFAULT := false
const TITLE := "Flat frame edges"
const HINT := "The 3D effect eases to the screen at the left and right edges of the picture: nothing in front of the screen is cut off by the frame, and the edges stop smearing. Things at the very edge look flatter. Works with Stretch edges."

static func load_enabled(settings: ConfigFile) -> bool:
	return bool(settings.get_value("video", KEY, DEFAULT))

static func choice(enabled: bool) -> Dictionary:
	return {"key": KEY, "value": enabled, "choices": [
		{"value": false, "label": "Off", "hint": HINT}, {"value": true, "label": "On", "hint": HINT}]}
