class_name CinemaBlueprint
extends RefCounted
## Reproducible, metre-scaled giant-screen auditorium prototype.
## All surfaces are combined by material, with simple baked vertex shading.

const SCREEN_WIDTH := 32.0
const SCREEN_HEIGHT := SCREEN_WIDTH / 1.43
const SCREEN_BOTTOM := 1.2
const SCREEN_Z := -4.0
const ROOM_HALF_WIDTH := 18.0
const ROOM_FRONT := -5.0
const ROOM_BACK := 38.0
const ROOM_HEIGHT := 26.0
const WALL_MARGIN := 0.4
const ROOM_DEPTH := ROOM_BACK - ROOM_FRONT
const ROOM_CENTRE_Z := (ROOM_FRONT + ROOM_BACK) * 0.5
const ROW_COUNT := 18
const COLUMN_COUNT := 30
const FIRST_ROW_Z := 7.75
const ROW_PITCH := 1.4
const ROW_RISER := 0.9
const STEPS_PER_ROW := 6
const STAIR_TREAD := ROW_PITCH / STEPS_PER_ROW
const STAIR_RISER := ROW_RISER / STEPS_PER_ROW
const SEAT_PITCH := 0.8
const SEAT_Z_OFFSET := -0.25
const SEAT_EXIT_Z_OFFSET := 0.425
const SEATED_EYE_HEIGHT := 1.2
const PLATFORM_HALF_WIDTH := 12.4
const AISLE_OUTER_X := 14.8
const RAIL_X := 15.4
const SOURCE_VERSION := 2

