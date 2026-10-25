extends Node3D
## World-fixed layouts. All cards are bounded previews; the existing photo surface owns focus.
const Previews := preload("res://scripts/photo_preview_cache.gd")
const SHADER := preload("res://shaders/photo_gallery.gdshader")
enum Layout { SINGLE, SIDES, WALL, FRAGMENTS, MAGAZINE }
const NAMES := ["Single image", "Side previews", "Photo wall", "Memory fragments", "Magazine / Comics"]
const RECT := [Vector2(-0.5, 0.5), Vector2(0.5, 0.5), Vector2(0.5, -0.5), Vector2(-0.5, -0.5)]
const SHAPES := [
	[Vector2(-0.5, 0.28), Vector2(0.3, 0.5), Vector2(0.5, -0.35), Vector2(-0.32, -0.5)],
	[Vector2(-0.5, 0.5), Vector2(0.5, 0.31), Vector2(0.32, -0.5), Vector2(-0.5, -0.28)],
	[Vector2(-0.5, 0.32), Vector2(0.5, 0.5), Vector2(0.39, -0.5), Vector2(-0.25, -0.25)],
	[Vector2(-0.5, 0.5), Vector2(0.5, 0.3), Vector2(0.15, -0.5), Vector2(0.15, -0.5)]
]
const MAX_CARDS := 40
const SCALE_LIMITS := Vector2(0.5, 2.0)
const DISTANCE_LIMITS := Vector2(1.5, 8.0)
const DEFAULT_DISTANCES := [3.0, 3.0, 4.0, 3.6, 3.0]
const ANIMATION_SECONDS := 0.34
var photo: Node3D
var previews := Previews.new()
var mode := Layout.SINGLE
var view_scale := 1.0
var wall_rows := 1
const WALL_FLOOR_MARGIN := 1.0
var _scales := [1.0, 1.0, 1.0, 1.0, 1.0]
var view_distance := 3.0
var _distances := DEFAULT_DISTANCES.duplicate()
var _pool := {}
var _pointers := {}
var _dual := {}
var _dual_blocked := false
var _fragment_indices: Array[int] = []
var _batch_direction := 1
var _wall_groups: Array[String] = []
var _wall_group := 0
var _swap_phase := 0 # 1 fades out, 2 fades in
var _swap_alpha := 1.0
var _reflow_after := 0
var anchor := Transform3D.IDENTITY
var cards := {} # queue index -> card, original pose/shape/size are never changed by focus
var focus := -1
var focus_pose := Transform3D.IDENTITY
var _viewing_offsets := {} # Head-relative, per layout/session; applied only when opening a photo.
var _layout_offsets := {} # Grip placement, relative to the head, never written to settings.
var progress := 0.0
var returning := false
var capture := {}
var hover := {}
var _signature := ""
var _reflow := true
var _fragment_seed := 0
var _yaw := 0.0
var _fragment_start := -1
var _wall_start := -1
var _wall_column := -1

func _init() -> void:
	add_child(previews)

func _ready() -> void:
	previews.preview_ready.connect(func(_uri): _refresh_textures())

func set_mode(value: int) -> void:
	if photo and photo.archive_mode and value not in [Layout.SINGLE, Layout.MAGAZINE]: return
	if value not in [0, 1, 2, 3, 4] or value == mode: return
	cancel_all(); focus = -1; progress = 0; returning = false; _swap_phase = 0; _swap_alpha = 1.0
	_scales[mode] = view_scale
	_distances[mode] = view_distance
	mode = value; view_scale = float(_scales[value]); view_distance = float(_distances[value]); _signature = ""; _reflow = true; _yaw = 0.0; _fragment_start = -1; _wall_start = -1
	_wall_column = -1
	if photo and photo.material:
		photo.finish_transition(); photo.close_inspect()
		photo.material.render_priority = 0; photo.set_target_feedback(0)
		if photo._hole_material: photo._hole_material.render_priority = -128
		if photo._placeholder_material: photo._placeholder_material.render_priority = -10
		if value in [Layout.SINGLE, Layout.SIDES, Layout.MAGAZINE] and photo._texture != null: photo.panel.visible = true
		recenter(false); synchronize()

func recenter(reset_viewing: bool = true) -> void:
	if reset_viewing: _viewing_offsets.clear()
	if photo and is_instance_valid(photo.view_camera):
		var head: Transform3D = photo.view_camera.global_transform
		var forward := -head.basis.z; forward.y = 0
		forward = forward.normalized() if forward.length() > 0.01 else Vector3.FORWARD
		anchor = Transform3D(Basis(Vector3.UP, atan2(-forward.x, -forward.z)), head.origin)
	else: anchor = Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	if _layout_offsets.has(mode): anchor = _view_head() * _layout_offsets[mode]
	_yaw = 0.0; _reflow = true
	if focus >= 0: _place_focus()

func set_wall_rows(value: int) -> void:
	var next := clampi(value, 1, 3)
	if next == wall_rows: return
	cancel_all(); focus = -1; progress = 0; returning = false
	wall_rows = next; _signature = ""; _reflow = true
	_wall_column = -1
	_wall_groups.clear(); _wall_group = 0; _swap_phase = 0; _swap_alpha = 1.0
	if photo:
		photo.finish_transition(); photo.close_inspect()
		synchronize()
		photo.suspend_gallery_photo()

## Move the complete world layout without changing its batch, scale or preview resources.
func translate_layout(offset: Vector3) -> void:
	if not offset.is_finite(): return
	transform_layout(Transform3D(Basis.IDENTITY, offset))

func transform_layout(motion: Transform3D) -> void:
	if not motion.is_finite(): return
	anchor = motion * anchor
	focus_pose = motion * focus_pose
	if focus >= 0: remember_focus_pose(focus_pose)
	for card in cards.values():
		card.pose = motion * card.pose
		card.node.global_transform = motion * card.node.global_transform
	remember_layout_pose()

func remember_layout_pose() -> void:
	if photo and is_instance_valid(photo.view_camera): _layout_offsets[mode] = _view_head().affine_inverse() * anchor

