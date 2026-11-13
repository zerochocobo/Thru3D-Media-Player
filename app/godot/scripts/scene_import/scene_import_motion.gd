extends Node3D
## Moving through an imported scene, with the gestures of the built-in scenes' free movement:
## aim an arc and land where it meets a floor, turn in steps. Flying has no landing: the stick
## carries the viewer along the line of sight. The scene slides around the viewer instead of the rig
## moving through it, so the player's screen, menus and tracking space are left alone.
## No authored floor is needed: the arc is tested against the scene's own triangles.
const FIXED := "fixed"
const WALK := "walk"
const FLY := "fly"
const MODES := [FIXED, WALK, FLY]
const DEADZONE := 0.18
const SNAP_ANGLE := PI / 6.0
## The arc, ring and colours of the built-in scenes' teleport pointer.
const ARC_SPEED := 8.5
const ARC_STEPS := 40
const ARC_STEP_SECONDS := 0.075
const VALID := Color(0.35, 0.95, 0.68)
const INVALID := Color(1, 0.18, 0.12)
const MARKER_LIFT := 0.025
## A landing needs a surface no steeper than this, room to stand, and nothing through the body.
const MAX_SLOPE_COSINE := 0.7
const HEADROOM := 1.8
const BODY := 0.22
const BODY_HEIGHT := 0.9
## Meshes past this size are left out of the test rather than held twice in memory.
const MAX_SHAPE_INDICES := 3000000

var mode := FIXED
var fly_speed := 3.0
## True once the scene's triangles can be tested; landings wait for it.
var prepared := false
var _scene: Node3D
var _home := Transform3D.IDENTITY
var _shapes: Array[Dictionary] = []
var _task := -1
var _generation := 0
var _turn_latched := false
var _fly_gesture := ""
var _capture_hand := ""
var _visuals := {}
var _moved_to := WALK

func attach(scene: Node3D, bounds: AABB) -> void:
	detach()
	_scene = scene
	_home = scene.transform
	fly_speed = clampf(bounds.size.length() / 20.0, 2.0, 12.0)
	if mode != FIXED: _prepare()

func detach() -> void:
	suspend()
	_generation += 1
	_scene = null
	_shapes = []
	prepared = false
	mode = FIXED

func set_mode(value: String) -> void:
	suspend()
	mode = value if value in MODES else FIXED
	if mode != FIXED:
		_moved_to = mode
		if _scene and not prepared: _prepare()

## The moving mode last used, for returning to movement without naming one.
func resume_mode() -> String:
	return _moved_to

func moving() -> bool:
	return _scene != null and mode != FIXED

## Back to where the scene put the viewer.
func home() -> void:
	suspend()
	if _scene: _scene.transform = _home

func _prepare() -> void:
	if _task >= 0 or prepared or _scene == null: return
	# Only meshes and transforms cross to the worker; the tree stays with the main thread.
	var jobs: Array[Dictionary] = []
	for node in _scene.find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = (node as MeshInstance3D).mesh
		if mesh == null or not (node as MeshInstance3D).visible: continue
		var indices := 0
		for surface in mesh.get_surface_count():
			var length: int = mesh.surface_get_array_index_len(surface)
			indices += length if length > 0 else mesh.surface_get_array_len(surface)
		if indices <= 0 or indices > MAX_SHAPE_INDICES: continue
		var to_scene := _scene.global_transform.affine_inverse() * (node as Node3D).global_transform
		jobs.append({"mesh": mesh, "to_scene": to_scene, "to_mesh": to_scene.affine_inverse(), "bounds": to_scene * mesh.get_aabb()})
	var generation := _generation
	_task = WorkerThreadPool.add_task(func() -> void:
		var built: Array[Dictionary] = []
		for job in jobs:
			var shape: TriangleMesh = (job.mesh as Mesh).generate_triangle_mesh()
			if shape != null: built.append({"shape": shape, "to_scene": job.to_scene, "to_mesh": job.to_mesh, "bounds": job.bounds})
		_prepared.call_deferred(built, generation))

