extends RefCounted
## Video slots share the main frame's lease, without extra video decoders or readback.
## Optional still images use one bounded, asynchronous loader and retain their texture.
signal changed
signal zoom_changed(slot: int, zoom: float)
signal window_opened(window: Node3D)
signal image_requested(window: Node3D)
signal container_opened(entry: Dictionary)
var images: Node
const PipWindow := preload("res://scripts/video_pip_window.gd")
const Move := preload("res://scripts/interface_move.gd")
var owner: Node3D
var windows := {}
var _stack: Array[int] = []
var preferences := {1: 1.0, 2: 1.0, 3: 1.0}
var anchor: Variant
var selecting := 0
var selection_hand := ""
var candidate := {}
var resize := {}
var movement := Move.new()
var reopening := false
var _format := []
var _outline: MeshInstance3D
var compositor := preload("res://scripts/video_pip_compositor.gd").new(self)

func _init(video: Node3D) -> void:
	owner = video

func video_windows() -> Array:
	return windows.values().filter(func(window): return not window.image_mode)

func load_image(window: Node3D, uri: String, document: Dictionary = {}) -> void:
	if not is_instance_valid(window) or windows.get(window.slot) != window: return
	cancel_interaction()
	if not is_instance_valid(images):
		images = preload("res://scripts/video_pip_images.gd").new()
		images.platform = owner.platform
		images.container_opened.connect(func(entry): container_opened.emit(entry))
		owner.add_child(images)
	images.load_window(window, uri, document)

func active() -> bool:
	return not windows.is_empty()

func close_protected_documents(store: RefCounted) -> void:
	for window in windows.values().duplicate():
		var documents: Array = [window.pdf_document]
		if is_instance_valid(images):
			for job in images.waiting + [images.active]:
				if not job.is_empty() and job.window.get_ref() == window: documents.append(job.get("document", {}))
		if documents.any(func(doc): return not doc.is_empty() and store.has_container_record(str(doc.get("source", {}).get("uri", "")))): close(window.slot)

func identify(slots: Array) -> void:
	for slot in windows: windows[slot].set_identified(slots.has(slot))

func focus(slot: int) -> void:
	if windows.has(slot): _raise(slot)

func blocked() -> bool:
	return selecting > 0 or not resize.is_empty() or not movement.capture.is_empty() or windows.values().any(func(window): return window.zoom_open or window.shape_open)

func capturing() -> bool:
	return not resize.is_empty() or not movement.capture.is_empty()

func load_settings(settings: ConfigFile) -> void:
	for slot in preferences:
		var value: Variant = settings.get_value("pip", "zoom_%d" % slot, 1.0)
		preferences[slot] = clampf(float(value), 1.0, 8.0) if (value is float or value is int) and is_finite(float(value)) else 1.0

func set_count(count: int, head: Transform3D) -> void:
	count = clampi(count, 0, 3)
	if count == windows.size(): return
	for slot in [3, 2, 1]:
		if windows.size() > count and windows.has(slot): close(slot)
	for slot in [1, 2, 3]:
		if windows.size() >= count: break
		if not windows.has(slot): _open(slot, head)
	changed.emit()

func toggle_slot(slot: int, head: Transform3D) -> void:
	if slot < 1 or slot > 3: return
	if windows.has(slot): close(slot)
	else: _open(slot, head); changed.emit()

static func level_head(head: Transform3D) -> Transform3D:
	var forward := -head.basis.z
	forward.y = 0
	if forward.length_squared() < 0.001: forward = Vector3.FORWARD
	return Transform3D(Basis.looking_at(forward.normalized(), Vector3.UP), head.origin)

