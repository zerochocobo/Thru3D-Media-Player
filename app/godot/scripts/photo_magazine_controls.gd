extends "res://scripts/ray_menu.gd"

## All full photos share one attached control region and the existing XR quad pool.
const OPERATIONS := ["magazine_previous", "magazine_next", "magazine_single"]
const PREVIOUS_IMAGE := 3
const ROTATE_IMAGE := 4
const NEXT_IMAGE := 5
const RETURN_TO_WALL := 6
const ENTER_MS := 120
const LEAVE_MS := 650
const ROW_GAP := 0.20
var app: Node3D
var _state_key: Array = []
var _single := false
var _magazine := false
var _return := false
var _flat_photo := true
var _enabled: Array[bool] = [false, false, false, false, false, false, false]
var _photo_scale := 0.0
var _entered_ms := -1
var _last_near_ms := -1
var _panorama_key := ""
var _panorama_pose := Transform3D.IDENTITY

func setup(host: Node3D) -> void:
	app = host
	process_priority = 90 # after photo movement, before MenuComposition (100)
	refresh()
	dismiss()

func composition_root() -> Node3D: return self
func has_pointer_capture() -> bool: return false
func release_pointer(_hand: String, _origin: Vector3, _direction: Vector3, _tracked: bool) -> void: pass
func grab_hit(_origin: Vector3, _direction: Vector3) -> Dictionary: return {}
func _place_device_status(_centre: Vector2) -> void: pass

func eligible() -> bool:
	if not is_instance_valid(app): return false
	if app.get("scenery_menu") and app.scenery_menu.visible: return false
	var photo: Node3D = app.photo
	return app.photo_active and photo.index >= 0 and photo.panel.visible and not photo.gallery.overview() \
		and not photo.gallery.returning and not photo.inspect and app._input_focused() and not app._background_app_paused \
		and not app.photo_menu.visible and not app.recent_menu.visible and not app.music_menu.visible \
		and not (app.puzzle_game and app.puzzle_game.active)

func sync(now: int = -1) -> void:
	if not is_instance_valid(app): return
	var photo: Node3D = app.photo
	if not eligible():
		dismiss(); _entered_ms = -1; _last_near_ms = -1
		return
	_magazine = photo.magazine.active()
	_return = photo.gallery.mode in [2, 3] and photo.gallery.focus >= 0
	_flat_photo = photo.geometry == 0
	var factor: float = photo.screen_scale if _flat_photo else 1.0
	if _flat_photo:
		_panorama_key = ""
		# Content rolls about its centre; the row stays upright in the user's placement plane.
		var pose: Transform3D = photo.global_transform * photo.flat_pose
		var bottom := 0.0
		for corner in 4:
			bottom = minf(bottom, (pose.affine_inverse() * photo.panel.to_global(photo.screen_corner(corner))).y)
		global_transform = pose * Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * factor), Vector3(0, bottom - 0.13 * factor, 0.025 * factor))
	else:
		# Spherical photos have no bottom edge. Capture a stable, comfortable control plane.
		var key := str([photo.local_uri, photo.geometry])
		if key != _panorama_key:
			_panorama_key = key
			_panorama_pose = app.xr_camera.global_transform * Transform3D(Basis.IDENTITY, Vector3(0, -0.45, -1.5))
		global_transform = _panorama_pose
	ray_max_distance = maxf(MAX_RAY_METRES, global_position.distance_to(app.xr_camera.global_position) + 2.0 * factor)
	if not is_equal_approx(factor, _photo_scale):
		_photo_scale = factor
		composition_layout_changed.emit()
	# Input routing calls sync several times a frame; do not poll native status via snapshot().
	var busy: bool = photo.loading or photo._presentation_pending or photo._transition_active or _moving_image() \
		or photo.gallery._swap_phase != 0 or (photo._directory_reorder and photo.directory.loading)
	var position: int = photo.pending_index if photo.pending_index >= 0 else photo.index
	var loop: bool = (_flat_photo or photo.gallery.mode != 0) and photo.queue_complete
	var can_previous: bool = position > 0 if _magazine else photo.queue.size() > 1 and (loop or position > 0)
	var can_next: bool = position >= 0 and photo.magazine.target(1) < photo.queue.size() if _magazine \
		else photo.queue.size() > 1 and (loop or (position >= 0 and position + 1 < photo.queue.size()))
	var key: Array = [photo.index, photo.queue.size(), busy, photo.magazine.single(photo.index), I18n.language,
		_magazine, _return, _flat_photo, can_previous, can_next, photo.gallery.mode]
	if key != _state_key:
		_state_key = key
		_single = key[3]
		_enabled = [not busy and photo.index > 0, not busy and photo.index + 1 < photo.queue.size(), not busy,
			not busy and can_previous, not busy and _flat_photo, not busy and can_next, not _moving_image()]
		refresh()
	if now < 0: now = Time.get_ticks_msec()
	var near := false
	for ray in _rays():
		if _near_photo_or_controls(ray[0], ray[1]): near = true; break
	if near:
		_last_near_ms = now
		if _entered_ms < 0: _entered_ms = now
		if now - _entered_ms >= ENTER_MS: visible = true
	else:
		_entered_ms = -1
		if _last_near_ms < 0 or now - _last_near_ms >= LEAVE_MS: dismiss()

