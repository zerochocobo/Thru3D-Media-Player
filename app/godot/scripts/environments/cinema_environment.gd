extends Node3D
## Bundled cinema host. Geometry is an imported PackedScene so exported builds
## do not depend on opening the source GLB through FileAccess.

signal changed

const Locomotion := preload("res://scripts/environments/cinema_locomotion.gd")
const Feature := preload("res://scripts/environments/cinema_feature.gd")
const Description := preload("res://scripts/environments/cinema_loader.gd")
const MODEL_PATH := "res://environments/grand_cinema/cinema.glb"
const MANIFEST_PATH := "res://environments/grand_cinema/manifest.json"
const MAX_RAY_DISTANCE := 100.0

var is_ready := false
var loading := false
var error := ""
var interaction := "watch"
var selected := false
var active := false

var _rig: Node3D
var _camera: Camera3D
var _manifest: Dictionary = {}
var _model: Node3D
var _movement: RefCounted
var _thread: Thread
var _requested_model := false
var _presented := true
var _has_original_rig := false
var _original_rig := Transform3D.IDENTITY
var _position_applied := false
var _capture: Dictionary = {}
var _capture_hand := ""
var _pointer_visuals: Dictionary = {}
var _sticks_waiting_for_neutral := true


func _ready() -> void:
	set_process(loading)


func configure(rig: Node3D, camera: Camera3D) -> void:
	if _has_original_rig and is_instance_valid(_rig):
		_rig.global_transform = _original_rig
	_has_original_rig = false
	_position_applied = false
	_rig = rig
	_camera = camera
	_update_active()


func select(enabled: bool) -> void:
	enabled = enabled and Feature.enabled()
	if selected == enabled:
		return
	selected = enabled
	if enabled and not is_ready and not loading:
		_begin_loading()
	if not enabled:
		suspend()
		interaction = "watch"
		if _has_original_rig and is_instance_valid(_rig):
			_rig.global_transform = _original_rig
		_has_original_rig = false
		_position_applied = false
	_update_active()
	changed.emit()


func set_presented(enabled: bool) -> void:
	if _presented == enabled:
		return
	_presented = enabled
	suspend()
	_update_active()
	changed.emit()


func set_interaction(value: String) -> bool:
	if value not in ["watch", "seat", "move"] or not active or not _movement:
		return false
	if interaction == value:
		return true
	suspend()
	if value == "move":
		if not _movement.set_moving(true):
			return false
		_align_head(_movement.eye_position, _movement.yaw)
	else:
		_movement.set_moving(false)
	interaction = value
	changed.emit()
	return true


func home() -> bool:
	if not active or not _movement:
		return false
	if not _movement.select_seat(str(_manifest.get("default_seat", ""))):
		return false
	interaction = "watch"
	suspend()
	_align_head(_movement.eye_position, _movement.yaw)
	changed.emit()
	return true


func poll_sticks(left: Vector2, right: Vector2, delta: float, blocked: bool = false) -> bool:
	if not active or not _movement:
		return false
	if blocked:
		suspend()
		return interaction != "watch"
	if interaction == "watch":
		return false
	if interaction != "move":
		return true
	# Locomotion only consumes right.x for snap turning. The host still owns
	# both full sticks, so right.y must also return to centre before rearming.
	if _sticks_waiting_for_neutral:
		if left.length() <= Locomotion.AXIS_DEADZONE and right.length() <= Locomotion.AXIS_DEADZONE:
			_sticks_waiting_for_neutral = false
			_movement.step(left, right.x, delta)
		return true
	# Real tracking can move the head inside the guardian. Test locomotion from
	# its current X/Z while preserving the navigation floor beneath the avatar.
	var head_position := _camera.global_position
	_movement.eye_position.x = head_position.x
	_movement.eye_position.z = head_position.z
	var previous_eye: Vector3 = _movement.eye_position
	var previous_yaw := _head_yaw()
	_movement.yaw = previous_yaw
	_movement.step(left, right.x, delta)
	var translation: Vector3 = _movement.eye_position - previous_eye
	var turn := wrapf(float(_movement.yaw) - previous_yaw, -PI, PI)
	if not is_zero_approx(turn):
		_rotate_around_head(turn)
	if not translation.is_zero_approx():
		_rig.global_position += translation
	return true


