extends RefCounted
## Pure scene-space locomotion. The host applies eye_position/yaw to its rig;
## this class never writes to an XR camera or changes the tracked head pose.

enum Mode { WATCH, MOVE }

const BODY_RADIUS := 0.22
const EYE_HEIGHT := 1.65
const HEAD_CLEARANCE := 0.15
const MAX_STEP_HEIGHT := 0.32
const AXIS_DEADZONE := 0.18
const SNAP_ANGLE := PI / 6.0
const NAV_CELL := 0.15
const HASH_CELL := 2.0
const MAX_NAV_VISITS := 140000
const EPSILON := 0.001
const LANDING_SNAP_RADIUS := 0.40
const LANDING_SNAP_HEIGHT := 0.18
# Floor under a chair moves to the nearest free floor of that row's passage.
const CHAIR_LANDING_RADIUS := 1.0

var eye_position := Vector3.ZERO
var yaw := 0.0
var selected_seat := ""
var mode := Mode.WATCH
var movement_speed := 1.8
var waiting_for_neutral := true
var navigation_ready := false
var navigation_prepare_ms := 0
var last_teleport_ms := 0

var _seats: Dictionary = {}
var _design: Dictionary = {}
var _walkable: Array[Dictionary] = []
var _floor_hash: Dictionary = {}
var _colliders: Array[AABB] = []
# Chair colliders block bodies, not the teleport arc (it passes over seat backs).
var _chair_colliders: Dictionary = {}
var _collider_hash: Dictionary = {}
var _nav_cache: Dictionary = {}
var _nav_components: Dictionary = {}
var _turn_latched := false
var _has_position := false


func configure(manifest: Dictionary) -> void:
	_seats.clear()
	_design = manifest.get("design", {}).duplicate() if manifest.get("design") is Dictionary else {}
	_walkable.clear()
	_floor_hash.clear()
	_colliders.clear()
	_chair_colliders.clear()
	_collider_hash.clear()
	_nav_cache.clear()
	_nav_components.clear()
	navigation_ready = false
	last_teleport_ms = 0
	selected_seat = ""
	mode = Mode.WATCH
	eye_position = Vector3.ZERO
	yaw = 0.0
	_has_position = false
	for value in manifest.get("seats", []):
		if value is Dictionary and value.has("id") and value.has("eye_position"):
			_seats[str(value.id)] = value.duplicate(true)
	for value in manifest.get("walkable", []):
		if not value is Dictionary:
			continue
		var minimum := Vector3.ZERO
		var maximum := Vector3.ZERO
		if value.has("min") and value.has("max"):
			minimum = _vector(value.min)
			maximum = _vector(value.max)
		elif value.get("bounds", []).size() == 4:
			var bounds: Array = value.bounds
			minimum = Vector3(float(bounds[0]), 0, float(bounds[1]))
			maximum = Vector3(float(bounds[2]), 0, float(bounds[3]))
		else:
			continue
		var height := float(value.get("height", minimum.y))
		if minimum.is_finite() and maximum.is_finite() and is_finite(height) and maximum.x > minimum.x and maximum.z > minimum.z:
			_add_floor({"min": minimum, "max": maximum, "height": height})
	for value in manifest.get("colliders", []):
		if not value is Dictionary or not value.has("min") or not value.has("max"):
			continue
		var minimum := _vector(value.min)
		var maximum := _vector(value.max)
		if minimum.is_finite() and maximum.is_finite() and maximum.x > minimum.x and maximum.y > minimum.y and maximum.z > minimum.z:
			if str(value.get("id", "")).begins_with("seat_"):
				_chair_colliders[_colliders.size()] = true
			_add_collider(AABB(minimum, maximum - minimum))
	# Do static navigation work while the scene is loading, never on a user's
	# teleport click. Each component includes body clearance and stair limits.
	var navigation_started := Time.get_ticks_msec()
	_prepare_navigation()
	navigation_prepare_ms = Time.get_ticks_msec() - navigation_started
	var initial_id := str(manifest.get("default_seat", ""))
	if initial_id.is_empty() and not _seats.is_empty():
		initial_id = str(_seats.keys()[0])
	if not initial_id.is_empty():
		select_seat(initial_id)
	suspend()


func select_seat(id: String) -> bool:
	if not _seats.has(id):
		return false
	var seat: Dictionary = _seats[id]
	var position := _vector(seat.eye_position)
	var heading := float(seat.get("yaw", 0.0))
	# A seat deliberately overlaps its cushion/back. Only the head volume needs
	# clearance; movement uses a full standing body and a separate aisle exit.
	if not position.is_finite() or not is_finite(heading) or _body_blocked(position, position.y - 0.10, position.y + HEAD_CLEARANCE):
		return false
	eye_position = position
	yaw = heading
	selected_seat = id
	mode = Mode.WATCH
	_has_position = true
	suspend()
	return true


