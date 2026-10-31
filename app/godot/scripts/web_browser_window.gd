extends "res://scripts/ray_menu.gd"
## Independent browser chrome. Reuses RayMenu hit testing and InterfaceMove placement math.
const Move := preload("res://scripts/interface_move.gd")
const Surface := preload("res://scripts/web_browser_surface.gd")
const Focus := preload("res://scripts/web_browser_focus.gd")
const RECT := Rect2(-0.59, -0.48, 1.44, 0.90)
const HEADER := Rect2(-0.60, 0.42, 1.46, 0.416)
const TOOL_SIZE := Vector2(0.12, 0.12)
const PLAY_Y := 0.50
const NAV_Y := 0.632
const TABS_Y := 0.764
var toolbar_shown := true
const MOVE := 986030
const WEB := 986020
const RESIZE := 986031
const RESIZE_RIGHT := 986032
const RESIZE_BOTTOM := 986033
const SELECT := 986019
const MIN_PAGE := Vector2(1.44, 1.44 / Surface.MAX_RATIO)
const MAX_PAGE := Vector2(2.88, 1.80)
var page_size := RECT.size
var selecting := false
var selection := Rect2()
var _selection_context := Vector2i.ZERO
var _feedback: Node3D
var _press_uv := Vector2.ZERO
var _press_until := 0
var _progress: MeshInstance3D
var _progress_value := 0.0
var _was_loading := false
var _progress_until := 0
var _feedback_page := -1
var _feedback_error := ""
var CENTRE: Vector3:
	get: return Vector3(0.13 + (page_size.x - RECT.size.x) / 2, -(page_size.y - RECT.size.y) / 2, 0)
var controller: WeakRef
var window_id := 1
var mode := "floating"
var surface: Node3D
var drag := {}
var title_move := Move.new()
var placed := false
var _save_at := 0
var _last_pose := Transform3D.IDENTITY
var _screen_attached := false
var _floating_pose := Transform3D.IDENTITY
# Cinema mode: the page fills the far screen while its controls float near the viewer,
# placed once like the cinema playback bar and left in place as the head turns.
const CinemaMenuLayout := preload("res://scripts/environments/cinema_menu_layout.gd")
var _near_pose: Variant = null
var _near_applied: Variant = null
var browser: RefCounted:
	get: return controller.get_ref()

func configure(owner: RefCounted, id: int) -> void:
	controller = weakref(owner); window_id = id
	set_meta("menu_browser_layer", true)
	ray_max_distance = 100.0
func composition_root() -> Node3D: return self
func _ready() -> void:
	super()
	surface = Surface.new()
	surface.configure(self, browser.menu.platform, window_id)
	get_tree().root.add_child(surface)
func head() -> Transform3D:
	var provider: Callable = browser.menu.layout_head_provider
	var value: Variant = provider.call() if provider.is_valid() else null
	return value if value is Transform3D else Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
func show_window() -> void:
	visible = true
	if not placed:
		placed = true; recenter(true)
	refresh()
func recenter(load_saved: bool = false) -> void:
	_screen_attached = false; _near_pose = null; _near_applied = null
	var frame := Move.menu_head(head())
	var offset: Vector3 = browser.default_window_offset(window_id)
	var factor := 1.0
	if load_saved and OS.get_name() == "Android":
		var config := ConfigFile.new()
		if config.load("user://browser_windows.cfg") == OK:
			var section := layout_section()
			# Migrate the old layouts once; peers retain one placement regardless of count.
			if not config.has_section(section): section = ("pair_" if browser.paired_layout else "single_") + str(window_id)
			if not config.has_section(section): section = str(window_id)
			var saved: Variant = config.get_value(section, "offset", offset)
			if saved is Vector3 and saved.is_finite() and saved.length() >= 0.6 and saved.length() <= 8: offset = saved
			factor = clampf(float(config.get_value(section, "scale", factor)), 0.6, 2.5)
			var dimensions: Variant = config.get_value(section, "page_size", RECT.size)
			page_size = clamp_page_size(dimensions) if dimensions is Vector2 and dimensions.is_finite() else RECT.size
			mode = str(config.get_value(section, "mode", mode))
			if mode not in ["floating", "cinema"]: mode = "floating"
	var centre := frame * offset
	global_transform = Transform3D(Move.face_viewer(centre, head()).scaled(Vector3.ONE * factor), centre)
	global_position -= global_basis * CENTRE
	_sync_presentation()
	_save_at = Time.get_ticks_msec() + 700