func clear(reset_viewing: bool = true) -> void:
	if reset_viewing: _viewing_offsets.clear()
	cancel_all(); focus = -1; progress = 0; returning = false; _signature = ""; _fragment_start = -1; _wall_start = -1; _fragment_seed = 0
	_wall_column = -1
	for card in cards.values(): _free_card(card)
	cards.clear(); previews.clear(); visible = false; _fragment_indices.clear(); _wall_groups.clear(); _wall_group = 0; _swap_phase = 0; _swap_alpha = 1.0
	if photo and photo.material: photo.material.render_priority = 0
	if photo and photo._hole_material: photo._hole_material.render_priority = -128
	if photo and photo._placeholder_material: photo._placeholder_material.render_priority = -10

func cancel_all() -> void:
	capture = {}; hover.clear(); _dual = {}; _dual_blocked = false
	for pointer in _pointers.values(): pointer.line.visible = false; pointer.dot.visible = false

func cancel_pointer(hand: String) -> void:
	if capture.get("hand", "") == hand: capture = {}
	hover.erase(hand)
	if not _dual.is_empty(): _dual_blocked = true
	if _pointers.has(hand): _pointers[hand].line.visible = false; _pointers[hand].dot.visible = false

func has_capture() -> bool:
	return not capture.is_empty() or not _dual.is_empty()

func hide_pointer(hand: String) -> void:
	if _pointers.has(hand):
		_pointers[hand].line.visible = false; _pointers[hand].dot.visible = false

func overview() -> bool:
	return mode in [Layout.WALL, Layout.FRAGMENTS] and focus < 0 and not (photo and photo.portrait_requested)

func set_view_scale(value: float) -> void:
	if not is_finite(value): return
	var next := clampf(value, SCALE_LIMITS.x, SCALE_LIMITS.y)
	if is_equal_approx(next, view_scale): return
	view_scale = next; _scales[mode] = view_scale; _reflow = true; _wall_column = -1

func set_view_distance(value: float) -> void:
	if not is_finite(value): return
	var next := clampf(value, DISTANCE_LIMITS.x, DISTANCE_LIMITS.y)
	if is_equal_approx(next, view_distance): return
	view_distance = next; _distances[mode] = next; _reflow = true; _wall_column = -1

func restore_settings(settings: ConfigFile) -> void:
	mode = clampi(int(settings.get_value("photo_screen", "layout", 0)), 0, 4)
	wall_rows = clampi(int(settings.get_value("photo_screen", "wall_rows", 1)), 1, 3)
	for layout in 5:
		var scale := float(settings.get_value("photo_screen", "layout_%d_scale" % layout,
			settings.get_value("photo_screen", "gallery_scale", 1.0) if layout == mode else 1.0))
		var distance := float(settings.get_value("photo_screen", "layout_%d_distance" % layout, DEFAULT_DISTANCES[layout]))
		_scales[layout] = clampf(scale, SCALE_LIMITS.x, SCALE_LIMITS.y) if is_finite(scale) else 1.0
		_distances[layout] = clampf(distance, DISTANCE_LIMITS.x, DISTANCE_LIMITS.y) if is_finite(distance) else DEFAULT_DISTANCES[layout]
	view_scale = _scales[mode]; view_distance = _distances[mode]; _reflow = true

func save_settings(settings: ConfigFile) -> void:
	settings.set_value("photo_screen", "layout", mode)
	settings.set_value("photo_screen", "wall_rows", wall_rows)
	settings.set_value("photo_screen", "gallery_scale", view_scale)
	for layout in 5:
		settings.set_value("photo_screen", "layout_%d_scale" % layout, _scales[layout])
		settings.set_value("photo_screen", "layout_%d_distance" % layout, _distances[layout])

## Two optical pinches take ownership before either single-pointer release can click.
func hand_zoom(inputs: Dictionary, enabled: bool) -> Dictionary:
	var consumed := []; var finished := false
	var both := true; var released := true
	for hand in ["left_hand", "right_hand"]:
		var input: Dictionary = inputs.get(hand, {})
		both = both and input.get("source") == "hand" and input.get("tracked", false) and input.get("down", false) \
			and input.get("position") is Vector3 and input.position.is_finite()
		released = released and not input.get("down", false)
	if not _dual.is_empty():
		consumed = ["left_hand", "right_hand"]
		if not enabled or not both: _dual_blocked = true
		if released:
			_dual = {}; _dual_blocked = false; finished = true
		elif not _dual_blocked:
			var span: float = inputs.left_hand.position.distance_to(inputs.right_hand.position)
			if span >= 0.05 and span <= 2.0:
				if _dual.get("surface",false): photo.set_hand_scale(float(_dual.scale) * span / float(_dual.span))
				else: set_view_scale(float(_dual.scale) * span / float(_dual.span))
				photo.changed.emit()
	elif enabled and both and inputs.values().any(func(input): return input.get("pressed", false)):
		var span: float = inputs.left_hand.position.distance_to(inputs.right_hand.position)
		if span >= 0.08 and span <= 2.0:
			var surface: bool = focus >= 0 and photo.geometry == 0
			capture = {}; hover.clear(); _dual = {"span": span, "scale": photo.screen_scale if surface else view_scale, "surface":surface}; _dual_blocked = false
			consumed = ["left_hand", "right_hand"]
	return {"consumed": consumed, "finished": finished}

func shuffle_fragments() -> bool:
	return change_batch(1) if mode == Layout.FRAGMENTS else false

func change_batch(direction: int = 1) -> bool:
	if not overview() or _swap_phase != 0 or has_capture() or photo.queue.is_empty(): return false
	_batch_direction = -1 if direction < 0 else 1
	_swap_phase = 1; _swap_alpha = 1.0; hover.clear()
	return true

