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
var _fullscreen_context := Vector2i(-1, -1)
var _fullscreen_active := false
var _fullscreen_restore: Variant = null
const MOVE := 986030
const WEB := 986020
const RESIZE := 986031
const RESIZE_RIGHT := 986032
const RESIZE_BOTTOM := 986033
const SELECT := 986019
const MIN_PAGE := Vector2(1.44, 1.44 / Surface.MAX_RATIO)
const MAX_PAGE := Vector2(2.88, MIN_PAGE.x / Surface.MIN_RATIO)
const CinemaBlueprint := preload("res://scripts/environments/cinema_blueprint.gd")
const MIN_DISPLAY := RECT.size * 0.6
const MAX_DISPLAY := Vector2(CinemaBlueprint.SCREEN_WIDTH, CinemaBlueprint.SCREEN_HEIGHT)
const RESIZE_OFFSET := Vector2(0.09, 0.09)
const RESIZE_EDGE_SIZE := Vector2(0.14, 0.26)
const RESIZE_CORNER_SIZE := Vector2(0.18, 0.18)
var page_size := RECT.size
var selecting := false
var depth := preload("res://scripts/web_browser_depth.gd").new()
var depth_settings := false
var depth_choices := preload("res://scripts/choice_fields.gd").new(self)
var SELECTED: Color:
	get: return UiTheme.color("selected")
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
var effect_controls: Node3D
var drag := {}
var title_move := Move.new()
var placed := false
var _save_at := 0
var _last_pose := Transform3D.IDENTITY
var _follow_applied: Variant = null
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

func sync_follow(follow: RefCounted, viewer: Transform3D, allowed: bool) -> void:
	var key := StringName("browser_window_%d" % get_instance_id())
	if not allowed or not visible or on_screen() or not follow.enabled:
		follow.forget(key); _follow_applied = null; return
	# Explicit moves recapture the offset; head motion never changes the saved offset.
	if _follow_applied == null or not global_transform.is_equal_approx(_follow_applied) or not drag.is_empty():
		follow.capture(key, viewer, global_transform)
	else:
		var pose: Variant = follow.pose(key, viewer)
		if pose != null:
			global_transform = pose
			_last_pose = pose # Head motion is not a user layout edit.
	_follow_applied = global_transform

func relocate_view(delta: Transform3D) -> void:
	end_drag()
	global_transform = delta * global_transform
	_last_pose = delta * _last_pose
	# Cinema controls and the saved floating page both belong to the old view frame.
	# The far page itself remains anchored to the cinema's physical screen.
	if _screen_attached: _floating_pose = delta * _floating_pose
	if _near_pose != null: _near_pose = delta * _near_pose
	if _near_applied != null: _near_applied = delta * _near_applied
	if visible: refresh()
func _ready() -> void:
	super()
	depth.load_preferences()
	depth_choices.changed.connect(_depth_changed)
	depth_choices.previewed.connect(_depth_preview)
	surface = Surface.new()
	surface.configure(self, browser.menu.platform, window_id)
	get_tree().root.add_child(surface)
	effect_controls = preload("res://scripts/web_browser_effect_controls.gd").new()
	effect_controls.configure(self); add_child(effect_controls)
	effect_controls.composition_changed.connect(func(): composition_changed.emit())
	effect_controls.composition_layout_changed.connect(func(): composition_layout_changed.emit())
func page_input_blocked() -> bool: return depth.matte and not selecting
func chrome_hidden() -> bool: return not on_screen() and (not toolbar_shown or page_input_blocked())

func set_toolbar_shown(shown: bool) -> void:
	if on_screen(): shown = true
	if toolbar_shown == shown: return
	toolbar_shown = shown; depth_settings = false; depth_choices.reset()
	if not shown and depth.auto_3d_hidden and not depth.enabled:
		depth.enabled = true; depth.error = ""; depth.state = "preparing"
		if depth.strength <= 0.0: depth.strength = depth.Strength.VIDEO_DEFAULT
	end_drag(); clear_pointer_visuals(); browser.tabs_open = false
	browser.history.reset()
	refresh(); effect_controls.sync()