static func manifest() -> Dictionary:
	var seats: Array = []
	var walkable: Array = []
	var colliders: Array = []
	var first_edge := FIRST_ROW_Z - ROW_PITCH * 0.5
	var rear_edge := first_edge + ROW_COUNT * ROW_PITCH
	# Extents describe floor support; adjoining rectangles share their boundary.
	walkable.append(_floor("front", -ROOM_HALF_WIDTH + WALL_MARGIN, SCREEN_Z + 0.3,
		ROOM_HALF_WIDTH - WALL_MARGIN, first_edge, 0.0))
	for row in range(ROW_COUNT):
		var z := FIRST_ROW_Z + row * ROW_PITCH
		var seat_z := z + SEAT_Z_OFFSET
		var level := (row + 1) * ROW_RISER
		walkable.append(_floor("row_%02d" % (row + 1), -PLATFORM_HALF_WIDTH, z - ROW_PITCH * 0.5,
			PLATFORM_HALF_WIDTH, z + ROW_PITCH * 0.5, level))
		for column in range(COLUMN_COUNT):
			var x := (column - (COLUMN_COUNT - 1) * 0.5) * SEAT_PITCH
			var id := "%s%02d" % [String.chr(65 + row), column + 1]
			seats.append({"id": id, "label": id, "row": row + 1, "column": column + 1,
				"eye_position": [x, level + SEATED_EYE_HEIGHT, seat_z - 0.10], "yaw": 0.0,
				"exit_position": [x, level, z + SEAT_EXIT_Z_OFFSET]})
			# Seat backs and cushions block free walking; selecting a seat is explicit.
			colliders.append(_box_bounds("seat_%s_back" % id, Vector3(x - 0.34, level + 0.5, seat_z + 0.13),
				Vector3(x + 0.34, level + 1.35, seat_z + 0.30)))
			colliders.append(_box_bounds("seat_%s_base" % id, Vector3(x - 0.35, level, seat_z - 0.43),
				Vector3(x + 0.35, level + 0.77, seat_z + 0.25)))
		for step in range(STEPS_PER_ROW):
			var start_z := z - ROW_PITCH * 0.5 + step * STAIR_TREAD
			var top := (row * STEPS_PER_ROW + step + 1) * STAIR_RISER
			walkable.append(_floor("stair_left_%02d_%d" % [row + 1, step], -AISLE_OUTER_X, start_z,
				-PLATFORM_HALF_WIDTH, start_z + STAIR_TREAD, top))
			walkable.append(_floor("stair_right_%02d_%d" % [row + 1, step], PLATFORM_HALF_WIDTH, start_z,
				AISLE_OUTER_X, start_z + STAIR_TREAD, top))
	walkable.append(_floor("rear", -ROOM_HALF_WIDTH + WALL_MARGIN, rear_edge,
		ROOM_HALF_WIDTH - WALL_MARGIN, ROOM_BACK - WALL_MARGIN, ROW_COUNT * ROW_RISER))
	# Outer service aisles follow the same small steps and provide room to turn.
	for side in [-1.0, 1.0]:
		for step in range(ROW_COUNT * STEPS_PER_ROW):
			var start_z := first_edge + step * STAIR_TREAD
			var inner_x := AISLE_OUTER_X if side > 0 else -ROOM_HALF_WIDTH + WALL_MARGIN
			var outer_x := ROOM_HALF_WIDTH - WALL_MARGIN if side > 0 else -AISLE_OUTER_X
			walkable.append(_floor("outer_%s_%02d" % ["right" if side > 0 else "left", step],
				inner_x, start_z, outer_x, start_z + STAIR_TREAD, (step + 1) * STAIR_RISER))
			# Segmented AABBs follow the sloped handrail without a triangle collider.
			var floor_y := (step + 1) * STAIR_RISER
			colliders.append(_box_bounds("rail_%s_%02d" % ["right" if side > 0 else "left", step],
				Vector3(side * RAIL_X - 0.045, floor_y + 0.88, start_z),
				Vector3(side * RAIL_X + 0.045, floor_y + 1.24, start_z + STAIR_TREAD)))
	for bounds in [
		_box_bounds("wall_left", Vector3(-ROOM_HALF_WIDTH - 0.3, 0, ROOM_FRONT - 0.3), Vector3(-ROOM_HALF_WIDTH + WALL_MARGIN, ROOM_HEIGHT, ROOM_BACK + 0.3)),
		_box_bounds("wall_right", Vector3(ROOM_HALF_WIDTH - WALL_MARGIN, 0, ROOM_FRONT - 0.3), Vector3(ROOM_HALF_WIDTH + 0.3, ROOM_HEIGHT, ROOM_BACK + 0.3)),
		_box_bounds("wall_front", Vector3(-ROOM_HALF_WIDTH - 0.3, 0, ROOM_FRONT - 0.3), Vector3(ROOM_HALF_WIDTH + 0.3, ROOM_HEIGHT, SCREEN_Z + 0.3)),
		_box_bounds("wall_rear", Vector3(-ROOM_HALF_WIDTH - 0.3, 0, ROOM_BACK - WALL_MARGIN), Vector3(ROOM_HALF_WIDTH + 0.3, ROOM_HEIGHT, ROOM_BACK + 0.3))]:
		colliders.append(bounds)
	var default_seat: Dictionary = seats[9 * COLUMN_COUNT + 14]
	return {"schema_version": 1, "id": "grand_cinema", "name": "Grand Cinema", "units": "metres",
		"source_version": SOURCE_VERSION, "model": "cinema.glb",
		"screen": {"position": [0.0, SCREEN_BOTTOM + SCREEN_HEIGHT * 0.5, SCREEN_Z],
			"width": SCREEN_WIDTH, "height": SCREEN_HEIGHT, "aspect_ratio": 1.43, "yaw": 0.0},
		"room": {"width": ROOM_HALF_WIDTH * 2.0, "depth": ROOM_DEPTH, "height": ROOM_HEIGHT},
		"seats": seats, "default_seat": default_seat.id, "spawn": {"seat_id": default_seat.id, "eye_position": default_seat.eye_position,
			"yaw": 0.0}, "walkable": walkable, "colliders": colliders,
		"design": {"row_count": ROW_COUNT, "seats_per_row": COLUMN_COUNT, "row_pitch": ROW_PITCH,
			"row_riser": ROW_RISER, "stair_riser": STAIR_RISER, "stair_tread": STAIR_TREAD,
			"steps_per_row": STEPS_PER_ROW, "side_aisle_width": AISLE_OUTER_X - PLATFORM_HALF_WIDTH,
			"seat_pitch": SEAT_PITCH, "seat_z_offset": SEAT_Z_OFFSET,
			"clear_row_passage": ROW_PITCH * 0.5 - (SEAT_Z_OFFSET + 0.30),
			"rake_degrees": rad_to_deg(atan(ROW_RISER / ROW_PITCH)), "seated_eye_height": SEATED_EYE_HEIGHT,
			"reference": "Original GT-scale 1.43 auditorium study; independent prototype, not a certified venue."}}

