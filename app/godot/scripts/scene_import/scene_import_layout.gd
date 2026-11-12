extends RefCounted
## Where the viewer stands and where the screen goes. Sources, in priority order:
## sidecar JSON, marker nodes (thru3d_spawn / thru3d_screen / thru3d_floor), geometry fallback.
const Audit := preload("res://scripts/scene_import/scene_import_audit.gd")
const SPAWN := "thru3d_spawn"
const SCREEN := "thru3d_screen"
const FLOOR := "thru3d_floor"
const EYE_HEIGHT := 1.6
const MAX_COORDINATE := 100000.0
const MAX_FLOOR_PROBE_INDICES := 3000000
const ROOM_SIZE := 6.0

static func resolve(root: Node3D, bounds: AABB, sidecar: Dictionary = {}) -> Dictionary:
	var floor_paths: Array[NodePath] = []
	var layout := {"source": "fallback", "floor": floor_paths}
	var spawn_marker := _marker(root, SPAWN)
	var screen_marker := _marker(root, SCREEN)
	for node in _markers(root, FLOOR): floor_paths.append(root.get_path_to(node))
	if spawn_marker:
		layout.spawn = Audit.to_root(spawn_marker, root).orthonormalized()
		layout.source = "marker"
	if screen_marker:
		var placed := Audit.to_root(screen_marker, root)
		layout.screen = placed.orthonormalized()
		layout.screen_width = clampf(placed.basis.x.length(), 0.5, 200.0)
	var position: Variant = _vector(sidecar.get("spawn"))
	if position != null:
		layout.spawn = Transform3D(Basis(Vector3.UP, _number(sidecar.get("spawn_yaw"), 0.0)), position)
		layout.source = "sidecar"
	var screen: Variant = sidecar.get("screen")
	if screen is Dictionary and _vector(screen.get("position")) != null:
		layout.screen = Transform3D(Basis(Vector3.UP, _number(screen.get("yaw"), 0.0)), _vector(screen.get("position")))
		layout.screen_width = clampf(_number(screen.get("width"), 8.0), 0.5, 200.0)
	if not layout.has("spawn"):
		# A place with a floor under its middle is stood in; anything else (a single object,
		# a wall, a cliff) is looked at from outside, from its low edge.
		var floor := _floor_point(root, bounds)
		if is_finite(floor.y) and minf(bounds.size.x, bounds.size.z) >= ROOM_SIZE:
			# Bounds are often stretched by stray geometry; look toward where the detail is.
			var toward := _detail_centre(root) - floor
			toward.y = 0.0
			layout.spawn = Transform3D(Basis.looking_at(toward.normalized()) if toward.length() > 0.5 else Basis.IDENTITY, floor)
		else:
			var back := bounds.size.z * 0.5 + clampf(maxf(bounds.size.x, bounds.size.y) * 0.8, 2.0, 40.0)
			var centre := bounds.get_center()
			layout.spawn = Transform3D(Basis.IDENTITY, Vector3(centre.x, bounds.position.y, centre.z + back))
			layout.source = "outside"
	if not layout.has("screen"):
		# Straight ahead of the viewer, far enough for the size of the scene.
		var spawn: Transform3D = layout.spawn
		var distance := clampf(bounds.size.length() * 0.08, 4.0, 14.0)
		var centre := spawn.origin - spawn.basis.z * distance + Vector3.UP * (EYE_HEIGHT + 0.6)
		layout.screen = Transform3D(spawn.basis, centre)
		layout.screen_width = distance * 1.6
	return layout

static func _markers(root: Node, prefix: String) -> Array[Node3D]:
	var found: Array[Node3D] = []
	for node in root.find_children("*", "Node3D", true, false):
		if String(node.name).to_lower().begins_with(prefix): found.append(node)
	return found

static func _marker(root: Node, prefix: String) -> Node3D:
	var found := _markers(root, prefix)
	return found[0] if not found.is_empty() else null

static func _number(value: Variant, fallback: float) -> float:
	if (value is float or value is int) and is_finite(value) and absf(value) <= MAX_COORDINATE: return float(value)
	return fallback

static func _vector(value: Variant) -> Variant:
	if not value is Array or value.size() != 3: return null
	for item in value:
		if not (item is float or item is int) or not is_finite(item) or absf(item) > MAX_COORDINATE: return null
	return Vector3(value[0], value[1], value[2])

static func _detail_centre(root: Node3D) -> Vector3:
	var centre := Vector3.ZERO
	var weight := 0.0
	for item in Audit.drawables(root):
		centre += (item.bounds as AABB).get_center() * float(item.triangles)
		weight += float(item.triangles)
	return centre / weight if weight > 0.0 else Vector3.ZERO

## Lowest upward-facing surface under the middle of the scene; y is INF when nothing is hit.
static func _floor_point(root: Node3D, bounds: AABB) -> Vector3:
	var centre := bounds.get_center()
	var top := bounds.end.y + 1.0
	var best := INF
	for item in Audit.drawables(root):
		var box: AABB = item.bounds
		if not item.node is MeshInstance3D or not item.mesh is ArrayMesh: continue
		if centre.x < box.position.x or centre.x > box.end.x or centre.z < box.position.z or centre.z > box.end.z: continue
		var indices := 0
		for surface in item.mesh.get_surface_count(): indices += item.mesh.surface_get_array_index_len(surface)
		if indices > MAX_FLOOR_PROBE_INDICES: continue
		var shape: TriangleMesh = item.mesh.generate_triangle_mesh()
		if shape == null or not shape.has_method("intersect_ray"): continue
		var faces := shape.get_faces()
		var to_scene := Audit.to_root(item.node, root)
		var to_mesh := to_scene.affine_inverse()
		var from := Vector3(centre.x, top, centre.z)
		for attempt in 24:
			var hit: Dictionary = shape.intersect_ray(to_mesh * from, (to_mesh.basis * Vector3.DOWN).normalized())
			if hit.is_empty(): break
			var point: Vector3 = to_scene * (hit.position as Vector3)
			# The reported normal always faces the ray; winding tells which side was hit (front faces are clockwise).
			var face := int(hit.face_index) * 3
			var facing := to_scene.basis * (faces[face + 2] - faces[face]).cross(faces[face + 1] - faces[face])
			if facing.normalized().y > 0.5: best = minf(best, point.y)
			from = point + Vector3.DOWN * 0.01
	return Vector3(centre.x, best, centre.z)
