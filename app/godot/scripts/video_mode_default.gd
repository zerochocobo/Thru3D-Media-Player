extends RefCounted
## A layout preference only: no file identity, effects, alignment or playback state.
const TITLE := "Reuse last video mode"
const HINT := "Use the last video mode when there is no filename match or saved per-file mode."

static func clean(value: Variant) -> Dictionary:
	if not value is Dictionary: return {}
	for key in ["geometry", "layout", "fisheye_fov"]:
		if not (value.get(key) is int or value.get(key) is float): return {}
		if not is_finite(float(value[key])) or float(value[key]) != float(int(value[key])): return {}
	if int(value.geometry) not in [0, 1, 2, 3] or int(value.layout) not in [0, 1, 2, 3, 4] \
		or int(value.fisheye_fov) not in [180, 190, 200, 220] or not value.get("swap_eyes", false) is bool: return {}
	return {"geometry": int(value.geometry), "layout": int(value.layout), "fisheye_fov": int(value.fisheye_fov),
		"swap_eyes": bool(value.get("swap_eyes", false)) and int(value.layout) != 0}

static func naming(mode: Dictionary) -> Dictionary:
	return {"geometry": mode.geometry, "stereo": int(mode.layout) != 0, "top_bottom": int(mode.layout) in [2, 4],
		"stereo_half": int(mode.layout) in [3, 4], "swap": mode.swap_eyes}