static func build() -> Node3D:
	var root := Node3D.new()
	root.name = "GrandCinema"
	var batches := {}
	for entry in [
		["Shell", Color("171e2b")], ["Carpet", Color("192535")], ["Acoustic", Color("253b52")],
		["SeatFabric", Color("702e39")], ["SeatInset", Color("8a3b46")], ["SeatBase", Color("20242d")],
		["Metal", Color("354553")], ["ScreenSurround", Color("080d14")],
		["WarmGuide", Color("b98c52")], ["ExitGlass", Color("285548")]]:
		batches[entry[0]] = {"color": entry[1], "vertices": PackedVector3Array(),
			"normals": PackedVector3Array(), "colors": PackedColorArray(), "indices": PackedInt32Array()}
	_build_shell(batches)
	_build_seating(batches)
	_build_details(batches)
	var mesh := ArrayMesh.new()
	for key: String in batches:
		var batch: Dictionary = batches[key]
		if batch.vertices.is_empty():
			continue
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = batch.vertices
		arrays[Mesh.ARRAY_NORMAL] = batch.normals
		arrays[Mesh.ARRAY_COLOR] = batch.colors
		arrays[Mesh.ARRAY_INDEX] = batch.indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var material := StandardMaterial3D.new()
		material.resource_name = key
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.vertex_color_use_as_albedo = true
		material.albedo_color = batch.color
		material.roughness = 0.95
		mesh.surface_set_material(mesh.get_surface_count() - 1, material)
	var instance := MeshInstance3D.new()
	instance.name = "AuditoriumCombined"
	instance.mesh = mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(instance)
	instance.owner = root
	return root

static func _floor(id: String, x0: float, z0: float, x1: float, z1: float, height: float) -> Dictionary:
	return {"id": id, "min": [x0, height, z0], "max": [x1, height, z1], "height": height}

static func _box_bounds(id: String, minimum: Vector3, maximum: Vector3) -> Dictionary:
	return {"id": id, "min": [minimum.x, minimum.y, minimum.z], "max": [maximum.x, maximum.y, maximum.z]}

