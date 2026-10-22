extends SceneTree
## P0 authoring-contract checks against the real runtime GLB loader.
const Loader := preload("res://scripts/environments/cinema_loader.gd")
const MODEL := "res://environments/grand_cinema/cinema.glb"
const MANIFEST := "res://environments/grand_cinema/manifest.json"
var loader := Loader.new()
var baseline: Dictionary
var checks: Array[Dictionary] = []
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../build/output/cinema-prototype/loader")
var fixture_dir := output.path_join("fixtures")

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks.append({"label": label, "passed": ok})
	if not ok: failures.append(label)

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(fixture_dir)
	baseline = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	_check(loader._validate_manifest(baseline).is_empty(), "Committed manifest satisfies P0 anchors")
	var valid := loader.load_environment(MODEL, MANIFEST)
	_check(not valid.has("error") and valid.has("root"), "Real runtime GLB loads successfully")
	if not valid.has("root"):
		_finish()
		return
	var retained := valid.root as Node3D
	retained.name = "RetainedEnvironment"
	root.add_child(retained)
	_check(valid.stats.seats == 420 and valid.stats.runtime_glb, "Real model preserves 420 seats and runtime-load identity")
	_check(valid.stats.bytes < 24 * 1024 * 1024 and valid.stats.triangles < 800000,
		"Detailed GT hall with both chair detail levels stays below 24 MiB and 800k stored triangles without raising model resource limits")
	_check(Loader.MAX_SEATS == 1024 and Loader.MAX_BYTES == 32 * 1024 * 1024 and Loader.MAX_VERTICES == 1000000 and Loader.MAX_AREAS == 4096,
		"420-seat support retains bounded seats, bytes, vertices and navigation areas")
	_check(_colored_surfaces_normalized(retained), "Imported COLOR_0 surfaces use vertex albedo including first primitive")
	var cases := [
		["wrong_schema", ["schema_version"], 2],
		["string_schema", ["schema_version"], "1"],
		["wrong_units", ["units"], "centimetres"],
		["screen_empty", ["screen"], {}],
		["screen_position_missing", ["screen", "position"], null],
		["screen_position_short", ["screen", "position"], [0, 1]],
		["screen_position_string", ["screen", "position"], [0, "1", 0]],
		["screen_position_outside_p0", ["screen", "position"], [0, 1, 300]],
		["screen_width_zero", ["screen", "width"], 0],
		["screen_width_boolean", ["screen", "width"], true],
		["screen_height_negative", ["screen", "height"], -10],
		["screen_height_too_large", ["screen", "height"], 101],
		["screen_yaw_string", ["screen", "yaw"], "0"],
		["screen_yaw_outside_range", ["screen", "yaw"], TAU + 0.01],
		["seats_empty", ["seats"], []],
		["seats_wrong_type", ["seats"], {}],
		["seat_not_dictionary", ["seats", 0], 7],
		["seat_id_empty", ["seats", 0, "id"], ""],
		["seat_id_duplicate", ["seats", 1, "id"], "A01"],
		["seat_eye_missing", ["seats", 0, "eye_position"], null],
		["seat_exit_missing", ["seats", 0, "exit_position"], null],
		["seat_exit_string", ["seats", 0, "exit_position"], [0, 1, "2"]],
		["seat_yaw_invalid", ["seats", 0, "yaw"], null],
		["default_missing", ["default_seat"], "Z99"],
		["walkable_empty", ["walkable"], []],
		["walkable_not_array", ["walkable"], {}],
		["walkable_invalid_bounds", ["walkable", 0, "min"], [2, 0, 50]],
		["walkable_height_missing", ["walkable", 0, "height"], null],
		["walkable_height_off_plane", ["walkable", 0, "height"], 1],
		["collider_not_array", ["colliders"], ""],
		["collider_bad_entry", ["colliders", 0], 1],
		["collider_empty_extent", ["colliders", 0, "max"], baseline.colliders[0].min],
	]
	for entry in cases:
		var manifest := baseline.duplicate(true)
		_set_path(manifest, entry[1], entry[2])
		_reject_manifest(manifest, entry[0], retained)
	var too_many := baseline.duplicate(true)
	too_many.seats.resize(Loader.MAX_SEATS + 1)
	_reject_manifest(too_many, "too_many_seats", retained)
	too_many = baseline.duplicate(true)
	too_many.colliders.resize(Loader.MAX_AREAS + 1)
	_reject_manifest(too_many, "too_many_colliders", retained)
	# JSON cannot portably carry NaN/Infinity, but callers and parsed-overflow
	# values still must fail numeric validation, before any vector construction.
	for entry in [
		["infinite_screen_position", ["screen", "position"], [0, INF, 0]],
		["nan_screen_height", ["screen", "height"], NAN],
		["infinite_seat_eye", ["seats", 0, "eye_position"], [INF, 1, 0]],
		["nan_exit", ["seats", 0, "exit_position"], [0, NAN, 0]],
		["infinite_seat_yaw", ["seats", 0, "yaw"], INF],
		["infinite_floor_height", ["walkable", 0, "height"], INF],
		["nan_collider_bounds", ["colliders", 0, "max"], [0, NAN, 0]]]:
		var manifest := baseline.duplicate(true)
		_set_path(manifest, entry[1], entry[2])
		_check(not loader._validate_manifest(manifest).is_empty(), entry[0] + " rejected before generating root")
	var corrupt := FileAccess.get_file_as_bytes(MODEL)
	corrupt.encode_u32(0, 0)
	_write_bytes(fixture_dir.path_join("bad_header.glb"), corrupt)
	_check(loader.load_environment(fixture_dir.path_join("bad_header.glb"), MANIFEST).has("error"), "Damaged GLB header fails explicitly")
	_check(loader.load_environment(fixture_dir.path_join("missing.glb"), MANIFEST).has("error"), "Missing GLB fails explicitly")
	for probe in [
		["external_buffer", {"asset": {"version": "2.0"}, "buffers": [{"uri": "https://example.invalid/model.bin", "byteLength": 4}]}],
		["external_image", {"asset": {"version": "2.0"}, "images": [{"uri": "texture.png"}]}],
		["blend_material", {"asset": {"version": "2.0"}, "materials": [{"alphaMode": "BLEND"}]}],
		["unsupported_required_extension", {"asset": {"version": "2.0"}, "extensionsRequired": ["KHR_draco_mesh_compression"]}]]:
		var path := fixture_dir.path_join(probe[0] + ".glb")
		_write_glb(path, probe[1])
		var rejected := loader.load_environment(path, MANIFEST)
		_check(rejected.has("error") and not rejected.has("root"), probe[0] + " rejected through real GLB entry point")
	_check(is_instance_valid(retained) and retained.is_inside_tree(), "All failed loads retain existing scene")
	retained.free()
	_finish()