func set_moving(enabled: bool) -> bool:
	if not enabled:
		mode = Mode.WATCH
		suspend()
		return true
	if mode == Mode.MOVE:
		return true
	if not _has_position:
		return false
	var floor_position := eye_position - Vector3.UP * EYE_HEIGHT
	if not selected_seat.is_empty():
		var seat: Dictionary = _seats[selected_seat]
		if not seat.has("exit_position"):
			return false
		floor_position = _vector(seat.exit_position)
	var standing := _standing_at(floor_position, MAX_STEP_HEIGHT)
	if not standing.is_finite():
		return false
	eye_position = standing + Vector3.UP * EYE_HEIGHT
	selected_seat = ""
	mode = Mode.MOVE
	suspend()
	return true


func teleport_floor(target: Vector3) -> bool:
	if mode != Mode.MOVE or not target.is_finite():
		return false
	var destination := _standing_at(target, MAX_STEP_HEIGHT)
	if not destination.is_finite():
		return false
	var source := eye_position - Vector3.UP * EYE_HEIGHT
	var started := Time.get_ticks_msec()
	if not _reachable(source, destination):
		last_teleport_ms = Time.get_ticks_msec() - started
		return false
	last_teleport_ms = Time.get_ticks_msec() - started
	eye_position = destination + Vector3.UP * EYE_HEIGHT
	selected_seat = ""
	suspend()
	return true


func landing_candidates(hit: Vector3, floor_y: float) -> Array[Vector3]:
	# Only existing body-safe samples in the current connected component qualify.
	# This bounded query uses the grid prepared at load time, not a new path search.
	var candidates: Array[Vector3] = []
	if not hit.is_finite() or not is_finite(floor_y): return candidates
	var source := _nav_anchor(eye_position - Vector3.UP * EYE_HEIGHT)
	if not _nav_components.has(source): return candidates
	var centre := Vector2i(roundi(hit.x / NAV_CELL), roundi(hit.z / NAV_CELL))
	var cells := ceili(LANDING_SNAP_RADIUS / NAV_CELL)
	for x in range(-cells, cells + 1):
		for z in range(-cells, cells + 1):
			var key := centre + Vector2i(x, z)
			if _nav_components.get(key, -1) != _nav_components[source]: continue
			var point: Vector3 = _nav_cache[key]
			if absf(point.y - floor_y) > .01: continue
			if Vector2(point.x - hit.x, point.z - hit.z).length() > LANDING_SNAP_RADIUS: continue
			candidates.append(point)
	candidates.sort_custom(func(a: Vector3, b: Vector3): return a.distance_squared_to(hit) < b.distance_squared_to(hit))
	return candidates


## The seat whose floor footprint contains [point], or "". Aiming the arc at a
## chair means "sit here"; the passage around it remains a standing target.
func seat_at(point: Vector3) -> String:
	if not point.is_finite(): return ""
	var half := float(_design.get("seat_pitch", 0.9)) * 0.5
	var front := float(_design.get("seat_front", 0.42))
	var rear := float(_design.get("seat_rear", 0.38))
	var seated := float(_design.get("seated_eye_height", 1.2))
	for id in _seats:
		var eye := _vector(_seats[id].eye_position)
		# Seat line relative to the seated eye (see cinema_blueprint.gd).
		var seat_z := eye.z + float(_design.get("seat_line_from_eye", 0.10))
		var inside := absf(point.x - eye.x) <= half and point.z >= seat_z - front and point.z <= seat_z + rear
		if inside and absf(point.y - (eye.y - seated)) <= 0.3:
			return str(id)
	return ""


func chair_landing_candidates(hit: Vector3) -> Array[Vector3]:
	# Same bounded grid query as landing_candidates, wider and limited to the
	# chair's own tier, so a landing below a seat lands in front of or behind it.
	var candidates: Array[Vector3] = []
	if not hit.is_finite(): return candidates
	var source := _nav_anchor(eye_position - Vector3.UP * EYE_HEIGHT)
	if not _nav_components.has(source): return candidates
	var centre := Vector2i(roundi(hit.x / NAV_CELL), roundi(hit.z / NAV_CELL))
	var cells := ceili(CHAIR_LANDING_RADIUS / NAV_CELL)
	for x in range(-cells, cells + 1):
		for z in range(-cells, cells + 1):
			var key := centre + Vector2i(x, z)
			if _nav_components.get(key, -1) != _nav_components[source]: continue
			var point: Vector3 = _nav_cache[key]
			if absf(point.y - hit.y) > MAX_STEP_HEIGHT * 2.0: continue
			if Vector2(point.x - hit.x, point.z - hit.z).length() > CHAIR_LANDING_RADIUS: continue
			candidates.append(point)
	candidates.sort_custom(func(a: Vector3, b: Vector3): return Vector2(a.x - hit.x, a.z - hit.z).length_squared() < Vector2(b.x - hit.x, b.z - hit.z).length_squared())
	return candidates