static func _build_shell(batches: Dictionary) -> void:
	_box(batches.Shell, Vector3(0, -0.2, ROOM_CENTRE_Z), Vector3(ROOM_HALF_WIDTH * 2, 0.4, ROOM_DEPTH))
	for side in [-1.0, 1.0]:
		_box(batches.Shell, Vector3(side * (ROOM_HALF_WIDTH + 0.12), ROOM_HEIGHT * 0.5, ROOM_CENTRE_Z), Vector3(0.24, ROOM_HEIGHT, ROOM_DEPTH))
	for z in [ROOM_FRONT - 0.12, ROOM_BACK + 0.12]:
		_box(batches.Shell, Vector3(0, ROOM_HEIGHT * 0.5, z), Vector3(ROOM_HALF_WIDTH * 2, ROOM_HEIGHT, 0.24))
	_box(batches.Shell, Vector3(0, ROOM_HEIGHT + 0.12, ROOM_CENTRE_Z), Vector3(ROOM_HALF_WIDTH * 2, 0.24, ROOM_DEPTH))
	var first_edge := FIRST_ROW_Z - ROW_PITCH * 0.5
	var front_start := SCREEN_Z + 0.3
	_box(batches.Carpet, Vector3(0, -0.025, (front_start + first_edge) * 0.5), Vector3((ROOM_HALF_WIDTH - 0.1) * 2, 0.05, first_edge - front_start))
	# A deliberately recessed black surface leaves the live video plane unobstructed.
	var screen_y := SCREEN_BOTTOM + SCREEN_HEIGHT * 0.5
	_box(batches.ScreenSurround, Vector3(0, screen_y, SCREEN_Z - 0.13), Vector3(SCREEN_WIDTH + 1.2, SCREEN_HEIGHT + 1.2, 0.12))
	for side in [-1.0, 1.0]:
		_box(batches.Metal, Vector3(side * (SCREEN_WIDTH * 0.5 + 0.19), screen_y, SCREEN_Z - 0.025), Vector3(0.20, SCREEN_HEIGHT + 0.42, 0.14))
		_box(batches.WarmGuide, Vector3(side * (SCREEN_WIDTH * 0.5 + 0.34), screen_y, SCREEN_Z - 0.015), Vector3(0.035, SCREEN_HEIGHT + 0.40, 0.07))
	for y in [SCREEN_BOTTOM - 0.16, SCREEN_BOTTOM + SCREEN_HEIGHT + 0.16]:
		_box(batches.Metal, Vector3(0, y, SCREEN_Z - 0.025), Vector3(SCREEN_WIDTH + 0.57, 0.20, 0.14))
	# Each broad seat platform and stair is one visual solid; physics uses the manifest.
	for row in range(ROW_COUNT):
		var z := FIRST_ROW_Z + row * ROW_PITCH
		var level := (row + 1) * ROW_RISER
		_box(batches.Carpet, Vector3(0, level * 0.5, z), Vector3(PLATFORM_HALF_WIDTH * 2, level, ROW_PITCH))
		for step in range(STEPS_PER_ROW):
			var top := (row * STEPS_PER_ROW + step + 1) * STAIR_RISER
			var step_z := z - ROW_PITCH * 0.5 + (step + 0.5) * STAIR_TREAD
			for side in [-1.0, 1.0]:
				var outer_edge := ROOM_HALF_WIDTH - 0.1
				_box(batches.Carpet, Vector3(side * (PLATFORM_HALF_WIDTH + outer_edge) * 0.5, top * 0.5, step_z), Vector3(outer_edge - PLATFORM_HALF_WIDTH, top, STAIR_TREAD))
				_box(batches.WarmGuide, Vector3(side * (PLATFORM_HALF_WIDTH + AISLE_OUTER_X) * 0.5, top + 0.008, step_z - STAIR_TREAD * 0.5 + 0.035), Vector3(AISLE_OUTER_X - PLATFORM_HALF_WIDTH - 0.4, 0.016, 0.045))
	var rear_start := FIRST_ROW_Z + (ROW_COUNT - 0.5) * ROW_PITCH
	var top := ROW_COUNT * ROW_RISER
	_box(batches.Carpet, Vector3(0, top * 0.5, (rear_start + ROOM_BACK) * 0.5), Vector3((ROOM_HALF_WIDTH - 0.1) * 2, top, ROOM_BACK - rear_start))

static func _build_seating(batches: Dictionary) -> void:
	for row in range(ROW_COUNT):
		var z := FIRST_ROW_Z + row * ROW_PITCH + SEAT_Z_OFFSET
		var level := (row + 1) * ROW_RISER
		for column in range(COLUMN_COUNT):
			var x := (column - (COLUMN_COUNT - 1) * 0.5) * SEAT_PITCH
			_box(batches.SeatBase, Vector3(x, level + 0.21, z - 0.03), Vector3(0.36, 0.42, 0.44))
			# Rounded eight-corner silhouettes remain inexpensive and readable at a distance.
			var cushion := Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(x, level + 0.49, z - 0.10))
			_chamfered_prism(batches.SeatFabric, Vector2(0.64, 0.64), 0.16, 0.07, cushion)
			_chamfered_prism(batches.SeatFabric, Vector2(0.64, 0.89), 0.16, 0.07,
				Transform3D(Basis.IDENTITY, Vector3(x, level + 0.905, z + 0.21)))
			_chamfered_prism(batches.SeatInset, Vector2(0.50, 0.30), 0.018, 0.05,
				Transform3D(Basis.IDENTITY, Vector3(x, level + 1.16, z + 0.118)))
			for arm in [-1.0, 1.0]:
				_box(batches.SeatBase, Vector3(x + arm * 0.355, level + 0.68, z - 0.07), Vector3(0.075, 0.11, 0.61))
				_box(batches.Metal, Vector3(x + arm * 0.355, level + 0.59, z + 0.10), Vector3(0.045, 0.18, 0.055))