func _advance_wall() -> void:
	var current: int = _wall_start if _wall_start >= 0 else (photo.pending_index if photo.pending_index >= 0 else photo.index)
	var uri := str(photo.queue[current].uri)
	if _wall_groups.is_empty() or _wall_groups[_wall_group] != uri:
		_wall_groups.assign([uri]); _wall_group = 0
	var target: int = _wall_group + _batch_direction
	var next := -1
	if target >= 0 and target < _wall_groups.size():
		var wanted: String = _wall_groups[target]
		for index in photo.queue.size():
			if str(photo.queue[index].uri) == wanted: next = index; break
		_wall_group = target
	if next < 0:
		if wall_rows > 1:
			var capacity := _wall_columns() * wall_rows
			var page := current / capacity + _batch_direction
			var count := ceili(photo.queue.size() / float(capacity))
			next = posmod(page, count) * capacity if photo.queue_complete else clampi(page, 0, count - 1) * capacity
		else:
			var step := 1 if cards.size() >= photo.queue.size() else maxi(1, cards.size())
			next = _neighbor(current, step * _batch_direction)
			if next < 0: next = 0 if _batch_direction < 0 else photo.queue.size() - 1
		if _batch_direction > 0:
			_wall_groups.append(str(photo.queue[next].uri)); _wall_group = _wall_groups.size() - 1
		else:
			_wall_groups.push_front(str(photo.queue[next].uri)); _wall_group = 0
		if _wall_groups.size() > 128:
			_wall_groups.pop_front() if _wall_group > 0 else _wall_groups.pop_back()
			_wall_group = mini(_wall_group, _wall_groups.size() - 1)
	_wall_start = next
	_wall_column = -1
	photo.finish_transition(); photo._select(next)


func _choose_memories(count: int, fresh: bool) -> void:
	var previous := _fragment_indices.duplicate()
	var candidates: Array[int] = []; var reused: Array[int] = []
	for index in photo.queue.size():
		if fresh and index in previous: reused.append(index)
		else: candidates.append(index)
	var random := RandomNumberGenerator.new(); random.seed = _fragment_seed
	for list in [candidates, reused]:
		for i in range(list.size() - 1, 0, -1):
			var other := random.randi_range(0, i)
			var value: int = list[i]; list[i] = list[other]; list[other] = value
	candidates.append_array(reused)
	_fragment_indices.assign(candidates.slice(0, count))

func clear_focus() -> void:
	_restore_focus_card(); focus = -1; progress = 0; returning = false; cancel_all(); _reflow = true
	if photo: photo.suspend_gallery_photo()

func new_window(index: int) -> void:
	_fragment_start = index; _wall_start = index; _fragment_indices.clear(); _signature = ""; _reflow = true
	_wall_column = -1

func replace_indices(old: Array[Dictionary], entries: Array[Dictionary]) -> void:
	var positions := {}
	for index in entries.size(): positions[str(entries[index].uri)] = index
	var replaced := {}
	for index in cards:
		var target := int(positions.get(str(old[index].uri), -1))
		if target >= 0: replaced[target] = cards[index]
		else: _free_card(cards[index])
	if focus >= 0: focus = int(positions.get(str(old[focus].uri), -1))
	if _fragment_start >= 0: _fragment_start = int(positions.get(str(old[_fragment_start].uri), -1))
	if _wall_start >= 0: _wall_start = int(positions.get(str(old[_wall_start].uri), -1))
	var remapped: Array[int] = []
	for index in _fragment_indices:
		var target := int(positions.get(str(old[index].uri), -1))
		if target >= 0: remapped.append(target)
	_fragment_indices = remapped
	cards = replaced; cancel_all(); _signature = ""; _reflow = true
	if mode == Layout.FRAGMENTS and not cards.is_empty():
		# Completing a paged index must not scatter an already visible memory group.
		_signature = "%d/%d/%d/%s" % [mode, _fragment_start, entries.size(), str(entries[0].uri)]
		_reflow = false

func _process(delta: float) -> void:
	if not photo: return
	previews.platform = photo.platform
	if photo.portrait_requested:
		visible = false; photo.panel.visible = true; return
	if _swap_phase == 1:
		_swap_alpha = move_toward(_swap_alpha, 0.0, delta / 0.22)
		if _swap_alpha <= 0:
			if mode == Layout.FRAGMENTS:
				_fragment_seed = randi(); _choose_memories(_fragment_count(), true)
			elif mode == Layout.WALL: _advance_wall()
			_reflow = true; _swap_phase = 2
	elif _swap_phase == 2:
		_swap_alpha = move_toward(_swap_alpha, 1.0, delta / 0.38)
		if _swap_alpha >= 1: _swap_phase = 0
	synchronize()
	if focus >= 0:
		progress = move_toward(progress, 0.0 if returning else 1.0, delta / ANIMATION_SECONDS)
		_animate_focus()
		if returning and progress <= 0:
			focus = -1; returning = false
			if mode != Layout.FRAGMENTS: _reflow = true
			synchronize()
	_refresh_visibility()

func synchronize() -> void:
	if photo and photo.portrait_requested:
		visible = false; photo.panel.visible = true; return
	if not photo or photo.queue.is_empty() or (photo.local_uri.is_empty() and not photo.loading):
		if not cards.is_empty(): clear()
		visible = false; return
	if mode in [Layout.SINGLE, Layout.MAGAZINE]:
		if not cards.is_empty(): clear(false)
		visible = false; return
	visible = true
	var current: int = photo.pending_index if photo.pending_index >= 0 else photo.index
	current = clampi(current, 0, photo.queue.size() - 1)
	if mode == Layout.WALL:
		if _wall_start < 0 or (wall_rows > 1 and _wall_column < 0): _wall_start = current
		_wall_start = _wall_page_start(_wall_start)
		current = _wall_start
	var signature := "%d/%d/%d/%s" % [mode, _fragment_start if mode == Layout.FRAGMENTS else current, photo.queue.size(), str(photo.queue[0].uri)]
	if mode == Layout.SIDES:
		anchor = photo.global_transform * photo.flat_pose * Transform3D(Basis.IDENTITY, Vector3(0, 0, photo.screen_distance))
		signature += "/%s/%s/%s/%s/%s" % [str(anchor), str(photo._flat.size), str(photo.screen_distance), str(photo.screen_curve), str(photo.screen_rotation)]
	if signature != _signature: _signature = signature; _reflow = true
	if _reflow and capture.is_empty() and focus < 0 and Time.get_ticks_msec() >= _reflow_after:
		_reflow_after = Time.get_ticks_msec() + (50 if not _dual.is_empty() else 0)
		_reflow = false
		_build(current)

## Rows are centred on the view; a multi-row wall rises just enough to keep its lowest edge
## within WALL_FLOOR_MARGIN below the eyes instead of sinking into the real floor.
func _wall_row_y(row: int, height: float) -> float:
	var centred := ((wall_rows - 1) * 0.5 - row) * (height + 0.08)
	if wall_rows <= 1: return centred
	var lowest := -(wall_rows - 1) * 0.5 * (height + 0.08) - height * 0.5
	return centred + maxf(0.0, -WALL_FLOOR_MARGIN - lowest)

