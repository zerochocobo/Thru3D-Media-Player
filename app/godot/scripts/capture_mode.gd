extends RefCounted

static func clean(value: Variant, allow_flat: bool = false) -> Dictionary:
	if not value is Dictionary or int(value.get("version", 0)) != 1: return {}
	if not value.get("geometry") is int and not value.get("geometry") is float: return {}
	if float(value.geometry) != floorf(float(value.geometry)) or int(value.geometry) not in ([0, 1, 2, 3] if allow_flat else [1, 2, 3]): return {}
	if int(value.get("fisheye_fov", 180)) not in [180, 190, 200, 220]: return {}
	for field in ["stereo_sbs", "top_bottom", "stereo_half", "swap_eyes"]:
		if not value.get(field, false) is bool: return {}
	return {"version": 1, "geometry": int(value.geometry), "stereo_sbs": bool(value.get("stereo_sbs", false)),
		"top_bottom": bool(value.get("top_bottom", false)), "stereo_half": bool(value.get("stereo_half", false)),
		"swap_eyes": bool(value.get("swap_eyes", false)), "fisheye_fov": int(value.get("fisheye_fov", 180))}
