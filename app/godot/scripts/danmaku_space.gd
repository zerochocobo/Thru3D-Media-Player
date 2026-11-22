extends Node3D

const Geometry := preload("res://scripts/video_geometry.gd")
const ProjectedSubtitles := preload("res://scripts/projected_subtitles.gd")
const Menu := preload("res://scripts/ray_menu.gd")
const RING := 0
const RAIN := 1
# Text sizes are defined at RADIUS. Each comment gets its own distance, so stereo
# depth and a slight size falloff separate overlapping layers.
const RADIUS := 3.4
const RING_NEAR := 2.6
const RING_FAR := 5.0
const RAIN_NEAR := 2.3
const RAIN_FAR := 5.4
const RAIN_JITTER := 0.3
const FALLOFF := 0.3
# About 1.9° per em at RADIUS. The raster stays close to the eye-buffer size, so it
# needs no mipmaps (font atlas uploads would have to rebuild them on every new glyph).
const FONT_SIZE := 48
const PIXEL_SIZE := 0.0023
const OUTLINE_SIZE := 6
const GAP := 0.3
const MAX_WIDTH := 2.4
const RAIN_CHARACTERS := 14
# Each ring comment makes one lap: it enters behind the viewer, crosses the picture
# direction at its own timestamp and leaves behind the viewer again. All comments share
# one angular speed, so lane gaps hold at any distance. Lanes are elevations spread
# evenly over RING_SPAN above and below eye level, about the headset's vertical view.
const RING_PERIOD_MS := 20000.0
const TURN := TAU / RING_PERIOD_MS
const RING_SPAN := PI / 4
# Rain columns cross eye level at the comment time and fall from above to below the view.
# They share one linear speed, so farther columns fall more slowly across the view.
# Columns are azimuths spread evenly over RAIN_SPAN either side of the picture.
const RAIN_SPEED := 0.0006
const RAIN_REACH := 3.5
const RAIN_SPAN := PI / 3
# Outside-the-picture lanes keep this angle from the picture edge, and still get at
# least OUTSIDE_REACH of room when the picture is wider than the usual span.
const OUTSIDE_MARGIN := 0.05
const OUTSIDE_REACH := 0.35
# Lanes over the span and comments laid out at once (across the whole lap or fall) per
# density. VR has room for many; the caps only bound per-frame work on dense videos.
const LANES := [[12, 22, 32], [20, 36, 50]]
const LIVE_LIMIT := [[200, 400, 700], [160, 320, 560]]
const REACH_MARGIN := 0.55
# The anchor eases after the viewer once they move or the picture turns beyond these
# (metres, radians), and jumps with a scene change or a seat move.
const FOLLOW_REACH := 0.35
const FOLLOW_TURN := 0.15
const FOLLOW_SNAP := 1.5
const FOLLOW_RATE := 4.0

var _anchored := false
var _heading := 0.0
var _origin := Vector3.ZERO
var _scale := 1.0
var _base := 0.0
var _mode := RING
var _density := 1
var _lanes := PackedFloat32Array()
var _tails: Array = []
var _comments: Array[Dictionary] = []
var _pool: Array[Label3D] = []
var _eyes: Array[Vector3] = []
# Five cone sides per guard, flattened for the per-frame test. Zero planes never separate.
var _guard_eyes := PackedVector3Array()
var _guard_directions := PackedVector3Array()
var _guard_reach := PackedFloat32Array()
var _guard_planes := PackedVector3Array()
var _panorama_forward := Vector3.ZERO
var _panorama_cos := 0.0
var _pivot := Node3D.new()
var _font: Font
var _line := 0.0
var _frame := 0
var _following := false
var _alpha := 1.0
var _outside := false

func _init() -> void:
	add_child(_pivot)

func configure(mode: int, density: int, outside: bool = false) -> void:
	if mode != _mode: clear()
	_mode = mode
	_density = density
	_outside = outside