func sync_fullscreen(current: Dictionary) -> void:
	if on_screen():
		_fullscreen_restore = null; _fullscreen_active = false
		set_toolbar_shown(true); return
	var context := Vector2i(int(current.get("tab_id", 0)), int(current.get("navigation", 0)))
	var fullscreen: bool = current.get("fullscreen", false)
	if context != _fullscreen_context or (not fullscreen and _fullscreen_active):
		if _fullscreen_restore != null: set_toolbar_shown(bool(_fullscreen_restore))
		_fullscreen_restore = null; _fullscreen_active = false; _fullscreen_context = context
	if fullscreen and not _fullscreen_active:
		_fullscreen_restore = toolbar_shown
		set_toolbar_shown(false)
	_fullscreen_active = fullscreen
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
			var dimensions: Variant = config.get_value(section, "page_size", RECT.size)
			page_size = clamp_page_size(dimensions) if dimensions is Vector2 and dimensions.is_finite() else RECT.size
			var saved_scale := float(config.get_value(section, "scale", factor))
			factor = clampf(saved_scale, minimum_scale(), maximum_scale()) if is_finite(saved_scale) else 1.0
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
	return Vector3(0.13, 0.04 if browser.overlay_open(window_id) else 0.158 if browser.start_page.active(window_id) else HEADER.get_center().y, 0) if on_screen() else CENTRE
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
	# Stop the dragged edge at the shared portrait/landscape viewport bounds.
	# Keep the other axis fixed, and apply the same bound when restoring old layouts.
	if edge == RESIZE_RIGHT:
		dimensions.x = clampf(dimensions.x, dimensions.y * Surface.MIN_RATIO, dimensions.y * Surface.MAX_RATIO)
	else:
		dimensions.y = clampf(dimensions.y, dimensions.x / Surface.MAX_RATIO, dimensions.x / Surface.MIN_RATIO)
	return dimensions

func minimum_scale() -> float:
	# Keep both the page and its controls usable at the smallest physical size.
	return maxf(0.6, maxf(MIN_DISPLAY.x / page_size.x, MIN_DISPLAY.y / page_size.y))

func maximum_scale() -> float:
	return minf(MAX_DISPLAY.x / page_size.x, MAX_DISPLAY.y / page_size.y)

static func _resize_scale_delta(change: Vector2, size: Vector2) -> float:
	var handle := size + RESIZE_OFFSET + Vector2.ONE * 0.01
	return change.dot(handle) / handle.length_squared()

static func _layout_resize_fraction(size: Vector2, change: Vector2) -> float:
	# Intersect the drag with the shared portrait/landscape bounds. Stop at the
	# first boundary, including aspect limits, before consuming the rest as zoom.
	var fraction := 1.0
	for bound in [Vector3(1, 0, MAX_PAGE.x), Vector3(-1, 0, -MIN_PAGE.x),
		Vector3(0, 1, MAX_PAGE.y), Vector3(0, -1, -MIN_PAGE.y),
		Vector3(1, -Surface.MAX_RATIO, 0), Vector3(-1, Surface.MIN_RATIO, 0)]:
		var normal := Vector2(bound.x, bound.y)
		var step := normal.dot(change)
		if step > 0.000001:
			fraction = minf(fraction, maxf(0.0, (bound.z - normal.dot(size)) / step))
	return fraction

func resize_by(change: Vector2, edge: int, reference_scale: float = -1.0) -> void:
	if on_screen() or not change.is_finite(): return
	if edge in [RESIZE_RIGHT, RESIZE_BOTTOM]:
		_reshape_edge(change, edge, reference_scale)
		return
	var pose := global_transform
	var factor := pose.basis.get_scale().x
	# Corner drags keep a scaled window's viewport across releases and restores.
	# Only crossing back through 1:1 resumes independent width/height changes.
	if not is_equal_approx(factor, 1.0):
		var step := _resize_scale_delta(change, page_size)
		if (factor < 1.0 and factor + step >= 1.0) or (factor > 1.0 and factor + step <= 1.0):
			change *= 1.0 - (1.0 - factor) / step
			factor = 1.0
		else:
			factor += step
			change = Vector2.ZERO
	if not change.is_zero_approx():
		var fraction := _layout_resize_fraction(page_size, change)
		page_size += change * fraction
		factor += _resize_scale_delta(change * (1.0 - fraction), page_size)
	factor = clampf(factor, minimum_scale(), maximum_scale())
	# Preserve the top-left page anchor through layout/zoom transitions.
	var anchor := Vector3(RECT.position.x, RECT.end.y, 0)
	var basis := pose.basis.orthonormalized().scaled(Vector3.ONE * factor)
	global_transform = Transform3D(basis, pose * anchor - basis * anchor)