func layout_section() -> String:
	return "window_" + str(window_id)
func save_layout() -> void:
	if not placed or OS.get_name() != "Android": return
	var config := ConfigFile.new(); config.load("user://browser_windows.cfg")
	var pose := _floating_pose if _screen_attached else global_transform
	config.set_value(layout_section(), "offset", Move.menu_head(head()).affine_inverse() * (pose * CENTRE))
	config.set_value(layout_section(), "scale", pose.basis.get_scale().x)
	config.set_value(layout_section(), "page_size", page_size)
	config.set_value(layout_section(), "mode", mode)
	config.save("user://browser_windows.cfg")
func cinema() -> Dictionary:
	return browser.cinema_provider.call() if browser.cinema_provider.is_valid() else {}
func on_screen() -> bool: return mode == "cinema" and not cinema().is_empty()
func move_centre() -> Vector3:
	return Vector3(0.13, 0.04 if browser.tabs_open and browser.focused_window == window_id else 0.158 if browser.start_page.active(window_id) else HEADER.get_center().y, 0) if on_screen() else CENTRE
func move_target(key: String) -> Dictionary:
	return {"node": self, "kind": "detail", "key": key, "pose": global_transform, "upright_facing": true, "face_center": move_centre()}
func set_mode(value: String) -> void:
	end_drag(); clear_pointer_visuals()
	mode = value
	_sync_presentation()
func page_rect() -> Rect2:
	return Rect2(Vector2(RECT.position.x, RECT.end.y - page_size.y), page_size)
static func clamp_page_size(value: Vector2, edge: int = RESIZE) -> Vector2:
	var dimensions := value.clamp(MIN_PAGE, MAX_PAGE)
	# Stop the dragged edge before the CSS viewport falls below the desktop minimum.
	# Keep the other axis fixed, and apply the same bound when restoring old layouts.
	if edge == RESIZE_RIGHT:
		dimensions.x = clampf(dimensions.x, dimensions.y * Surface.MIN_RATIO, dimensions.y * Surface.MAX_RATIO)
	else:
		dimensions.y = clampf(dimensions.y, dimensions.x / Surface.MAX_RATIO, dimensions.x / Surface.MIN_RATIO)
	return dimensions
func _sync_presentation() -> void:
	if on_screen():
		if not _screen_attached: _floating_pose = global_transform; _screen_attached = true
		var anchor := move_centre()
		# A title or grip drag moved the bar: keep it where it was put.
		if _near_pose != null and _near_applied != null and not global_transform.is_equal_approx(_near_applied):
			_near_pose = Transform3D(global_basis, global_transform * anchor)
		if _near_pose == null: _near_pose = CinemaMenuLayout.near_transport_pose(head())
		var near: Transform3D = _near_pose
		global_transform = Transform3D(near.basis, near.origin - near.basis * anchor)
		_near_applied = global_transform
	elif _screen_attached:
		global_transform = _floating_pose; _screen_attached = false; _near_pose = null; _near_applied = null
func full_page_layout() -> Dictionary:
	if on_screen():
		var screen := cinema()
		var size := page_size * minf(float(screen.width) / page_size.x, float(screen.height) / page_size.y)
		var basis := Basis(Vector3.UP, float(screen.get("yaw", 0.0)))
		var pose := Transform3D(basis, Vector3(float(screen.position[0]), float(screen.position[1]), float(screen.position[2])) + basis.z * 0.06)
		return {"pose": pose, "size": size}
	var bounds := page_rect()
	var pose := global_transform * Transform3D(Basis.IDENTITY, Vector3(bounds.get_center().x, bounds.get_center().y, 0.012))
	var size := page_size * Vector2(pose.basis.get_scale().x, pose.basis.get_scale().y)
	pose.basis = pose.basis.orthonormalized()
	return {"pose": pose, "size": size}
