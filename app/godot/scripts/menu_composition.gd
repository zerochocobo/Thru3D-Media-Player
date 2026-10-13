extends Node
## High-density menus on OpenXR quad layers. Every flat surface of the visible 3D menu (main panel,
## angled side column, raised popups) is captured orthographically into its own quad layer, so the
## compositor resolves stereo parallax and head motion: a surface re-renders only when its content
## changes, never because the head moved. Ray hit geometry and the 3D menu code stay unchanged.
##
## Swapchain rules (Godot 4.7.2, GLES3):
## - A layer viewport in UPDATE_ONCE creates a new *static* swapchain on every update. The submit
##   viewports switch between UPDATE_ALWAYS (repaint frames) and UPDATE_DISABLED instead, which
##   keeps one dynamic swapchain and lets the compositor reuse the last released image.
## - Freeing a swapchain while the viewport's render target is overridden with its image (hiding
##   the layer, detaching or resizing its viewport) corrupts the render target and crashed the
##   Quest GL thread. Each slot therefore has a fixed pixel size, is never hidden or detached, and
##   keeps its swapchain for the session; an idle slot shrinks to a sub-pixel quad instead.
const GROUP_BIT := 16
const MAX_GROUPS := 4
const GROUP_MASK := ((1 << MAX_GROUPS) - 1) << GROUP_BIT
## Fixed per-slot capture sizes: main panel, tall side column, two popups. Low-end GPUs use 2/3.
const SLOT_PIXELS := [Vector2i(2560, 2560), Vector2i(1024, 2304), Vector2i(1536, 1536), Vector2i(1536, 1536)]
const SLOT_PREFERENCE := {"panel": [0, 2, 3, 1], "tall": [1, 0, 2, 3], "popup": [2, 3, 0, 1]}
const HIDDEN_SIZE := Vector2(0.0005, 0.0005)
## Layer orders: video/pictures at -8, menu surfaces back-to-front from here, eye buffer at 0.
const ORDER_BASE := -6
## Surfaces whose offsets along a shared normal differ less than this share one layer plane.
const PLANE_GAP := 0.015
## Popups draw with render priority 30+; they and their children never share a panel's layer.
const POPUP_PRIORITY := 30
const NORMAL_DOT := 0.9995
const MARGIN := 0.012
const GRID := 0.05
## A low-rate refresh catches visuals changed without a signal (late thumbnails, text).
const KEEPALIVE_MS := 250
## Session kill switch: a sustained frame-rate collapse while menu layers show returns to the
## eye-buffer menu until restart. Catastrophic cases only; not a tuning loop.
const WATCHDOG_SECONDS := 2.0
const WATCHDOG_FPS_RATIO := 0.5
const HOLE_SHADER := preload("res://shaders/menu_layer_hole.gdshader")
const COPY_SHADER := preload("res://shaders/menu_layer_copy.gdshader")
var menus: Array = []
var origin: Node3D
var eye_camera: Camera3D
var display: RefCounted
var xr: XRInterface
var api: OpenXRAPIExtension
var enabled := false
## Host-only injection: captures the same textures without claiming a native XR result.
var force_capture := false
var low_end := false
var active: Node3D
var slots: Array[Dictionary] = []
var originals: Array[Dictionary] = []
var dirty := true
var geometry_dirty := true
var eye_mask := 0
var fallback_reason := "not_configured"
var repaints := 0
var _painted_ms := 0
var _last_menu: Node3D
var _watch_time := 0.0
var _watch_frames := 0

