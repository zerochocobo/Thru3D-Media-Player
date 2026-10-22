extends RefCounted
## Runtime GLB path used by the prototype, independent from editor-imported scene caches.
const MAX_BYTES := 32 * 1024 * 1024
const MAX_NODES := 4096
const MAX_VERTICES := 1000000
const MAX_SEATS := 1024
const MAX_AREAS := 4096
const MAX_COORDINATE := 256.0
const MIN_SCREEN_SIZE := 0.1
const MAX_SCREEN_SIZE := 100.0

func load_environment(model_path: String, manifest_path: String) -> Dictionary:
	var json_file := FileAccess.open(manifest_path, FileAccess.READ)
	if not json_file or json_file.get_length() > 1024 * 1024: return {"error": "Scene description unavailable"}
	var manifest: Variant = JSON.parse_string(json_file.get_as_text())
	var manifest_error := _validate_manifest(manifest)
	if not manifest_error.is_empty(): return {"error": manifest_error}
	var input := FileAccess.open(model_path, FileAccess.READ)
	if not input or input.get_length() < 20 or input.get_length() > MAX_BYTES:
		return {"error": "Model unavailable or too large"}
	var bytes := input.get_buffer(input.get_length())
	if bytes.decode_u32(0) != 0x46546c67 or bytes.decode_u32(4) != 2 or bytes.decode_u32(8) != bytes.size():
		return {"error": "Invalid GLB header"}
	var length := int(bytes.decode_u32(12))
	if length <= 0 or length > bytes.size() - 20 or bytes.decode_u32(16) != 0x4e4f534a:
		return {"error": "Invalid GLB scene data"}
	var gltf: Variant = JSON.parse_string(bytes.slice(20, 20 + length).get_string_from_utf8())
	if not gltf is Dictionary: return {"error": "Invalid GLB scene data"}
	var validation := _validate_document(gltf)
	if not validation.is_empty(): return {"error": validation}
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var result := document.append_from_file(model_path, state)
	if result != OK: return {"error": "Model could not be loaded (%s)" % error_string(result)}
	var scene := document.generate_scene(state) as Node3D
	if scene == null: return {"error": "Model contains no 3D scene"}
	var nodes := [scene]
	var mesh_count := 0
	var triangle_count := 0
	while not nodes.is_empty():
		var node: Node = nodes.pop_back()
		if node is Camera3D or node is Light3D or node is AnimationPlayer:
			scene.free()
			return {"error": "Prototype accepts static geometry only"}
		if node is MeshInstance3D and node.mesh:
			mesh_count += 1
			for surface in node.mesh.get_surface_count():
				var arrays: Array = node.mesh.surface_get_arrays(surface)
				var source_material := node.mesh.surface_get_material(surface) as StandardMaterial3D
				# 4.7.2 can omit the COLOR_0 switch on the first imported primitive.
				if arrays[Mesh.ARRAY_COLOR] != null and not arrays[Mesh.ARRAY_COLOR].is_empty() and source_material and not source_material.vertex_color_use_as_albedo:
					var normalized := source_material.duplicate() as StandardMaterial3D
					normalized.vertex_color_use_as_albedo = true
					node.set_surface_override_material(surface, normalized)
				triangle_count += (arrays[Mesh.ARRAY_INDEX].size() if arrays[Mesh.ARRAY_INDEX] != null and not arrays[Mesh.ARRAY_INDEX].is_empty() else arrays[Mesh.ARRAY_VERTEX].size()) / 3
		for child in node.get_children(): nodes.append(child)
	apply_seat_detail(scene)
	return {"root": scene, "manifest": manifest, "stats": {"bytes": bytes.size(), "meshes": mesh_count,
		"triangles": triangle_count, "seats": manifest.seats.size(), "runtime_glb": true}}

## Chairs ship as coincident near/far meshes per ten-seat run, each centred on
## its run. Only runs around the viewer draw the detailed chair.
const SEAT_DETAIL_RANGE := 7.0
const SEAT_DETAIL_MARGIN := 0.5

static func apply_seat_detail(root: Node) -> int:
	var count := 0
	for node in root.find_children("Seats_*", "GeometryInstance3D", true, false):
		var instance := node as GeometryInstance3D
		if str(instance.name).ends_with("_near"):
			instance.visibility_range_end = SEAT_DETAIL_RANGE
			instance.visibility_range_end_margin = SEAT_DETAIL_MARGIN
		elif str(instance.name).ends_with("_far"):
			instance.visibility_range_begin = SEAT_DETAIL_RANGE
			instance.visibility_range_begin_margin = SEAT_DETAIL_MARGIN
		else:
			continue
		instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		count += 1
	return count