func focus_tab() -> int:
	return int(browser.window_state(window_id).get("tab_id", window_id))
func focus_crop() -> Rect2:
	return browser.focus_regions.get(focus_tab(), Focus.FULL)
func is_focused() -> bool: return focus_crop() != Focus.FULL
func source_point(uv: Vector2) -> Vector2:
	return Focus.map_point(uv, focus_crop())
func page_layout() -> Dictionary:
	var layout := full_page_layout()
	layout.size = Focus.fitted(layout.size, Vector2(Surface.pixels_for(page_size, browser.low_end)), focus_crop())
	return layout
func toggle_focus() -> void:
	end_drag()
	if selecting: selecting = false
	elif is_focused(): browser.focus_regions.erase(focus_tab())
	else:
		selecting = true; selection = Rect2()
		_selection_context = Vector2i(focus_tab(), int(browser.window_state(window_id).get("navigation", 0)))
	refresh()
func sync_page_state() -> void:
	var context := Vector2i(focus_tab(), int(browser.window_state(window_id).get("navigation", 0)))
	if selecting and context != _selection_context:
		selecting = false; end_drag(); refresh()
func show_press(uv: Vector2) -> void:
	_press_uv = uv; _press_until = Time.get_ticks_msec() + 280
func finish_selection() -> void:
	if Focus.valid(selection):
		browser.focus_regions[focus_tab()] = selection
		selecting = false
	end_drag(); refresh()
func _create_feedback() -> void:
	if is_instance_valid(_feedback): return
	_feedback = Node3D.new(); _feedback.set_meta("menu_eye_buffer", true); add_child(_feedback)
	# Persistent, inexpensive eye-buffer overlays; never rebuild the chrome for each progress tick.
	for spec in [["background", Color("10141b"), 24], ["progress", ACCENT, 27], ["press", ACCENT, 27]]:
		var mesh := _quad(Vector2.ONE, Vector3.ZERO, spec[1], spec[2])
		mesh.name = spec[0]; mesh.visible = false
		mesh.material_override.set_shader_parameter("corner_radius", 0.0)
		_feedback.add_child(mesh)
	for index in 8:
		var mesh := _quad(Vector2.ONE, Vector3.ZERO, Color(0.02, 0.03, 0.04, 0.60) if index < 4 else ACCENT, 26)
		mesh.name = "selection" + str(index); mesh.visible = false
		mesh.material_override.set_shader_parameter("corner_radius", 0.0)
		_feedback.add_child(mesh)
	_progress = _feedback.get_node("progress")
func _feedback_rect(mesh: MeshInstance3D, rect: Rect2, z: float = 0.003) -> void:
	mesh.visible = rect.size.x > 0.00001 and rect.size.y > 0.00001
	if not mesh.visible: return
	if mesh.mesh.size != rect.size:
		mesh.mesh.size = rect.size
		mesh.material_override.set_shader_parameter("surface_size", rect.size)
	mesh.position = Vector3(rect.get_center().x, rect.get_center().y, z)