func configure(target_origin: Node3D, target_camera: Camera3D, target_display: RefCounted,
		target_menus: Array, is_low_end: bool, host_capture: bool = false) -> void:
	origin = target_origin; eye_camera = target_camera; display = target_display
	menus = target_menus; low_end = is_low_end; force_capture = host_capture
	xr = XRServer.find_interface("OpenXR")
	var probe := OpenXRCompositionLayerQuad.new()
	enabled = host_capture or (xr != null and xr.is_initialized() and xr.get_view_count() == 2 and probe.is_natively_supported())
	probe.free()
	if not enabled:
		fallback_reason = "native_quad_unavailable"
		set_process(false)
		return
	if not host_capture:
		api = OpenXRAPIExtension.new()
		xr.session_begun.connect(invalidate)
	process_priority = 100 # after scrolling, hover, controller moves and gesture animation
	eye_mask = eye_camera.cull_mask
	eye_camera.cull_mask &= ~GROUP_MASK
	for index in MAX_GROUPS:
		slots.append(_make_slot(index))
	get_tree().node_added.connect(_node_added)
	for menu in menus:
		menu.composition_changed.connect(repaint)
		menu.composition_layout_changed.connect(invalidate)
		_watch_children(menu)
	fallback_reason = ""

func _make_slot(index: int) -> Dictionary:
	# Child viewports render before their parent: the capture is complete before the copy.
	var pixels: Vector2i = SLOT_PIXELS[index]
	if low_end: pixels = Vector2i(ceili(pixels.x * 2.0 / 3.0 / 16) * 16, ceili(pixels.y * 2.0 / 3.0 / 16) * 16)
	var submit := SubViewport.new(); submit.size = pixels
	submit.transparent_bg = true; submit.disable_3d = true; submit.world_2d = World2D.new()
	submit.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(submit)
	var raw := SubViewport.new(); raw.size = pixels; raw.transparent_bg = true
	raw.world_3d = origin.get_viewport().world_3d
	raw.render_target_update_mode = SubViewport.UPDATE_DISABLED
	submit.add_child(raw)
	var camera := Camera3D.new(); camera.cull_mask = 1 << (GROUP_BIT + index)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.near = 0.05; camera.far = 0.5
	camera.environment = clear_environment(); raw.add_child(camera)
	# The swapchain image cannot be sampled by the eye-buffer mask, so it gets a copy.
	var copy := ColorRect.new(); copy.size = Vector2(pixels)
	var copy_material := ShaderMaterial.new(); copy_material.shader = COPY_SHADER
	copy_material.set_shader_parameter("menu_texture", raw.get_texture())
	copy.material = copy_material; submit.add_child(copy)
	var layer := OpenXRCompositionLayerQuad.new()
	layer.name = "Menu%d" % index
	layer.alpha_blend = true
	# The mask follows actual menu coverage instead of clearing the whole rectangle.
	# Visible for the whole session; without an acquired image Godot skips it.
	layer.enable_hole_punch = false; layer.visible = not force_capture
	layer.quad_size = HIDDEN_SIZE
	origin.add_child(layer); layer.layer_viewport = submit
	for property in layer.get_property_list():
		if property.name == "XR_FB_composition_layer_settings/manual/supersampling_mode":
			layer.set(property.name, 1) # normal: the capture is denser than the display
	var hole := MeshInstance3D.new(); hole.mesh = QuadMesh.new()
	hole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := ShaderMaterial.new(); material.shader = HOLE_SHADER
	# First in the transparent pass: later eye-buffer content in front still blends over it.
	material.render_priority = -128
	material.set_shader_parameter("menu_texture", raw.get_texture())
	hole.material_override = material; hole.visible = false
	origin.add_child(hole)
	return {"index": index, "raw": raw, "camera": camera, "submit": submit, "copy": copy, "layer": layer,
		"hole": hole, "key": "", "used": false, "relative": Transform3D.IDENTITY, "rect": Rect2(),
		"nodes": [], "rank": Vector2.ZERO, "tail": 0}

static func clear_environment() -> Environment:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0, 0, 0, 0)
	return environment

func invalidate() -> void:
	dirty = true; geometry_dirty = true

func repaint() -> void:
	dirty = true

func _watch_children(node: Node) -> void:
	if node.has_meta("menu_eye_buffer"): return
	if node.has_signal("visual_changed") and not node.is_connected("visual_changed", repaint):
		node.connect("visual_changed", repaint)
	for child in node.get_children(): _watch_children(child)

func _node_added(node: Node) -> void:
	for menu in menus:
		if menu.is_ancestor_of(node):
			_watch_children(node)
			if menu == active: invalidate()
			return