func _neighbor(current: int, offset: int) -> int:
	var target := current + offset
	if photo.queue_complete: return posmod(target, photo.queue.size())
	return target if target >= 0 and target < photo.queue.size() else -1

## Multi-row pages read left to right, then top to bottom. Capacity depends on the
## layout controls, never on late thumbnail metadata, so files keep their slots.
func _wall_columns() -> int:
	var pitch := 2.0 * atan(1.05 * view_scale * (4.0 / 3.0) * 0.5 / view_distance) + 0.07
	return maxi(1, mini(mini(MAX_CARDS / wall_rows, ceili(photo.queue.size() / float(wall_rows))), floori((TAU - 0.16) / pitch)))

func _wall_page_start(current: int) -> int:
	if wall_rows == 1: return current
	var capacity := _wall_columns() * wall_rows
	return current / capacity * capacity

func _build_wall_rows(current: int) -> void:
	var columns := _wall_columns()
	if _wall_column < 0:
		var selected: int = photo.pending_index if photo.pending_index >= 0 else photo.index
		_wall_column = maxi(0, selected - current) % columns
	var count := mini(columns * wall_rows, photo.queue.size() - current)
	var height := 1.05 * view_scale
	var aspect := 0.01
	for slot in count: aspect = maxf(aspect, _aspect(current + slot))
	var pitch := minf((TAU - 0.16) / columns, 2.0 * atan(height * aspect * 0.5 / view_distance) + 0.07)
	var width := 2.0 * view_distance * tan(minf(pitch * 0.5 - 0.035, 1.4))
	height = minf(height, width / aspect)
	for slot in count:
		var row := slot / columns
		var column := slot % columns
		var angle := (column - _wall_column) * pitch
		var index := current + slot
		_add(index, anchor * _ring_pose(angle, view_distance, _wall_row_y(row, height)), Vector2(height * _aspect(index), height), RECT)

func _aspect(index: int) -> float:
	var uri := str(photo.queue[index].uri)
	var info := previews.metadata(uri)
	if info.is_empty(): info = photo.queue[index].get("photo_info", {})
	var resolved: Dictionary = photo._resolved_mode(index, info)
	if int(resolved.geometry) != 0: return 4.0 / 3.0
	var texture := previews.texture(uri)
	var aspect := float(texture.get_width()) / texture.get_height() if texture else float(info.get("width", 3)) / maxf(1.0, float(info.get("height", 2)))
	if resolved.stereo_sbs and not info.get("single_eye", false): aspect *= 2.0 if resolved.top_bottom else 0.5
	return maxf(0.001, aspect)

func _fragment_count() -> int:
	# Density follows angular footprint and usable vertical space, with a bounded texture budget.
	var columns := clampi(floori(TAU / (2.0 * atan(0.55 * view_scale / view_distance) + 0.04)), 4, 24)
	var rows := clampi(floori(2.2 / (0.80 * view_scale)), 1, 3)
	return mini(mini(MAX_CARDS, columns * rows), photo.queue.size())

func _build(current: int) -> void:
	_pool = cards; cards = {}
	var used := {current: true} if mode == Layout.SIDES else {}
	if mode == Layout.SIDES:
		# Continue from the picture's actual edge, rather than placing previews over it.
		var frame: Transform3D = photo.global_transform * photo.flat_pose * Transform3D(Basis(Vector3.FORWARD, deg_to_rad(photo.screen_rotation)), Vector3.ZERO)
		var edge: Vector3 = photo.screen_corner(1); edge.y = 0
		var viewing_distance := maxf(Vector2(edge.x, photo.screen_distance - edge.z).length(), 0.25)
		var edge_angle := atan2(absf(edge.x), photo.screen_distance - edge.z)
		var eye_frame := frame * Transform3D(Basis.IDENTITY, Vector3(0, 0, photo.screen_distance))
		for side in [-1, 1]:
			for rank in range(1, 4):
				var index := _neighbor(current, side * rank)
				if index < 0 or used.has(index): continue
				used[index] = true
				var height := viewing_distance * 0.18
				var size := Vector2(height * _aspect(index), height)
				if size.x > viewing_distance * 0.25: size *= viewing_distance * 0.25 / size.x
				var angle := edge_angle + atan(size.x * 0.5 / viewing_distance) + 0.045
				_add(index, eye_frame * _ring_pose(angle * side, viewing_distance, (2 - rank) * viewing_distance * 0.22), size, RECT)
	elif mode == Layout.WALL and wall_rows > 1:
		_build_wall_rows(current)
	elif mode == Layout.WALL:
		var radius := view_distance
		var height := 1.05 * view_scale
		# The single-row ring keeps its continuous previous/next neighbours.
		var row_edges := {}
		for row in wall_rows:
			row_edges[row] = {-1: 0.0, 1: 0.0}
			var seed := current
			if seed < 0 or used.has(seed) or cards.size() >= MAX_CARDS: continue
			var centre_width := height * _aspect(seed)
			_add(seed, anchor * _ring_pose(0.0, radius, _wall_row_y(row, height)), Vector2(centre_width, height), RECT)
			used[seed] = true
			row_edges[row] = {-1: atan(centre_width * 0.5 / radius), 1: atan(centre_width * 0.5 / radius)}
		var open := {-1: not row_edges.is_empty(), 1: not row_edges.is_empty()}
		for rank in range(1, MAX_CARDS):
			for side in [-1, 1]:
				if not open[side]: continue
				var column := {}
				for row in row_edges:
					var index := _neighbor(current, rank * side)
					if index < 0: continue
					var half := atan(height * _aspect(index) * 0.5 / radius)
					var centre: float = row_edges[row][side] + 0.035 + half
					if used.has(index) or centre + half >= PI - 0.08: column.clear(); open[side] = false; break
					column[row] = [index, centre, half]
				if column.is_empty() or cards.size() + column.size() > MAX_CARDS: open[side] = false; continue
				for row in column:
					var index: int = column[row][0]
					used[index] = true
					_add(index, anchor * _ring_pose(column[row][1] * side, radius, _wall_row_y(int(row), height)), Vector2(height * _aspect(index), height), RECT)
					row_edges[row][side] = column[row][1] + column[row][2]
	else:
		if _fragment_start < 0: _fragment_start = current
		current = _fragment_start
		if _fragment_seed == 0: _fragment_seed = str(photo.queue[0].uri).hash()
		var random := RandomNumberGenerator.new(); random.seed = _fragment_seed
		var count := _fragment_count()
		if _fragment_indices.is_empty():
			for slot in count:
				var index := _neighbor(current, slot if slot <= count / 2 else slot - count)
				if index >= 0 and not _fragment_indices.has(index): _fragment_indices.append(index)
		elif _fragment_indices.size() < count:
			for offset in photo.queue.size():
				var index := _neighbor(current, offset)
				if index >= 0 and not _fragment_indices.has(index): _fragment_indices.append(index)
				if _fragment_indices.size() >= count: break
		_fragment_indices.resize(mini(count, _fragment_indices.size()))
		count = _fragment_indices.size()
		var rows := clampi(floori(2.2 / (0.80 * view_scale)), 1, 3)
		var columns := maxi(1, ceili(count / float(rows)))
		var phase := random.randf_range(-0.16, 0.16)
		var pattern := random.randi_range(0, 2)
		for slot in count:
			var index: int = _fragment_indices[slot]
			var row := slot % rows
			var angle := TAU * floori(slot / float(rows)) / columns + row * TAU / columns * 0.38 + phase + random.randf_range(-0.04, 0.04)
			var radius := view_distance * random.randf_range(0.92, 1.08)
			var size := Vector2(random.randf_range(0.62, 1.16), random.randf_range(0.44, 0.82)) * view_scale
			var roll := random.randf_range(-0.25, 0.25)
			var half_height := (absf(sin(roll)) * size.x + absf(cos(roll)) * size.y) * 0.5
			if half_height > 1.04: size *= 1.04 / half_height; half_height = 1.04
			var centre := (row + 0.5) * 2.2 / rows + random.randf_range(-0.12, 0.12)
			if pattern == 1: centre += sin(angle * 2.0 + phase) * 0.20
			elif pattern == 2: centre += random.randf_range(-0.20, 0.20)
			var elevation := clampf(centre, half_height + 0.06, maxf(half_height + 0.06, 2.2 - half_height))
			var local := _ring_pose(angle, radius, elevation)
			local.basis *= Basis(Vector3.FORWARD, roll)
			var silhouette: Array = SHAPES[random.randi_range(0, SHAPES.size() - 1)].duplicate()
			var triangular: bool = silhouette[2] == silhouette[3]
			for vertex in (3 if triangular else 4):
				silhouette[vertex] = (silhouette[vertex] + Vector2(random.randf_range(-0.035, 0.035), random.randf_range(-0.035, 0.035))).clamp(Vector2(-0.5,-0.5), Vector2(0.5,0.5))
			if triangular: silhouette[3] = silhouette[2]
			_add(index, anchor * local, size, silhouette)
	for card in _pool.values(): _free_card(card)
	_pool.clear()
	var entries: Array[Dictionary] = []
	for index in cards: entries.append(photo.queue[index])
	previews.request(entries); _refresh_textures(); _refresh_visibility()

