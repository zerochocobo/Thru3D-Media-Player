extends RefCounted
## One normalized, top-left crop drives both compositor and pointer coordinates.
const FULL := Rect2(0, 0, 1, 1)
## Visible aspects a focused floating window may take. Regions are not only
## video (article columns, image strips); anything thinner is an unusable sliver.
const MIN_ASPECT := 1.0 / 3.0
const MAX_ASPECT := 3.0
const AXIS_DEADZONE := 0.005
## Free box from the press `a` to the drag point `b`. With a `frame` (the page's
## visible size) the box's shape is held within MIN/MAX_ASPECT while dragging,
## growing its short side away from the press, so the outline is the result.
static func selection(a: Vector2, b: Vector2, frame := Vector2.ZERO) -> Rect2:
	if not a.is_finite() or not b.is_finite(): return Rect2()
	var start := a.clamp(Vector2.ZERO, Vector2.ONE)
	var end := b.clamp(Vector2.ZERO, Vector2.ONE)
	var delta := end - start
	if not (frame.x > 0.0 and frame.y > 0.0): return Rect2(start.min(end), delta.abs())
	var direction := Vector2(-1 if delta.x < 0 else 1, -1 if delta.y < 0 else 1)
	# Near-horizontal/vertical controller jitter must not flip the grown side.
	if absf(delta.x) < AXIS_DEADZONE: direction.x = 1 if start.x <= 0.5 else -1
	if absf(delta.y) < AXIS_DEADZONE: direction.y = 1 if start.y <= 0.5 else -1
	var available := Vector2(start.x if direction.x < 0 else 1 - start.x, start.y if direction.y < 0 else 1 - start.y)
	var size := delta.abs()
	var scale := frame.x / frame.y # visible aspect of a box with equal UV extents
	if size.x * scale > MAX_ASPECT * size.y:
		size.y = minf(size.x * scale / MAX_ASPECT, available.y)
		size.x = minf(size.x, size.y * MAX_ASPECT / scale)
	elif size.x * scale < MIN_ASPECT * size.y:
		size.x = minf(size.y * MIN_ASPECT / scale, available.x)
		size.y = minf(size.y, size.x * scale / MIN_ASPECT)
	end = start + direction * size
	return Rect2(start.min(end), size)
static func valid(rect: Rect2) -> bool:
	return rect.position.is_finite() and rect.size.is_finite() and FULL.encloses(rect) and rect.size.x >= 0.04 and rect.size.y >= 0.04
## Grows `crop` about its centre until its visible aspect on `frame` lies within
## [low, high], staying inside the page. A fixed screen passes its own aspect for
## both bounds, so the region fills it with surrounding page instead of margins.
static func framed(crop: Rect2, frame: Vector2, low: float, high: float) -> Rect2:
	if crop == FULL or not valid(crop): return crop
	var aspect := frame.x * crop.size.x / (frame.y * crop.size.y)
	var target := clampf(aspect, low, high)
	if is_equal_approx(aspect, target): return crop
	var size := crop.size
	if aspect < target: size.x = target * frame.y * size.y / frame.x
	else: size.y = frame.x * size.x / (target * frame.y)
	size = size.min(Vector2.ONE)
	var position := (crop.get_center() - size / 2).clamp(Vector2.ZERO, Vector2.ONE - size)
	return Rect2(position, size)
## Size of a floating window focused on `crop` of a `page`: the crop's visible
## aspect at the page's own area, so focusing never makes the picture smaller.
static func focused_size(page: Vector2, crop: Rect2) -> Vector2:
	if crop == FULL or not valid(crop): return page
	return area_size(page, page.x * crop.size.x / (page.y * crop.size.y))
## A rectangle of `aspect` with the same area as `page`.
static func area_size(page: Vector2, aspect: float) -> Vector2:
	var width := sqrt(page.x * page.y * aspect)
	return Vector2(width, width / aspect)
static func fitted(frame: Vector2, _source: Vector2, crop: Rect2) -> Vector2:
	if crop == FULL or not valid(crop): return frame
	# Fit the rectangle the viewer actually drew. Texture pixel quantization must
	# not introduce a second aspect ratio after the full page was sized to its frame.
	var size := frame * crop.size
	return size * minf(frame.x / size.x, frame.y / size.y)
static func map_point(point: Vector2, crop: Rect2) -> Vector2:
	return crop.position + point * crop.size
## Focus video: the page's video picture from each frame's report (video-focus.js),
## as a region of the top frame's viewport; Rect2() when none is worth focusing.
## A playing video wins unless a paused one is much larger (a muted preview beside it).
## Players without a picture yet count only when no frame shows a video, the surest
## kind first: an embedded player frame reporting itself, then a video the page hides
## until its first frame, then an iframe that looks like a player from outside.
const FALLBACK_ORDER := ["player", "video", "embed"]
static func video_region(frames: Array) -> Rect2:
	var top: Dictionary = {}
	for frame in frames:
		if frame is Dictionary and frame.get("top", false): top = frame; break
	var view := _numbers(top.get("view"), 4)
	if view.size() < 4 or view[2] <= 0.0 or view[3] <= 0.0: return Rect2()
	var origin := _numbers(top.get("screen"), 2)
	if origin.size() < 2: return Rect2()
	var shown := _candidates(frames, top, view, origin, "videos")
	if shown.is_empty():
		var fallback := _candidates(frames, top, view, origin, "fallback")
		for kind in FALLBACK_ORDER:
			shown = fallback.filter(func(item): return item.kind == kind)
			if not shown.is_empty(): break
	var best := Rect2()
	var best_playing := Rect2()
	for item in shown:
		if item.rect.get_area() > best.get_area(): best = item.rect
		if item.playing and item.rect.get_area() > best_playing.get_area(): best_playing = item.rect
	return best_playing if best_playing.has_area() and best_playing.get_area() * 4.0 >= best.get_area() else best
## Every frame's `key` list as {rect, playing} regions of the top viewport.
static func _candidates(frames: Array, top: Dictionary, view: PackedFloat64Array, origin: PackedFloat64Array, key: String) -> Array:
	var result := []
	for frame in frames:
		if not frame is Dictionary: continue
		var screen := _numbers(frame.get("screen"), 2)
		if screen.size() < 2: continue
		# An iframe's rectangles are in its own viewport; the screen origins give its place in the page.
		var offset := Vector2(view[0], view[1]) if frame == top else Vector2(origin[0] - screen[0], origin[1] - screen[1])
		var items: Variant = frame.get(key, [])
		if not items is Array: continue
		for item in items.slice(0, 16):
			if not item is Dictionary: continue
			var rect := _numbers(item.get("rect"), 4)
			if rect.size() < 4: continue
			var uv := Rect2((Vector2(rect[0], rect[1]) - offset) / Vector2(view[2], view[3]), Vector2(rect[2], rect[3]) / Vector2(view[2], view[3])).intersection(FULL)
			if valid(uv) and uv.get_area() >= 0.01: result.append({"rect": uv, "playing": item.get("playing", false) == true, "kind": str(item.get("kind", ""))})
	return result
static func _numbers(value: Variant, count: int) -> PackedFloat64Array:
	var result := PackedFloat64Array()
	if not value is Array or value.size() < count: return result
	for index in count:
		if not (value[index] is float or value[index] is int) or not is_finite(float(value[index])): return PackedFloat64Array()
		result.append(float(value[index]))
	return result
