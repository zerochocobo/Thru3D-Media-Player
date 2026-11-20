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
## The floor search: columns per side, the steepest floor, the tallest step, the room a body needs.
const GRID := 32
const FLOOR_SLOPE_COSINE := 0.7
const FLOOR_STEP := 0.4
const HEADROOM := 1.8
const MIN_FLOOR_EXTENT := 2.5
const CORE_MARGIN := 3.0
## The default screen: looked for straight ahead and a little to each side, kept off what it meets.
const SCREEN_PROBE_ANGLES := [0.0, 0.26, -0.26]
const SCREEN_WALL_GAP := 0.3
const SCREEN_NEAREST := 0.8

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
	var items := Audit.drawables(root)
	var core := _core(items, bounds)
	if not layout.has("spawn"):
		# A place is stood in, in the middle of its widest stretch of floor; anything without one
		# (a single object, a wall, a cliff) is looked at from outside, from its low edge.
		var stand := _stand_point(root, items, core, floor_paths)
		if not stand.is_empty():
			var floor: Vector3 = stand.point
			var toward := _detail_centre(items) - floor
			toward.y = 0.0
			layout.spawn = Transform3D(Basis.looking_at(toward.normalized()) if toward.length() > 0.5 else Basis.IDENTITY, floor)
		else:
			var back := core.size.z * 0.5 + clampf(maxf(core.size.x, core.size.y) * 0.8, 2.0, 40.0)
			var centre := core.get_center()
			layout.spawn = Transform3D(Basis.IDENTITY, Vector3(centre.x, core.position.y, centre.z + back))
			layout.source = "outside"
	if not layout.has("screen"):
		# Straight ahead of the viewer, far enough for the size of the scene.
		var spawn: Transform3D = layout.spawn
		var distance := clampf(core.size.length() * 0.08, 4.0, 14.0)
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

static func _detail_centre(items: Array[Dictionary]) -> Vector3:
	var centre := Vector3.ZERO
	var weight := 0.0
	for item in items:
		centre += (item.bounds as AABB).get_center() * float(item.triangles)
		weight += float(item.triangles)
	return centre / weight if weight > 0.0 else Vector3.ZERO

## The value below which `share` of the weight lies; `pairs` holds [value, weight].
static func _quantile(pairs: Array, share: float) -> float:
	if pairs.is_empty(): return 0.0
	pairs.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var total := 0.0
	for pair in pairs: total += pair[1]
	var passed := 0.0
	for pair in pairs:
		passed += pair[1]
		if passed >= total * share: return pair[0]
	return pairs[-1][0]

## Where the scene's triangles are: its bounds without what a sky dome or a stray far object adds.
static func _core(items: Array[Dictionary], bounds: AABB) -> AABB:
	if items.is_empty(): return bounds
	var low := Vector3.ZERO
	var high := Vector3.ZERO
	for axis in 3:
		var centres: Array = []
		var halves: Array = []
		for item in items:
			var box: AABB = item.bounds
			var weight := maxf(float(item.triangles), 1.0)
			centres.append([box.get_center()[axis], weight])
			halves.append([box.size[axis] * 0.5, weight])
		# Objects reach past their centres by about the size of a typical one; a few steps at least,
		# since the floor between them carries next to none of the triangles.
		var reach := maxf(_quantile(halves, 0.5), CORE_MARGIN)
		low[axis] = maxf(_quantile(centres, 0.02) - reach, bounds.position[axis])
		high[axis] = minf(_quantile(centres, 0.98) + reach, bounds.end[axis])
	return AABB(low, (high - low).max(Vector3.ZERO))