func _open(slot: int, head: Transform3D) -> void:
	if anchor == null: anchor = level_head(head)
	var window := PipWindow.new()
	window.slot = slot; window.zoom = preferences[slot]
	window.source_aspect = _aspect()
	window.panorama = owner.geometry != 0
	if not window.panorama:
		var aspect := _aspect()
		var width := minf(0.48, 0.6 * aspect)
		window.size = Vector2(width, width / aspect)
	owner.add_child(window)
	var offset: Vector3 = [Vector3(0, 0.18, -1.36), Vector3(-0.95, 0.05, -1.16), Vector3(0.95, 0.05, -1.16)][slot - 1] if window.panorama \
		else [Vector3(0.75, 0.47, -1.21), Vector3(-0.75, 0.47, -1.21), Vector3(0, 0.75, -1.30)][slot - 1]
	# Panoramic slots share a fixed group layout. A newly opened flat window uses
	# the current viewer, even if another window keeps an older group anchor alive.
	var placement: Transform3D = anchor if window.panorama else level_head(head)
	window.global_transform = placement * Transform3D(Basis.looking_at(offset.normalized()), offset.normalized() * 1.5)
	window.crop_basis = _default_basis()
	window.requested.connect(_action)
	windows[slot] = window
	_raise(slot)
	if windows.size() == 1: _format = _format_key()
	window.crop_parameters()
	window_opened.emit(window)

func _aspect() -> float:
	return 16.0 / 9.0 if owner.geometry != 0 else maxf(0.05, owner._flat.size.x / maxf(0.001, owner._flat.size.y))

func _format_key() -> Array:
	# Main-screen physical resizing never changes this per-eye aspect/format key.
	return [owner.geometry, owner.stereo_sbs, owner.top_bottom, owner.stereo_half, roundi(_aspect() * 10000)]

func _default_basis() -> Basis:
	var head: Transform3D = anchor if anchor is Transform3D else Transform3D.IDENTITY
	var direction: Vector3 = owner.panel.global_basis.inverse() * -head.basis.z
	return view_basis(direction)

static func view_basis(direction: Vector3) -> Basis:
	var forward := direction.normalized()
	var up := Vector3.FORWARD if absf(forward.dot(Vector3.UP)) > 0.999 else Vector3.UP
	return Basis.looking_at(forward, up)

func close(slot: int) -> void:
	if not windows.has(slot): return
	# Capture never outlives its slot (even if the slot number is reused immediately).
	cancel_interaction()
	var window: Node3D = windows[slot]
	owner._binding.unshare(window.picture)
	if is_instance_valid(images): images.cancel(window); images.unload(window)
	windows.erase(slot)
	_stack.erase(slot); _restack()
	window.queue_free(); window.visible = false
	if windows.is_empty():
		anchor = null; compositor.release()
	changed.emit()

func clear() -> void:
	for slot in windows.keys(): close(slot)
	cancel_interaction()
	_format.clear()

func cancel_interaction() -> bool:
	var was := blocked()
	selecting = 0; selection_hand = ""; candidate.clear(); resize.clear(); movement.cancel()
	if _outline: _outline.visible = false
	for window in windows.values():
		window.set_resize_feedback({}, true)
		window.cancel_pointer("left_hand"); window.cancel_pointer("right_hand")
		if window.selecting or window.zoom_open or window.shape_open:
			window.selecting = false; window.zoom_open = false; window.shape_open = false; window.refresh()
	return was

func cancel_pointer(hand: String) -> void:
	if resize.get("hand", "") == hand: resize.clear()
	if movement.capture.get("hand", "") == hand: movement.cancel()
	if selection_hand == hand:
		candidate.clear()
		if _outline: _outline.visible = false
	for window in windows.values(): window.cancel_pointer(hand)
	_update_resize_feedback()

func _action(slot: int, operation: String, value: float) -> void:
	if not windows.has(slot): return
	if windows[slot].image_mode and operation in ["zoom", "select", "shape", "view"]: return
	match operation:
		"page":
			if is_instance_valid(images): images.turn_page(windows[slot], int(value))
		"image": cancel_interaction(); image_requested.emit(windows[slot])
		"video":
			if is_instance_valid(images): images.cancel(windows[slot]); images.unload(windows[slot])
			windows[slot].restore_video(); changed.emit()
		"close": close(slot)
		"zoom":
			if not is_finite(value): return
			preferences[slot] = clampf(value, 1.0, 8.0)
			windows[slot].zoom = preferences[slot]
			windows[slot].crop_parameters(); windows[slot].refresh()
			zoom_changed.emit(slot, preferences[slot]); changed.emit()
		"select":
			var previous := selecting
			cancel_interaction()
			if previous != slot:
				selecting = slot; windows[slot].selecting = true; windows[slot].refresh()
		"shape", "view": changed.emit()