func _process(delta: float) -> void:
	update()
	_watchdog(delta)

func _watchdog(delta: float) -> void:
	if not enabled or force_capture or not display or not display.menu_layers:
		_watch_time = 0.0; _watch_frames = 0; return
	_watch_time += delta; _watch_frames += 1
	if _watch_time < WATCHDOG_SECONDS: return
	var refresh := 72.0
	if xr is OpenXRInterface and xr.display_refresh_rate > 0.0: refresh = xr.display_refresh_rate
	var fps := _watch_frames / _watch_time
	if fps < refresh * WATCHDOG_FPS_RATIO:
		DiagnosticLog.record("menu_composition_disabled", {"fps": snappedf(fps, 0.1), "refresh": refresh})
		shutdown("watchdog_fps")
		return
	_watch_time = 0.0; _watch_frames = 0

## Debug comparison: pauses the layers and restores the eye-buffer menu without freeing them.
func set_active(on: bool) -> void:
	if not enabled or not is_instance_valid(eye_camera): return
	if on:
		eye_camera.cull_mask = eye_mask & ~GROUP_MASK
		active = null; set_process(true); invalidate()
	else:
		_restore(); _hide(); active = null
		set_process(false); eye_camera.cull_mask = eye_mask
		fallback_reason = "debug_paused"

## Returns to the original eye-buffer menu for the rest of the session.
func shutdown(reason: String) -> void:
	# Layers stay allocated (sub-pixel, not rendering): freeing them is the unsafe path above.
	_restore(); _hide()
	enabled = false; set_process(false)
	if is_instance_valid(eye_camera): eye_camera.cull_mask = eye_mask
	fallback_reason = reason

func update() -> void:
	if not enabled: return
	if not force_capture and (not xr.is_initialized() or not api.is_running()):
		_restore(); _hide(); fallback_reason = "session_not_running"; return
	var wanted: Node3D
	for menu in menus:
		if menu.is_visible_in_tree(): wanted = menu; break
	if wanted != active:
		_restore(); _hide(); active = wanted
		# Reopening the same menu keeps its slots and swapchain sizes.
		if active and active != _last_menu:
			for slot in slots: slot.key = ""; slot.rect = Rect2()
			_last_menu = active
		invalidate()
	if not active:
		return
	if geometry_dirty:
		_collect(); geometry_dirty = false; dirty = true
	var now := Time.get_ticks_msec()
	if now - _painted_ms >= KEEPALIVE_MS: dirty = true
	if dirty:
		for slot in slots:
			if slot.used: _measure(slot)
		dirty = false; _painted_ms = now; repaints += 1
	var root := _root_pose()
	var any := false
	for slot in slots:
		_place(slot, root)
		any = any or slot.used
	if display: display.set_menu_layers(any and not force_capture)
	fallback_reason = "" if any else "no_planar_surfaces"

func _root_pose() -> Transform3D:
	var pose := active.global_transform
	pose.basis = pose.basis.orthonormalized()
	return pose