func ray_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	if not active or interaction == "watch" or not origin.is_finite() or not direction.is_finite() or direction.length_squared() < 0.000001:
		return {}
	var ray := direction.normalized()
	var obstruction := _nearest_collider(origin, ray)
	if interaction == "seat":
		var closest: Dictionary = {}
		for seat in _manifest.get("seats", []):
			# The controller can rest inside the user's own seat volume. Ignoring
			# that seat prevents a zero-distance target from swallowing every ray.
			if str(seat.id) == str(_movement.selected_seat):
				continue
			var eye := _vector(seat.eye_position)
			var minimum := eye + Vector3(-0.35, -0.95, -0.35)
			var maximum := eye + Vector3(0.35, 0.20, 0.42)
			var distance := _ray_box(origin, ray, minimum, maximum)
			if distance < 0 or (not closest.is_empty() and distance >= float(closest.distance)):
				continue
			closest = {"kind": "seat", "id": str(seat.id), "label": str(seat.get("label", seat.id)),
				"position": origin + ray * distance, "distance": distance, "valid": true}
		if closest.is_empty():
			return {}
		if not obstruction.is_empty() and float(obstruction.distance) + 0.02 < float(closest.distance):
			# A target seat's own visible cushion/back is a valid selection surface.
			if not str(obstruction.id).begins_with("seat_%s_" % closest.id):
				return {}
		return closest
	var closest: Dictionary = {}
	if absf(ray.y) <= 0.0001:
		return {}
	for area in _manifest.get("walkable", []):
		var distance := (float(area.height) - origin.y) / ray.y
		if distance <= 0.03 or distance > MAX_RAY_DISTANCE or (not closest.is_empty() and distance >= float(closest.distance)):
			continue
		var position := origin + ray * distance
		var minimum := _vector(area.min)
		var maximum := _vector(area.max)
		if position.x < minimum.x or position.x > maximum.x or position.z < minimum.z or position.z > maximum.z:
			continue
		closest = {"kind": "floor", "id": str(area.get("id", "floor")), "label": "",
			"position": position, "distance": distance, "valid": false}
	if closest.is_empty() or (not obstruction.is_empty() and float(obstruction.distance) + 0.02 < float(closest.distance)):
		return {}
	var destination: Vector3 = _movement._standing_at(closest.position, Locomotion.MAX_STEP_HEIGHT)
	if destination.is_finite():
		var source: Vector3 = _movement.eye_position - Vector3.UP * Locomotion.EYE_HEIGHT
		closest.valid = _movement._reachable(source, destination)
	return closest


func pointer_press(hand: String, origin: Vector3, direction: Vector3) -> bool:
	if hand.is_empty() or not _capture_hand.is_empty():
		return false
	var target := ray_hit(origin, direction)
	if target.is_empty() or not target.get("valid", false):
		return false
	_capture_hand = hand
	_capture = target
	return true


func pointer_release(hand: String, origin: Vector3, direction: Vector3, valid: bool) -> bool:
	if _capture_hand != hand or _capture.is_empty():
		return false
	var captured := _capture
	_capture = {}
	_capture_hand = ""
	if not valid:
		return true
	var target := ray_hit(origin, direction)
	if target.is_empty() or not target.get("valid", false) or target.kind != captured.kind or target.id != captured.id:
		return true
	if target.kind == "seat":
		if _movement.select_seat(str(target.id)):
			interaction = "watch"
			suspend()
			_align_head(_movement.eye_position, _movement.yaw)
			changed.emit()
	elif Vector3(target.position).distance_to(captured.position) <= 0.4:
		if _movement.teleport_floor(target.position):
			suspend()
			_align_head(_movement.eye_position, _movement.yaw)
			changed.emit()
	return true


func cancel_pointer(hand: String) -> void:
	hide_pointer(hand)
	if _capture_hand == hand:
		_capture = {}
		_capture_hand = ""


func update_pointer(hand: String, origin: Vector3, direction: Vector3, valid: bool = true) -> void:
	if not valid or hand.is_empty():
		hide_pointer(hand)
		return
	var hit := ray_hit(origin, direction)
	if hit.is_empty() or not hit.get("valid", false):
		hide_pointer(hand)
		return
	var visual := _pointer_visual(hand)
	var pointer: Node3D = visual.root
	var seat_marker: MeshInstance3D = visual.seat
	var floor_ring: MeshInstance3D = visual.floor
	var label: Label3D = visual.label
	var seat_mode: bool = hit.kind == "seat"
	seat_marker.visible = seat_mode
	floor_ring.visible = not seat_mode
	label.visible = seat_mode
	if seat_mode:
		var anchor: Vector3 = hit.position
		for seat in _manifest.seats:
			if str(seat.id) == str(hit.id):
				anchor = _vector(seat.eye_position) + Vector3.UP * 0.30
				break
		pointer.global_position = anchor
		label.text = str(hit.label)
	else:
		pointer.global_position = Vector3(hit.position) + Vector3.UP * 0.025
		label.text = ""
	pointer.visible = true