static func _ring_pose(angle: float, radius: float, height: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, -angle), Vector3(sin(angle) * radius, height, -cos(angle) * radius))

static func _free_card(card: Dictionary) -> void:
	card.node.free(); card.rim.free(); card.echo.free()

static func _plain(color: Color, priority: int = 0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	material.albedo_color = color; material.render_priority = priority
	return material

func _add(index: int, pose: Transform3D, size: Vector2, shape: Array) -> void:
	var card: Dictionary
	if _pool.has(index):
		card = _pool[index]; _pool.erase(index)
		card.pose = pose; card.size = size; card.shape = shape.duplicate()
	else:
		var node := MeshInstance3D.new()
		var material := ShaderMaterial.new(); material.shader = SHADER
		node.material_override = material; node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF; add_child(node)
		var rim := MeshInstance3D.new(); rim.material_override = _plain(Color(0.65, 0.82, 0.92, 0.5), 2); add_child(rim)
		var echo := MeshInstance3D.new(); echo.material_override = _plain(Color(0.55, 0.75, 0.9, 0.13)); add_child(echo)
		rim.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF; echo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		card = {"node": node, "rim": rim, "echo": echo, "pose": pose, "size": size, "shape": shape.duplicate(), "shown_shape": [], "shown_size": Vector2.ZERO}
	cards[index] = card; card.node.global_transform = pose
	card.node.material_override.set_shader_parameter("edge_feather", _card_feather(size))
	_mesh(card, shape, size)

func _card_feather(size: Vector2) -> Vector2:
	return Vector2.ONE * photo.SOFT_EDGE_METRES / size if mode == Layout.WALL else Vector2.ZERO

static func _mesh(card: Dictionary, shape: Array, size: Vector2) -> void:
	if card.node.mesh != null and card.shown_shape == shape and card.shown_size == size: return
	card.node.material_override.set_shader_parameter("surface_size", size)
	var vertices := PackedVector3Array(); var uv := PackedVector2Array()
	for point in shape:
		vertices.append(Vector3(point.x * size.x, point.y * size.y, 0))
		uv.append(Vector2(point.x + 0.5, 0.5 - point.y))
	var arrays := []; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices; arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 0, 3, 2])
	var mesh := ArrayMesh.new(); mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	card.node.mesh = mesh; card.shown_shape = shape; card.shown_size = size
	# Trace the polygon itself, including diagonal fragment edges and triangular silhouettes.
	var outline := PackedVector3Array(); var indices := PackedInt32Array()
	var centre := Vector2.ZERO
	for point in shape: centre += point
	centre /= shape.size()
	for i in shape.size():
		var start: Vector2 = shape[i] * size; var end: Vector2 = shape[(i + 1) % shape.size()] * size
		if start.distance_to(end) < 0.001: continue
		var normal := (end - start).orthogonal().normalized() * minf(size.x, size.y) * 0.018
		if normal.dot((start + end) * 0.5 - centre * size) < 0: normal = -normal
		var base := outline.size()
		for point in [start - normal * 0.25, end - normal * 0.25, end + normal, start + normal]: outline.append(Vector3(point.x, point.y, 0.004))
		indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	var frame_arrays := []; frame_arrays.resize(Mesh.ARRAY_MAX)
	frame_arrays[Mesh.ARRAY_VERTEX] = outline; frame_arrays[Mesh.ARRAY_INDEX] = indices
	var frame := ArrayMesh.new(); frame.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, frame_arrays)
	card.rim.mesh = frame; card.echo.mesh = frame