## 0 is opaque. Text and outline fade together.
func set_transparency(percent: float) -> void:
	_alpha = 1.0 - clampf(percent, 0.0, 90.0) / 100.0
	for comment in _comments:
		var label: Label3D = comment.label
		label.modulate.a = _alpha
		label.outline_modulate.a = _alpha

func lead_ms() -> float:
	if _mode == RING: return RING_PERIOD_MS * 0.5
	var far := RAIN_FAR + RAIN_JITTER
	return (RAIN_REACH * far / RADIUS + RAIN_CHARACTERS * _rain_height() * 0.5 * _size(far)) / RAIN_SPEED

func active_count() -> int:
	return _comments.size()

func recenter() -> void:
	_anchored = false

func clear() -> void:
	for comment in _comments:
		var label: Label3D = comment.label
		label.hide()
		_pool.append(label)
	_comments.clear()
	_tails.fill(null)

func hide_labels() -> void:
	for comment in _comments: comment.label.hide()

func prepare(video: Node3D, menu: Node3D, cover: bool, delta: float = 0.0) -> bool:
	var camera: Camera3D = video.view_camera
	if not camera or not camera.is_inside_tree() or not video.panel.visible: return false
	if not cover and video.geometry == Geometry.Geometry.EQUIRECT_360: return false
	var head := camera.global_transform.orthonormalized()
	if not head.is_finite(): return false
	_follow(video, head, delta)
	var eye_offset := head.basis.x * ProjectedSubtitles.runtime_ipd() * _scale * 0.5
	_eyes.assign([head.origin - eye_offset, head.origin + eye_offset])
	_guard_eyes.clear()
	_guard_directions.clear()
	_guard_reach.clear()
	_guard_planes.clear()
	_panorama_forward = Vector3.ZERO
	if not cover:
		if video.geometry == Geometry.Geometry.FLAT:
			_exclude(video.panel.global_transform, video.panel.get_aabb().grow(0.045))
		else:
			_panorama_forward = -video.panel.global_basis.z.normalized()
			var half_fov := maxf(90.0, float(video.fisheye_fov) / 2.0) if video.geometry == Geometry.Geometry.FISHEYE else 90.0
			var centre_offset := head.origin.distance_to(video.panel.global_position) + eye_offset.length()
			var sphere_radius: float = video.SPHERE_RADIUS * video.panel.global_basis.z.length()
			if centre_offset >= sphere_radius: return false
			var shift := asin(centre_offset / sphere_radius)
			_panorama_cos = cos(minf(PI, deg_to_rad(half_fov + 6.0) + shift))
	if video.caption.visible and not video.caption.text.is_empty():
		_exclude(video.caption.global_transform, video.caption.get_aabb().grow(0.015))
	if cover: _exclude_subtitles(video)
	if is_instance_valid(menu) and menu.is_visible_in_tree():
		for area: Dictionary in menu.danmaku_exclusions():
			var rect: Rect2 = area.rect
			if not rect.has_area(): continue
			_exclude(area.pose, AABB(Vector3(rect.position.x, rect.position.y, 0), Vector3(rect.size.x, rect.size.y, 0)).grow(0.012))
	var span := RING_SPAN if _mode == RING else RAIN_SPAN
	var intervals: Array[Vector2] = [Vector2(-span, span)]
	if _outside and not cover and video.geometry == Geometry.Geometry.FLAT:
		var picture := _picture_range(video.panel.global_transform, video.panel.get_aabb())
		var low := picture.x - OUTSIDE_MARGIN
		var high := picture.y + OUTSIDE_MARGIN
		intervals.assign([Vector2(minf(-span, low - OUTSIDE_REACH), low), Vector2(high, maxf(span, high + OUTSIDE_REACH))])
	_layout_lanes(intervals, 2.0 * span / LANES[_mode][_density])
	return true