func hit(origin: Vector3, direction: Vector3) -> Dictionary:
	var best := {}
	for slot in _stack:
		var value: Dictionary = windows[slot].window_hit(origin, direction)
		if not value.is_empty():
			best = value; best["slot"] = slot
	return best

func _restack() -> void:
	for i in _stack.size(): windows[_stack[i]].set_draw_order(i)

func _raise(slot: int) -> void:
	if not _stack.is_empty() and _stack.back() == slot: return
	_stack.erase(slot); _stack.append(slot); _restack()

func press(hand: String, action: String, ray: Variant, pose: Variant, head: Variant, hand_pointer: bool = false) -> bool:
	if not active(): return false
	if action in ["by_button", "menu_button"]: return cancel_interaction()
	if action not in ["trigger_click", "grip_click"] or ray == null: return false
	if not resize.is_empty() or not movement.capture.is_empty(): return true
	var target := hit(ray[0], ray[1])
	if not target.is_empty(): _raise(target.slot)
	if action == "trigger_click":
		# Actual local controls outrank selection; body clicks during selection commit the source only.
		if not target.is_empty():
			var window: Node3D = windows[target.slot]
			if window.press_pointer(hand, ray[0], ray[1], true):
				if selecting > 0: selection_hand = hand
				return true
		if selecting > 0:
			var chosen := source_hit(ray[0], ray[1])
			if not chosen.is_empty():
				windows[selecting].crop_center = chosen.get("center", Vector2(0.5, 0.5))
				windows[selecting].crop_basis = chosen.get("basis", Basis.IDENTITY)
				cancel_interaction()
			return true
		if not target.is_empty() and (target.corner >= 0 or target.edge >= 0):
			var window: Node3D = windows[target.slot]
			resize = {"slot": target.slot, "hand": hand, "corner": target.corner,
				"edge": target.edge, "pose": window.global_transform, "size": window.size, "point": Vector2(target.point.x, target.point.y)}
			_update_resize_feedback()
			return true
		for window in windows.values():
			if window.zoom_open or window.shape_open:
				window.zoom_open = false; window.shape_open = false; window.refresh(); return true
		# Optical hands have a pinch but no separate grip. Only a body pinch falls
		# through to movement; buttons, crop selection and resize keep priority.
		if not hand_pointer or target.is_empty() or not target.body: return not target.is_empty()
	if selecting > 0: return true
	if not target.is_empty() and target.body and pose is Transform3D and head is Transform3D:
		var window: Node3D = windows[target.slot]
		window.global_basis = Move.face_viewer(window.global_position, head)
		var point: Variant = window.plane_point(ray[0], ray[1])
		var anchor_point: Vector3 = window.to_global(point) if point is Vector3 else window.global_position
		return movement.begin(hand, action, pose, [{"node": window, "kind": "detail", "pose": window.global_transform,
			"key": "pip_%d" % target.slot, "upright_facing": true}], anchor_point, head)
	return false

func release(hand: String, action: String) -> bool:
	if action == "trigger_click" and resize.get("hand", "") == hand:
		resize.clear(); _update_resize_feedback(); return true
	if movement.capture.get("hand", "") == hand and movement.capture.get("input", "") == action:
		movement.cancel(); return true
	return false

func adjust_distance(hand: String, stick: Vector2, delta: float, pose: Variant, head: Variant) -> bool:
	if movement.capture.get("hand", "") != hand or not pose is Transform3D or not head is Transform3D: return false
	if not movement.adjust_distance(stick, delta): return false
	return movement.update(pose, head, null)

