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
const CHAIR_LANDING_TRIES := 24

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
var light_mode := "auto"
var lights_on := true
const FILM_UNIFORMS := ["film_left", "film_center", "film_right"]
var film_light: Array = [Color.BLACK, Color.BLACK, Color.BLACK]
var _light_mix := 1.0
var _light_target := 1.0
var _light_materials: Array[Dictionary] = []


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
	if value not in ["watch", "move"] or not active or not _movement:
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
			_movement.step(Vector2.ZERO, right.x, delta)
		return true
	# Real tracking can move the head inside the guardian. Test locomotion from
	# its current X/Z while preserving the navigation floor beneath the avatar.
	var head_position := _camera.global_position
	_movement.eye_position.x = head_position.x
	_movement.eye_position.z = head_position.z
	var previous_eye: Vector3 = _movement.eye_position
	var previous_yaw := _head_yaw()
	_movement.yaw = previous_yaw
	_movement.step(Vector2.ZERO, right.x, delta)
	var translation: Vector3 = _movement.eye_position - previous_eye
	var turn := wrapf(float(_movement.yaw) - previous_yaw, -PI, PI)
	if not is_zero_approx(turn):
		_rotate_around_head(turn)
	if not translation.is_zero_approx():
		_rig.global_position += translation
	return true


func ray_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	if not active or interaction != "move" or not origin.is_finite() or not direction.is_finite() or direction.length_squared() < 0.000001:
		return {}
	var points := PackedVector3Array([origin])
	var velocity := direction.normalized() * 8.5
	var previous := origin
	for step in range(1, 41):
		var t := step * 0.075
		var point := origin + velocity * t + Vector3.DOWN * 4.9 * t * t
		var hit := _arc_segment(previous, point)
		if not hit.is_empty() and hit.kind in ["floor", "riser"]:
			var seat_id: String = _movement.seat_at(hit.position)
			if not seat_id.is_empty():
				points.append(hit.position)
				return _seat_target(seat_id, points, origin)
		if not hit.is_empty():
			points.append(hit.position)
			var landing := _landing_destination(hit)
			hit["valid"] = landing.is_finite()
			hit["raw_position"] = hit.position
			hit["snapped"] = landing.is_finite() and not landing.is_equal_approx(hit.position)
			if landing.is_finite():
				hit["position"] = landing
				if hit.snapped: points.append(landing)
			hit["points"] = points
			hit["distance"] = origin.distance_to(hit.position)
			return hit
		points.append(point)
		previous = point
	return {"kind": "miss", "position": previous, "points": points, "valid": false, "distance": origin.distance_to(previous)}

func _arc_segment(start: Vector3, end: Vector3) -> Dictionary:
	# Reuse the navigation spatial hash; never scan all chairs for every arc segment.
	var lo: Vector2i = _movement._hash_key(start.min(end) - Vector3.ONE * .035)
	var hi: Vector2i = _movement._hash_key(start.max(end) + Vector3.ONE * .035)
	var colliders := {}; var floors := {}
	for x in range(lo.x, hi.x + 1):
		for z in range(lo.y, hi.y + 1):
			for index in _movement._collider_hash.get(Vector2i(x, z), []): colliders[index] = true
			for index in _movement._floor_hash.get(Vector2i(x, z), []): floors[index] = true
	var distance := start.distance_to(end)
	if distance < .00001: return {}
	var direction := (end - start) / distance
	var nearest := distance + .001
	var result := {}
	for index in colliders:
		# Like system teleports, the arc passes over seat backs; chairs still block bodies.
		if _movement._chair_colliders.has(index): continue
		var box: AABB = _movement._colliders[index]
		box = box.grow(.035)
		var d := _ray_box(start, direction, box.position, box.end)
		if d >= 0 and d <= distance and d < nearest:
			nearest = d; result = {"kind": "blocked", "position": start + direction * d}
	for index in floors:
		var area: Dictionary = _movement._walkable[index]
		var minimum: Vector3 = area.min; var maximum: Vector3 = area.max
		minimum.y = minf(-.3, float(area.height) - .08); maximum.y = area.height
		var d := _ray_box(start, direction, minimum, maximum)
		if d >= 0 and d <= distance and d < nearest:
			nearest = d
			var position := start + direction * d
			var top_hit := absf(position.y - float(area.height)) < .002 and direction.y < 0
			# A small stair's front face is a landing hint for its top, not a wall.
			# Tall tier sides and undersides remain blocked.
			var rise := float(area.height) - position.y
			var kind := "floor" if top_hit else "riser" if rise >= 0 and rise <= Locomotion.LANDING_SNAP_HEIGHT else "blocked"
			result = {"kind": kind, "position": position, "floor_y": float(area.height)}
	return result