## The middle of the widest connected stretch of floor a viewer can stand on: {point}, or empty.
## Probes a grid of columns over `core`; marked floors, when the scene has any, are the only candidates.
static func _stand_point(root: Node3D, items: Array[Dictionary], core: AABB, floor_paths: Array[NodePath]) -> Dictionary:
	var cell := Vector2(core.size.x, core.size.z) / GRID
	if cell.x <= 0.0 or cell.y <= 0.0: return {}
	var marked := {}
	var probes: Array[Dictionary] = items.duplicate()
	for path in floor_paths:
		var node := root.get_node_or_null(path)
		if not node is MeshInstance3D or node.mesh == null: continue
		marked[node] = true
		# Collider-only walk areas are hidden, so they are not among the drawables.
		if not node.visible: probes.append({"node": node, "mesh": node.mesh, "bounds": Audit.to_root(node, root) * node.get_aabb()})
	var columns: Array = []
	columns.resize(GRID * GRID)
	var top := -INF
	for item in probes: top = maxf(top, (item.bounds as AABB).end.y + 1.0)
	for item in probes:
		var box: AABB = item.bounds
		if not item.node is MeshInstance3D or not item.mesh is ArrayMesh: continue
		var x0 := maxi(ceili((box.position.x - core.position.x) / cell.x - 0.5), 0)
		var x1 := mini(floori((box.end.x - core.position.x) / cell.x - 0.5), GRID - 1)
		var z0 := maxi(ceili((box.position.z - core.position.z) / cell.y - 0.5), 0)
		var z1 := mini(floori((box.end.z - core.position.z) / cell.y - 0.5), GRID - 1)
		if x0 > x1 or z0 > z1: continue
		var indices := 0
		for surface in item.mesh.get_surface_count(): indices += item.mesh.surface_get_array_index_len(surface)
		if indices > MAX_FLOOR_PROBE_INDICES: continue
		var shape: TriangleMesh = item.mesh.generate_triangle_mesh()
		if shape == null or not shape.has_method("intersect_ray"): continue
		var faces := shape.get_faces()
		var to_scene := Audit.to_root(item.node, root)
		var to_mesh := to_scene.affine_inverse()
		var down := (to_mesh.basis * Vector3.DOWN).normalized()
		var candidate: bool = marked.is_empty() or marked.has(item.node)
		for z in range(z0, z1 + 1):
			for x in range(x0, x1 + 1):
				var from := Vector3(core.position.x + (x + 0.5) * cell.x, top, core.position.z + (z + 0.5) * cell.y)
				for attempt in 24:
					var hit: Dictionary = shape.intersect_ray(to_mesh * from, down)
					if hit.is_empty(): break
					var point: Vector3 = to_scene * (hit.position as Vector3)
					# The reported normal always faces the ray; winding tells which side was hit (front faces are clockwise).
					var face := int(hit.face_index) * 3
					var facing := to_scene.basis * (faces[face + 2] - faces[face]).cross(faces[face + 1] - faces[face])
					if columns[z * GRID + x] == null: columns[z * GRID + x] = []
					columns[z * GRID + x].append([point.y, candidate and facing.normalized().y >= FLOOR_SLOPE_COSINE])
					from = point + Vector3.DOWN * 0.01
	# What is left of each column: the heights with a floor underfoot and nothing through the body.
	var floors: Array[PackedFloat32Array] = []
	for index in GRID * GRID:
		var heights := PackedFloat32Array()
		if columns[index] != null:
			for hit in columns[index]:
				if not hit[1] or hit[0] < core.position.y - 0.5 or hit[0] > core.end.y: continue
				var clear := true
				for other in columns[index]:
					if other[0] > hit[0] + 0.3 and other[0] < hit[0] + HEADROOM: clear = false
				for known in heights:
					if absf(known - hit[0]) < 0.05: clear = false
				if clear: heights.append(hit[0])
		floors.append(heights)
	# Neighbouring columns a step apart or less are one stretch of floor.
	var seen := {}
	var stretches: Array[Dictionary] = []
	for index in GRID * GRID:
		for start in floors[index].size():
			if seen.has(index * 32 + start): continue
			seen[index * 32 + start] = true
			var members: Array = [[index, floors[index][start]]]
			var cursor := 0
			var height := 0.0
			while cursor < members.size():
				var at: int = members[cursor][0]
				var y: float = members[cursor][1]
				height += y
				cursor += 1
				for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var x: int = at % GRID + offset.x
					var z: int = at / GRID + offset.y
					if x < 0 or x >= GRID or z < 0 or z >= GRID: continue
					var next: int = z * GRID + x
					for other in floors[next].size():
						if seen.has(next * 32 + other) or absf(floors[next][other] - y) > FLOOR_STEP: continue
						seen[next * 32 + other] = true
						members.append([next, floors[next][other]])
			stretches.append({"members": members, "height": height / members.size()})
	if stretches.is_empty(): return {}
	# Roofs are floors too, and often the widest. What the scene's detail sits on lies below the
	# middle of that detail; of the storeys there, about the same size, the top one.
	var middle: Array = []
	for item in items: middle.append([(item.bounds as AABB).get_center().y, maxf(float(item.triangles), 1.0)])
	var level := _quantile(middle, 0.5) + 1.0
	var largest := 0
	var largest_under := 0
	for stretch in stretches:
		largest = maxi(largest, stretch.members.size())
		if stretch.height <= level: largest_under = maxi(largest_under, stretch.members.size())
	var under := largest_under >= largest * 0.2
	var chosen := {}
	for stretch in stretches:
		if under and (stretch.height > level or stretch.members.size() < largest_under * 0.7): continue
		if not under and stretch.members.size() < largest * 0.7: continue
		if chosen.is_empty() or (stretch.height > chosen.height) == under: chosen = stretch
	var inside := {}
	var centre := Vector2.ZERO
	var low := Vector2i(GRID, GRID)
	var high := Vector2i(-1, -1)
	for member in chosen.members:
		var at := Vector2i(member[0] % GRID, member[0] / GRID)
		inside[at] = true
		centre += Vector2(at)
		low = low.min(at)
		high = high.max(at)
	centre /= chosen.members.size()
	# Too little floor to be a place: a pedestal, a tabletop, the top of a single object.
	var extent := Vector2(high - low + Vector2i.ONE) * cell
	if minf(extent.x, extent.y) < MIN_FLOOR_EXTENT: return {}
	if minf(core.size.x, core.size.z) < ROOM_SIZE and chosen.height - core.position.y > core.size.y * 0.5: return {}
	var best := INF
	var point := Vector3.ZERO
	for member in chosen.members:
		var at := Vector2i(member[0] % GRID, member[0] / GRID)
		var score := Vector2(at).distance_squared_to(centre)
		# Away from the edge of the floor when there is such a spot.
		for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if not inside.has(at + offset): score += GRID * GRID * 4.0
		if score < best:
			best = score
			point = Vector3(core.position.x + (at.x + 0.5) * cell.x, member[1], core.position.z + (at.y + 0.5) * cell.y)
	return {"point": point}

