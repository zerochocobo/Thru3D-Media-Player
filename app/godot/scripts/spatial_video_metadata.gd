extends RefCounted
## Source metadata only; display preferences and manual corrections live separately.

static func normalize(value: Variant) -> Dictionary:
	var result := {}
	if not value is Dictionary: return result
	for key in ["baseline_meters", "horizontal_fov_degrees", "horizontal_disparity"]:
		var number: Variant = value.get(key)
		if not (number is int or number is float) or not is_finite(float(number)): continue
		var n := float(number)
		if key == "baseline_meters" and n > 0.0 and n <= 4294.967295: result[key] = n
		elif key == "horizontal_fov_degrees" and n > 0.0 and n < 180.0: result[key] = n
		elif key == "horizontal_disparity" and absf(n) <= 1.0: result[key] = n
	return result

static func fov_scale(fov: float, distance: float, base_width: float) -> float:
	if not is_finite(fov) or not is_finite(distance) or not is_finite(base_width) \
		or fov <= 0.0 or fov >= 180.0 or distance <= 0.0 or base_width <= 0.0: return -1.0
	return 2.0 * distance * tan(deg_to_rad(fov) * 0.5) / base_width