## Aiming at a chair: sit there, eyes at the seat, facing the screen.
func _seat_target(seat_id: String, points: PackedVector3Array, origin: Vector3) -> Dictionary:
	var eye := _vector(_movement._seats[seat_id].eye_position)
	var seated := float(_movement._design.get("seated_eye_height", 1.2))
	# Marker rests on the cushion: seat line 10 cm behind the eye, cushion top ~0.47 m.
	var cushion := Vector3(eye.x, eye.y - seated + 0.47, eye.z + 0.05)
	return {"kind": "seat", "id": seat_id, "position": cushion, "points": points, "valid": true,
		"distance": origin.distance_to(cushion)}

func _landing_destination(hit: Dictionary) -> Vector3:
	if hit.kind not in ["floor", "riser"]: return Vector3.INF
	var point: Vector3 = hit.position
	if hit.kind == "floor" and _valid_destination(point): return point
	for candidate in _movement.landing_candidates(point, float(hit.get("floor_y", point.y))):
		if not _snap_segment_clear(point, candidate): continue
		if _valid_destination(candidate): return candidate
	# Floor under or between chairs: land in the row passage nearest the aim.
	var tries := 0
	for candidate in _movement.chair_landing_candidates(point):
		if _valid_destination(candidate): return candidate
		tries += 1
		if tries >= CHAIR_LANDING_TRIES: break
	return Vector3.INF

func _snap_segment_clear(source: Vector3, target: Vector3) -> bool:
	# A tiny adjustment may move out of a clearance margin, but never cross actual
	# chair/wall/rail geometry. Check the entire standing column along the offset.
	var low: Vector2i = _movement._hash_key(source.min(target))
	var high: Vector2i = _movement._hash_key(source.max(target))
	var checked := {}
	var direction := target - source
	var distance := direction.length()
	if distance < .00001: return true
	direction /= distance
	var height := maxf(Locomotion.EYE_HEIGHT + Locomotion.HEAD_CLEARANCE, _camera.position.y + Locomotion.HEAD_CLEARANCE)
	for x in range(low.x, high.x + 1):
		for z in range(low.y, high.y + 1):
			for index in _movement._collider_hash.get(Vector2i(x, z), []):
				if checked.has(index): continue
				checked[index] = true
				var box: AABB = _movement._colliders[index]
				var minimum := box.position - Vector3.UP * height
				var maximum := box.end - Vector3.UP * .03
				var d := _ray_box(source, direction, minimum, maximum)
				if d >= 0 and d <= distance: return false
	return true

func _valid_destination(point: Vector3) -> bool:
	var standing: Vector3 = _movement._standing_at(point, .04)
	if not standing.is_finite(): return false
	var height := maxf(Locomotion.EYE_HEIGHT + Locomotion.HEAD_CLEARANCE, _camera.position.y + Locomotion.HEAD_CLEARANCE)
	if _movement._body_blocked(standing, standing.y + .03, standing.y + height): return false
	if _manifest.has("room") and standing.y + height > float(_manifest.room.height): return false
	var source: Vector3 = _movement.eye_position - Vector3.UP * Locomotion.EYE_HEIGHT
	return _movement._reachable(source, standing)

func pointer_press(hand: String, origin: Vector3, direction: Vector3) -> bool:
	if hand.is_empty() or not _capture_hand.is_empty():
		return false
	if not active or interaction != "move": return false
	_capture_hand = hand
	_capture = {"aiming": true}
	update_pointer(hand, origin, direction)
	return true

func pointer_release(hand: String, origin: Vector3, direction: Vector3, valid: bool) -> bool:
	if _capture_hand != hand or _capture.is_empty(): return false
	_capture = {}; _capture_hand = ""
	var target := ray_hit(origin, direction) if valid else {}
	hide_pointer(hand)
	if target.get("kind", "") == "seat":
		# Sitting ends free movement: the view settles facing the screen.
		if _movement.select_seat(str(target.id)):
			interaction = "watch"
			suspend()
			_align_head(_movement.eye_position, _movement.yaw)
			changed.emit()
		return true
	if target.get("valid", false) and _valid_destination(target.position):
		if _movement.teleport_floor(target.position):
			_movement.yaw = _head_yaw()
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
	if not valid or hand.is_empty() or hand != _capture_hand:
		hide_pointer(hand); return
	var hit := ray_hit(origin, direction)
	if hit.is_empty(): hide_pointer(hand); return
	var visual := _pointer_visual(hand)
	var pointer: Node3D = visual.root
	pointer.global_transform = Transform3D.IDENTITY
	var material: StandardMaterial3D = visual.material
	material.albedo_color = Color(.35, .95, .68) if hit.valid else Color(1, .18, .12)
	visual.floor.position = Vector3(hit.position) + Vector3.UP * .025
	# A seat target shows a wider ring on the cushion: release to sit.
	visual.floor.scale = Vector3.ONE * (1.35 if hit.kind == "seat" else 1.0)
	visual.floor.visible = hit.kind != "miss"
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var points: PackedVector3Array = hit.points
	for index in range(1, points.size()):
		var a := points[index - 1]; var b := points[index]
		var side := (b - a).cross(_camera.global_position - (a + b) * .5).normalized() * .008
		if side.length_squared() < .000001: side = Vector3.RIGHT * .008
		for vertex in [a - side, a + side, b + side, a - side, b + side, b - side]: mesh.surface_add_vertex(vertex)
	mesh.surface_end()
	visual.arc.mesh = mesh
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
	var arc := MeshInstance3D.new()
	arc.name = "TeleportArc"; arc.material_override = material
	arc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pointer.add_child(arc)
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
	var visual := {"root": pointer, "floor": floor_ring, "arc": arc, "material": material}
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
	# Both independent bakes are required before presenting the room.
	ResourceLoader.load_threaded_request(Description.LIGHT_PATH, "Texture2D")
	ResourceLoader.load_threaded_request(Description.LIGHT_OFF_PATH, "Texture2D")
	ResourceLoader.load_threaded_request(Description.SCREEN_LIGHT_PATH, "Texture2D")
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