func _update_feedback() -> void:
	_create_feedback()
	_feedback.visible = visible and not browser.start_page.active(window_id) and not (browser.tabs_open and browser.focused_window == window_id)
	if not _feedback.visible: return
	var frame := full_page_layout()
	_feedback.global_transform = frame.pose
	var size: Vector2 = frame.size
	var page: Vector2 = page_layout().size
	var backing: MeshInstance3D = _feedback.get_node("background")
	_feedback_rect(backing, Rect2(-size / 2, size), -0.001)
	backing.visible = is_focused()
	var state: Dictionary = browser.window_state(window_id)
	var now := Time.get_ticks_msec()
	if _feedback_page != focus_tab():
		_feedback_page = focus_tab(); _was_loading = false; _progress_until = 0; _progress_value = 0; _press_until = 0; _feedback_error = ""
	var loading: bool = state.get("loading", false)
	var error := str(state.get("error", ""))
	if loading:
		if not _was_loading: _progress_value = 0
		_progress_value = maxf(_progress_value, clampf(float(state.get("progress", 0)) / 100.0, 0.035, 0.97))
	elif _was_loading: _progress_value = 1.0; _progress_until = now + (900 if not error.is_empty() else 250)
	if not error.is_empty() and error != _feedback_error:
		_progress_value = 1.0; _progress_until = now + 900
	_was_loading = loading; _feedback_error = error
	_feedback_rect(_progress, Rect2(-size.x / 2, -size.y / 2 - 0.004, size.x * _progress_value, 0.004))
	_progress.material_override.set_shader_parameter("surface_color", Color("ef8d80") if not error.is_empty() else ACCENT)
	_progress.visible = loading or now < _progress_until
	var press: MeshInstance3D = _feedback.get_node("press")
	var remaining := clampf(float(_press_until - now) / 280.0, 0, 1)
	var diameter := minf(page.x, page.y) * (0.018 + 0.018 * (1.0 - remaining))
	var centre := Vector2((_press_uv.x - 0.5) * page.x, (0.5 - _press_uv.y) * page.y)
	_feedback_rect(press, Rect2(centre - Vector2.ONE * diameter / 2, Vector2.ONE * diameter))
	press.material_override.set_shader_parameter("corner_radius", diameter / 2)
	press.material_override.set_shader_parameter("surface_color", Color(ACCENT, remaining * 0.8))
	press.visible = remaining > 0 and not selecting
	if not selecting or not selection.has_area():
		for index in 8: _feedback.get_node("selection" + str(index)).visible = false
		return
	# Dim only outside the selected rectangle; the content inside remains readable.
	var box := Rect2(Vector2((selection.position.x - 0.5) * size.x, (0.5 - selection.end.y) * size.y), selection.size * size)
	var masks := [Rect2(-size / 2, Vector2(box.position.x + size.x / 2, size.y)),
		Rect2(Vector2(box.end.x, -size.y / 2), Vector2(size.x / 2 - box.end.x, size.y)),
		Rect2(Vector2(box.position.x, -size.y / 2), Vector2(box.size.x, box.position.y + size.y / 2)),
		Rect2(Vector2(box.position.x, box.end.y), Vector2(box.size.x, size.y / 2 - box.end.y))]
	var thickness := minf(size.x, size.y) * 0.003
	masks.append_array([Rect2(box.position, Vector2(box.size.x, thickness)), Rect2(Vector2(box.position.x, box.end.y - thickness), Vector2(box.size.x, thickness)),
		Rect2(box.position, Vector2(thickness, box.size.y)), Rect2(Vector2(box.end.x - thickness, box.position.y), Vector2(thickness, box.size.y))])
	for index in 8:
		var mesh: MeshInstance3D = _feedback.get_node("selection" + str(index))
		_feedback_rect(mesh, masks[index])
		mesh.visible = mesh.visible and selecting and selection.has_area()
func page_point(origin: Vector3, direction: Vector3) -> Variant:
	var layout := page_layout()
	var point: Variant = project_pointer(origin, direction, global_transform.affine_inverse() * layout.pose)
	if point == null: return null
	return Vector2(point.x / layout.size.x + 0.5, 0.5 - point.y / layout.size.y)
func _process(_delta: float) -> void:
	if not browser: queue_free(); return
	if not browser.active():
		if visible: dismiss()
		if surface: surface.present(false, RECT)
		return
	if visible:
		_sync_presentation()
		_update_feedback()
		if not _screen_attached and not global_transform.is_equal_approx(_last_pose):
			_last_pose = global_transform; _save_at = Time.get_ticks_msec() + 700
		if _save_at > 0 and drag.is_empty() and Time.get_ticks_msec() >= _save_at:
			_save_at = 0; save_layout()
		for button in _buttons:
			if button.target == WEB:
				var layout := page_layout()
				button.node.global_transform = layout.pose
				button.node.mesh.size = layout.size
				button.rect.size = layout.size
	if surface: surface.present(visible and not browser.start_page.active(window_id) and not (browser.tabs_open and browser.focused_window == window_id), RECT)