## Keep the comments around the viewer. A scene or seat change moves the viewer far at
## once, so the anchor jumps; walking or a moved picture lets it ease after them.
func _follow(video: Node3D, head: Transform3D, delta: float) -> void:
	var flat: bool = video.geometry == Geometry.Geometry.FLAT
	var forward: Vector3 = video.panel.global_position - head.origin if flat else -head.basis.z
	var heading := atan2(forward.x, -forward.z)
	var scale := XRServer.world_scale
	var drift := head.origin.distance_to(_origin) / scale
	if not _anchored or drift > FOLLOW_SNAP or not is_equal_approx(scale, _scale):
		_origin = head.origin
		_heading = heading
		_scale = scale
		_anchored = true
		_following = false
		return
	var turn := angle_difference(_heading, heading) if flat else 0.0
	if drift > FOLLOW_REACH or absf(turn) > FOLLOW_TURN: _following = true
	if not _following: return
	var weight := 1.0 - exp(-delta * FOLLOW_RATE)
	_origin = _origin.lerp(head.origin, weight)
	_heading = wrapf(_heading + turn * weight, -PI, PI)
	if drift < 0.02 and absf(turn) < 0.01: _following = false

## Elevation (ring) or azimuth from the picture direction (rain) that the picture spans,
## seen from the anchor.
func _picture_range(pose: Transform3D, bounds: AABB) -> Vector2:
	var low := INF
	var high := -INF
	for corner in range(8):
		var offset := pose * bounds.get_endpoint(corner) - _origin
		var angle := atan2(offset.y, Vector2(offset.x, offset.z).length())
		if _mode == RAIN: angle = angle_difference(_heading, atan2(offset.x, -offset.z))
		low = minf(low, angle)
		high = maxf(high, angle)
	return Vector2(snappedf(low, 0.01), snappedf(high, 0.01))

## Ring lanes are elevations and rain lanes are azimuths, evenly spaced over each free
## interval. Comments pick among the free lanes at random, so they spread over the span.
## Text that crosses the picture while covering is off is hidden there.
func _layout_lanes(intervals: Array[Vector2], step: float) -> void:
	step = maxf(step, (_ring_height() * 1.12 if _mode == RING else FONT_SIZE * PIXEL_SIZE * 1.15) / RADIUS)
	var lanes := PackedFloat32Array()
	for interval in intervals:
		var count := int((interval.y - interval.x) / step + 0.001)
		var first := (interval.x + interval.y - (count - 1) * step) * 0.5
		for index in range(count): lanes.append(snappedf(first + index * step, 0.0001))
	if lanes == _lanes: return
	_lanes = lanes
	_tails.resize(_lanes.size())
	for comment in _comments:
		if comment.lane < _lanes.size(): _place(comment)

func _exclude_subtitles(video: Node3D) -> void:
	var material: ShaderMaterial = video.material
	if video.geometry != Geometry.Geometry.FLAT:
		if material.get_shader_parameter("subtitle_enabled") == true:
			var to_patch: Variant = material.get_shader_parameter("subtitle_world_to_patch")
			var extent: Variant = material.get_shader_parameter("subtitle_patch_half_extent")
			if to_patch is Transform3D:
				var half := float(extent) if extent != null else 0.35
				_exclude(to_patch.affine_inverse(), AABB(Vector3(-half, -half, 0), Vector3(2 * half, 2 * half, 0)).grow(0.005))
		return
	if material.get_shader_parameter("bitmap_subtitle_enabled") == true or (video._depth_subtitles and video._depth_subtitles.active):
		# The bitmap shader meshes can cover the whole video. Reserve the subtitle band.
		var screen: AABB = video.panel.get_aabb()
		var band := AABB(screen.position - Vector3(0, screen.size.y * 0.18, 0),
			Vector3(screen.size.x, screen.size.y * 0.42, screen.size.z))
		_exclude(video.panel.global_transform, band.grow(0.035))