func set_lighting(mode: String, playing: bool) -> void:
	light_mode = mode if mode in ["auto", "on", "off"] else "auto"
	lights_on = light_mode == "on" or (light_mode == "auto" and not playing)
	_light_target = 1.0 if lights_on else 0.0
	if not is_equal_approx(_light_mix, _light_target): set_process(true)

func _prepare_light_materials() -> void:
	_light_materials.clear()
	var seen := {}
	for node in _model.find_children("*", "MeshInstance3D", true, false):
		for index in node.mesh.get_surface_count():
			var material := node.get_active_material(index) as ShaderMaterial
			if not material or material.shader not in [Description.SURFACE_SHADER, Description.SEAT_SHADER, Description.FIXTURE_SHADER]: continue
			if seen.has(material.get_instance_id()): continue
			seen[material.get_instance_id()] = true
			_light_materials.append({"material": material})
	_apply_lighting()

func _apply_lighting() -> void:
	for entry in _light_materials:
		entry.material.set_shader_parameter("cinema_light_mix", _light_mix)

## Film colours (linear, normalised) for the left, centre and right screen strips.
func set_film_light(colors: Array) -> void:
	if colors.size() < 3: return
	film_light = colors.duplicate()
	for entry in _light_materials:
		if entry.material.shader == Description.FIXTURE_SHADER: continue
		for index in 3:
			var color: Color = colors[index]
			entry.material.set_shader_parameter(FILM_UNIFORMS[index], Vector3(color.r, color.g, color.b))

func _process(_delta: float) -> void:
	if not is_equal_approx(_light_mix, _light_target):
		_light_mix = move_toward(_light_mix, _light_target, _delta * 1.25)
		_apply_lighting()
	if _thread and not _thread.is_alive():
		_movement = _thread.wait_to_finish()
		_thread = null
		if not _movement or not _movement.navigation_ready:
			_fail("Cinema navigation could not be prepared")
	if loading and _requested_model and not is_instance_valid(_model):
		var status := ResourceLoader.load_threaded_get_status(MODEL_PATH)
		var light_status := ResourceLoader.load_threaded_get_status(Description.LIGHT_PATH)
		var off_status := ResourceLoader.load_threaded_get_status(Description.LIGHT_OFF_PATH)
		var screen_status := ResourceLoader.load_threaded_get_status(Description.SCREEN_LIGHT_PATH)
		if light_status in [ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE] or off_status in [ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE]:
			_fail("Cinema lighting could not be loaded"); return
		var lights_loaded := light_status == ResourceLoader.THREAD_LOAD_LOADED and off_status == ResourceLoader.THREAD_LOAD_LOADED
		if status == ResourceLoader.THREAD_LOAD_LOADED and lights_loaded and screen_status != ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			var light := ResourceLoader.load_threaded_get(Description.LIGHT_PATH) as Texture2D
			var light_off := ResourceLoader.load_threaded_get(Description.LIGHT_OFF_PATH) as Texture2D
			# Without the screen map the hall still works, lit by its house states only.
			var screen: Texture2D = null
			if screen_status == ResourceLoader.THREAD_LOAD_LOADED:
				screen = ResourceLoader.load_threaded_get(Description.SCREEN_LIGHT_PATH) as Texture2D
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
			Description.apply_baked_surfaces(_model, light, light_off, screen)
			Description.apply_seat_lighting(_model)
			_prepare_light_materials()
			_model.visible = false
			add_child(_model)
		elif status in [ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE]:
			_fail("Cinema model could not be loaded")
	if loading and _model and _movement:
		loading = false
		is_ready = true
		_update_active()
		changed.emit()
	if not loading and not _thread and is_equal_approx(_light_mix, _light_target):
		set_process(false)


func _update_active() -> void:
	active = Feature.enabled() and selected and _presented and is_ready and is_instance_valid(_rig) and is_instance_valid(_camera)
	if _model:
		_model.visible = active
	if not active:
		suspend()
		if _has_original_rig and is_instance_valid(_rig): _rig.global_transform = _original_rig
		_has_original_rig = false; _position_applied = false
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
