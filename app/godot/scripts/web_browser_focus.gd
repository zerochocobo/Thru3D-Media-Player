extends RefCounted
## One normalized, top-left crop drives both compositor and pointer coordinates.
const FULL := Rect2(0, 0, 1, 1)
const AXIS_DEADZONE := 0.005
static func selection(a: Vector2, b: Vector2) -> Rect2:
	if not a.is_finite() or not b.is_finite(): return Rect2()
	# Free rectangle: width and height follow the drag independently, so a tall or wide
	# region can be focused. Dragging past an edge stops at that edge only.
	var start := a.clamp(Vector2.ZERO, Vector2.ONE)
	var end := b.clamp(Vector2.ZERO, Vector2.ONE)
	return Rect2(start.min(end), (end - start).abs())
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

## Auto select: the picture inside a page shown with black bars (a letterboxed or pillarboxed
## player). Rows and columns count as picture when enough of their pixels are not black; the
## longest run wins, so a caption or a progress bar on a black bar does not stretch the box.
## Returns an empty rect when nothing but black is found.
static func content_rect(image: Image, level: int = 18, share: float = 0.04) -> Rect2:
	if image == null or image.is_empty(): return Rect2()
	if image.get_format() != Image.FORMAT_RGBA8:
		image = image.duplicate(); image.convert(Image.FORMAT_RGBA8)
	var w := image.get_width()
	var h := image.get_height()
	var data := image.get_data()
	var rows := PackedInt32Array(); rows.resize(h)
	for y in h:
		var count := 0
		var at := y * w * 4
		for x in w:
			if data[at] > level or data[at + 1] > level or data[at + 2] > level: count += 1
			at += 4
		rows[y] = count
	var vertical := _longest_run(rows, maxi(2, int(w * share)), maxi(1, h / 40))
	if vertical.y < vertical.x: return Rect2()
	var columns := PackedInt32Array(); columns.resize(w)
	for y in range(vertical.x, vertical.y + 1):
		var at := y * w * 4
		for x in w:
			if data[at] > level or data[at + 1] > level or data[at + 2] > level: columns[x] += 1
			at += 4
	var horizontal := _longest_run(columns, maxi(2, int((vertical.y - vertical.x + 1) * share)), maxi(1, w / 40))
	if horizontal.y < horizontal.x: return Rect2()
	return Rect2(float(horizontal.x) / w, float(vertical.x) / h,
		float(horizontal.y - horizontal.x + 1) / w, float(vertical.y - vertical.x + 1) / h)

## First and last index of the longest run of counts >= minimum, bridging gaps up to `gap` long
## (dark lines inside a picture). (0, -1) when there is none.
static func _longest_run(counts: PackedInt32Array, minimum: int, gap: int) -> Vector2i:
	var best := Vector2i(0, -1)
	var start := -1
	var last := -1
	for i in counts.size() + 1:
		var lit := i < counts.size() and counts[i] >= minimum
		if lit:
			if start < 0 or i - last > gap + 1: 
				if start >= 0 and last - start > best.y - best.x: best = Vector2i(start, last)
				start = i
			last = i
	if start >= 0 and last - start > best.y - best.x: best = Vector2i(start, last)
	return best

## ---- Smart auto select: where on the page is the playing picture? -------------------------
## Works from a short burst of small captures of the whole page (any layout, light or dark):
## 1. motion: pixels that change between captures belong to the playing video;
## 2. edges: each side snaps to the strongest straight edge nearby (the player's real border);
## 3. bars: black bars inside that box are trimmed (content_rect).
## A paused video has no motion, so the black-bar search on the whole page is the fallback.
## Returns an empty rect when no picture is found.
static func smart_rect(frames: Array) -> Rect2:
	if frames.is_empty(): return Rect2()
	var last: Image = frames.back()
	var w := last.get_width()
	var h := last.get_height()
	var lumas: Array[PackedByteArray] = []
	for frame in frames:
		var grey: Image = frame.duplicate()
		grey.convert(Image.FORMAT_L8)
		if grey.get_width() != w or grey.get_height() != h: return Rect2()
		lumas.append(grey.get_data())
	var box := motion_box(lumas, w, h)
	if box.size.x < w * 0.1 or box.size.y < h * 0.1:
		return content_rect(last)
	box = snap_box(lumas.back(), w, h, box)
	# Black bars inside the player (a 21:9 film in a 16:9 player), unless the scene is just dark.
	var inner := content_rect(last.get_region(box))
	if valid(inner) and inner.size.x >= 0.5 and inner.size.y >= 0.5:
		box = Rect2i(box.position + Vector2i((inner.position * Vector2(box.size)).round()), Vector2i((inner.size * Vector2(box.size)).round()))
	return Rect2(Vector2(box.position) / Vector2(w, h), Vector2(box.size) / Vector2(w, h)).intersection(FULL)