func _prepared(built: Array[Dictionary], generation: int) -> void:
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	if generation == _generation:
		_shapes = built
		prepared = true
	elif mode != FIXED and _scene: _prepare()

func _exit_tree() -> void:
	if _task >= 0: WorkerThreadPool.wait_for_task_completion(_task)

## The nearest thing the segment a→b (scene space) runs into: {position, normal}, or empty.
func _segment(a: Vector3, b: Vector3) -> Dictionary:
	var span := AABB(a, Vector3.ZERO).expand(b).grow(0.01)
	var nearest := INF
	var result := {}
	for entry in _shapes:
		if not (entry.bounds as AABB).intersects(span): continue
		var hit: Dictionary = (entry.shape as TriangleMesh).intersect_segment(entry.to_mesh * a, entry.to_mesh * b)
		if hit.is_empty(): continue
		var position: Vector3 = (entry.to_scene as Transform3D) * (hit.position as Vector3)
		var distance := a.distance_squared_to(position)
		if distance < nearest:
			nearest = distance
			# The reported normal faces the ray: hit from above, a floor's points up.
			result = {"position": position, "normal": ((entry.to_scene as Transform3D).basis * (hit.normal as Vector3)).normalized()}
	return result

## Whether a viewer can stand at `point` (scene space): head room above, nothing through the body.
func _standable(point: Vector3) -> bool:
	if not _segment(point + Vector3.UP * 0.3, point + Vector3.UP * HEADROOM).is_empty(): return false
	var chest := point + Vector3.UP * BODY_HEIGHT
	for side in [Vector3(BODY, 0, 0), Vector3(0, 0, BODY)]:
		if not _segment(chest - side, chest + side).is_empty(): return false
	return true

## Where the arc from a hand lands, all in world space: {kind, position, points, valid}.
func ray_hit(origin: Vector3, direction: Vector3) -> Dictionary:
	if not moving() or not origin.is_finite() or not direction.is_finite() or direction.length_squared() < 0.000001: return {}
	var to_scene := _scene.global_transform.affine_inverse()
	var to_world := _scene.global_transform
	var points := PackedVector3Array([origin])
	var velocity := direction.normalized() * ARC_SPEED
	var previous := origin
	for step in range(1, ARC_STEPS + 1):
		var t := step * ARC_STEP_SECONDS
		var point := origin + velocity * t + Vector3.DOWN * 4.9 * t * t
		var hit := _segment(to_scene * previous, to_scene * point) if prepared else {}
		if not hit.is_empty():
			var floor := (hit.normal as Vector3).y >= MAX_SLOPE_COSINE
			points.append(to_world * (hit.position as Vector3))
			return {"kind": "floor" if floor else "blocked", "position": to_world * (hit.position as Vector3), "points": points,
				"valid": floor and _standable(hit.position)}
		points.append(point)
		previous = point
	return {"kind": "miss", "position": previous, "points": points, "valid": false}

func pointer_press(hand: String, origin: Vector3, direction: Vector3) -> bool:
	if hand.is_empty() or not _capture_hand.is_empty() or mode != WALK: return false
	_capture_hand = hand
	update_pointer(hand, origin, direction)
	return true

## Landing: the scene moves so that the chosen point comes under the viewer's feet.
func pointer_release(hand: String, origin: Vector3, direction: Vector3, valid: bool, feet: Vector3) -> bool:
	if _capture_hand != hand: return false
	var target := ray_hit(origin, direction) if valid else {}
	_capture_hand = ""
	hide_pointer(hand)
	if target.get("valid", false): _scene.global_position += feet - (target.position as Vector3)
	return true

func cancel_pointer(hand: String) -> void:
	hide_pointer(hand)
	if _capture_hand == hand: _capture_hand = ""

