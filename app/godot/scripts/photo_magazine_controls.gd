extends "res://scripts/ray_menu.gd"

## Photo-attached controls share RayMenu input, typography and the existing XR quad pool.
const OPERATIONS := ["magazine_previous", "magazine_next", "magazine_single"]
var app: Node3D
var _state_key: Array = []
var _single := false
var _enabled: Array[bool] = [false, false, false]
var _photo_scale := 0.0

func setup(host: Node3D) -> void:
	app = host
	process_priority = 90 # after photo movement, before MenuComposition (100)
	refresh()

func composition_root() -> Node3D: return self
func has_pointer_capture() -> bool: return false
func release_pointer(_hand: String, _origin: Vector3, _direction: Vector3, _tracked: bool) -> void: pass
func grab_hit(_origin: Vector3, _direction: Vector3) -> Dictionary: return {}
func _place_device_status(_centre: Vector2) -> void: pass

func sync() -> void:
	if not is_instance_valid(app): return
	var photo: Node3D = app.photo
	var show: bool = app.photo_active and photo.magazine.active() and photo.index >= 0 \
		and photo.panel.visible and not photo.inspect and app._input_focused() and not app._background_app_paused \
		and not app.recent_menu.visible and not app.music_menu.visible and not (app.puzzle_game and app.puzzle_game.active)
	if not show:
		if visible: dismiss()
		return
	# Everything, including the gap and tooltip, uses the picture's scale and plane.
	# Distance changes only its world pose: there is no head-locked/fixed-angular-size fallback.
	var factor: float = photo.screen_scale
	var offset := Vector3(0, -photo._flat.size.y * 0.5 - 0.13 * factor, 0.025 * factor)
	global_transform = photo.panel.global_transform * Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * factor), offset)
	ray_max_distance = maxf(MAX_RAY_METRES, global_position.distance_to(app.xr_camera.global_position) + 2.0 * factor)
	if not is_equal_approx(factor, _photo_scale):
		_photo_scale = factor
		composition_layout_changed.emit()
	var busy: bool = photo.loading or _moving_image()
	var key: Array = [photo.index, photo.queue.size(), busy, photo.magazine.single(photo.index), I18n.language]
	if key != _state_key:
		_state_key = key
		_single = key[3]
		_enabled = [not busy and photo.index > 0, not busy and photo.index + 1 < photo.queue.size(), not busy]
		refresh()
	visible = true

func _process(_delta: float) -> void:
	sync()
	if not visible: return
	for hand in ["left_hand", "right_hand"]:
		var ray: Variant = app._ray(hand)
		if ray != null and owns_ray(ray[0], ray[1]): update_pointer(hand, ray[0], ray[1], true)
		else: cancel_pointer(hand)

func _moving_image() -> bool:
	return not app._grab.is_empty() or not app.interface_move.capture.is_empty() or not app.photo_hands.owners.is_empty()

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

func _draw() -> void:
	_clear_layout(); _set_backdrop(Vector2.ONE * 0.001); _backdrop.visible = false
	var icons := ["pair_previous", "pair_next", "magazine" if _single else "single_page"]
	var tips := ["Shift pairing back by one image", "Shift pairing forward by one image", "Two pages" if _single else "Show this image alone; continue with pairs on the next turn"]
	for i in 3:
		_round(i, icons[i], Vector2((i - 1) * 0.15, 0), 0.12, _enabled[i], i == 2 and _single, I18n.t(tips[i]))
		_buttons.back()["hover_disabled"] = true
		_buttons.back()["tip_below"] = true

func _icon(key: String, location: Vector3, size: float, color: Color, parent: Node = self) -> MeshInstance3D:
	var glyph := super._icon(key, location, size * 1.2, color, parent)
	glyph.material_override.albedo_texture = Icons.texture(key, 256)
	return glyph

func _activate(target: int) -> void:
	if target >= 0 and target < 3 and _enabled[target]:
		app._on_photo_action(OPERATIONS[target])
		sync()