func update_input(rays: Dictionary, poses: Dictionary, head: Variant, now: int) -> void:
	if not active(): return
	if not movement.capture.is_empty():
		var pose: Variant = poses.get(movement.capture.hand)
		if pose is Transform3D and head is Transform3D: movement.update(pose, head, null)
		else: movement.cancel()
	if not resize.is_empty():
		var ray: Variant = rays.get(resize.hand)
		if ray == null: resize.clear()
		else: _resize_to(ray[0], ray[1])
	_update_resize_feedback()
	var hovered := {}
	for hand in ["left_hand", "right_hand"]:
		var ray: Variant = rays.get(hand)
		var target := hit(ray[0], ray[1]) if ray != null else {}
		if not target.is_empty(): hovered[target.slot] = true
		for slot in windows:
			windows[slot].update_pointer(hand, ray[0] if ray != null else Vector3.ZERO, ray[1] if ray != null else Vector3.ZERO, ray != null and target.get("slot", 0) == slot)
		if selecting > 0 and (selection_hand.is_empty() or selection_hand == hand) and ray != null:
			selection_hand = hand
			candidate = source_hit(ray[0], ray[1]) if target.is_empty() else {}
			_draw_selection()
			if target.is_empty(): windows[selecting].update_move_pointer(hand, ray[0], candidate.get("point", ray[0] + ray[1] * 3), true)
	if selecting > 0 and rays.get(selection_hand) == null:
		candidate.clear()
		if _outline: _outline.visible = false
	for slot in windows: windows[slot].hover(hovered.has(slot), now)

func _update_resize_feedback() -> void:
	var available := selecting == 0 and resize.is_empty() and movement.capture.is_empty()
	for slot in windows:
		windows[slot].set_resize_feedback(resize if resize.get("slot", 0) == slot else {}, available)

func _resize_to(origin: Vector3, direction: Vector3) -> void:
	var initial: Transform3D = resize.pose
	var inverse := initial.affine_inverse()
	var start := inverse * origin
	var ray := inverse.basis * direction
	if absf(ray.z) < 0.00001 or -start.z / ray.z <= 0: return
	var point: Vector3 = start + ray * (-start.z / ray.z)
	var size: Vector2 = resize.size
	var window: Node3D = windows[resize.slot]
	if int(resize.get("edge", -1)) >= 0:
		if window.image_mode: return
		var edge := int(resize.edge)
		var axis := 1 if edge < 2 else 0
		var sign_axis := 1.0 if edge in [0, 3] else -1.0
		var next := size
		next[axis] = clampf(size[axis] + (point[axis] - (resize.point as Vector2)[axis]) * sign_axis, 0.18, 1.2)
		if next.is_equal_approx(size): return
		var shift := Vector3.ZERO; shift[axis] = (next[axis] - size[axis]) * sign_axis / 2
		window.custom_shape = true; window.set_size(next)
		window.global_transform = initial * Transform3D(Basis.IDENTITY, shift)
		return
	var sign_xy := Vector2(-1 if int(resize.corner) % 2 == 0 else 1, 1 if int(resize.corner) < 2 else -1)
	var diagonal := size * sign_xy
	var delta := Vector2(point.x, point.y) - (resize.point as Vector2)
	# Bound the long edge for images so portrait images cannot grow arbitrarily tall.
	var extent := maxf(size.x, size.y) if window.image_mode else size.x
	var factor := clampf(1.0 + delta.dot(diagonal) / diagonal.length_squared(), 0.22 / extent, 1.2 / extent)
	window.set_size(size * factor)
	window.global_transform = initial * Transform3D(Basis.IDENTITY, Vector3(diagonal.x, diagonal.y, 0) * (factor - 1.0) / 2)