func _reshape_edge(change: Vector2, edge: int, reference_scale: float) -> void:
	var pose := global_transform
	var factor := pose.basis.get_scale().x
	var dimensions := page_size * factor
	# Edge handles change shape at any zoom. Keep the opposite physical edge
	# fixed, including when the local layout has already reached its old cap.
	if edge == RESIZE_RIGHT:
		dimensions.x = clampf(dimensions.x + change.x,
			maxf(MIN_DISPLAY.x, dimensions.y * Surface.MIN_RATIO),
			minf(MAX_DISPLAY.x, dimensions.y * Surface.MAX_RATIO))
	else:
		dimensions.y = clampf(dimensions.y + change.y,
			maxf(MIN_DISPLAY.y, dimensions.x / Surface.MAX_RATIO),
			minf(MAX_DISPLAY.y, dimensions.x / Surface.MIN_RATIO))
	# Re-express the same physical rectangle using the existing saved layout
	# bounds. A fixed per-drag reference avoids accumulating chrome scale on
	# repeated pointer updates or reversing across a layout boundary.
	var lower := maxf(0.6, maxf(dimensions.x / MAX_PAGE.x, dimensions.y / MAX_PAGE.y))
	var upper := minf(dimensions.x / MIN_PAGE.x, dimensions.y / MIN_PAGE.y)
	factor = clampf(reference_scale if reference_scale > 0.0 else factor, lower, upper)
	page_size = dimensions / factor
	var anchor := Vector3(RECT.position.x, RECT.end.y, 0)
	var basis := pose.basis.orthonormalized().scaled(Vector3.ONE * factor)
	global_transform = Transform3D(basis, pose * anchor - basis * anchor)

func _sync_presentation() -> void:
	if on_screen():
		toolbar_shown = true; _fullscreen_restore = null
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
		basis *= Basis(Vector3.RIGHT, float(screen.get("pitch", 0.0)))
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
# CSS pixels covered by one unit of page_point() UV, including focus zoom.
func page_css_scale() -> Vector2:
	return Vector2(Surface.logical_for(page_size)) * focus_crop().size
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
	browser.effects_changed.emit()
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
	browser.effects_changed.emit()
func _create_feedback() -> void:
	if is_instance_valid(_feedback): return
	_feedback = Node3D.new(); _feedback.set_meta("menu_eye_buffer", true); _feedback.set_meta("browser_world_pointer", true); add_child(_feedback)
	# Persistent, inexpensive eye-buffer overlays; never rebuild the chrome for each progress tick.
	for spec in [["background", UiTheme.color("browser_feedback"), 24], ["progress", ACCENT, 27], ["press", ACCENT, 27]]:
		var mesh := _quad(Vector2.ONE, Vector3.ZERO, spec[1], spec[2])
		mesh.name = spec[0]; mesh.visible = false
		mesh.material_override.set_shader_parameter("corner_radius", 0.0)
		_feedback.add_child(mesh)
	for index in 8:
		var mesh := _quad(Vector2.ONE, Vector3.ZERO, UiTheme.color("browser_rim") if index < 4 else ACCENT, 26)
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
	_feedback.visible = visible and not page_input_blocked() and not browser.start_page.active(window_id) and not browser.overlay_open(window_id)
	if not _feedback.visible: return
	var frame := full_page_layout()
	_feedback.global_transform = frame.pose
	var size: Vector2 = frame.size
	var page: Vector2 = page_layout().size
	var backing: MeshInstance3D = _feedback.get_node("background")
	_feedback_rect(backing, Rect2(-size / 2, size), -0.001)
	backing.visible = is_focused() and toolbar_shown
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
	_progress.material_override.set_shader_parameter("surface_color", UiTheme.color("browser_error") if not error.is_empty() else ACCENT)
	_progress.visible = toolbar_shown and (loading or now < _progress_until)
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
func page_world_point(uv: Vector2) -> Vector3:
	var layout := page_layout()
	return layout.pose * Vector3((uv.x - 0.5) * layout.size.x, (0.5 - uv.y) * layout.size.y, 0.0)