static func _build_details(batches: Dictionary) -> void:
	# Large modules communicate the room volume without textures or tiny geometry.
	var wall_bays := 15
	var wall_bay_pitch := ROOM_DEPTH / wall_bays
	var wall_bands := 5
	var wall_band_pitch := ROOM_HEIGHT / wall_bands
	var rear_floor := ROW_COUNT * ROW_RISER
	var door_x := (RAIL_X + ROOM_HALF_WIDTH - WALL_MARGIN) * 0.5
	for side in [-1.0, 1.0]:
		for bay in range(wall_bays):
			var z := ROOM_FRONT + (bay + 0.5) * wall_bay_pitch
			for band in range(wall_bands):
				var y := (band + 0.5) * wall_band_pitch
				_box(batches.Acoustic, Vector3(side * (ROOM_HALF_WIDTH - 0.13), y, z), Vector3(0.15, wall_band_pitch - 0.6, wall_bay_pitch - 0.38))
			_box(batches.Metal, Vector3(side * (ROOM_HALF_WIDTH - 0.28), ROOM_HEIGHT * 0.5, z + wall_bay_pitch * 0.5 - 0.06), Vector3(0.14, ROOM_HEIGHT - 1.0, 0.09))
		for band in range(wall_bands):
			_box(batches.Metal, Vector3(side * (ROOM_HALF_WIDTH - 0.33), 0.25 + band * wall_band_pitch, ROOM_CENTRE_Z), Vector3(0.11, 0.10, ROOM_DEPTH - 0.4))
		# Side railings keep a visual edge above the wide stairs; no aisle obstruction.
		for row in range(ROW_COUNT):
			var z := FIRST_ROW_Z + row * ROW_PITCH
			var level := (row + 1) * ROW_RISER
			_box(batches.Metal, Vector3(side * RAIL_X, level + 0.54, z), Vector3(0.055, 1.08, 0.055))
		var rail_start := Vector3(side * RAIL_X, STAIR_RISER + 1.12, FIRST_ROW_Z - ROW_PITCH * 0.5)
		var rail_end := Vector3(side * RAIL_X, rear_floor + 1.12, FIRST_ROW_Z + (ROW_COUNT - 0.5) * ROW_PITCH)
		_beam(batches.Metal, rail_start, rail_end, 0.065)
		# Recessed rear door and an abstract green locator: no decorative UI prose.
		_box(batches.ScreenSurround, Vector3(side * door_x, rear_floor + 1.45, ROOM_BACK - 0.07), Vector3(2.0, 2.9, 0.08))
		_box(batches.Metal, Vector3(side * door_x, rear_floor + 1.40, ROOM_BACK - 0.16), Vector3(0.045, 2.7, 0.05))
		_box(batches.ExitGlass, Vector3(side * door_x, rear_floor + 3.13, ROOM_BACK - 0.18), Vector3(0.78, 0.25, 0.06))
		_box(batches.WarmGuide, Vector3(side * door_x, rear_floor + 0.02, ROOM_BACK - 0.25), Vector3(2.15, 0.025, 0.045))
	var ceiling_bays := 9
	var ceiling_pitch := ROOM_DEPTH / ceiling_bays
	for bay in range(ceiling_bays):
		var z := ROOM_FRONT + (bay + 0.5) * ceiling_pitch
		_box(batches.Metal, Vector3(0, ROOM_HEIGHT - 0.25, z - ceiling_pitch * 0.5 + 0.2), Vector3(ROOM_HALF_WIDTH * 2 - 0.3, 0.35, 0.20))
		for side in [-1.0, 1.0]:
			_box(batches.Acoustic, Vector3(side * ROOM_HALF_WIDTH * 0.5, ROOM_HEIGHT - 0.43, z), Vector3(ROOM_HALF_WIDTH - 1.2, 0.12, ceiling_pitch - 1.7))
			_box(batches.WarmGuide, Vector3(side * RAIL_X, ROOM_HEIGHT - 0.48, z), Vector3(0.05, 0.035, 1.8))
	for x in [-ROOM_HALF_WIDTH * 0.5, 0.0, ROOM_HALF_WIDTH * 0.5]:
		_box(batches.ScreenSurround, Vector3(x, ROOM_HEIGHT - 2.0, ROOM_BACK - 0.14), Vector3(1.9, 0.75, 0.10))
		_box(batches.Acoustic, Vector3(x, rear_floor + 3.0, ROOM_BACK - 0.14), Vector3(5.3, 4.6, 0.13))

