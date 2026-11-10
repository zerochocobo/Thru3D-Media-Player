extends RefCounted
## The same layout contract as video, restricted to the photo viewer's layouts.
const Layout := preload("res://scripts/video_mode_default.gd")
const TITLE := "Reuse last photo mode"
const HINT := "Use the last photo mode when there is no filename match or saved per-photo mode."

static func clean(value: Variant) -> Dictionary:
	var mode := Layout.clean(value)
	return mode if not mode.is_empty() and int(mode.layout) in [0, 1, 2] else {}

static func resolved(mode: Dictionary) -> Dictionary:
	return {"geometry": mode.geometry, "stereo_sbs": int(mode.layout) != 0, "top_bottom": int(mode.layout) == 2,
		"swap_eyes": mode.swap_eyes, "fisheye_fov": mode.fisheye_fov}