## Build the four sides of the cone that contains the padded bounds for each eye.
## This also covers a curved screen's interior and long strings crossing an edge.
func _exclude(pose: Transform3D, bounds: AABB) -> void:
	var centre := pose * bounds.get_center()
	for eye in _eyes:
		if centre.distance_squared_to(eye) < 0.0001:
			_add_guard(eye, Vector3.FORWARD, -1.0, [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
			continue
		var direction := eye.direction_to(centre)
		var up := Vector3.FORWARD if absf(direction.y) > 0.98 else Vector3.UP
		var basis := Basis.looking_at(direction, up)
		var inverse := basis.transposed()
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		var spread := 0.0
		for corner in range(8):
			var offset := pose * bounds.get_endpoint(corner) - eye
			spread = maxf(spread, direction.angle_to(offset))
			var point := inverse * offset
			var xy := Vector2(point.x, point.y) / maxf(0.005, -point.z)
			lo = lo.min(xy)
			hi = hi.max(xy)
		_add_guard(eye, direction, cos(minf(PI, spread + REACH_MARGIN)), [
			-basis.z,
			(basis * Vector3(1, 0, lo.x)).normalized(),
			(basis * Vector3(-1, 0, -hi.x)).normalized(),
			(basis * Vector3(0, 1, lo.y)).normalized(),
			(basis * Vector3(0, -1, -hi.y)).normalized()])

func _add_guard(eye: Vector3, direction: Vector3, reach: float, planes: Array[Vector3]) -> void:
	_guard_eyes.append(eye)
	_guard_directions.append(direction)
	_guard_reach.append(reach)
	_guard_planes.append_array(PackedVector3Array(planes))

## The text is a segment along its reading axis with a thin radius. A guard misses it
## when both ends lie outside the same cone side.
func _blocked(centre: Vector3, axis: Vector3, radius: float) -> bool:
	if _panorama_forward != Vector3.ZERO:
		for eye in _eyes:
			for point in [centre - axis, centre, centre + axis]:
				var offset: Vector3 = point - eye
				if offset.normalized().dot(_panorama_forward) >= _panorama_cos - radius / maxf(offset.length(), radius):
					return true
	var near := RAIN_NEAR * 0.8 * _scale
	for guard in range(_guard_eyes.size()):
		# Cheap cone test first: the longest text seen from its own distance spans less
		# than REACH_MARGIN, so anything outside the widened cone cannot touch the guard.
		var offset := centre - _guard_eyes[guard]
		var distance := offset.length()
		if distance > near and offset.dot(_guard_directions[guard]) < distance * _guard_reach[guard]: continue
		var start := offset - axis
		var end := offset + axis
		var intersects := true
		for side in range(guard * 5, guard * 5 + 5):
			var plane := _guard_planes[side]
			if plane.dot(start) < -radius and plane.dot(end) < -radius:
				intersects = false
				break
		if intersects: return true
	return false

## World centre of a comment at a media time, for tests and screen guards.
func point(comment: Dictionary, time: float) -> Vector3:
	var lane: float = _lanes[comment.lane]
	var depth: float = comment.depth
	var angle: float = _heading + lane if _mode == RAIN else _heading + TURN * (comment.time - time)
	var height: float = RAIN_SPEED * (comment.time - time) if _mode == RAIN else depth * tan(lane)
	return _origin + Vector3(sin(angle) * depth, height, -cos(angle) * depth) * _scale

func advance(time: float) -> void:
	if absf(time - _base) > 300000.0:
		_base = time
		for comment in _comments:
			if comment.lane < _lanes.size(): _place(comment)
	# Every comment in a mode moves at the same speed, so one pivot carries all of them.
	var pivot := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * _scale), _origin)
	if _mode == RING:
		pivot.basis = Basis(Vector3.UP, TURN * (time - _base) - _heading).scaled(Vector3.ONE * _scale)
	else:
		pivot.basis = Basis(Vector3.UP, -_heading).scaled(Vector3.ONE * _scale)
		pivot.origin.y -= RAIN_SPEED * (time - _base) * _scale
	_pivot.transform = pivot
	var guarded := not _guard_eyes.is_empty() or _panorama_forward != Vector3.ZERO
	var thickness := _thickness()
	var rain := _mode == RAIN
	# The pivot moves every label each frame. Lifetime and guard state are refreshed for a
	# third of them per frame: text moves about 45 mm in three frames, inside the screen
	# margin, and the late starts and ends happen outside the view.
	_frame += 1
	var index := _comments.size() - 1 - _frame % 3
	while index >= 0:
		var comment := _comments[index]
		var label: Label3D = comment.label
		if time >= comment.end:
			label.hide(); _pool.append(label); _comments.remove_at(index)
		elif time < comment.start or comment.lane >= _lanes.size():
			label.visible = false
		elif not guarded:
			label.visible = true
		else:
			var lane: float = _lanes[comment.lane]
			var age: float = comment.time - time
			var depth: float = comment.depth
			var half: float = comment.half * _scale
			var angle := _heading + (lane if rain else TURN * age)
			var across := Vector3(sin(angle), 0, -cos(angle))
			var centre := _origin + (across * depth + Vector3(0, RAIN_SPEED * age if rain else depth * tan(lane), 0)) * _scale
			var axis := Vector3(0, half, 0) if rain else Vector3(-across.z * half, 0, across.x * half)
			label.visible = not _blocked(centre, axis, thickness * float(comment.size))
		index -= 3