func page_point(origin: Vector3, direction: Vector3) -> Variant:
	var layout := page_layout()
	# The page is its own XR surface, outside the mono toolbar capture.
	var point: Variant = project_pointer(origin, direction, global_transform.affine_inverse() * layout.pose, false)
	if point == null: return null
	return Vector2(point.x / layout.size.x + 0.5, 0.5 - point.y / layout.size.y)
func _process(_delta: float) -> void:
	if not browser: queue_free(); return
	if effect_controls: effect_controls.sync()
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
	if surface: surface.present(visible and not browser.start_page.active(window_id) and not browser.overlay_open(window_id), RECT)
func _place_device_status(_centre: Vector2) -> void: pass
func _redraw_theme() -> void:
	super._redraw_theme()
	if not is_instance_valid(_feedback): return
	# These eye-buffer overlays intentionally survive chrome redraws.
	_feedback.get_node("background").material_override.set_shader_parameter("surface_color", UiTheme.color("browser_feedback"))
	for index in 8:
		_feedback.get_node("selection" + str(index)).material_override.set_shader_parameter("surface_color", UiTheme.color("browser_rim") if index < 4 else ACCENT)
	_update_feedback()

func _draw() -> void:
	_clear_layout()
	_sync_presentation()
	_backdrop.visible = not chrome_hidden()
	if browser and (not page_input_blocked() or on_screen()): browser.draw_window(self)
	depth_choices.begin("browser_depth_" + str(window_id))
	if depth_settings and not chrome_hidden(): _draw_depth_settings()
	if browser:
		_create_feedback()
		_pointer_panels.append(_feedback.get_node("background"))
	if page_input_blocked():
		_feedback.visible = false; _pointer_panels.clear()
		if not on_screen(): _ray_blockers.clear()
	# Disabled controls still occlude other windows and the header drag surface.
	for button in _buttons: button.hover_disabled = true
	# Above the distant page's alpha hole (25) yet below MenuComposition.POPUP_PRIORITY (30):
	# popup-classed chrome was squeezed into a 0.93 m popup slot and blurred.
	_backdrop.material_override.render_priority = 26 if on_screen() else 10
	if on_screen() and not chrome_hidden():
		if not browser.start_page.active(window_id) and not browser.overlay_open(window_id):
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
	if target == effect_controls.CHROME and on_screen(): return
	browser.focus_window(window_id)
	if depth_choices.action(target): return
	if target == effect_controls.CHROME:
		_fullscreen_restore = null
		set_toolbar_shown(not toolbar_shown); return
	if target == effect_controls.KEYBOARD:
		browser.toggle_keyboard(window_id); effect_controls.sync(); return
	if target == browser.BASE + 21:
		depth.matte = not depth.matte; depth.error = ""; depth.state = "preparing"; depth_settings = false
		refresh(); browser.effects_changed.emit(); return
	if target == browser.BASE + 16:
		depth.error = ""; depth.state = "preparing"
		if not depth.enabled and depth.strength <= 0.0: depth.strength = depth.Strength.VIDEO_DEFAULT
		depth.enabled = not depth.enabled
		if effect_controls: effect_controls.set_strength_open(depth.enabled)
		refresh(); return
	if target == browser.BASE + 17:
		depth_settings = not depth_settings; depth_choices.reset(); refresh(); return
	browser.action(target)

func _depth_preview(key: String, value: Variant) -> void:
	if key == "strength": depth.strength = float(value) / 100.0
	elif key == "position": depth.position = depth.Position.normalize(value)

