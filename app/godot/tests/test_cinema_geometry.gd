extends SceneTree

const Blueprint := preload("res://scripts/environments/cinema_blueprint.gd")
const MODEL := "res://environments/grand_cinema/cinema.glb"
var checks := 0
var failures: Array[String] = []

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)

func vector(values: Array) -> Vector3:
	return Vector3(float(values[0]), float(values[1]), float(values[2]))

func _initialize() -> void:
	var data := Blueprint.manifest()
	check(data.schema_version == 1 and data.units == "metres", "Manifest declares its schema and metre units")
	check(data.seats.size() == 540 and data.design.row_count == 18 and data.design.seats_per_row == 30,
		"GT auditorium has eighteen rows and thirty individually selectable seats per row")
	check(is_equal_approx(data.screen.width / data.screen.height, 1.43), "The active screen is 1.43:1")
	check(is_equal_approx(data.screen.width, 32.0) and data.screen.height > 22.3 and data.screen.height < 22.5,
		"GT active screen measures 32 metres wide and about 22.38 metres high")
	check(data.room.width == 36.0 and data.room.depth == 43.0 and data.room.height == 26.0,
		"Architecture encloses a 36 by 43 by 26 metre hall")
	check(is_equal_approx(float(data.screen.position[1]) - float(data.screen.height) * 0.5, 1.2)
		and data.room.height - (float(data.screen.position[1]) + float(data.screen.height) * 0.5) < 2.5,
		"Tall screen starts near the floor and reaches close to the ceiling")
	check(data.default_seat == "J15", "Default seat is the tenth row, centre-left")
	var preferred := vector(_seat(data, "J15").eye_position)
	var last := vector(_seat(data, "R15").eye_position)
	check(preferred.is_equal_approx(Vector3(-0.4, 10.2, 20.0)), "Default seat uses the intended human eye position")
	var preferred_distance := preferred.z - float(data.screen.position[2])
	var last_distance := last.z - float(data.screen.position[2])
	var preferred_fov := rad_to_deg(2.0 * atan(float(data.screen.width) * 0.5 / preferred_distance))
	var last_fov := rad_to_deg(2.0 * atan(float(data.screen.width) * 0.5 / last_distance))
	check(preferred_distance > 23.9 and preferred_distance < 24.1 and preferred_fov > 67.0 and preferred_fov < 68.0,
		"Default seat is 24m from the screen with about 67.4 degrees horizontal coverage")
	check(preferred_distance / float(data.screen.height) > 1.05 and preferred_distance / float(data.screen.height) < 1.10,
		"Default viewing distance stays close to 1.07 screen heights")
	check(last_distance > 35.1 and last_distance < 35.3 and last_fov > 48.0 and last_fov < 50.0,
		"Rear row remains 35.2m away with about 48.9 degrees horizontal coverage")
	check(last_distance / float(data.screen.height) > 1.55 and last_distance / float(data.screen.height) < 1.59,
		"Rear viewing distance stays below 1.59 screen heights")
	var first_eye := vector(_seat(data, "A15").eye_position)
	var rake := rad_to_deg(atan2(last.y - first_eye.y, last.z - first_eye.z))
	check(rake > 32.0 and rake < 33.0, "Tiered seating has a measurable 32.7 degree GT rake")
	check(is_equal_approx(vector(_seat(data, "A02").eye_position).x - vector(_seat(data, "A01").eye_position).x, 0.8),
		"Seat pitch remains 0.8m instead of scaling up the human furniture")
	check(data.design.clear_row_passage >= 0.64 and data.design.clear_row_passage <= 0.66,
		"Forward-offset chairs retain a 0.65m rear passage for body and navigation grid clearance")
	var ids := {}
	for seat: Dictionary in data.seats:
		check(not ids.has(seat.id), "Seat %s is unique" % seat.id)
		ids[seat.id] = true
		var eye := vector(seat.eye_position)
		var exit := vector(seat.exit_position)
		var supported := false
		for floor: Dictionary in data.walkable:
			var minimum := vector(floor.min)
			var maximum := vector(floor.max)
			if exit.x >= minimum.x and exit.x <= maximum.x and exit.z >= minimum.z and exit.z <= maximum.z:
				supported = supported or is_equal_approx(exit.y, float(floor.height))
		check(supported, "Seat %s exits onto a supported floor" % seat.id)
		for bounds: Dictionary in data.colliders:
			var minimum := vector(bounds.min)
			var maximum := vector(bounds.max)
			# A standing traveller at the exit has a 0.22m radius and floor-to-head body.
			if maximum.y > exit.y + 0.15 and minimum.y < exit.y + 1.75:
				var closest := Vector2(clampf(exit.x, minimum.x, maximum.x), clampf(exit.z, minimum.z, maximum.z))
				check(Vector2(exit.x, exit.z).distance_to(closest) >= 0.22,
					"Seat %s egress clears collider %s" % [seat.id, bounds.id])
			# Selected seats need head clearance even though the seated body overlaps the chair.
			if maximum.y > eye.y - 0.1 and minimum.y < eye.y + 0.15:
				var closest := Vector2(clampf(eye.x, minimum.x, maximum.x), clampf(eye.z, minimum.z, maximum.z))
				check(Vector2(eye.x, eye.z).distance_to(closest) >= 0.22,
					"Seat %s head clears collider %s" % [seat.id, bounds.id])
		# A direct lower-screen sightline must clear every preceding centre seat back.
		for previous in range(int(seat.row) - 1):
			var back_z := Blueprint.FIRST_ROW_Z + previous * Blueprint.ROW_PITCH + Blueprint.SEAT_Z_OFFSET + 0.30
			var fraction := (back_z - Blueprint.SCREEN_Z) / (eye.z - Blueprint.SCREEN_Z)
			var ray_y := lerpf(Blueprint.SCREEN_BOTTOM, eye.y, fraction)
			var back_y := (previous + 1) * Blueprint.ROW_RISER + 1.35
			check(ray_y > back_y, "Seat %s sees the lower screen over row %d" % [seat.id, previous + 1])
	var rear_sightline_clearance := INF
	for bounds: Dictionary in data.colliders:
		if str(bounds.id).begins_with("seat_") and str(bounds.id).ends_with("_back"):
			var maximum := vector(bounds.max)
			if maximum.z < last.z:
				var fraction := (maximum.z - float(data.screen.position[2])) / last_distance
				var ray_y := lerpf(1.2, last.y, fraction)
				rear_sightline_clearance = minf(rear_sightline_clearance, ray_y - maximum.y)
	check(rear_sightline_clearance > 0.20, "Rear-row sightline clears preceding chair backs by more than 20cm")
	for step in range(Blueprint.ROW_COUNT * Blueprint.STEPS_PER_ROW):
		var expected := (step + 1) * Blueprint.STAIR_RISER
		var stair_id := "stair_left_%02d_%d" % [step / Blueprint.STEPS_PER_ROW + 1, step % Blueprint.STEPS_PER_ROW]
		var found := false
		for floor: Dictionary in data.walkable:
			if floor.id == stair_id:
				found = is_equal_approx(float(floor.height), expected)
		check(found, "Stair %s follows the six-step 0.15m rise" % stair_id)
	check(data.walkable.filter(func(area): return str(area.id).begins_with("stair_left_")).size() == 108,
		"Each side staircase contains 108 human-sized steps")
	var source := Blueprint.build()
	var mesh: ArrayMesh = source.get_child(0).mesh
	var triangles := 0
	check(mesh.get_surface_count() <= 12, "Geometry batches into at most twelve material surfaces")
	for surface in range(mesh.get_surface_count()):
		triangles += mesh.surface_get_array_index_len(surface) / 3
		var material: StandardMaterial3D = mesh.surface_get_material(surface)
		check(material.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED, "Surface %d has deterministic baked shading" % surface)
		check(material.vertex_color_use_as_albedo, "Surface %d retains per-face vertex shading" % surface)
	check(triangles < 100000, "540-seat auditorium remains below 100,000 triangles with ten batches")
	var first_chair := _fabric_bounds(mesh, vector(_seat(data, "A01").eye_position))
	check(first_chair.size.x > 0.63 and first_chair.size.x < 0.65 and first_chair.size.z > 0.70 and first_chair.size.z < 0.73,
		"Actual GLB chair upholstery stays about 0.64m wide and 0.71m deep")
	check(first_chair.size.y > 0.93 and first_chair.size.y < 0.95,
		"Actual chair upholstery height remains human-sized after enlarging the hall")
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_file(MODEL, state)
	check(error == OK, "The generated GLB loads through the runtime glTF parser")
	if error == OK:
		var loaded := document.generate_scene(state)
		check(loaded != null, "The generated GLB instantiates without editor import")
		if loaded != null:
			check(_mesh_count(loaded) == 1, "Runtime GLB contains one combined mesh node")
			var imported_mesh := _first_mesh(loaded)
			check(imported_mesh != null and imported_mesh.get_surface_count() == mesh.get_surface_count(), "Runtime GLB preserves the material batches")
			if imported_mesh != null:
				for surface in range(imported_mesh.get_surface_count()):
					var material := imported_mesh.surface_get_material(surface) as StandardMaterial3D
					check(material != null and material.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED,
						"Runtime GLB preserves unlit shading on surface %d" % surface)
					var arrays: Array = imported_mesh.surface_get_arrays(surface)
					check(arrays[Mesh.ARRAY_COLOR] != null and not arrays[Mesh.ARRAY_COLOR].is_empty(),
						"Runtime GLB preserves baked vertex color data on surface %d" % surface)
			loaded.free()
	var manifest_json: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://environments/grand_cinema/manifest.json"))
	var expected_json: Variant = JSON.parse_string(JSON.stringify(data, "\t", false))
	check(manifest_json is Dictionary and manifest_json == expected_json, "Committed manifest matches its source blueprint")
	source.free()
	if failures.is_empty():
		print("CINEMA_GEOMETRY_OK checks=%d triangles=%d surfaces=%d default_fov=%.3f rear_fov=%.3f rake=%.3f rear_clearance=%.3f" % [checks,
			triangles, mesh.get_surface_count(), preferred_fov, last_fov, rake, rear_sightline_clearance])
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		print("CINEMA_GEOMETRY_FAILED %d/%d" % [failures.size(), checks])
		quit(1)

func _mesh_count(node: Node) -> int:
	var count := 1 if node is MeshInstance3D else 0
	for child in node.get_children():
		count += _mesh_count(child)
	return count

func _seat(data: Dictionary, id: String) -> Dictionary:
	for item: Dictionary in data.seats:
		if item.id == id: return item
	return {}

func _fabric_bounds(mesh: Mesh, eye: Vector3) -> AABB:
	var minimum := Vector3(INF, INF, INF)
	var maximum := -minimum
	for surface in mesh.get_surface_count():
		if mesh.surface_get_material(surface).resource_name != "SeatFabric": continue
		var arrays := mesh.surface_get_arrays(surface)
		for point: Vector3 in arrays[Mesh.ARRAY_VERTEX]:
			if absf(point.x - eye.x) < 0.36 and absf(point.z - eye.z) < 0.60:
				minimum = minimum.min(point)
				maximum = maximum.max(point)
	return AABB(minimum, maximum - minimum)

func _first_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D:
		return node.mesh
	for child in node.get_children():
		var found := _first_mesh(child)
		if found != null:
			return found
	return null