func _axis(comment: Dictionary, time: float) -> Vector3:
	if _mode == RAIN: return Vector3(0, comment.half * _scale, 0)
	var angle: float = _heading + TURN * (comment.time - time)
	return Vector3(cos(angle), 0, sin(angle)) * comment.half * _scale

func _thickness() -> float:
	return (_ring_height() if _mode == RING else FONT_SIZE * PIXEL_SIZE) * 0.5 * _scale

## Assign a time-ordered comment to a random lane where it keeps its gap to the previous
## one. Ring gaps are angles and rain gaps are metres, both constant in flight.
func feed(item: Array, time: float) -> bool:
	if _lanes.is_empty() or _comments.size() >= LIVE_LIMIT[_mode][_density]: return false
	var at := int(item[0])
	var ring := _mode == RING
	var speed := TURN if ring else RAIN_SPEED
	var gap := GAP / RADIUS if ring else GAP
	var free := range(_lanes.size()).any(func(lane: int) -> bool:
		return _tails[lane] == null or (at - int(_tails[lane][0])) * speed >= float(_tails[lane][1]) + gap)
	if not free: return false
	var text := _layout_text(str(item[1]))
	var key := str(at) + str(item[1])
	var chance := float(hash(key) & 0xffff) / 65535.0
	var fits: Array[Dictionary] = []
	for lane in range(_lanes.size()):
		var depth := lerpf(RING_NEAR, RING_FAR, chance) if ring else _column_depth(lane) + (chance - 0.5) * 2.0 * RAIN_JITTER
		var size := _size(depth)
		var half := float(text.half) * size
		var extent := half / depth if ring else half
		var tail: Variant = _tails[lane]
		if tail != null and (at - int(tail[0])) * speed < float(tail[1]) + extent + gap: continue
		fits.append({"lane": lane, "depth": depth, "size": size, "half": half, "extent": extent})
	if fits.is_empty(): return false
	var fit: Dictionary = fits[(hash(key + "lane") & 0x7fffffff) % fits.size()]
	var window := RING_PERIOD_MS * 0.5 if ring else (RAIN_REACH * float(fit.depth) / RADIUS + float(fit.half)) / RAIN_SPEED
	if at + window <= time: return false
	_tails[fit.lane] = [at, fit.extent]
	var label := _take_label()
	label.text = text.text
	label.line_spacing = text.spacing
	var rgb := int(item[2])
	var color := Color.from_rgba8((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255)
	label.outline_modulate = Color(Color.WHITE if color.get_luminance() < 0.19 else Color.BLACK, _alpha)
	label.modulate = Color(color, _alpha)
	var comment := {"time": at, "lane": fit.lane, "half": fit.half, "depth": fit.depth, "size": fit.size,
		"label": label, "start": at - window, "end": at + window}
	_comments.append(comment)
	_place(comment)
	label.visible = false
	return true

## World scale of the text at a distance: nearly constant angular size, slightly smaller
## when farther away.
func _size(depth: float) -> float:
	return depth / RADIUS * pow(minf(RING_NEAR, RAIN_NEAR) / depth, FALLOFF)

## Every rain column keeps its own stable distance, so neighbouring columns separate.
func _column_depth(lane: int) -> float:
	return lerpf(RAIN_NEAR, RAIN_FAR, float(hash(lane * 7919 + 17) & 0xffff) / 65535.0)

func _layout_text(text: String) -> Dictionary:
	_measure()
	if _mode == RAIN:
		var glyphs := PackedStringArray()
		var start := 0
		for end in TextServerManager.get_primary_interface().string_get_character_breaks(text):
			var glyph := text.substr(start, end - start)
			start = end
			if glyph.strip_edges().is_empty() and (glyphs.is_empty() or glyphs[-1].is_empty()): continue
			glyphs.append("" if glyph.strip_edges().is_empty() else glyph)
		while not glyphs.is_empty() and glyphs[-1].is_empty(): glyphs.remove_at(glyphs.size() - 1)
		if glyphs.size() > RAIN_CHARACTERS:
			glyphs.resize(RAIN_CHARACTERS - 1)
			glyphs.append("︙")
		var spacing := _rain_height() / PIXEL_SIZE - _font.get_height(FONT_SIZE)
		return {"text": "\n".join(glyphs), "half": glyphs.size() * _rain_height() * 0.5, "spacing": spacing}
	var width := _text_width(text)
	if width > MAX_WIDTH:
		var left := 1
		var right := text.length()
		while left < right:
			var middle := (left + right + 1) >> 1
			if _text_width(text.left(middle) + "…") <= MAX_WIDTH: left = middle
			else: right = middle - 1
		text = text.left(left) + "…"
		width = _text_width(text)
	return {"text": text, "half": width * 0.5, "spacing": 0.0}

func _text_width(text: String) -> float:
	return (_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x + OUTLINE_SIZE * 2) * PIXEL_SIZE

func _measure() -> void:
	var font := Menu.ui_bold_font()
	if font == _font: return
	_font = font
	_line = font.get_height(FONT_SIZE) * PIXEL_SIZE
	for label in _pool: label.font = font
	for comment in _comments: comment.label.font = font

func _ring_height() -> float:
	_measure()
	return _line

## Stacked characters use a tighter pitch than the font's line height.
func _rain_height() -> float:
	return FONT_SIZE * PIXEL_SIZE * 1.08

func _place(comment: Dictionary) -> void:
	var lane: float = _lanes[comment.lane]
	var depth: float = comment.depth
	var angle: float = lane if _mode == RAIN else TURN * (comment.time - _base)
	var height: float = RAIN_SPEED * (comment.time - _base) if _mode == RAIN else depth * tan(lane)
	var label: Label3D = comment.label
	label.transform = Transform3D(Basis(Vector3.UP, -angle).scaled(Vector3.ONE * float(comment.size)),
		Vector3(sin(angle) * depth, height, -cos(angle) * depth))

func _take_label() -> Label3D:
	if not _pool.is_empty(): return _pool.pop_back()
	var label := Label3D.new()
	label.hide()
	label.font = _font
	label.font_size = FONT_SIZE
	label.pixel_size = PIXEL_SIZE
	label.outline_size = OUTLINE_SIZE
	label.no_depth_test = true
	label.double_sided = false
	label.render_priority = -2
	label.outline_render_priority = -3
	_pivot.add_child(label)
	return label
