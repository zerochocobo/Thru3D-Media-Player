extends SceneTree

const Blueprint := preload("res://scripts/environments/cinema_blueprint.gd")
const MODEL := "res://environments/grand_cinema/cinema.glb"
const Loader := preload("res://scripts/environments/cinema_loader.gd")
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
	check(data.seats.size() == 336 and data.design.row_count == 14 and data.design.seats_per_row == 24,
		"GT auditorium has fourteen rows and twenty-four individually selectable seats per row")
	check(is_equal_approx(data.screen.width / data.screen.height, 1.43), "The active screen is 1.43:1")
	check(is_equal_approx(data.screen.width, 32.0) and data.screen.height > 22.3 and data.screen.height < 22.5,
		"GT active screen measures 32 metres wide and about 22.38 metres high")
	check(data.room.width == 34.0 and is_equal_approx(data.room.depth, 37.4) and data.room.height == 26.0,
		"Architecture encloses a 34 by 37.4 by 26 metre hall")
	check(data.room.width - data.screen.width <= 2.0, "The screen spans the front wall instead of hanging inside a frame")
	check(is_equal_approx(float(data.screen.position[1]) - float(data.screen.height) * 0.5, 1.2)
		and data.room.height - (float(data.screen.position[1]) + float(data.screen.height) * 0.5) < 2.5,
		"Tall screen starts near the floor and reaches close to the ceiling")
	check(data.default_seat == "I12", "Default seat is the ninth row, centre-left")
	var preferred := vector(_seat(data, "I12").eye_position)
	var last := vector(_seat(data, "N12").eye_position)
	check(preferred.is_equal_approx(Vector3(-0.45, 5.25, 19.9)), "Default seat uses the intended human eye position")
	var preferred_distance := preferred.z - float(data.screen.position[2])
	var last_distance := last.z - float(data.screen.position[2])
	var preferred_fov := rad_to_deg(2.0 * atan(float(data.screen.width) * 0.5 / preferred_distance))
	var last_fov := rad_to_deg(2.0 * atan(float(data.screen.width) * 0.5 / last_distance))
	check(preferred_distance > 23.8 and preferred_distance < 24.0 and preferred_fov > 67 and preferred_fov < 68,
		"Default seat retains an immersive 67 degree horizontal screen coverage")
	check(preferred_distance / float(data.screen.height) > 1.0 and preferred_distance / float(data.screen.height) < 1.1,
		"Default viewing distance stays near one screen height")
	check(last_distance > 32.8 and last_distance < 33.0 and last_fov > 51 and last_fov < 53,
		"Wider rows retain over 51 degrees horizontal coverage at the rear")
	check(last_distance / float(data.screen.height) < 1.5, "Rear viewing distance stays within 1.5 screen heights")
	var first_eye := vector(_seat(data, "A12").eye_position)
	var rake := rad_to_deg(atan2(last.y - first_eye.y, last.z - first_eye.z))
	check(rake > 14.0 and rake < 14.1, "Gentler 14 degree rake avoids the old high seating plinths")
	check(is_equal_approx(vector(_seat(data, "A02").eye_position).x - vector(_seat(data, "A01").eye_position).x, 0.9),
		"Premium chairs sharing wide consoles keep a 0.9m pitch")
	check(data.design.clear_row_passage >= 0.99 and data.design.clear_row_passage <= 1.01,
		"Each chair shares a full one-metre front footwell/passage with its own deck")
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
			var back_z := Blueprint.FIRST_ROW_Z + previous * Blueprint.ROW_PITCH + Blueprint.SEAT_Z_OFFSET + Blueprint.SEAT_REAR
			var fraction := (back_z - Blueprint.SCREEN_Z) / (eye.z - Blueprint.SCREEN_Z)
			var ray_y := lerpf(Blueprint.SCREEN_BOTTOM, eye.y, fraction)
			var back_y := (previous + 1) * Blueprint.ROW_RISER + Blueprint.SEAT_BACK_TOP
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
		check(found, "Stair %s follows the three-step 0.15m rise" % stair_id)
	check(data.walkable.filter(func(area): return str(area.id).begins_with("stair_left_")).size() == 42,
		"Each side staircase contains 42 human-sized steps")
	check(Blueprint.STAIR_RISER < 0.17 and Blueprint.STAIR_TREAD >= 0.59, "Aisle steps keep a comfortable 15cm rise and 60cm tread")
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_file(MODEL, state)
	var triangles := 0
	var surfaces := 0
	check(error == OK, "The baked GLB loads through the runtime glTF parser")
	if error == OK:
		var loaded := document.generate_scene(state)
		check(loaded != null, "The baked GLB instantiates without editor import")
		if loaded != null:
			var meshes := _meshes(loaded)
			var names := meshes.map(func(item: MeshInstance3D): return str(item.name))
			check("Hall" in names and "Fixtures" in names, "Architecture and light fixtures are separate meshes")
			var near := meshes.filter(func(item: MeshInstance3D): return str(item.name).begins_with("Seats_") and str(item.name).ends_with("_near"))
			var far := meshes.filter(func(item: MeshInstance3D): return str(item.name).begins_with("Seats_") and str(item.name).ends_with("_far"))
			var chunks := near + far
			check(near.size() == data.design.row_count * 6 and far.size() == near.size(),
				"Each row ships six four-seat runs, each with a detailed and a distant chair mesh")
			check(Loader.apply_seat_detail(loaded) == chunks.size() and near.all(func(item): return item.visibility_range_end == Loader.SEAT_DETAIL_RANGE)
				and far.all(func(item): return item.visibility_range_begin == Loader.SEAT_DETAIL_RANGE),
				"Runtime switches every run between detailed and distant chairs at the same distance")
			# Worst case actually drawn from the default seat: all architecture and
			# distant chairs, plus detailed runs whose centres lie within the switch range.
			var drawn := 0
			var near_max := 0
			for item: MeshInstance3D in meshes:
				var item_triangles := 0
				for surface in range(item.mesh.get_surface_count()):
					surfaces += 1
					var indices: int = item.mesh.surface_get_array_index_len(surface)
					item_triangles += (indices if indices > 0 else item.mesh.surface_get_array_len(surface)) / 3
				triangles += item_triangles
				var detailed := item.transform.origin.distance_to(preferred) < Loader.SEAT_DETAIL_RANGE + Loader.SEAT_DETAIL_MARGIN
				if item in near:
					near_max = maxi(near_max, item_triangles)
					if detailed:
						drawn += item_triangles
				elif not (item in far and detailed):
					drawn += item_triangles
			check(near_max <= 9600, "A detailed four-seat run stays within 9,600 triangles: %d" % near_max)
			check(drawn < 250000, "Default seat draws fewer than 250,000 triangles for Quest 2: %d" % drawn)
			print("CINEMA_BUDGET drawn=%d near_run_max=%d" % [drawn, near_max])
			for item: MeshInstance3D in meshes:
				for surface in range(item.mesh.get_surface_count()):
					var material: StandardMaterial3D = item.mesh.surface_get_material(surface) as StandardMaterial3D
					check(material != null and material.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED,
						"%s surface %d is unlit; lighting is baked" % [item.name, surface])
			if "Hall" in names:
				var hall: MeshInstance3D = meshes[names.find("Hall")]
				var scanned := 0
				for surface in hall.mesh.get_surface_count():
					var material := hall.mesh.surface_get_material(surface) as StandardMaterial3D
					var arrays: Array = hall.mesh.surface_get_arrays(surface)
					if material.albedo_texture != null and material.albedo_texture.get_width() >= 1024 							and arrays[Mesh.ARRAY_TEX_UV2] != null and not arrays[Mesh.ARRAY_TEX_UV2].is_empty():
						scanned += 1
				check(hall.mesh.get_surface_count() >= 8 and scanned == hall.mesh.get_surface_count(),
					"Every architecture finish carries a 1024px scan plus a light-bake UV2: %d/%d" % [scanned, hall.mesh.get_surface_count()])
				var light := load(Loader.LIGHT_PATH) as Texture2D
				check(light != null and light.get_width() >= 2048, "The lighting bake ships beside the model at 2048px or more")
				check(Loader.apply_baked_surfaces(loaded, light) == hall.mesh.get_surface_count()
					and hall.get_surface_override_material(0) is ShaderMaterial,
					"Runtime multiplies every scanned finish by the light bake in one unlit shader")
			if "Fixtures" in names:
				var fixtures: MeshInstance3D = meshes[names.find("Fixtures")]
				check(fixtures.mesh.get_surface_count() >= 6, "Step, sconce, exit and screen fixtures keep their distinct colours")
			if not chunks.is_empty():
				var chunk: MeshInstance3D = chunks[0]
				var arrays: Array = chunk.mesh.surface_get_arrays(0)
				var material := chunk.mesh.surface_get_material(0) as StandardMaterial3D
				check(material.albedo_texture != null and arrays[Mesh.ARRAY_COLOR] != null and not arrays[Mesh.ARRAY_COLOR].is_empty(),
					"Seat chunks combine a chair texture with per-vertex baked hall lighting")
			var chair := _seat_bounds(near, vector(_seat(data, "A01").eye_position))
			check(chair.size.x > 0.85 and chair.size.x <= 0.91 and chair.size.z > 0.6 and chair.size.z <= 0.805,
				"Actual GLB chair plus its shared console spans one 0.9m pitch and 0.80m depth: %s" % chair.size)
			check(chair.size.y > 1.0 and chair.size.y <= 1.09, "Actual chair height remains human-sized: %s" % chair.size)
			loaded.free()
	check(triangles > 0 and triangles < 1000000, "Both chair detail levels together stay below 1,000,000 stored triangles")
	check(surfaces <= 200, "Auditorium stores at most 200 surfaces")
	check(FileAccess.get_file_as_bytes(MODEL).size() < 28 * 1024 * 1024, "Baked GLB with real scans stays below 28 MiB")
	var textures := Array(DirAccess.get_files_at("res://environments/grand_cinema")).filter(
		func(file: String): return file.get_extension() in ["jpg", "png"])
	check(textures.size() >= 9 and "cinema_light.jpg" in textures, "Scans, chair texture and light bake are all extracted")
	for texture in textures:
		var settings := FileAccess.get_file_as_string("res://environments/grand_cinema/%s.import" % texture)
		check("compress/mode=2" in settings and "mipmaps/generate=true" in settings,
			"Extracted %s imports VRAM-compressed with mipmaps for headsets" % texture)
	var manifest_json: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://environments/grand_cinema/manifest.json"))
	var expected_json: Variant = JSON.parse_string(JSON.stringify(data, "\t", false))
	check(manifest_json is Dictionary and manifest_json == expected_json, "Committed manifest matches its source blueprint")
	if failures.is_empty():
		print("CINEMA_GEOMETRY_OK checks=%d triangles=%d surfaces=%d default_fov=%.3f rear_fov=%.3f rake=%.3f rear_clearance=%.3f" % [checks,
			triangles, surfaces, preferred_fov, last_fov, rake, rear_sightline_clearance])
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		print("CINEMA_GEOMETRY_FAILED %d/%d" % [failures.size(), checks])
		quit(1)

func _meshes(node: Node) -> Array:
	var found: Array = [node] if node is MeshInstance3D else []
	for child in node.get_children():
		found.append_array(_meshes(child))
	return found

func _seat(data: Dictionary, id: String) -> Dictionary:
	for item: Dictionary in data.seats:
		if item.id == id: return item
	return {}

func _seat_bounds(chunks: Array, eye: Vector3) -> AABB:
	var minimum := Vector3(INF, INF, INF)
	var maximum := -minimum
	for chunk: MeshInstance3D in chunks:
		var arrays := chunk.mesh.surface_get_arrays(0)
		for local: Vector3 in arrays[Mesh.ARRAY_VERTEX]:
			var point := chunk.transform * local
			if point.x > eye.x - 0.55 and point.x < eye.x + 0.36 and absf(point.z - (eye.z + 0.10)) < 0.5 and point.y < eye.y:
				minimum = minimum.min(point)
				maximum = maximum.max(point)
	return AABB(minimum, maximum - minimum)