func _reject_manifest(manifest: Dictionary, label: String, retained: Node3D) -> void:
	var path := fixture_dir.path_join(label + ".json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(manifest)); file.close()
	var rejected := loader.load_environment(MODEL, path)
	_check(rejected.has("error") and not rejected.has("root"), label + " rejects valid GLB plus bad manifest")
	_check(is_instance_valid(retained) and retained.is_inside_tree(), label + " leaves old scene alive")
	if rejected.has("root"): rejected.root.free()

func _set_path(data: Variant, path: Array, value: Variant) -> void:
	var target: Variant = data
	for index in path.size() - 1: target = target[path[index]]
	target[path[-1]] = value

func _colored_surfaces_normalized(node: Node) -> bool:
	var found := false
	var nodes := [node]
	while not nodes.is_empty():
		var current: Node = nodes.pop_back()
		if current is MeshInstance3D and current.mesh:
			for surface in current.mesh.get_surface_count():
				var arrays: Array = current.mesh.surface_get_arrays(surface)
				if arrays[Mesh.ARRAY_COLOR] != null and not arrays[Mesh.ARRAY_COLOR].is_empty():
					found = true
					var material := current.get_active_material(surface) as StandardMaterial3D
					if material == null or not material.vertex_color_use_as_albedo: return false
		for child in current.get_children(): nodes.append(child)
	return found

func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes); file.close()

func _write_glb(path: String, data: Dictionary) -> void:
	var bytes := JSON.stringify(data).to_utf8_buffer()
	while bytes.size() % 4 != 0: bytes.append(32)
	var header := PackedByteArray()
	header.resize(20)
	header.encode_u32(0, 0x46546c67)
	header.encode_u32(4, 2)
	header.encode_u32(8, bytes.size() + 20)
	header.encode_u32(12, bytes.size())
	header.encode_u32(16, 0x4e4f534a)
	header.append_array(bytes)
	_write_bytes(path, header)

func _finish() -> void:
	var file := FileAccess.open(output.path_join("summary.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": checks, "failures": failures, "passed": failures.is_empty()}, "\t")); file.close()
	for failure in failures: push_error(failure)
	print("Cinema loader: %d checks, %d failures" % [checks.size(), failures.size()])
	quit(0 if failures.is_empty() else 1)