## Bounding box (pixels) of the main moving region across consecutive luma frames.
static func motion_box(lumas: Array[PackedByteArray], w: int, h: int, level: int = 10) -> Rect2i:
	var rows := PackedInt32Array(); rows.resize(h)
	var moved := PackedByteArray(); moved.resize(w * h)
	for index in range(1, lumas.size()):
		var a := lumas[index - 1]
		var b := lumas[index]
		for i in w * h:
			if moved[i] == 0 and absi(a[i] - b[i]) > level: moved[i] = 1
	for y in h:
		var count := 0
		var at := y * w
		for x in w: count += moved[at + x]
		rows[y] = count
	# Static parts of a picture leave gaps: bridge up to a twelfth of the page.
	var vertical := _longest_run(rows, maxi(3, w / 20), maxi(1, h / 12))
	if vertical.y < vertical.x: return Rect2i()
	var columns := PackedInt32Array(); columns.resize(w)
	for y in range(vertical.x, vertical.y + 1):
		var at := y * w
		for x in w: columns[x] += moved[at + x]
	var horizontal := _longest_run(columns, maxi(3, (vertical.y - vertical.x + 1) / 20), maxi(1, w / 12))
	if horizontal.y < horizontal.x: return Rect2i()
	return Rect2i(horizontal.x, vertical.x, horizontal.y - horizontal.x + 1, vertical.y - vertical.x + 1)

## Moves each side of the box onto the strongest straight edge near it. Motion usually stops
## short of the player's border, so the search reaches further outwards than inwards.
static func snap_box(luma: PackedByteArray, w: int, h: int, box: Rect2i, strength: float = 10.0) -> Rect2i:
	var left := box.position.x
	var top := box.position.y
	var right := box.end.x # exclusive
	var bottom := box.end.y
	var reach_x := maxi(2, w / 6)
	var reach_y := maxi(2, h / 6)
	left = _best_edge(luma, w, h, true, left, left - reach_x, left + reach_x / 8, top, bottom, strength)
	right = _best_edge(luma, w, h, true, right, right - reach_x / 8, right + reach_x, top, bottom, strength)
	top = _best_edge(luma, w, h, false, top, top - reach_y, top + reach_y / 8, left, right, strength)
	bottom = _best_edge(luma, w, h, false, bottom, bottom - reach_y / 8, bottom + reach_y, left, right, strength)
	return Rect2i(left, top, maxi(1, right - left), maxi(1, bottom - top))

## The boundary index in [from, to] (a line between pixel index-1 and index) with the largest mean
## luma step along [start, end); `fallback` when none is strong enough. The page's own edge counts.
static func _best_edge(luma: PackedByteArray, w: int, h: int, vertical: bool, fallback: int, from: int, to: int,
		start: int, end: int, strength: float) -> int:
	var limit := w if vertical else h
	var best := fallback
	var best_step := strength
	for index in range(maxi(from, 0), mini(to, limit) + 1):
		if index == 0 or index == limit: 
			if absi(index - fallback) <= 2: return index
			continue
		var total := 0
		for along in range(start, end):
			var a := luma[along * w + index - 1] if vertical else luma[(index - 1) * w + along]
			var b := luma[along * w + index] if vertical else luma[index * w + along]
			total += absi(a - b)
		var step := float(total) / maxi(1, end - start)
		if step > best_step:
			best_step = step; best = index
	return best