func _depth_changed(key: String, value: Variant) -> void:
	depth.change(key, float(value) / 100.0 if key == "strength" else value)
	if key == "auto_3d_hidden":
		for peer in browser.windows.values():
			peer.depth.auto_3d_hidden = depth.auto_3d_hidden
			if peer != self and peer.depth_settings: peer.refresh()
	if key == "matte": depth.error = ""; depth.state = "preparing"
	if key == "strength" and depth.strength <= 0.0: depth.enabled = false
	refresh()
	browser.effects_changed.emit()

func _draw_depth_settings() -> void:
	var panel := _quad(Vector2(0.98, 0.56), Vector3(0.13, 0.095, 0.028), PANEL, 30)
	add_child(panel); _decorations.append(panel); _pointer_panels.append(panel)
	var title := _label(I18n.t("Browser effects"), Vector3(-0.30, 0.325, 0.04), 24)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; title.render_priority = 32
	_button(browser.BASE + 17, "", Vector2(0.54, 0.325), Vector2(0.08, 0.08), true, "close")
	_buttons.back().node.position.z = 0.04
	_depth_overlay_priority(_buttons.back().node)
	var rows: Array = depth.rows()
	for index in 2:
		var y := 0.21 - index * 0.13
		var label := _label(I18n.t([depth.Position.TITLE, "3D rendering"][index]), Vector3(-0.30, y, 0.04), 20)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; label.render_priority = 32
		var first := _buttons.size()
		depth_choices.field(null, rows[index + 1], Vector2(0.30, y), 0.48, 0.055)
		for button in _buttons.slice(first):
			button.node.position.z += 0.038
			_depth_overlay_priority(button.node)
	var auto_title := _label(I18n.t("3D when menus hide"), Vector3(-0.30, -0.05, 0.04), 20)
	auto_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; auto_title.render_priority = 32
	var auto_first := _buttons.size()
	depth_choices.field(null, {"key":"auto_3d_hidden", "value":depth.auto_3d_hidden, "switch":true,
		"choices":[{"value":false,"label":"Off"},{"value":true,"label":"On"}],
		"hint":"Automatically enable 2D to 3D when browser menus are hidden."}, Vector2(0.50, -0.05), 0.09, 0.055)
	for button in _buttons.slice(auto_first):
		button.node.position.z += 0.038; _depth_overlay_priority(button.node)
	var popup_buttons := _buttons.size()
	var popup_panels := _decorations.size()
	var popup_labels := _labels.size()
	depth_choices.finish()
	for button in _buttons.slice(popup_buttons):
		button.node.position.z += 0.04; _depth_overlay_priority(button.node, 35)
	for decoration in _decorations.slice(popup_panels):
		decoration.position.z += 0.04
		decoration.material_override.render_priority = 34
	for label in _labels.slice(popup_labels):
		label.position.z += 0.04; label.render_priority = 36

func _depth_overlay_priority(node: Node, priority: int = 31, base: int = -1000) -> void:
	var original := int(node.get_meta("browser_effect_priority", node.material_override.render_priority if node is MeshInstance3D and node.material_override else node.render_priority if node is Label3D else 0))
	node.set_meta("browser_effect_priority", original)
	if base == -1000: base = original
	# Preserve the icon/rail/fill/knob order when raising the whole field above its panel.
	if node is MeshInstance3D and node.material_override: node.material_override.render_priority = priority + maxi(0, original - base)
	if node is Label3D:
		node.render_priority = priority + maxi(1, original - base)
		node.outline_render_priority = node.render_priority - 1
	for child in node.get_children(): _depth_overlay_priority(child, priority, base)
func _activate_hit(hit: Dictionary) -> void:
	if not hit.get("enabled", true): return
	var peer: Node = browser.windows.get(int(hit.get("window", window_id)), self)
	if peer != self: peer._activate(int(hit.target))
	else: super(hit)