func _place_device_status(_centre: Vector2) -> void: pass
func _draw() -> void:
	_clear_layout()
	_sync_presentation()
	if browser: browser.draw_window(self)
	if browser:
		_create_feedback()
		_pointer_panels.append(_feedback.get_node("background"))
	# Disabled controls still occlude other windows and the header drag surface.
	for button in _buttons: button.hover_disabled = true
	# Above the distant page's alpha hole (25) yet below MenuComposition.POPUP_PRIORITY (30):
	# popup-classed chrome was squeezed into a 0.93 m popup slot and blurred.
	_backdrop.material_override.render_priority = 26 if on_screen() else 10
	if on_screen():
		if not browser.start_page.active(window_id) and not (browser.tabs_open and browser.focused_window == window_id):
			# The near bar uses the same empty-header drag surface as floating windows.
			_ray_blockers.append({"target": MOVE, "rect": Rect2(-_backdrop.mesh.size / 2, _backdrop.mesh.size), "enabled": true, "node": _backdrop, "radius": 0.025})
		# Transparent menu tiles do not write depth. Draw near controls after the
		# distant page's alpha hole (priority 25), without raising its hit tile.
		for button in _buttons:
			if button.target != WEB: _raise_chrome(button.node)
		for label in _labels: _raise_chrome(label)
		for decoration in _decorations: _raise_chrome(decoration)

func toolbar_bounds() -> Rect2:
	return HEADER if on_screen() else Rect2(HEADER.position, Vector2(page_size.x + 0.02, HEADER.size.y))

func _raise_chrome(node: Node) -> void:
	if node is Label3D:
		if not node.has_meta("browser_priority"): node.set_meta("browser_priority", node.render_priority)
		node.render_priority = int(node.get_meta("browser_priority")) + 16
	elif node is MeshInstance3D and node.material_override:
		var material: Material = node.material_override
		if not material.has_meta("browser_priority"): material.set_meta("browser_priority", material.render_priority)
		material.render_priority = int(material.get_meta("browser_priority")) + 16
	for child in node.get_children(): _raise_chrome(child)
func _activate(target: int) -> void:
	browser.focus_window(window_id)
	browser.action(target)
func _activate_hit(hit: Dictionary) -> void:
	if not hit.get("enabled", true): return
	var peer: Node = browser.windows.get(int(hit.get("window", window_id)), self)
	if peer != self: peer._activate(int(hit.target))
	else: super(hit)
func local_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	# Include the whole visible frame before choosing the nearest window. Otherwise
	# the secondary's empty chrome is invisible to both the ray and trigger routing.
	var hit := _pointer_hit_over(origin, direction, super.ray_hit(origin, direction))
	if not hit.is_empty(): hit.window = window_id
	return hit
func ray_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	var hit := local_hit(origin, direction)
	if browser:
		for peer in browser.windows.values():
			if peer == self or not peer.visible: continue
			var candidate: Dictionary = peer.local_hit(origin, direction)
			if not candidate.is_empty() and (hit.is_empty() or candidate.distance < hit.distance):
				candidate.point = to_local(peer.to_global(candidate.point)); hit = candidate
	return hit
func grab_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	var hit := _local_grab_hit(origin, direction)
	if browser:
		for peer in browser.windows.values():
			if peer == self: continue
			var candidate: Dictionary = peer._local_grab_hit(origin, direction)
			if not candidate.is_empty() and (hit.is_empty() or candidate.distance < hit.distance):
				candidate.point = to_local(peer.to_global(candidate.point)); hit = candidate
	return hit