## Groups visible menu geometry by plane. Each group keeps its slot (and swapchain size)
## across rebuilds of the same page, so hover tips and page redraws do not reallocate.
func _collect() -> void:
	_restore()
	var root := _root_pose()
	var inverse := root.affine_inverse()
	var items: Array[Dictionary] = []
	_gather(active, items, inverse, false)
	var groups: Array[Dictionary] = []
	items.sort_custom(func(a, b): return a.offset < b.offset)
	for item in items:
		var joined := false
		for group in groups:
			if group.popup == item.popup and group.normal.dot(item.normal) > NORMAL_DOT and item.offset - group.last <= PLANE_GAP:
				group.nodes.append(item); group.last = item.offset
				group.shown += int(item.shown)
				joined = true; break
		if not joined:
			groups.append({"normal": item.normal, "basis": item.basis, "first": item.offset, "last": item.offset,
				"nodes": [item], "popup": item.popup, "shown": int(item.shown)})
	# Visible, larger groups claim slots first; any surplus geometry stays in the eye buffer.
	groups.sort_custom(func(a, b): return a.shown > b.shown or (a.shown == b.shown and a.nodes.size() > b.nodes.size()))
	for group in groups.slice(0, MAX_GROUPS):
		var key := "%d:%d:%d:%d:%d" % [int(group.popup), roundi(group.normal.x * 50), roundi(group.normal.y * 50), roundi(group.normal.z * 50), roundi(group.first / PLANE_GAP)]
		group["key"] = key
	for slot in slots: slot.used = false; slot.nodes = []
	# Slot pixel sizes are fixed, so each surface takes the free slot whose shape fits it best.
	for group in groups.slice(0, MAX_GROUPS):
		for index in SLOT_PREFERENCE[_kind(group, inverse)]:
			var slot: Dictionary = slots[index]
			if slot.used: continue
			if slot.key != group.key: slot.key = group.key; slot.rect = Rect2()
			_assign(slot, group, root); break
	# Back to front: popups over panels, then nearer planes.
	var ordered := slots.filter(func(s): return s.used)
	ordered.sort_custom(func(a, b): return a.rank.x < b.rank.x or (a.rank.x == b.rank.x and a.rank.y < b.rank.y))
	for index in ordered.size():
		ordered[index].layer.sort_order = ORDER_BASE + index
	for slot in slots:
		if not slot.used: _hide_slot(slot)

static func _kind(group: Dictionary, root_inverse: Transform3D) -> String:
	if group.popup: return "popup"
	var frame_inverse := Basis(group.basis).inverse()
	var lo := Vector2(INF, INF); var hi := Vector2(-INF, -INF)
	for item in group.nodes:
		var node: VisualInstance3D = item.node
		if not node.is_visible_in_tree(): continue
		var box := node.get_aabb()
		var to_frame := Transform3D(frame_inverse, Vector3.ZERO) * root_inverse * node.global_transform
		for corner in 8:
			var point: Vector3 = to_frame * box.get_endpoint(corner)
			lo = lo.min(Vector2(point.x, point.y)); hi = hi.max(Vector2(point.x, point.y))
	if not lo.is_finite(): return "panel"
	var size := hi - lo
	return "tall" if size.y > size.x * 1.6 else "panel"

func _assign(slot: Dictionary, group: Dictionary, root: Transform3D) -> void:
	slot.used = true
	var plane := (float(group.first) + float(group.last)) * 0.5
	var basis: Basis = group.basis
	var local_normal: Vector3 = basis.z
	# The plane frame lives in the menu root's space; the menu may move every frame.
	var relative := Transform3D(basis, local_normal * plane)
	if slot.rect.has_area() and not slot.relative.basis.is_equal_approx(basis):
		slot.rect = Rect2()
	slot.relative = relative
	slot.rank = Vector2(int(group.popup), relative.origin.z)
	var bit := 1 << (GROUP_BIT + int(slot.index))
	for item in group.nodes:
		var node: VisualInstance3D = item.node
		originals.append({"node": node, "layers": node.layers})
		node.layers = bit
		slot.nodes.append(node)

func _gather(node: Node, items: Array[Dictionary], inverse: Transform3D, popup: bool) -> void:
	if node.has_meta("menu_pointer") or node.has_meta("menu_eye_buffer"): return
	if node is CanvasItem or node is Viewport: return
	# Hidden rows, tips and popups join their plane now; they may appear without a rebuild.
	if node is VisualInstance3D:
		var local: Transform3D = inverse * node.global_transform
		var basis := local.basis.orthonormalized()
		var normal := basis.z
		popup = popup or _priority(node) >= POPUP_PRIORITY
		items.append({"node": node, "normal": normal, "basis": basis, "offset": normal.dot(local.origin), "popup": popup,
			"shown": node.is_visible_in_tree()})
	for child in node.get_children(): _gather(child, items, inverse, popup)

static func _priority(node: VisualInstance3D) -> int:
	if node is Label3D: return node.render_priority
	if node is GeometryInstance3D and node.material_override: return node.material_override.render_priority
	return 0