func _rays() -> Array:
	var result := []
	for hand in ["left_hand", "right_hand"]:
		var ray: Variant = app._ray(hand)
		if ray != null: result.append(ray)
	if app.display.preview:
		var mouse: Vector2 = app.get_viewport().get_mouse_position()
		result.append([app.xr_camera.project_ray_origin(mouse), app.xr_camera.project_ray_normal(mouse)])
	return result

func _near_photo_or_controls(origin: Vector3, direction: Vector3) -> bool:
	if not origin.is_finite() or not direction.is_finite() or direction.length_squared() < 0.000001: return false
	var photo: Node3D = app.photo
	if _flat_photo:
		var local_origin: Vector3 = photo.panel.to_local(origin)
		if local_origin.z > 0 and photo.screen_hit(origin, direction) != null: return true
	else:
		var start: Vector3 = photo.panel.to_local(origin)
		var ray: Vector3 = (photo.panel.global_basis.inverse() * direction).normalized()
		var b: float = start.dot(ray)
		var discriminant: float = b * b - start.length_squared() + photo.SPHERE_RADIUS * photo.SPHERE_RADIUS
		if discriminant >= 0:
			var distance: float = -b + sqrt(discriminant)
			var hit: Vector3 = start + ray * distance
			if distance > 0 and (photo.geometry == 3 or (photo.geometry == 1 and hit.z <= 0) \
				or (photo.geometry == 2 and hit.angle_to(Vector3.FORWARD) <= deg_to_rad(photo.fisheye_fov * 0.5))): return true
	# Independent wake region: hidden RayMenu buttons deliberately cannot be hit.
	var inverse := global_transform.affine_inverse()
	var start: Vector3 = inverse * origin
	var ray: Vector3 = inverse.basis * direction
	if ray.z >= -0.00001 or start.z <= 0: return false
	var point: Vector3 = start + ray * (-start.z / ray.z)
	var region := Rect2(Vector2(-0.36, -0.40 if _magazine else -0.20), Vector2(0.76 if _return else 0.72, 0.56 if _magazine else 0.36))
	if region.has_point(Vector2(point.x, point.y)): return true
	if visible and _tooltip and _tooltip.visible:
		var tip: Vector3 = _tooltip.to_local(global_transform * point)
		if absf(tip.x) <= _tooltip.mesh.size.x * 0.5 + 0.04 and absf(tip.y) <= _tooltip.mesh.size.y * 0.5 + 0.04: return true
	return false

func puzzle_pose() -> Transform3D:
	# Reserve tooltip room even before hover, so the puzzle target never jumps under a ray.
	return global_transform * Transform3D(Basis.IDENTITY, Vector3(0, -0.50 if _magazine else -0.30, 0))

func _process(_delta: float) -> void:
	sync()
	if not visible: return
	for hand in ["left_hand", "right_hand"]:
		var ray: Variant = app._ray(hand)
		if ray != null and owns_ray(ray[0], ray[1]): update_pointer(hand, ray[0], ray[1], true)
		else: cancel_pointer(hand)