static func _box(batch: Dictionary, centre: Vector3, size: Vector3, basis: Basis = Basis.IDENTITY) -> void:
	var half := size * 0.5
	var corners: Array[Vector3] = [Vector3(-half.x, -half.y, -half.z), Vector3(half.x, -half.y, -half.z),
		Vector3(half.x, half.y, -half.z), Vector3(-half.x, half.y, -half.z),
		Vector3(-half.x, -half.y, half.z), Vector3(half.x, -half.y, half.z),
		Vector3(half.x, half.y, half.z), Vector3(-half.x, half.y, half.z)]
	for face in [[0, 3, 2, 1], [5, 6, 7, 4], [4, 7, 3, 0], [1, 2, 6, 5], [3, 7, 6, 2], [4, 0, 1, 5]]:
		var points: Array[Vector3] = []
		for index in face:
			points.append(centre + basis * corners[index])
		_quad(batch, points[0], points[1], points[2], points[3])

static func _beam(batch: Dictionary, from: Vector3, to: Vector3, width: float) -> void:
	var direction := (to - from).normalized()
	var side := direction.cross(Vector3.RIGHT).normalized()
	var basis := Basis(side, direction, side.cross(direction)).orthonormalized()
	_box(batch, (from + to) * 0.5, Vector3(width, from.distance_to(to), width), basis)

static func _chamfered_prism(batch: Dictionary, size: Vector2, depth: float, chamfer: float, transform: Transform3D) -> void:
	var x := size.x * 0.5
	var y := size.y * 0.5
	var polygon: Array[Vector2] = [Vector2(-x + chamfer, -y), Vector2(x - chamfer, -y),
		Vector2(x, -y + chamfer), Vector2(x, y - chamfer), Vector2(x - chamfer, y),
		Vector2(-x + chamfer, y), Vector2(-x, y - chamfer), Vector2(-x, -y + chamfer)]
	for index in range(polygon.size()):
		var a := polygon[index]
		var b := polygon[(index + 1) % polygon.size()]
		_quad(batch, transform * Vector3(a.x, a.y, -depth * 0.5), transform * Vector3(b.x, b.y, -depth * 0.5),
			transform * Vector3(b.x, b.y, depth * 0.5), transform * Vector3(a.x, a.y, depth * 0.5))
	for sign_z in [-1.0, 1.0]:
		for index in range(1, polygon.size() - 1):
			var a := transform * Vector3(polygon[0].x, polygon[0].y, sign_z * depth * 0.5)
			var b := transform * Vector3(polygon[index].x, polygon[index].y, sign_z * depth * 0.5)
			var c := transform * Vector3(polygon[index + 1].x, polygon[index + 1].y, sign_z * depth * 0.5)
			_triangle(batch, a, b, c) if sign_z > 0 else _triangle(batch, a, c, b)

static func _quad(batch: Dictionary, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	var normal := (b - a).cross(c - a).normalized()
	var start: int = batch.vertices.size()
	for point in [a, b, c, d]:
		batch.vertices.append(point)
		batch.normals.append(normal)
		batch.colors.append(_face_color(normal))
	# Godot front faces use clockwise winding; normals above are the outward face.
	for index in [0, 2, 1, 0, 3, 2]:
		batch.indices.append(start + index)

static func _triangle(batch: Dictionary, a: Vector3, b: Vector3, c: Vector3) -> void:
	var normal := (b - a).cross(c - a).normalized()
	var start: int = batch.vertices.size()
	for point in [a, b, c]:
		batch.vertices.append(point)
		batch.normals.append(normal)
		batch.colors.append(_face_color(normal))
	for index in [0, 2, 1]:
		batch.indices.append(start + index)

static func _face_color(normal: Vector3) -> Color:
	var brightness := 0.61 + maxf(normal.dot(Vector3(-0.28, 0.87, -0.40).normalized()), 0.0) * 0.39
	return Color(brightness, brightness, brightness, 1.0)
