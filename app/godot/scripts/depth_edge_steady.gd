extends RefCounted
## Video 2D to 3D: depth contours refitted to the picture's own (the guided filter of He, Sun and Tang,
## "Guided Image Filtering", ECCV 2010 / TPAMI 2013; see render_bridge.cpp), one preference shared by the
## library and playback settings. Edge stretching only: with Fill gaps the snapped steps follow picture
## texture and shred (research/video_depth_replay/photo_fill_sheet.py). Photos keep their own switch
## (photo/edge_steady, PhotoDisplay), likewise for edge stretching only.
const KEY := "depth_edge_steady"
## On for everyone (user decision, 2026-11-22): new viewers should meet the steadier edges.
const DEFAULT := true
const TITLE := "Steady edges"
const HINT := "Object edges in 3D follow the picture's own outlines and shimmer less, and look slightly softer in depth. Works with Stretch edges."

static func load_enabled(settings: ConfigFile) -> bool:
	return bool(settings.get_value("video", KEY, DEFAULT))

static func choice(enabled: bool) -> Dictionary:
	return {"key": KEY, "value": enabled, "choices": [
		{"value": false, "label": "Off", "hint": HINT}, {"value": true, "label": "On", "hint": HINT}]}