func _moving_image() -> bool:
	return not app._grab.is_empty() or not app.interface_move.capture.is_empty() or not app.photo_hands.owners.is_empty() or app.photo.gallery.has_capture()

func owns_ray(origin: Vector3, direction: Vector3) -> bool:
	if _moving_image() or (app.photo_menu.visible and app.photo_menu.has_pointer_capture()): return false
	var hit := ray_hit(origin, direction)
	if hit.is_empty(): return false
	var other: Dictionary = app.photo_menu.pointer_hit(origin, direction) if app.photo_menu.visible else {}
	return other.is_empty() or float(hit.distance) < float(other.distance)

## Only a ray over a button reserves menu input; the rest of the image keeps its gestures.
func input_menu() -> Node3D:
	sync()
	if not visible: return null
	for hand in ["left_hand", "right_hand"]:
		var ray: Variant = app._ray(hand)
		if ray != null and owns_ray(ray[0], ray[1]): return self
	if app.display.preview:
		var mouse: Vector2 = app.get_viewport().get_mouse_position()
		if owns_ray(app.xr_camera.project_ray_origin(mouse), app.xr_camera.project_ray_normal(mouse)): return self
	return null

func press_pointer(hand: String, origin: Vector3, direction: Vector3, tracked: bool) -> bool:
	if not tracked or not eligible() or not owns_ray(origin, direction): return false
	var handled := super.press_pointer(hand, origin, direction, tracked)
	if handled and hand in ["left_hand", "right_hand"]:
		app._controller_consumed[hand + "/trigger_click"] = true
	return handled

func _draw() -> void:
	_clear_layout(); _set_backdrop(Vector2.ONE * 0.001); _backdrop.visible = false
	var shift := -0.075 if _return else 0.0
	_action(PREVIOUS_IMAGE, "previous", Vector2(shift - 0.15, 0), "Previous image")
	if _flat_photo: _action(ROTATE_IMAGE, "photo_rotate", Vector2(shift, 0), "Rotate clockwise")
	_action(NEXT_IMAGE, "next", Vector2(shift + 0.15, 0), "Next image")
	if _return: _action(RETURN_TO_WALL, "up", Vector2(0.275, 0), "Back to photo wall" if app.photo.gallery.mode == 2 else "Back to memory wall")
	if not _magazine: return
	var icons := ["pair_previous", "pair_next", "magazine" if _single else "single_page"]
	var tips := ["Shift pairing back by one image", "Shift pairing forward by one image", "Two pages" if _single else "Show this image alone; continue with pairs on the next turn"]
	for i in 3:
		_action(i, icons[i], Vector2((i - 1) * 0.15, -ROW_GAP), tips[i], i == 2 and _single)

func _action(target: int, icon: String, point: Vector2, tip: String, selected: bool = false) -> void:
	_round(target, icon, point, 0.12, _enabled[target], selected, I18n.t(tip))
	_buttons.back()["hover_disabled"] = true
	_buttons.back()["tip_below"] = true

func _update_tooltip() -> void:
	super._update_tooltip()
	if _tooltip and _tooltip.visible:
		_tooltip.position.y = (-ROW_GAP if _magazine else 0.0) - 0.077 - _tooltip.mesh.size.y * 0.5

func _icon(key: String, location: Vector3, size: float, color: Color, parent: Node = self) -> MeshInstance3D:
	var glyph := super._icon(key, location, size * 1.2, color, parent)
	glyph.material_override.albedo_texture = Icons.texture(key, 256)
	return glyph

func _activate(target: int) -> void:
	if target < 0 or target >= _enabled.size() or not _enabled[target]: return
	if target < 3: app._on_photo_action(OPERATIONS[target])
	else:
		app._on_photo_action({PREVIOUS_IMAGE: "photo_previous", ROTATE_IMAGE: "photo_rotate",
			NEXT_IMAGE: "photo_next", RETURN_TO_WALL: "photo_return_to_wall"}[target])
	sync()