func update_pointer(hand: String, origin: Vector3, direction: Vector3, valid: bool = true, eye: Vector3 = Vector3.ZERO) -> void:
	if not valid or hand.is_empty() or hand != _capture_hand:
		cancel_pointer(hand)
		return
	var hit := ray_hit(origin, direction)
	if hit.is_empty():
		hide_pointer(hand)
		return
	var visual := _visual(hand)
	(visual.material as StandardMaterial3D).albedo_color = VALID if hit.valid else INVALID
	(visual.ring as Node3D).global_position = (hit.position as Vector3) + Vector3.UP * MARKER_LIFT
	(visual.ring as Node3D).visible = hit.kind != "miss"
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var points: PackedVector3Array = hit.points
	for index in range(1, points.size()):
		var a := points[index - 1]
		var b := points[index]
		var side := (b - a).cross(eye - (a + b) * 0.5).normalized() * 0.008
		if side.length_squared() < 0.000001: side = Vector3.RIGHT * 0.008
		for vertex in [a - side, a + side, b + side, a - side, b + side, b - side]: mesh.surface_add_vertex(vertex)
	mesh.surface_end()
	(visual.arc as MeshInstance3D).mesh = mesh
	(visual.root as Node3D).visible = true

func hide_pointer(hand: String) -> void:
	if _visuals.has(hand): (_visuals[hand].root as Node3D).visible = false

func capture_hand() -> String:
	return _capture_hand

func _visual(hand: String) -> Dictionary:
	if _visuals.has(hand): return _visuals[hand]
	var pointer := Node3D.new()
	pointer.name = "ScenePointer_%s" % hand.validate_node_name()
	pointer.top_level = true
	pointer.visible = false
	add_child(pointer)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = VALID
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var arc := MeshInstance3D.new()
	arc.material_override = material
	arc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pointer.add_child(arc)
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.18
	torus.outer_radius = 0.21
	torus.rings = 24
	torus.ring_segments = 6
	ring.mesh = torus
	ring.material_override = material
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pointer.add_child(ring)
	_visuals[hand] = {"root": pointer, "arc": arc, "ring": ring, "material": material}
	return _visuals[hand]

## Drops any aim in progress; the next stick gesture starts clean.
func suspend() -> void:
	_capture_hand = ""
	_turn_latched = false
	_fly_gesture = ""
	for hand in _visuals: hide_pointer(str(hand))

## Walking: turns in steps on `turn.x`, about-face on `turn.y` < 0. Flying: `stick` forward and
## back travels along the line of sight, a sideways flick turns one step.
func poll_sticks(stick: Vector2, turn: Vector2, delta: float, head: Transform3D, feet: Vector3) -> void:
	if not moving() or not stick.is_finite() or not turn.is_finite() or delta <= 0.0: return
	if mode == FLY:
		# One gesture until the stick is back at centre, so a rolling thumb neither turns nor drifts.
		if stick.length() <= DEADZONE: _fly_gesture = ""
		elif _fly_gesture.is_empty():
			if absf(stick.y) >= absf(stick.x): _fly_gesture = "travel"
			elif absf(stick.x) >= 0.65:
				_fly_gesture = "turn"
				_turn(signf(stick.x) * SNAP_ANGLE, feet)
		if _fly_gesture != "travel": return
		var strength := clampf((absf(stick.y) - DEADZONE) / (1.0 - DEADZONE), 0.0, 1.0) * signf(stick.y)
		_scene.global_position -= (-head.basis.z).normalized() * strength * fly_speed * minf(delta, 0.25)
		return
	if absf(turn.x) <= DEADZONE and turn.y >= -DEADZONE: _turn_latched = false
	elif not _turn_latched and (absf(turn.x) >= 0.65 or turn.y <= -0.65):
		_turn_latched = true
		_turn(PI if absf(turn.x) < 0.65 else signf(turn.x) * SNAP_ANGLE, feet)

## Turning the viewer right is the scene turning left about where they stand.
func _turn(angle: float, feet: Vector3) -> void:
	_scene.global_transform = Transform3D(Basis(Vector3.UP, angle), feet) * Transform3D(Basis.IDENTITY, -feet) * _scene.global_transform