func _local_grab_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	if not visible: return {}
	var hit := local_hit(origin, direction)
	# In cinema mode only the near controls move; the page stays on the far screen.
	if on_screen() and int(hit.get("target", -1)) in [WEB, NONE]: return {}
	if not hit.is_empty(): hit.window = window_id
	return hit
func draw_frame_panels() -> void:
	# The separate web layer sits below the menu layers. Capture a transparent
	# centre rather than an opaque backdrop that would paint over the page.
	var page := page_rect()
	var header := Rect2(HEADER.position, Vector2(page.size.x + 0.02, HEADER.size.y))
	for bounds in [header, Rect2(-0.60, page.position.y - 0.02, page.size.x + 0.02, 0.02),
		Rect2(-0.60, page.position.y, 0.01, page.size.y), Rect2(page.end.x, page.position.y, 0.01, page.size.y)]:
		var centre: Vector2 = bounds.get_center()
		var panel := _quad(bounds.size, Vector3(centre.x, centre.y, 0), PANEL, 10)
		panel.material_override.set_shader_parameter("corner_radius", 0.004)
		add_child(panel); _decorations.append(panel); _pointer_panels.append(panel)
		if bounds == header:
			panel.set_meta("browser_header", true)
			# The existing header mesh doubles as a drag surface behind its controls.
			_ray_blockers.append({"target": MOVE, "rect": bounds, "enabled": true, "node": panel, "radius": 0.004})
func draw_resize_handles() -> void:
	# All three hit regions stay outside the webpage, including its fullscreen button.
	var page := page_rect()
	for spec in [[RESIZE_RIGHT, Vector2(page.end.x + 0.035, page.get_center().y), Vector2(0.05, 0.14)],
		[RESIZE_BOTTOM, Vector2(page.get_center().x, page.position.y - 0.045), Vector2(0.14, 0.05)],
		[RESIZE, Vector2(page.end.x + 0.035, page.position.y - 0.045), Vector2(0.05, 0.05)]]:
		_button(spec[0], "", spec[1], spec[2])
		var tile: Dictionary = _buttons.back()
		tile.node.position.z = 0.025
		tile.base_color = Color(0, 0, 0, 0); tile.node.material_override.set_shader_parameter("surface_color", tile.base_color)
		var marks := [Vector4(0, 0, 0.004, 0.06)] if spec[0] == RESIZE_RIGHT else [Vector4(0, 0, 0.06, 0.004)] if spec[0] == RESIZE_BOTTOM else [Vector4(0.009, 0.001, 0.004, 0.025), Vector4(-0.001, -0.009, 0.025, 0.004)]
		for edge in marks:
			var mark := _quad(Vector2(edge.z, edge.w), Vector3(edge.x, edge.y, 0.005), Color(0.7, 0.85, 0.82), 12)
			tile.node.add_child(mark)
func end_drag() -> void:
	drag.clear(); title_move.cancel()
func dismiss() -> void:
	selecting = false; end_drag(); super()
static func ray_pose(origin: Vector3, direction: Vector3) -> Transform3D:
	var up := Vector3.FORWARD if absf(direction.normalized().dot(Vector3.UP)) > 0.99 else Vector3.UP
	return Transform3D(Basis.looking_at(direction.normalized(), up), origin)
func has_pointer_capture() -> bool:
	return not browser.hand.is_empty() or browser.windows.values().any(func(item): return not item.drag.is_empty())
