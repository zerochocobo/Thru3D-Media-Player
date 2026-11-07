extends RefCounted
## One normalized, top-left crop drives both compositor and pointer coordinates.
const FULL := Rect2(0, 0, 1, 1)
const AXIS_DEADZONE := 0.005
static func selection(a: Vector2, b: Vector2) -> Rect2:
	if not a.is_finite() or not b.is_finite(): return Rect2()
	var start := a.clamp(Vector2.ZERO, Vector2.ONE)
	var end := b.clamp(Vector2.ZERO, Vector2.ONE)
	var delta := end - start
	var direction := Vector2(-1 if delta.x < 0 else 1, -1 if delta.y < 0 else 1)
	# Near-horizontal/vertical controller jitter must not flip the whole box.
	if absf(delta.x) < AXIS_DEADZONE: direction.x = 1 if start.x <= 0.5 else -1
	if absf(delta.y) < AXIS_DEADZONE: direction.y = 1 if start.y <= 0.5 else -1
	# Equal UV extents occupy the same fraction of the current page's width and
	# height, so the visible box has that page's aspect in floating and cinema modes.
	var available := Vector2(start.x if direction.x < 0 else 1 - start.x, start.y if direction.y < 0 else 1 - start.y)
	var side := minf(maxf(absf(delta.x), absf(delta.y)), minf(available.x, available.y))
	end = start + direction * side
	return Rect2(start.min(end), Vector2.ONE * side)
static func valid(rect: Rect2) -> bool:
	return rect.position.is_finite() and rect.size.is_finite() and FULL.encloses(rect) and rect.size.x >= 0.04 and rect.size.y >= 0.04
static func fitted(frame: Vector2, _source: Vector2, crop: Rect2) -> Vector2:
	if crop == FULL or not valid(crop): return frame
	# Fit the rectangle the viewer actually drew. Texture pixel quantization must
	# not introduce a second aspect ratio after the full page was sized to its frame.
	var size := frame * crop.size
	return size * minf(frame.x / size.x, frame.y / size.y)
static func map_point(point: Vector2, crop: Rect2) -> Vector2:
	return crop.position + point * crop.size