func local_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	# Include the whole visible frame before choosing the nearest window. Otherwise
	# the secondary's empty chrome is invisible to both the ray and trigger routing.
	var hit := {} if page_input_blocked() and not on_screen() else _pointer_hit_over(origin, direction, super.ray_hit(origin, direction))
	if effect_controls:
		var footer: Dictionary = effect_controls.ray_hit(origin,direction)
		if not footer.is_empty() and (hit.is_empty() or footer.distance < hit.distance):
			footer.point = to_local(effect_controls.to_global(footer.point)); footer.footer = true; hit = footer
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
		else:
			# Long, plain frame strips must not stretch the fixed-pixel chrome capture.
			panel.set_meta("menu_eye_buffer", true)
			panel.set_meta("browser_world_pointer", true)
func draw_resize_handles() -> void:
	# All three hit regions stay outside the webpage, including its fullscreen button.
	var page := page_rect()
	for spec in [[RESIZE_RIGHT, Vector2(page.end.x + RESIZE_OFFSET.x, page.get_center().y), RESIZE_EDGE_SIZE],
		[RESIZE_BOTTOM, Vector2(page.get_center().x, page.position.y - RESIZE_OFFSET.y), Vector2(RESIZE_EDGE_SIZE.y, RESIZE_EDGE_SIZE.x)],
		[RESIZE, Vector2(page.end.x + RESIZE_OFFSET.x + 0.01, page.position.y - RESIZE_OFFSET.y - 0.01), RESIZE_CORNER_SIZE]]:
		_button(spec[0], "", spec[1], spec[2])
		var tile: Dictionary = _buttons.back()
		# Simple resize marks remain in the eye buffer; the distant bottom grip
		# must not lower the title bar's compositor pixels per metre.
		tile.node.set_meta("menu_eye_buffer", true)
		tile.node.set_meta("browser_world_pointer", true)
		tile.node.position.z = 0.025
		tile.base_color = Color(0, 0, 0, 0); tile.node.material_override.set_shader_parameter("surface_color", tile.base_color)
		# Keep the visible grips by the frame; the generous transparent targets
		# extend outward so aiming need not be as precise as the glyph itself.
		var mark_offset := Vector2(-0.065, 0) if spec[0] == RESIZE_RIGHT else Vector2(0, 0.065) if spec[0] == RESIZE_BOTTOM else Vector2(-RESIZE_OFFSET.x - 0.01, RESIZE_OFFSET.y + 0.01)
		var marks := [Vector4(0, 0, 0.008, 0.12)] if spec[0] == RESIZE_RIGHT else [Vector4(0, 0, 0.12, 0.008)] if spec[0] == RESIZE_BOTTOM else [Vector4(0.025, 0, 0.009, 0.06), Vector4(0, -0.025, 0.06, 0.009)]
		for edge in marks:
			var mark := _quad(Vector2(edge.z, edge.w), Vector3(edge.x + mark_offset.x, edge.y + mark_offset.y, 0.005), UiTheme.color("browser_mark"), 12)
			tile.node.add_child(mark)
	# The corner glyph hugs both edges. Extend the same target along those edges
	# without putting a rectangular hit area over the website's fullscreen button.
	for bounds in [Rect2(page.end.x + 0.01, page.position.y - 0.02, 0.08, 0.10),
		Rect2(page.end.x - 0.08, page.position.y - 0.10, 0.09, 0.08)]:
		_text_button(RESIZE, "", bounds.get_center(), bounds.size)
func end_drag() -> void:
	drag.clear(); title_move.cancel()
func dismiss() -> void:
	depth_choices.reset(); depth_settings = false
	selecting = false; end_drag(); super()
	if browser: browser.effects_changed.emit()
static func ray_pose(origin: Vector3, direction: Vector3) -> Transform3D:
	var up := Vector3.FORWARD if absf(direction.normalized().dot(Vector3.UP)) > 0.99 else Vector3.UP
	return Transform3D(Basis.looking_at(direction.normalized(), up), origin)
func has_pointer_capture() -> bool:
	return not browser.hand.is_empty() or browser.windows.values().any(func(item): return not item.drag.is_empty() or not item.depth_choices.capture.is_empty() or (item.effect_controls and item.effect_controls.has_pointer_capture()))