func _refresh_textures() -> void:
	if not photo: return
	for index in cards:
		var card: Dictionary = cards[index]
		var uri := str(photo.queue[index].uri)
		var texture := previews.texture(uri)
		var info := previews.metadata(uri)
		var resolved: Dictionary = photo._resolved_mode(index, info)
		var material: ShaderMaterial = card.node.material_override
		material.set_shader_parameter("picture", texture)
		material.set_shader_parameter("has_picture", texture != null)
		material.set_shader_parameter("geometry", int(resolved.geometry))
		var rect := Vector4(0, 0, 1, 1)
		if resolved.stereo_sbs and not info.get("single_eye", false):
			rect = Vector4(0, 0.5 if resolved.swap_eyes else 0.0, 1, 0.5) if resolved.top_bottom else Vector4(0.5 if resolved.swap_eyes else 0.0, 0, 0.5, 1)
		material.set_shader_parameter("eye_rect", rect)
		material.set_shader_parameter("crop_rect", _crop(index, card.size) if mode == Layout.FRAGMENTS else Vector4(0, 0, 1, 1))
	# Reflow only when aspect ratios actually change, not each texture completion.
	if mode in [Layout.SIDES, Layout.WALL]:
		for index in cards:
			var size: Vector2 = cards[index].size
			if absf(size.x / size.y - _aspect(index)) > 0.02: _reflow = true; break

func _crop(index: int, size: Vector2) -> Vector4:
	var image_aspect := _aspect(index); var box_aspect := size.x / size.y
	var extent := Vector2(minf(1, box_aspect / image_aspect), minf(1, image_aspect / box_aspect))
	return Vector4((1.0 - extent.x) * 0.5, (1.0 - extent.y) * 0.5, extent.x, extent.y)

func activate(index: int) -> void:
	if (photo and photo.portrait_requested) or not cards.has(index): return
	previews.retry(str(photo.queue[index].uri))
	if focus == index:
		return_focus(); return
	if focus >= 0:
		_restore_focus_card()
	focus = index; progress = 0.0; returning = false; cancel_all()
	_place_focus()
	if mode == Layout.SIDES:
		focus = -1
		photo._select(index); _reflow = true
	else:
		photo.finish_transition()
		if photo.pending_index != index and (photo.index != index or photo.loading or photo._texture == null): photo._select(index)
		photo.changed.emit()

func _place_focus() -> void:
	var head := _view_head()
	if _viewing_offsets.has(mode):
		focus_pose = head * _viewing_offsets[mode]; return
	var direction := -head.basis.z; direction.y = 0
	var level := Transform3D(Basis(Vector3.UP, atan2(-direction.x, -direction.z)), head.origin) if direction.length() > 0.01 else Transform3D(Basis.IDENTITY, head.origin)
	focus_pose = level * Transform3D(Basis.IDENTITY, Vector3(0, 0, -maxf(1.5, photo.screen_distance)))
	_viewing_offsets[mode] = head.affine_inverse() * focus_pose

func _view_head() -> Transform3D:
	if photo and is_instance_valid(photo.view_camera):
		var transform: Transform3D = photo.view_camera.global_transform
		if transform.is_finite() and absf(transform.basis.determinant()) > 0.001:
			return Transform3D(transform.basis.orthonormalized(), transform.origin)
	return anchor

func remember_focus_pose(pose: Transform3D) -> void:
	if focus < 0 or returning or not pose.is_finite(): return
	focus_pose = pose; _viewing_offsets[mode] = _view_head().affine_inverse() * pose

func return_focus() -> void:
	if photo and photo.portrait_requested: return
	if focus < 0: return
	returning = true; cancel_all(); photo.close_inspect(); photo.changed.emit()
	photo.suspend_gallery_photo()

func _restore_focus_card() -> void:
	if not cards.has(focus): return
	var card: Dictionary = cards[focus]
	card.node.global_transform = card.pose; _mesh(card, card.shape, card.size)
	card.node.material_override.set_shader_parameter("edge_feather", _card_feather(card.size))
	card.node.material_override.set_shader_parameter("crop_rect", _crop(focus, card.size) if mode == Layout.FRAGMENTS else Vector4(0, 0, 1, 1))

func _animate_focus() -> void:
	if not cards.has(focus): return
	var card: Dictionary = cards[focus]
	var eased := smoothstep(0.0, 1.0, progress)
	var size: Vector2 = photo._flat.size if photo.index == focus and photo.geometry == 0 else Vector2(2.8, 2.8 / _aspect(focus))
	if photo.loading and photo.pending_index == focus: size = photo._placeholder_size
	card.node.global_transform = card.pose if eased <= 0 else (focus_pose if eased >= 1 else card.pose.interpolate_with(focus_pose, eased))
	var shape := []
	for i in 4: shape.append(card.shape[i] if eased <= 0 else (RECT[i] if eased >= 1 else card.shape[i].lerp(RECT[i], eased)))
	var shown_size: Vector2 = card.size if eased <= 0 else (size if eased >= 1 else card.size.lerp(size, eased))
	_mesh(card, shape, shown_size)
	var feather: float = photo.SOFT_EDGE_METRES if mode == Layout.WALL else photo.SOFT_EDGE_METRES * eased
	card.node.material_override.set_shader_parameter("edge_feather", Vector2.ONE * feather / shown_size)
	var crop := _crop(focus, card.size) if mode == Layout.FRAGMENTS else Vector4(0, 0, 1, 1)
	card.node.material_override.set_shader_parameter("crop_rect", crop if eased <= 0 else (Vector4(0, 0, 1, 1) if eased >= 1 else crop.lerp(Vector4(0, 0, 1, 1), eased)))
	if progress >= 1 and not returning and photo.index == focus and not photo.loading:
		if photo._reveal_seconds <= 0: photo.finish_transition()
		if photo.geometry == 0:
			photo.apply_focus_world_pose(focus_pose)