func _validate_manifest(data: Variant) -> String:
	# This is the desktop prototype's authoring contract, before GLTF scene
	# generation. Invalid anchors must never replace an already loaded scene.
	if not data is Dictionary or not _number_in_range(data.get("schema_version"), 1, 1):
		return "Unsupported scene description"
	if data.get("units", "metres") != "metres": return "Scene description must use metres"
	var screen: Variant = data.get("screen")
	if not screen is Dictionary or not _position_valid(screen.get("position")):
		return "Invalid screen position"
	for dimension in ["width", "height"]:
		if not _number_in_range(screen.get(dimension), MIN_SCREEN_SIZE, MAX_SCREEN_SIZE):
			return "Invalid screen " + dimension
	if not _number_in_range(screen.get("yaw", 0.0), -TAU, TAU): return "Invalid screen yaw"
	var seats: Variant = data.get("seats")
	if not seats is Array or seats.is_empty() or seats.size() > MAX_SEATS:
		return "Scene must contain between 1 and %d seats" % MAX_SEATS
	var ids := {}
	for seat in seats:
		if not seat is Dictionary: return "Invalid seat description"
		var id: Variant = seat.get("id")
		if not id is String or id.strip_edges().is_empty() or id != id.strip_edges() or id.length() > 64 or ids.has(id):
			return "Seat identifiers must be unique nonempty strings"
		if not _position_valid(seat.get("eye_position")) or not _position_valid(seat.get("exit_position")):
			return "Invalid eye or aisle exit position for seat " + id
		if not _number_in_range(seat.get("yaw", 0.0), -TAU, TAU): return "Invalid seat yaw: " + id
		ids[id] = true
	var default_id: Variant = data.get("default_seat")
	if not default_id is String or not ids.has(default_id): return "Default seat does not exist"
	for category in ["walkable", "colliders"]:
		var areas: Variant = data.get(category)
		if not areas is Array or areas.size() > MAX_AREAS or (category == "walkable" and areas.is_empty()):
			return "Invalid " + category + " areas"
		for area in areas:
			if not area is Dictionary or not _position_valid(area.get("min")) or not _position_valid(area.get("max")):
				return "Invalid " + category + " bounds"
			var minimum := Vector3(area.min[0], area.min[1], area.min[2])
			var maximum := Vector3(area.max[0], area.max[1], area.max[2])
			if maximum.x <= minimum.x or maximum.z <= minimum.z or maximum.y < minimum.y:
				return "Reversed or empty " + category + " bounds"
			if category == "colliders" and maximum.y <= minimum.y:
				return "Collider must have positive height"
			if category == "walkable":
				if not _number_in_range(area.get("height"), -MAX_COORDINATE, MAX_COORDINATE):
					return "Invalid walkable floor height"
				var height := float(area.height)
				if absf(minimum.y - height) > 0.001 or absf(maximum.y - height) > 0.001:
					return "Walkable bounds must describe one horizontal floor"
	return ""

func _number_in_range(value: Variant, minimum: float, maximum: float) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= minimum and float(value) <= maximum

func _position_valid(value: Variant) -> bool:
	if not value is Array or value.size() != 3: return false
	for component in value:
		if not _number_in_range(component, -MAX_COORDINATE, MAX_COORDINATE): return false
	return true

func _validate_document(data: Dictionary) -> String:
	if data.get("nodes", []).size() > MAX_NODES: return "Model has too many nodes"
	if not data.get("animations", []).is_empty() or not data.get("skins", []).is_empty(): return "Prototype accepts static geometry only"
	for material in data.get("materials", []):
		if material.get("alphaMode", "OPAQUE") == "BLEND": return "Prototype does not support blended scene materials"
	for extension in data.get("extensionsRequired", []):
		if extension != "KHR_materials_unlit": return "Unsupported required model extension: " + str(extension)
	for category in ["buffers", "images"]:
		for item in data.get(category, []):
			if item.has("uri"): return "Prototype requires embedded GLB resources"
	var vertices := 0
	for mesh in data.get("meshes", []):
		for primitive in mesh.get("primitives", []):
			if int(primitive.get("mode", 4)) != 4: return "Prototype requires triangle meshes"
			var index := int(primitive.get("attributes", {}).get("POSITION", -1))
			if index < 0 or index >= data.get("accessors", []).size(): return "Invalid model vertices"
			vertices += int(data.accessors[index].get("count", 0))
			if vertices > MAX_VERTICES: return "Model has too many vertices"
	return ""