func hide_pointer(hand: String) -> void:
	if _pointer_visuals.has(hand):
		var pointer: Node3D = _pointer_visuals[hand].root
		pointer.visible = false


func _pointer_visual(hand: String) -> Dictionary:
	if _pointer_visuals.has(hand):
		return _pointer_visuals[hand]
	var pointer := Node3D.new()
	pointer.name = "CinemaPointer_%s" % hand.validate_node_name()
	pointer.visible = false
	add_child(pointer)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.35, 0.95, 0.68)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var seat_marker := MeshInstance3D.new()
	seat_marker.name = "SeatMarker"
	var sphere := SphereMesh.new()
	sphere.radius = 0.06
	sphere.height = 0.12
	sphere.radial_segments = 12
	sphere.rings = 6
	seat_marker.mesh = sphere
	seat_marker.material_override = material
	seat_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pointer.add_child(seat_marker)
	var floor_ring := MeshInstance3D.new()
	floor_ring.name = "FloorRing"
	var ring := TorusMesh.new()
	ring.inner_radius = 0.18
	ring.outer_radius = 0.21
	ring.rings = 24
	ring.ring_segments = 6
	floor_ring.mesh = ring
	floor_ring.material_override = material
	floor_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pointer.add_child(floor_ring)
	var label := Label3D.new()
	label.name = "SeatLabel"
	label.position.y = 0.18
	label.font_size = 36
	label.pixel_size = 0.006
	label.outline_size = 6
	label.modulate = Color(0.75, 1.0, 0.87)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	pointer.add_child(label)
	var visual := {"root": pointer, "seat": seat_marker, "floor": floor_ring, "label": label}
	_pointer_visuals[hand] = visual
	return visual


func suspend() -> void:
	_capture = {}
	_capture_hand = ""
	_sticks_waiting_for_neutral = true
	for hand in _pointer_visuals:
		hide_pointer(str(hand))
	if _movement:
		_movement.suspend()


func snapshot() -> Dictionary:
	return {"ready": is_ready, "loading": loading, "error": error, "selected": selected, "active": active,
		"interaction": interaction, "seat": str(_movement.selected_seat) if _movement else "",
		"screen": _manifest.get("screen", {}).duplicate(true), "capture_hand": _capture_hand,
		"navigation_ms": int(_movement.navigation_prepare_ms) if _movement else 0}


func _begin_loading() -> void:
	if not Feature.enabled(): return
	loading = true
	error = ""
	var file := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if not file:
		_fail("Cinema description unavailable")
		return
	var data: Variant = JSON.parse_string(file.get_as_text())
	var validation := Description.new()._validate_manifest(data)
	if not validation.is_empty():
		_fail(validation)
		return
	_manifest = data
	var status := ResourceLoader.load_threaded_request(MODEL_PATH, "PackedScene")
	if status != OK:
		_fail("Cinema model unavailable (%s)" % error_string(status))
		return
	_requested_model = true
	_thread = Thread.new()
	status = _thread.start(_prepare_movement.bind(_manifest.duplicate(true)))
	if status != OK:
		_thread = null
		_fail("Cinema navigation unavailable (%s)" % error_string(status))
		return
	set_process(true)


func _prepare_movement(manifest: Dictionary) -> RefCounted:
	var movement := Locomotion.new()
	movement.configure(manifest)
	return movement


func _process(_delta: float) -> void:
	if _thread and not _thread.is_alive():
		_movement = _thread.wait_to_finish()
		_thread = null
		if not _movement or not _movement.navigation_ready:
			_fail("Cinema navigation could not be prepared")
	if loading and _requested_model and not is_instance_valid(_model):
		var status := ResourceLoader.load_threaded_get_status(MODEL_PATH)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			var packed := ResourceLoader.load_threaded_get(MODEL_PATH) as PackedScene
			if not packed:
				_fail("Cinema model contains no scene")
				return
			_model = packed.instantiate() as Node3D
			if not _model:
				_fail("Cinema model contains no 3D root")
				return
			_model.name = "GrandCinema"
			_normalize_vertex_materials(_model)
			Description.apply_seat_detail(_model)
			_model.visible = false
			add_child(_model)
		elif status in [ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE]:
			_fail("Cinema model could not be loaded")
	if loading and _model and _movement:
		loading = false
		is_ready = true
		_update_active()
		changed.emit()
	if not loading and not _thread:
		set_process(false)