func source_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	if not owner.panel.visible or not origin.is_finite() or not direction.is_finite() or direction.length_squared() < 0.00001: return {}
	if owner.geometry == 0:
		var world: Variant = owner.screen_hit(origin, direction)
		if world == null: return {}
		var local: Vector3 = owner.panel.to_local(world)
		var x := local.x
		if owner.screen_curve > 0:
			var radius: float = owner._curve_radius()
			x = atan2(local.x, radius - local.z) * radius
		return {"center": Vector2(x / owner._flat.size.x + 0.5, 0.5 - local.y / owner._flat.size.y), "point": world}
	var start: Vector3 = owner.panel.to_local(origin)
	var ray: Vector3 = (owner.panel.global_basis.inverse() * direction).normalized()
	var b := start.dot(ray)
	var discriminant: float = b * b - start.length_squared() + owner.SPHERE_RADIUS * owner.SPHERE_RADIUS
	if discriminant < 0: return {}
	var distance := -b + sqrt(discriminant)
	if distance <= 0: return {}
	var forward := (start + ray * distance).normalized()
	if owner.geometry == 1 and forward.z > 0: return {}
	if owner.geometry == 2 and acos(clampf(-forward.z, -1, 1)) > deg_to_rad(owner.fisheye_fov / 2): return {}
	return {"basis": view_basis(forward), "point": owner.panel.to_global(start + ray * distance)}

func _draw_selection() -> void:
	if not _outline:
		_outline = MeshInstance3D.new()
		_outline.mesh = ImmediateMesh.new()
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = Color(0.54, 0.93, 0.77)
		material.no_depth_test = true; material.render_priority = -1
		_outline.material_override = material
		owner.add_child(_outline)
	_outline.visible = not candidate.is_empty()
	if candidate.is_empty(): return
	var window: Node3D = windows[selecting]
	var mesh: ImmediateMesh = _outline.mesh
	mesh.clear_surfaces(); mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	var points := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), Vector2(0, 0)]
	for edge in 4:
		for step in 17:
			var uv: Vector2 = points[edge].lerp(points[edge + 1], step / 16.0)
			var p: Vector3
			if owner.geometry == 0:
				var span: Vector2 = window.crop_span()
				var center: Vector2 = candidate.center.clamp(span / 2, Vector2.ONE - span / 2)
				uv = center + (uv - Vector2.ONE * 0.5) * span
				p = Vector3((uv.x - 0.5) * owner._flat.size.x, (0.5 - uv.y) * owner._flat.size.y, 0.004)
				if owner.screen_curve > 0:
					var radius: float = owner._curve_radius()
					p = Vector3(sin(p.x / radius) * radius, p.y, (1 - cos(p.x / radius)) * radius + 0.004)
			else:
				var tangent: Vector2 = window.tangent()
				var d: Vector3 = (candidate.basis as Basis) * Vector3((uv.x - 0.5) * 2 * tangent.x, (0.5 - uv.y) * 2 * tangent.y, -1)
				p = d.normalized() * (owner.SPHERE_RADIUS - 0.01)
			mesh.surface_add_vertex(owner.to_local(owner.panel.to_global(p)))
	mesh.surface_end()

func sync() -> void:
	if not active(): return
	var ready: bool = owner.panel.visible and owner._binding.material != null
	if not ready:
		for window in windows.values(): window.frame.visible = window.image_mode; window.set_compositor(false)
		return # A renderer reopen briefly has no format; keep the committed crop until its first frame.
	var format := _format_key()
	if _format != format:
		cancel_interaction(); _format = format
		for window in windows.values():
			window.panorama = owner.geometry != 0
			window.crop_center = Vector2(0.5, 0.5); window.crop_basis = _default_basis()
			if not window.image_mode and not window.custom_shape: window.set_size(Vector2(window.size.x, window.size.x / _aspect()))
	var parameters: Dictionary = owner._binding.shared_parameters() if not owner._binding.layer else {}
	for slot in windows:
		var window: Node3D = windows[slot]
		window.frame.visible = true
		if window.image_mode:
			owner._binding.unshare(window.picture); window.set_compositor(false); continue
		if not owner._binding.layer: owner._binding.share_with(window.picture, parameters)
		window.source_aspect = _aspect()
		window.crop_parameters(candidate if selecting == slot else {})