func press_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if has_pointer_capture(): return true
	var hit := ray_hit(origin, direction) if tracked else {}
	if hit.is_empty(): return false
	if not hit.get("enabled", true): return true
	var peer: Node = browser.windows.get(int(hit.get("window", window_id)), self)
	browser.focus_window(peer.window_id)
	if int(hit.target) == MOVE:
		if peer.title_move.begin(hand, "trigger", ray_pose(origin, direction),
			[peer.move_target("browser")], to_global(hit.point), peer.head()):
			peer.drag = {"hand": hand, "kind": MOVE}
		return true
	if int(hit.target) in [RESIZE_RIGHT, RESIZE_BOTTOM, RESIZE] and not peer.on_screen():
		var point: Variant = peer.project_pointer(origin, direction, Transform3D.IDENTITY)
		if point != null:
			peer.drag = {"hand": hand, "kind": int(hit.target), "pose": peer.global_transform, "start": point, "size": peer.page_size}
		return true
	if int(hit.target) == WEB:
		if peer.selecting:
			var uv: Variant = peer.page_point(origin, direction)
			if uv != null:
				peer.selection = Rect2(uv, Vector2.ZERO)
				peer.drag = {"hand": hand, "kind": SELECT, "start": uv}
			return true
		return browser.press(hand, origin, direction, tracked)
	peer._activate(int(hit.target)); return true
func update_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	browser.menu.clear_pointer_visuals()
	for peer in browser.windows.values():
		if peer != self: peer.clear_pointer_visuals()
	super(hand, origin, direction, tracked)
	for peer in browser.windows.values():
		if peer.drag.get("hand", "") != hand: continue
		if not tracked or not origin.is_finite() or not direction.is_finite() or direction.length_squared() < 0.00001: peer.end_drag(); return
		if peer.drag.kind == MOVE:
			peer.title_move.update(ray_pose(origin, direction), peer.head(), null)
			if peer.title_move.capture.is_empty(): peer.end_drag()
			return
		if peer.drag.kind == SELECT:
			var uv: Variant = peer.page_point(origin, direction)
			if uv != null: peer.selection = Focus.selection(peer.drag.start, uv)
			return
		var capture: Dictionary = peer.drag
		var point: Variant = peer.project_pointer(origin, direction, peer.global_transform.affine_inverse() * capture.pose)
		if point != null:
			var change: Vector3 = Vector3(point) - Vector3(capture.start)
			var dimensions: Vector2 = capture.size + Vector2(0.0 if capture.kind == RESIZE_BOTTOM else change.x, 0.0 if capture.kind == RESIZE_RIGHT else -change.y)
			dimensions = clamp_page_size(dimensions, capture.kind)
			if not peer.page_size.is_equal_approx(dimensions):
				peer.page_size = dimensions; peer.refresh()
		return
	browser.move(hand, origin, direction, tracked)
func release_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	for peer in browser.windows.values():
		if peer.drag.get("hand", "") == hand:
			if peer.drag.kind == SELECT:
				var uv: Variant = peer.page_point(origin, direction) if tracked else null
				if uv != null:
					peer.selection = Focus.selection(peer.drag.start, uv); peer.finish_selection()
				else: peer.end_drag(); peer.selection = Rect2()
			else: peer.end_drag(); peer.save_layout()
			return
	browser.release(hand, origin, direction, tracked)
func cancel_pointer(hand: String) -> void:
	for peer in browser.windows.values():
		if peer.drag.get("hand", "") == hand: peer.end_drag()
	if browser.hand == hand: browser.cancel()
	super(hand)
func stick_scroll(amount: float, delta: float) -> void:
	for peer in browser.windows.values():
		if not peer.drag.is_empty(): return
	browser.scroll(amount, delta)
func _scale_about_centre(factor: float, pose: Transform3D) -> void:
	var centre := pose * CENTRE
	var basis := pose.basis.orthonormalized().scaled(Vector3.ONE * factor)
	global_transform = Transform3D(basis, centre - basis * CENTRE)
func adjust_size(amount: float) -> void:
	if on_screen(): return
	var factor := clampf(global_basis.get_scale().x + amount, 0.6, 2.5)
	_scale_about_centre(factor, global_transform); save_layout()
func adjust_distance(amount: float) -> void:
	var centre := to_global(CENTRE); var offset := centre - head().origin
	var distance := clampf(offset.length() + amount, 0.6, 8.0)
	global_position += offset.normalized() * (distance - offset.length()); save_layout()
func _exit_tree() -> void:
	if is_instance_valid(surface): surface.queue_free()