## The meshes of `root` that the default screen's probe from `eye` along `heading` may meet,
## as plain data a worker can test (see free_ahead).
static func probe_jobs(root: Node3D, eye: Vector3, heading: Basis, reach: float) -> Array[Dictionary]:
	var span := AABB(eye, Vector3.ZERO)
	for angle in SCREEN_PROBE_ANGLES: span = span.expand(eye + Basis(Vector3.UP, angle) * -heading.z * reach)
	span = span.grow(0.05)
	var jobs: Array[Dictionary] = []
	var to_root := root.global_transform.affine_inverse()
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = (node as MeshInstance3D).mesh
		if mesh == null or not (node as MeshInstance3D).is_visible_in_tree(): continue
		var to_scene := to_root * (node as Node3D).global_transform
		var bounds: AABB = to_scene * mesh.get_aabb()
		if not bounds.intersects(span): continue
		# Imported meshes are ArrayMeshes; what is too big to hold twice is left out.
		if mesh is ArrayMesh:
			var indices := 0
			for surface in mesh.get_surface_count():
				var length: int = mesh.surface_get_array_index_len(surface)
				indices += length if length > 0 else mesh.surface_get_array_len(surface)
			if indices <= 0 or indices > MAX_FLOOR_PROBE_INDICES: continue
		jobs.append({"mesh": mesh, "to_scene": to_scene, "to_mesh": to_scene.affine_inverse(), "bounds": bounds})
	return jobs

## How far ahead of `eye` the wall is, measured along `heading`'s forward; `reach` when nothing is
## met. Of the three probes the middle distance counts, so a lamp or a pillar in one of them does
## not pull the screen up to the face. Builds triangle shapes, so it belongs on a worker thread.
static func free_ahead(jobs: Array[Dictionary], eye: Vector3, heading: Basis, reach: float) -> float:
	var forward := -heading.z
	var ends: Array[Vector3] = []
	var nearest: Array[float] = []
	for angle in SCREEN_PROBE_ANGLES:
		ends.append(eye + Basis(Vector3.UP, angle) * forward * reach / cos(angle))
		nearest.append(reach)
	for job in jobs:
		var shape: TriangleMesh = null
		for probe in ends.size():
			if not (job.bounds as AABB).intersects(AABB(eye, Vector3.ZERO).expand(ends[probe]).grow(0.01)): continue
			# Built here and dropped after: Mesh.generate_triangle_mesh would keep a copy as long as the scene.
			if shape == null:
				shape = TriangleMesh.new()
				if not shape.create_from_faces(_faces(job.mesh)): break
			var hit: Dictionary = shape.intersect_segment(job.to_mesh * eye, job.to_mesh * ends[probe])
			if not hit.is_empty(): nearest[probe] = minf(nearest[probe], ((job.to_scene as Transform3D) * (hit.position as Vector3) - eye).dot(forward))
	nearest.sort()
	return nearest[nearest.size() / 2]

## The triangles of a mesh, three corners each.
static func _faces(mesh: Mesh) -> PackedVector3Array:
	var faces := PackedVector3Array()
	for surface in mesh.get_surface_count():
		if mesh is ArrayMesh and (mesh as ArrayMesh).surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES: continue
		var arrays := mesh.surface_get_arrays(surface)
		var corners: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var order: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if order.is_empty():
			faces.append_array(corners.slice(0, corners.size() - corners.size() % 3))
			continue
		var start := faces.size()
		faces.resize(start + order.size() - order.size() % 3)
		for index in faces.size() - start: faces[start + index] = corners[order[index]]
	return faces

## Where the screen stands by default, `free` ahead of an eye at `eye` on a floor at `floor`:
## the middle of its bottom edge (as Library.screen_pin keeps it), facing back along `heading`.
## The viewer's usual `distance` when the room allows it, else just short of the wall.
static func default_screen(eye: Vector3, floor: float, heading: Basis, distance: float, free: float, height: float) -> Transform3D:
	var away := clampf(minf(distance, free - SCREEN_WALL_GAP), SCREEN_NEAREST, maxf(distance, SCREEN_NEAREST))
	var basis := heading.orthonormalized()
	var at := eye - basis.z * away
	at.y = maxf(eye.y - height * 0.5, floor)
	return Transform3D(basis, at)