func suspend() -> void:
	waiting_for_neutral = true
	_turn_latched = true


func step(input: Vector2, turn: float, delta: float, turn_back: bool = false) -> void:
	if not input.is_finite() or not is_finite(turn) or not is_finite(delta):
		return
	var neutral := input.length() <= AXIS_DEADZONE and absf(turn) <= AXIS_DEADZONE and not turn_back
	if waiting_for_neutral:
		if neutral:
			waiting_for_neutral = false
			_turn_latched = false
		return
	if absf(turn) <= AXIS_DEADZONE and not turn_back:
		_turn_latched = false
	if mode != Mode.MOVE or delta <= 0.0:
		return
	if (absf(turn) >= 0.65 or turn_back) and not _turn_latched:
		yaw = wrapf(yaw + (PI if turn_back else -signf(turn) * SNAP_ANGLE), -PI, PI)
		_turn_latched = true
	if input.length() <= AXIS_DEADZONE:
		return
	var strength := clampf((input.length() - AXIS_DEADZONE) / (1.0 - AXIS_DEADZONE), 0.0, 1.0)
	var direction := Vector3(input.normalized().x, 0.0, input.normalized().y).rotated(Vector3.UP, yaw)
	var displacement := direction * movement_speed * strength * minf(delta, 0.25)
	var count := maxi(1, ceili(displacement.length() / 0.08))
	var increment := displacement / float(count)
	for index in count:
		var floor_position := eye_position - Vector3.UP * EYE_HEIGHT
		var destination := _standing_at(floor_position + increment, MAX_STEP_HEIGHT)
		if destination.is_finite():
			eye_position = destination + Vector3.UP * EYE_HEIGHT
			continue
		# Slide along a wall instead of stopping both axes on diagonal contact.
		for slide in [Vector3(increment.x, 0, 0), Vector3(0, 0, increment.z)]:
			floor_position = eye_position - Vector3.UP * EYE_HEIGHT
			destination = _standing_at(floor_position + slide, MAX_STEP_HEIGHT)
			if destination.is_finite():
				eye_position = destination + Vector3.UP * EYE_HEIGHT


func _standing_at(hint: Vector3, height_tolerance: float) -> Vector3:
	if not hint.is_finite():
		return Vector3.INF
	var floor_height := _floor_height(hint, height_tolerance)
	if not is_finite(floor_height):
		return Vector3.INF
	var position := Vector3(hint.x, floor_height, hint.z)
	# Footprint must remain on connected floor, including adjacent small stairs.
	# Check the diagonal too, so room corners cannot support only the centre.
	for offset in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1), Vector2(0.7071, 0.7071), Vector2(-0.7071, 0.7071), Vector2(0.7071, -0.7071), Vector2(-0.7071, -0.7071)]:
		var sample := position + Vector3(offset.x, 0, offset.y) * BODY_RADIUS
		if not is_finite(_floor_height(sample, MAX_STEP_HEIGHT)):
			return Vector3.INF
	if _body_blocked(position, floor_height + 0.03, floor_height + EYE_HEIGHT + HEAD_CLEARANCE):
		return Vector3.INF
	return position


func _floor_height(hint: Vector3, tolerance: float) -> float:
	var result := INF
	var difference := INF
	for index in _floor_hash.get(_hash_key(hint), []):
		var area: Dictionary = _walkable[index]
		var minimum: Vector3 = area.min
		var maximum: Vector3 = area.max
		if hint.x < minimum.x - EPSILON or hint.x > maximum.x + EPSILON or hint.z < minimum.z - EPSILON or hint.z > maximum.z + EPSILON:
			continue
		var distance := absf(float(area.height) - hint.y)
		if distance <= tolerance + EPSILON and distance < difference:
			result = float(area.height)
			difference = distance
	return result


func _add_floor(area: Dictionary) -> void:
	var index := _walkable.size()
	_walkable.append(area)
	var minimum := _hash_key(area.min - Vector3(EPSILON, 0, EPSILON))
	var maximum := _hash_key(area.max + Vector3(EPSILON, 0, EPSILON))
	for x in range(minimum.x, maximum.x + 1):
		for z in range(minimum.y, maximum.y + 1):
			var key := Vector2i(x, z)
			if not _floor_hash.has(key):
				_floor_hash[key] = []
			_floor_hash[key].append(index)