func _refresh_visibility() -> void:
	if photo and photo.portrait_requested:
		visible = false; photo.panel.visible = true; return
	if mode in [Layout.SINGLE, Layout.MAGAZINE]: return
	var focused_ready: bool = focus >= 0 and progress >= 1 and not returning and photo.index == focus and not photo.loading and photo._texture != null
	var foreground: bool = focus >= 0
	photo.material.render_priority = 1 if focused_ready else 0
	if photo._hole_material: photo._hole_material.render_priority = 0 if foreground else -128
	if photo._placeholder_material: photo._placeholder_material.render_priority = 2 if foreground else -10
	if mode in [Layout.WALL, Layout.FRAGMENTS]: photo.set_target_feedback(0)
	if mode == Layout.SIDES:
		for card in cards.values():
			card.node.visible = true; card.node.material_override.set_shader_parameter("brightness", 1.0)
	else:
		photo.panel.visible = focused_ready
		if is_instance_valid(photo._placeholder): photo._placeholder.visible = focused_ready and photo.geometry == 0 and photo._reveal_seconds > 0
		for index in cards:
			var card: Dictionary = cards[index]
			card.node.visible = not (index == focus and focused_ready) and not (focused_ready and photo.geometry != 0)
			card.node.material_override.set_shader_parameter("brightness", 0.3 if focus >= 0 and index != focus else 1.0)
	for index in cards:
		var card: Dictionary = cards[index]
		var targeted: bool = hover.values().has(index)
		var pressed: bool = capture.get("index", -1) == index
		var full: bool = index == focus and focused_ready
		# The focused surface (including its compositor hole) follows every background card.
		var background: bool = focus >= 0 and index != focus
		card.node.material_override.render_priority = -4 if background else (1 if index == focus else 0)
		card.rim.material_override.render_priority = -2 if foreground else 2
		card.echo.material_override.render_priority = -3 if foreground else 0
		card.node.material_override.set_shader_parameter("waiting_for_full", index == focus and not returning and photo.loading)
		card.rim.global_transform = card.node.global_transform
		card.echo.global_transform = card.node.global_transform * Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 1.025), Vector3(0.018, -0.012, -0.008))
		card.rim.visible = card.node.visible and index != focus and (mode == Layout.FRAGMENTS or targeted or pressed)
		card.echo.visible = card.node.visible and mode == Layout.FRAGMENTS and index != focus
		var color := Color(1.0, 0.88, 0.55) if pressed else (Color(0.15, 0.95, 1.0) if targeted or full else Color(0.67, 0.83, 0.94, 0.5))
		color.a *= _swap_alpha * (0.3 if focus >= 0 and index != focus else 1.0)
		card.rim.material_override.albedo_color = color
		card.echo.material_override.albedo_color.a = 0.14 * _swap_alpha * (0.3 if focus >= 0 else 1.0)
		card.node.material_override.set_shader_parameter("opacity", _swap_alpha)

func ray_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	if _swap_phase != 0 or not _dual.is_empty() or not photo or photo.portrait_requested or photo.inspect or not origin.is_finite() or not direction.is_finite() or direction.length_squared() < 0.00001: return {}
	var nearest := {}
	if mode in [Layout.SINGLE, Layout.SIDES, Layout.MAGAZINE] and photo.panel.visible and photo.geometry == 0:
		var point: Variant = photo.screen_point(origin, direction)
		if point != null and absf(point.x) <= photo._flat.size.x * 0.5 and absf(point.y) <= photo._flat.size.y * 0.5:
			nearest = {"index": photo.index, "distance": origin.distance_to(photo.panel.global_transform * point), "point": photo.panel.global_transform * point}
	if not visible and mode not in [Layout.SINGLE, Layout.MAGAZINE]: return {}
	if focus >= 0 and progress >= 1 and not returning and photo.panel.visible:
		if photo.geometry != 0: return {"index": focus, "distance": 2.0, "point": origin + direction.normalized() * 2.0}
		var point: Variant = photo.screen_point(origin, direction)
		if point != null and absf(point.x) <= photo._flat.size.x * 0.5 and absf(point.y) <= photo._flat.size.y * 0.5:
			return {"index": focus, "distance": origin.distance_to(photo.panel.global_transform * point), "point": photo.panel.global_transform * point}
	for index in cards:
		var card: Dictionary = cards[index]
		if not card.node.visible: continue
		var inverse: Transform3D = card.node.global_transform.affine_inverse()
		var start := inverse * origin; var vector := inverse.basis * direction.normalized()
		if absf(vector.z) < 0.0001: continue
		var distance := -start.z / vector.z
		if distance <= 0: continue
		var point := start + vector * distance
		var polygon := PackedVector2Array()
		for vertex in card.shown_shape: polygon.append(vertex * card.shown_size)
		var inside := Geometry2D.is_point_in_polygon(Vector2(point.x, point.y), polygon)
		if not inside:
			for edge in polygon.size():
				var closest := Geometry2D.get_closest_point_to_segment(Vector2(point.x, point.y), polygon[edge], polygon[(edge + 1) % polygon.size()])
				if closest.distance_to(Vector2(point.x, point.y)) < minf(0.035, distance * 0.006): inside = true; break
		if inside and (nearest.is_empty() or distance < float(nearest.distance)):
			nearest = {"index": index, "distance": distance, "point": origin + direction.normalized() * distance}
	return nearest

func press_pointer(hand: String, origin: Vector3, direction: Vector3) -> bool:
	if has_capture(): return true
	var hit := ray_hit(origin, direction)
	if hit.is_empty() or (mode in [Layout.SINGLE, Layout.SIDES, Layout.MAGAZINE] and not cards.has(int(hit.index))): return false
	capture = {"hand": hand, "index": int(hit.index), "start": direction.normalized(), "last": direction.normalized(), "moved": false}
	if int(hit.index) == focus and progress >= 1 and not returning and photo.geometry == 0:
		var eye := _focus_eye()
		var radius := focus_pose.origin.distance_to(eye)
		var point: Variant = _drag_ray_point(origin, direction, eye, radius)
		if point != null:
			capture.merge({"focus_drag":true, "radius":radius, "start_angles":_direction_angles(point-eye),
				"picture_angles":_direction_angles(focus_pose.origin-eye), "last_point":point})
	return true

