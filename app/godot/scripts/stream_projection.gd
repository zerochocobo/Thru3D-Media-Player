extends RefCounted
## Stream-authored SV3D mesh. Positions use OpenGL axes; source UV origin is lower-left.
## Eye colors select a mesh in the existing multiview shader, without assuming shared topology.
const Geometry := preload("res://scripts/video_geometry.gd")

static func read(platform: Object, uri: String) -> Dictionary:
	if not preload("res://scripts/platform_methods.gd").supports(platform, "web_video_projection"): return {}
	var value: Variant = JSON.parse_string(str(platform.web_video_projection(uri)))
	# JSON numbers arrive as floats. Array membership is type-sensitive in Godot.
	return value if value is Dictionary and value.get("version") == 1 and int(value.get("geometry", -1)) in [1, 3] else {}

static func stereo(data: Dictionary) -> bool:
	return int(data.get("stereo_mode", 0)) != 0 or data.get("meshes", []).size() == 2

static func mesh(data: Dictionary) -> ArrayMesh:
	if data.is_empty(): return null
	var pose: Array = data.get("pose", [0, 0, 0])
	# RFC: yaw, then pitch, then clockwise roll around forward (-Z).
	var rotation := Basis(Vector3.BACK, deg_to_rad(float(pose[2]))) * Basis(Vector3.RIGHT, deg_to_rad(float(pose[1]))) * Basis(Vector3.UP, deg_to_rad(float(pose[0])))
	var meshes: Array = data.get("meshes", [])
	if data.kind == "equirectangular":
		var bounds: Array = data.get("bounds", [0, 0, 0, 0]) # top, bottom, left, right
		if bounds.all(func(v): return is_zero_approx(float(v))) and pose.all(func(v): return is_zero_approx(float(v))):
			return null # Exact existing equirectangular compositor/eye-buffer path.
		var v: Array = []; var indices: Array = []
		for row in 73:
			var t := float(row) / 72
			var latitude := (0.5 - float(bounds[0]) - t * (1.0 - float(bounds[0]) - float(bounds[1]))) * PI
			for col in 145:
				var u := float(col) / 144
				var longitude := (float(bounds[2]) + u * (1.0 - float(bounds[2]) - float(bounds[3])) - 0.5) * TAU
				v.append_array([sin(longitude)*cos(latitude), sin(latitude), -cos(longitude)*cos(latitude), u, 1.0-t])
		for row in 72:
			for col in 144:
				var a := row*145+col; var b := a+145
				indices.append_array([a,b,a+1,a+1,b,b+1])
		meshes = [{"vertices": v, "indices": indices}]
	if meshes.is_empty() or meshes.size() > 2: return null
	var points := PackedVector3Array(); var uv := PackedVector2Array()
	var colors := PackedColorArray(); var triangles := PackedInt32Array()
	for eye in (2 if stereo(data) else 1):
		var entry: Dictionary = meshes[mini(eye, meshes.size()-1)]
		var values: Array = entry.vertices
		var offset := points.size()
		for i in range(0, values.size(), 5):
			var direction := Vector3(float(values[i]), float(values[i+1]), float(values[i+2])).normalized()
			points.append(rotation * direction * 50.0)
			uv.append(Vector2(float(values[i+3]), 1.0-float(values[i+4])))
			colors.append(Color(float(eye),0,0,1))
		for index in entry.indices: triangles.append(offset+int(index))
	var arrays := []; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=points; arrays[Mesh.ARRAY_TEX_UV]=uv
	arrays[Mesh.ARRAY_COLOR]=colors; arrays[Mesh.ARRAY_INDEX]=triangles
	var result := ArrayMesh.new(); result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result