func _body_blocked(position: Vector3, bottom: float, top: float) -> bool:
	var minimum := _hash_key(position - Vector3(BODY_RADIUS, 0, BODY_RADIUS))
	var maximum := _hash_key(position + Vector3(BODY_RADIUS, 0, BODY_RADIUS))
	for x in range(minimum.x, maximum.x + 1):
		for z in range(minimum.y, maximum.y + 1):
			for index in _collider_hash.get(Vector2i(x, z), []):
				var box: AABB = _colliders[index]
				if top <= box.position.y + EPSILON or bottom >= box.end.y - EPSILON:
					continue
				var nearest := Vector2(clampf(position.x, box.position.x, box.end.x), clampf(position.z, box.position.z, box.end.z))
				if Vector2(position.x, position.z).distance_squared_to(nearest) < BODY_RADIUS * BODY_RADIUS - EPSILON * EPSILON:
					return true
	return false


func _add_collider(box: AABB) -> void:
	var index := _colliders.size()
	_colliders.append(box)
	var minimum := _hash_key(box.position)
	var maximum := _hash_key(box.end)
	for x in range(minimum.x, maximum.x + 1):
		for z in range(minimum.y, maximum.y + 1):
			var key := Vector2i(x, z)
			if not _collider_hash.has(key):
				_collider_hash[key] = []
			_collider_hash[key].append(index)


func _hash_key(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x / HASH_CELL), floori(position.z / HASH_CELL))


func _nav_position(key: Vector2i) -> Vector3:
	if _nav_cache.has(key):
		return _nav_cache[key]
	var hint := Vector3(key.x * NAV_CELL, 0, key.y * NAV_CELL)
	# This prototype supports one floor per X/Z coordinate. Authoring validation
	# must reject overlapping stacked navigation decks until that is extended.
	var floor_height := _floor_height(hint, INF)
	var position := Vector3.INF
	if is_finite(floor_height):
		hint.y = floor_height
		position = _standing_at(hint, MAX_STEP_HEIGHT)
	_nav_cache[key] = position
	return position


func _nav_anchor(position: Vector3) -> Vector2i:
	var centre := Vector2i(roundi(position.x / NAV_CELL), roundi(position.z / NAV_CELL))
	var result := Vector2i(2147483647, 2147483647)
	var distance := INF
	for x in range(-1, 2):
		for z in range(-1, 2):
			var key := centre + Vector2i(x, z)
			var candidate := _nav_position(key)
			if not candidate.is_finite() or absf(candidate.y - position.y) > MAX_STEP_HEIGHT:
				continue
			if candidate.distance_squared_to(position) < distance and _segment_clear(position, candidate):
				distance = candidate.distance_squared_to(position)
				result = key
	return result


func _segment_clear(source: Vector3, target: Vector3) -> bool:
	var distance := Vector2(source.x, source.z).distance_to(Vector2(target.x, target.z))
	var count := maxi(1, ceili(distance / 0.07))
	var position := source
	for index in range(1, count + 1):
		var hint := source.lerp(target, float(index) / float(count))
		hint.y = position.y
		position = _standing_at(hint, MAX_STEP_HEIGHT)
		if not position.is_finite():
			return false
	return absf(position.y - target.y) <= MAX_STEP_HEIGHT


func _prepare_navigation() -> void:
	var keys: Dictionary = {}
	for area in _walkable:
		var minimum: Vector3 = area.min
		var maximum: Vector3 = area.max
		for x in range(ceili(minimum.x / NAV_CELL), floori(maximum.x / NAV_CELL) + 1):
			for z in range(ceili(minimum.z / NAV_CELL), floori(maximum.z / NAV_CELL) + 1):
				keys[Vector2i(x, z)] = true
				if keys.size() > MAX_NAV_VISITS:
					return
	var points: Dictionary = {}
	for key: Vector2i in keys:
		var position := _nav_position(key)
		if position.is_finite():
			points[key] = position
	var component := 0
	for key: Vector2i in points:
		if _nav_components.has(key):
			continue
		component += 1
		var queue: Array[Vector2i] = [key]
		_nav_components[key] = component
		var cursor := 0
		while cursor < queue.size():
			var current := queue[cursor]
			cursor += 1
			var position: Vector3 = points[current]
			for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				var neighbour: Vector2i = current + offset
				if _nav_components.has(neighbour) or not points.has(neighbour):
					continue
				var candidate: Vector3 = points[neighbour]
				if absf(candidate.y - position.y) > MAX_STEP_HEIGHT:
					continue
				# Adjacent samples are closer than the body radius. Their swept
				# footprints overlap, so a thin wall cannot hide between them.
				_nav_components[neighbour] = component
				queue.append(neighbour)
	navigation_ready = not points.is_empty()


func _reachable(source: Vector3, target: Vector3) -> bool:
	if not navigation_ready:
		return false
	var start := _nav_anchor(source)
	var goal := _nav_anchor(target)
	return _nav_components.has(start) and _nav_components.has(goal) and _nav_components[start] == _nav_components[goal]


func _vector(value: Variant) -> Vector3:
	if value is Vector3:
		return value
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.INF
