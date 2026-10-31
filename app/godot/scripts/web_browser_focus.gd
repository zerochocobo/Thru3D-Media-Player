extends RefCounted
## One normalized, top-left crop drives both compositor and pointer coordinates.
const FULL := Rect2(0, 0, 1, 1)
static func selection(a: Vector2, b: Vector2) -> Rect2:
	var start := a.clamp(Vector2.ZERO, Vector2.ONE)
	var end := b.clamp(Vector2.ZERO, Vector2.ONE)
	return Rect2(start.min(end), (start - end).abs())
static func valid(rect: Rect2) -> bool:
	return rect.position.is_finite() and rect.size.is_finite() and FULL.encloses(rect) and rect.size.x >= 0.04 and rect.size.y >= 0.04
static func fitted(frame: Vector2, source: Vector2, crop: Rect2) -> Vector2:
	if crop == FULL: return frame
	var pixels := ((crop.end * source).round() - (crop.position * source).round()).max(Vector2.ONE)
	return pixels * minf(frame.x / pixels.x, frame.y / pixels.y)
static func map_point(point: Vector2, crop: Rect2) -> Vector2:
	return crop.position + point * crop.size