func _update_active() -> void:
	active = Feature.enabled() and selected and _presented and is_ready and is_instance_valid(_rig) and is_instance_valid(_camera)
	if _model:
		_model.visible = active
	if not active:
		suspend()
		return
	if not _has_original_rig:
		_original_rig = _rig.global_transform
		_has_original_rig = true
	if not _position_applied:
		_align_head(_movement.eye_position, _movement.yaw)
		_position_applied = true


func _fail(message: String) -> void:
	error = message
	loading = false
	is_ready = false
	_update_active()
	set_process(_thread != null)
	changed.emit()


func _exit_tree() -> void:
	suspend()
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null
	if _has_original_rig and is_instance_valid(_rig) and _rig.is_inside_tree():
		_rig.global_transform = _original_rig


func _align_head(position: Vector3, heading: float) -> void:
	if not is_instance_valid(_rig) or not is_instance_valid(_camera):
		return
	_rotate_around_head(wrapf(heading - _head_yaw(), -PI, PI))
	_rig.global_position += position - _camera.global_position


func _rotate_around_head(angle: float) -> void:
	var head := _camera.global_position
	var rotation := Basis(Vector3.UP, angle)
	var transform := _rig.global_transform
	transform.origin = head + rotation * (transform.origin - head)
	transform.basis = rotation * transform.basis
	_rig.global_transform = transform


func _head_yaw() -> float:
	var forward := -_camera.global_basis.z
	return atan2(-forward.x, -forward.z)


func _nearest_collider(origin: Vector3, direction: Vector3) -> Dictionary:
	var closest: Dictionary = {}
	for collider in _manifest.get("colliders", []):
		if not str(_movement.selected_seat).is_empty() and str(collider.get("id", "")).begins_with("seat_%s_" % _movement.selected_seat):
			continue
		var distance := _ray_box(origin, direction, _vector(collider.min), _vector(collider.max))
		if distance >= 0 and (closest.is_empty() or distance < float(closest.distance)):
			closest = {"id": str(collider.get("id", "")), "distance": distance}
	# Stepped platforms are floor support in navigation, but their solid visual
	# risers also occlude controller rays. Otherwise an aisle ray could select a
	# chair through the floor of the next tier.
	for area in _manifest.get("walkable", []):
		var minimum := _vector(area.min)
		var maximum := _vector(area.max)
		minimum.y = minf(0.0, float(area.height) - 0.08)
		maximum.y = float(area.height)
		var distance := _ray_box(origin, direction, minimum, maximum)
		if distance >= 0 and (closest.is_empty() or distance < float(closest.distance)):
			closest = {"id": "floor_%s" % area.get("id", ""), "distance": distance}
	return closest


func _ray_box(origin: Vector3, direction: Vector3, minimum: Vector3, maximum: Vector3) -> float:
	var near := 0.0
	var far := MAX_RAY_DISTANCE
	for axis in 3:
		if absf(direction[axis]) < 0.00001:
			if origin[axis] < minimum[axis] or origin[axis] > maximum[axis]:
				return -1.0
			continue
		var first := (minimum[axis] - origin[axis]) / direction[axis]
		var last := (maximum[axis] - origin[axis]) / direction[axis]
		near = maxf(near, minf(first, last))
		far = minf(far, maxf(first, last))
		if near > far:
			return -1.0
	return near if far >= 0.0 and near <= MAX_RAY_DISTANCE else -1.0


func _normalize_vertex_materials(node: Node) -> void:
	if node is MeshInstance3D and node.mesh:
		for index in node.mesh.get_surface_count():
			var material := node.mesh.surface_get_material(index) as StandardMaterial3D
			var arrays: Array = node.mesh.surface_get_arrays(index)
			if material and not material.vertex_color_use_as_albedo and arrays[Mesh.ARRAY_COLOR] != null and not arrays[Mesh.ARRAY_COLOR].is_empty():
				var normalized := material.duplicate() as StandardMaterial3D
				normalized.vertex_color_use_as_albedo = true
				node.set_surface_override_material(index, normalized)
	for child in node.get_children():
		_normalize_vertex_materials(child)


func _vector(value: Variant) -> Vector3:
	if value is Vector3:
		return value
	return Vector3(float(value[0]), float(value[1]), float(value[2]))