func press_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if has_pointer_capture(): return true
	var hit := ray_hit(origin, direction) if tracked else {}
	# Browser windows close explicitly. A generic menu dismiss would hide this
	# window for one frame, then native tab synchronisation would reopen it.
	if hit.is_empty(): return browser.active()
	if not hit.get("enabled", true): return true
	var peer: Node = browser.windows.get(int(hit.get("window", window_id)), self)
	if hit.get("footer", false): return peer.effect_controls.press_pointer(hand,origin,direction,tracked)
	browser.focus_window(peer.window_id)
	if peer.depth_choices.press(hand, origin, direction, tracked): return true
	if int(hit.target) == MOVE:
		if peer.title_move.begin(hand, "trigger", ray_pose(origin, direction),
			[peer.move_target("browser")], to_global(hit.point), peer.head()):
			peer.drag = {"hand": hand, "kind": MOVE}
		return true
	if int(hit.target) in [RESIZE_RIGHT, RESIZE_BOTTOM, RESIZE] and not peer.on_screen():
		var point: Variant = peer.project_pointer(origin, direction, Transform3D.IDENTITY)
		if point != null:
			peer.drag = {"hand": hand, "kind": int(hit.target), "pose": peer.global_transform, "previous": point}
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
	for peer in browser.windows.values():
		if peer.effect_controls:
			peer.effect_controls.observe_ray(hand,origin,direction,tracked)
			peer.effect_controls.drag_pointer(hand,origin,direction,tracked)
	browser.menu.clear_pointer_visuals()
	for peer in browser.windows.values():
		if peer != self: peer.clear_pointer_visuals()
	super(hand, origin, direction, tracked)
	for peer in browser.windows.values(): peer.depth_choices.update(hand, origin, direction, tracked)
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
			var change: Vector3 = Vector3(point) - Vector3(capture.previous)
			capture.previous = point
			var old_size: Vector2 = peer.page_size
			var old_pose: Transform3D = peer.global_transform
			peer.resize_by(Vector2(change.x, -change.y) * capture.pose.basis.get_scale().x, capture.kind, capture.pose.basis.get_scale().x)
			if not peer.page_size.is_equal_approx(old_size) or not peer.global_transform.is_equal_approx(old_pose): peer.refresh()
		return
	browser.move(hand, origin, direction, tracked)
func release_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> void:
	for peer in browser.windows.values():
		if peer.effect_controls: peer.effect_controls.app_actions.release(hand)
	for peer in browser.windows.values():
		if peer.effect_controls and peer.effect_controls.capture_hand == hand:
			peer.effect_controls.release_pointer(hand,origin,direction,tracked); return
	for peer in browser.windows.values():
		if peer.depth_choices.capture.get("hand", "") == hand:
			peer.depth_choices.release(hand, origin, direction, tracked); return
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
		if peer.effect_controls: peer.effect_controls.cancel_pointer(hand)
		peer.depth_choices.cancel(hand)
		if peer.drag.get("hand", "") == hand: peer.end_drag()
	if browser.hand == hand: browser.cancel()
	super(hand)
func stick_scroll(amount: float, delta: float) -> void:
	if page_input_blocked() or has_pointer_capture(): return
	for peer in browser.windows.values():
		if not peer.drag.is_empty(): return
	browser.scroll(amount, delta)
func _scale_about_centre(factor: float, pose: Transform3D) -> void:
	var centre := pose * CENTRE
	var basis := pose.basis.orthonormalized().scaled(Vector3.ONE * factor)
	global_transform = Transform3D(basis, centre - basis * CENTRE)
func adjust_size(amount: float) -> void:
	if on_screen(): return
	var factor := clampf(global_basis.get_scale().x + amount, minimum_scale(), maximum_scale())
	_scale_about_centre(factor, global_transform); save_layout()
func adjust_distance(amount: float) -> void:
	var centre := to_global(CENTRE); var offset := centre - head().origin
	var distance := clampf(offset.length() + amount, 0.6, 8.0)
	global_position += offset.normalized() * (distance - offset.length()); save_layout()
func _exit_tree() -> void:
	if is_instance_valid(surface): surface.queue_free()