## Grow-only bounds in the plane frame, snapped to a grid; pixel sizes stay stable.
func _measure(slot: Dictionary) -> void:
	var root_inverse := _root_pose().affine_inverse()
	var frame_inverse: Transform3D = slot.relative.affine_inverse()
	var lo := Vector2(INF, INF); var hi := Vector2(-INF, -INF)
	for node: VisualInstance3D in slot.nodes:
		if not is_instance_valid(node) or not node.is_visible_in_tree(): continue
		var box := node.get_aabb()
		if box.size.x <= 0 and box.size.y <= 0: continue
		var to_frame: Transform3D = frame_inverse * root_inverse * node.global_transform
		for corner in 8:
			var point: Vector3 = to_frame * box.get_endpoint(corner)
			lo = lo.min(Vector2(point.x, point.y)); hi = hi.max(Vector2(point.x, point.y))
	if not lo.is_finite(): return
	lo = ((lo - Vector2.ONE * MARGIN) / GRID).floor() * GRID
	hi = ((hi + Vector2.ONE * MARGIN) / GRID).ceil() * GRID
	var rect := Rect2(lo, hi - lo)
	var previous: Rect2 = slot.rect
	slot.rect = rect if not previous.has_area() else previous.merge(rect)
	slot.raw.render_target_update_mode = SubViewport.UPDATE_ONCE
	slot.submit.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	slot.tail = 2

func _place(slot: Dictionary, root: Transform3D) -> void:
	if not slot.used or not slot.rect.has_area():
		_hide_slot(slot); return
	var rect: Rect2 = slot.rect
	# The pixel grid is rounded up; widen the captured rectangle to the exact pixel aspect.
	var pixels: Vector2 = Vector2(slot.raw.size)
	var size := rect.size
	if size.x / size.y < pixels.x / pixels.y: size.x = size.y * pixels.x / pixels.y
	else: size.y = size.x * pixels.y / pixels.x
	var pose: Transform3D = root * slot.relative * Transform3D(Basis.IDENTITY, Vector3(rect.get_center().x, rect.get_center().y, 0))
	var camera: Camera3D = slot.camera
	camera.size = size.y
	camera.global_transform = pose * Transform3D(Basis.IDENTITY, Vector3(0, 0, 0.25))
	slot.layer.quad_size = size
	slot.layer.global_transform = pose
	slot.hole.mesh.size = size
	slot.hole.global_transform = pose
	slot.hole.visible = true
	if slot.tail > 0:
		slot.tail -= 1
		if slot.tail == 0:
			slot.raw.render_target_update_mode = SubViewport.UPDATE_DISABLED
			slot.submit.render_target_update_mode = SubViewport.UPDATE_DISABLED

func _restore() -> void:
	for item in originals:
		if is_instance_valid(item.node): item.node.layers = item.layers
	originals.clear()

func _hide_slot(slot: Dictionary) -> void:
	slot.layer.quad_size = HIDDEN_SIZE
	slot.hole.visible = false
	slot.raw.render_target_update_mode = SubViewport.UPDATE_DISABLED
	slot.submit.render_target_update_mode = SubViewport.UPDATE_DISABLED
	slot.tail = 0

func _hide() -> void:
	for slot in slots:
		slot.used = false; slot.nodes = []
		_hide_slot(slot)
	if display: display.set_menu_layers(false)

func snapshot() -> Dictionary:
	var sizes := []
	for slot in slots:
		if slot.used: sizes.append([slot.raw.size.x, slot.raw.size.y])
	return {"enabled": enabled, "active": not sizes.is_empty(), "native": enabled and not force_capture,
		"fallback": fallback_reason, "layers": sizes.size(), "pixels": sizes,
		"repaints": repaints}

func _exit_tree() -> void:
	_restore()
	if enabled and is_instance_valid(eye_camera): eye_camera.cull_mask = eye_mask
	for slot in slots:
		if is_instance_valid(slot.layer): slot.layer.queue_free()
		if is_instance_valid(slot.hole): slot.hole.queue_free()
	if display: display.set_menu_layers(false)
