extends RefCounted
## Bound each group's visual span; chaining adjacent points cannot collapse the whole timeline.
# Share the hit width with the renderer: spare padding must not hide distinct markers.
const MARKER_WIDTH := 0.044

static func groups(markers: Array, duration_ms: int, width: float, pitch: float = MARKER_WIDTH) -> Array:
	var result: Array = []
	if duration_ms <= 0: return result
	for marker in markers:
		var time := int(marker.position_ms)
		if time < 0 or time >= duration_ms: continue
		var x := -width / 2 + width * float(time) / duration_ms
		if result.is_empty() or x - float(result.back().first_x) >= pitch:
			result.append({"first_x": x, "x": x, "markers": [marker]})
		else:
			result.back().markers.append(marker)
	return result