func update_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool = true) -> void:
	if not tracked: cancel_pointer(hand); return
	var hit := ray_hit(origin, direction)
	hover[hand] = int(hit.get("index", -1))
	_show_pointer(hand, origin, hit)
	_refresh_visibility()
	if capture.get("hand", "") != hand: return
	if capture.get("focus_drag", false):
		var eye := _focus_eye()
		var point: Variant = _drag_ray_point(origin, direction, eye, float(capture.radius))
		if point == null: cancel_pointer(hand); return
		if point.distance_to(capture.last_point) > 0.6 * maxf(0.001, XRServer.world_scale): cancel_pointer(hand); return
		capture.last_point = point
		var offset := _direction_angles(point-eye) - Vector2(capture.start_angles)
		offset.x = wrapf(offset.x, -PI, PI)
		if offset.length() * float(capture.radius) >= 0.025 * maxf(0.001, XRServer.world_scale): capture.moved = true
		if capture.moved:
			var angles: Vector2 = Vector2(capture.picture_angles) + offset
			var facing := Basis(Vector3.UP, angles.x) * Basis(Vector3.RIGHT, clampf(angles.y, -1.3, 1.3))
			photo.set_flat_world_pose(Transform3D(facing, eye + facing * Vector3(0,0,-float(capture.radius))))
		return
	if direction.normalized().angle_to(capture.start) > 0.035: capture.moved = true
	if capture.moved and mode == Layout.WALL and focus < 0:
		var old: Vector3 = capture.last; var current := direction.normalized()
		var step := wrapf(atan2(-current.x, -current.z) - atan2(-old.x, -old.z), -PI, PI)
		_yaw += step
		for card in cards.values():
			var pivot := anchor * Transform3D(Basis(Vector3.UP, _yaw), Vector3.ZERO) * anchor.affine_inverse()
			card.node.global_transform = pivot * card.pose
	capture.last = direction.normalized()

func _focus_eye() -> Vector3:
	return photo.view_camera.global_position if photo and is_instance_valid(photo.view_camera) else anchor.origin

static func _direction_angles(direction: Vector3) -> Vector2:
	var unit := direction.normalized()
	return Vector2(atan2(-unit.x,-unit.z),asin(clampf(unit.y,-1,1)))

static func _drag_ray_point(origin: Vector3, direction: Vector3, eye: Vector3, radius: float) -> Variant:
	if not origin.is_finite() or not direction.is_finite() or not eye.is_finite() or not is_finite(radius) or radius < 0.1 or direction.length_squared() < 0.00001: return null
	var ray := direction.normalized(); var offset := origin-eye
	var b := offset.dot(ray); var discriminant := b*b-offset.length_squared()+radius*radius
	if discriminant < 0: return null
	var root := sqrt(discriminant)
	var distance := -b-root
	if distance <= 0: distance = -b+root
	if distance <= 0: return null
	return origin+ray*distance

func release_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool = true) -> bool:
	if capture.get("hand", "") != hand: return false
	update_pointer(hand, origin, direction, tracked)
	if capture.is_empty(): return true
	var pressed := capture.duplicate(); capture = {}
	var hit := ray_hit(origin, direction)
	if not pressed.moved and not hit.is_empty() and int(hit.index) == int(pressed.index): activate(int(hit.index))
	elif pressed.moved and mode == Layout.WALL and focus < 0:
		# Commit the closest visible exhibit as the next window centre, then refill off-screen slots.
		var closest := -1; var angle := INF
		var forward := -anchor.basis.z
		for index in cards:
			var offset: Vector3 = cards[index].node.global_position - anchor.origin
			var value := forward.angle_to(offset)
			if value < angle: closest = index; angle = value
		if closest >= 0:
			_wall_start = _wall_page_start(closest); _wall_column = -1; photo._select(closest)
		_yaw = 0; _reflow = true
	return true

func _show_pointer(hand: String, origin: Vector3, hit: Dictionary) -> void:
	if not _pointers.has(hand):
		var line := MeshInstance3D.new(); line.mesh = CylinderMesh.new()
		line.mesh.top_radius = 1.0; line.mesh.bottom_radius = 1.0; line.mesh.height = 1.0; line.mesh.radial_segments = 6
		line.material_override = _plain(Color(0.15, 0.9, 1.0, 0.65), 4); photo.add_child(line)
		var dot := MeshInstance3D.new(); dot.mesh = SphereMesh.new(); dot.mesh.radius = 1.0; dot.mesh.height = 2.0
		dot.mesh.radial_segments = 12; dot.mesh.rings = 6; dot.material_override = _plain(Color(0.85, 1.0, 1.0), 5)
		dot.material_override.no_depth_test = true; photo.add_child(dot)
		line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF; dot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_pointers[hand] = {"line": line, "dot": dot}
	var pointer: Dictionary = _pointers[hand]
	pointer.line.visible = not hit.is_empty(); pointer.dot.visible = not hit.is_empty()
	if hit.is_empty(): return
	var target: Vector3 = hit.point
	var direction := (target - origin).normalized()
	var length := origin.distance_to(target)
	var right := direction.cross(Vector3.FORWARD)
	if right.length_squared() < 0.001: right = direction.cross(Vector3.UP)
	right = right.normalized()
	pointer.line.global_transform = Transform3D(Basis(right, direction, right.cross(direction)), (origin + target) * 0.5)
	pointer.line.scale = Vector3(0.0018, length, 0.0018)
	pointer.dot.global_position = target - direction * 0.012
	pointer.dot.scale = Vector3.ONE * clampf(length * 0.0045, 0.008, 0.03)
	pointer.dot.material_override.albedo_color = Color(1.0, 0.88, 0.55) if capture.get("hand", "") == hand else Color(0.8, 1.0, 1.0)

func set_focus_distance(value: float) -> void:
	if focus < 0 or not photo or photo.geometry != 0: return
	var eye: Vector3 = photo.view_camera.global_position if is_instance_valid(photo.view_camera) else anchor.origin
	var direction := (focus_pose.origin-eye).normalized()
	if direction.length_squared() < 0.001: direction = -focus_pose.basis.z
	photo.set_screen_distance(value)
	focus_pose.origin = eye + direction * photo.screen_distance
	photo.flat_pose = photo.global_transform.affine_inverse() * focus_pose
	remember_focus_pose(focus_pose)
	photo._apply_geometry()
