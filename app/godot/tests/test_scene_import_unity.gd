extends SceneTree
## Unity scene path. The container reader is checked against containers written here; the
## native unpacker and a real bundle are exercised only when THRU3D_UNITY_SAMPLE names one
## (no third-party scene is stored in the repository).
const Loader := preload("res://scripts/scene_import/scene_import_loader.gd")
const Budget := preload("res://scripts/scene_import/scene_import_budget.gd")
const Unity := preload("res://scripts/scene_import/scene_import_unity.gd")
var checks: Array[Dictionary] = []
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../build/output/scene-import/unity")

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks.append({"label": label, "passed": ok})
	if not ok: failures.append(label)

## Minimal writer for the container format: blobs first, JSON last, offsets in the header.
class SceneFile:
	var bytes := PackedByteArray()
	func _init() -> void:
		bytes.resize(24)
	func blob(data: PackedByteArray) -> Dictionary:
		var where := {"offset": bytes.size(), "size": data.size()}
		bytes.append_array(data)
		return where
	func quad(size: float, uv2: bool) -> Dictionary:
		var half := size * 0.5
		var surface := {"vertices": 4, "triangles": 2, "name": "Quad", "bounds": [-half, 0.0, -half, half, 0.0, half],
			"position": blob(PackedVector3Array([Vector3(-half, 0, -half), Vector3(half, 0, -half), Vector3(half, 0, half), Vector3(-half, 0, half)]).to_byte_array()),
			"index": blob(PackedInt32Array([0, 1, 2, 0, 2, 3]).to_byte_array()),
			"normal": blob(PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP]).to_byte_array()),
			"uv": blob(PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]).to_byte_array())}
		if uv2: surface.uv2 = blob(PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]).to_byte_array())
		return surface
	func texture(name: String, color: Color) -> Dictionary:
		var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
		image.fill(color)
		return {"name": name, "width": 2, "height": 2, "format": "rgba8", "mipmaps": false, "srgb": true, "data": blob(image.get_data())}
	func save(path: String, scene: Dictionary) -> void:
		var text := JSON.stringify(scene).to_utf8_buffer()
		var at := bytes.size()
		var out := bytes.duplicate()
		out.append_array(text)
		for i in 8: out[i] = "T3DSCENE".unicode_at(i)
		out.encode_u64(8, at)
		out.encode_u64(16, text.size())
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_buffer(out)

func _place(origin: Vector3) -> Array:
	return [1, 0, 0, 0, 1, 0, 0, 0, 1, origin.x, origin.y, origin.z]

func _scene(container: SceneFile) -> Dictionary:
	var near := container.quad(10.0, true)
	var far := container.quad(4.0, false)
	var hidden := container.quad(6.0, false)
	return {
		"format": 1, "unity_version": "2022.3.0f1", "ambient": [0.2, 0.2, 0.25], "sky_material": 2, "warnings": ["one note"],
		"textures": [container.texture("Albedo", Color(0.8, 0.6, 0.4)), container.texture("Lightmap-0", Color(0.5, 0.5, 0.5)), container.texture("Panorama", Color(0.1, 0.1, 0.4))],
		"materials": [
			{"name": "Stone", "shader": "Standard", "keywords": [], "floats": {"_Mode": 0}, "colors": {"_Color": [1, 1, 1, 1]}, "textures": {"_MainTex": {"texture": 0, "scale": [2, 2], "offset": [0, 0]}}},
			{"name": "Leaf", "shader": "Standard", "keywords": ["_ALPHATEST_ON"], "floats": {"_Mode": 1, "_Cutoff": 0.4}, "colors": {}, "textures": {}},
			{"name": "Night", "shader": "Skybox/Panoramic", "keywords": [], "floats": {"_Rotation": 90, "_Exposure": 1}, "colors": {"_Tint": [0.5, 0.5, 0.5, 0.5]}, "textures": {"_MainTex": {"texture": 2, "scale": [1, 1], "offset": [0, 0]}}},
		],
		"surfaces": [near, far, hidden],
		"lightmaps": [1],
		"renderers": [
			{"name": "Plaza", "object": 0, "transform": _place(Vector3.ZERO), "lightmap": 1, "surfaces": [{"surface": 0, "material": 0}]},
			{"name": "Tree", "object": 1, "transform": _place(Vector3(0, 0, -200)), "lightmap": -1, "surfaces": [{"surface": 1, "material": 1}]},
		],
		"colliders": [],
		"behaviours": [
			{"class": "TeleportationArea", "name": "Plaza", "object": 0, "transform": _place(Vector3.ZERO), "fields": {}},
			{"class": "TeleportationArea", "name": "Ledge", "object": 7, "transform": _place(Vector3(0, 2, 30)), "fields": {}, "collider_surfaces": [2]},
			{"class": "Start", "name": "Rules", "object": 8, "transform": _place(Vector3.ZERO),
				"fields": {"ChuShengDian": {"name": "Spawn", "object": 9, "transform": _place(Vector3(3, 0, 4))}}},
		],
		"lights": [],
	}

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var limits := Budget.limits(Budget.HIGH)
	var path := output.path_join("synthetic.t3ds")
	var container := SceneFile.new()
	var scene := _scene(container)
	container.save(path, scene)
	var read := Unity.new().read_container(path, limits)
	_check(read.has("root"), "Synthetic container builds a scene")
	if not read.has("root"):
		push_error(str(read.get("error")))
		_finish()
		return
	var root: Node3D = read.root
	var plaza := root.find_child("thru3d_floor_Plaza", true, false) as MeshInstance3D
	var tree := root.find_child("Tree", true, false) as MeshInstance3D
	_check(plaza != null and tree != null and tree.position.is_equal_approx(Vector3(0, 0, -200)), "Renderers become mesh instances at their transforms; a walkable one is named as floor")
	if plaza != null and tree != null:
		var arrays := plaza.mesh.surface_get_arrays(0)
		_check(arrays[Mesh.ARRAY_VERTEX].size() == 4 and arrays[Mesh.ARRAY_INDEX].size() == 6 and arrays[Mesh.ARRAY_TEX_UV2].size() == 4, "Geometry arrives intact with both UV sets")
		var lit := plaza.mesh.surface_get_material(0) as ShaderMaterial
		_check(lit != null and is_equal_approx(lit.get_shader_parameter("light_scale"), 2.0) and lit.get_shader_parameter("light_map") is Texture2D
			and lit.get_shader_parameter("albedo_st") == Vector4(2, 2, 0, 0), "Baked object multiplies its lightmap and keeps texture tiling")
		var leaf := tree.mesh.surface_get_material(0) as ShaderMaterial
		_check(leaf != null and leaf.get_shader_parameter("light_map") == null and is_equal_approx(leaf.get_shader_parameter("alpha_cutoff"), 0.4)
			and leaf.shader.code.contains("discard"), "Unbaked cutout object gets ambient light and alpha test")
	var ledge := root.find_child("thru3d_floor_Ledge", true, false) as MeshInstance3D
	_check(ledge != null and not ledge.visible and ledge.position.is_equal_approx(Vector3(0, 2, 30)), "Collider-only walkable area is kept as hidden floor geometry")
	var marker := root.find_child("thru3d_spawn", true, false) as Node3D
	_check(marker != null and marker.position.is_equal_approx(Vector3(3, 0, 4)), "Spawn comes from the script field")
	if marker != null:
		_check((-marker.basis.z).dot((Vector3(0, 0, 0) - marker.position).normalized()) > 0.5, "Viewer starts facing the scene")
	_check(read.sky is Sky and read.warnings == ["one note"], "Panoramic sky and unpacker notes are passed on")
	root.free()

	var tight := limits.duplicate()
	tight.triangles = 3
	var culled := Unity.new().read_container(path, tight)
	_check(culled.has("root") and culled.actions.meshes_culled == 1 and culled.root.find_child("Tree", true, false) == null
		and culled.root.find_child("thru3d_floor_Plaza", true, false) != null, "Over budget, the far object is dropped before its geometry is read")
	if culled.has("root"): culled.root.free()

	var bytes := FileAccess.get_file_as_bytes(path)
	var cases := {}
	var magic := bytes.duplicate()
	magic[0] = 0x58
	cases["bad magic"] = magic
	var beyond := bytes.duplicate()
	beyond.encode_u64(8, bytes.size() + 10)
	cases["JSON offset past the end"] = beyond
	var huge := bytes.duplicate()
	huge.encode_u64(16, 1 << 40)
	cases["JSON size past the end"] = huge
	cases["truncated header"] = bytes.slice(0, 12)
	var garbled := bytes.duplicate()
	garbled[garbled.decode_u64(8)] = 0x5d
	cases["broken JSON"] = garbled
	for label in cases:
		var broken := output.path_join("broken.t3ds")
		var file := FileAccess.open(broken, FileAccess.WRITE)
		file.store_buffer(cases[label])
		file.close()
		var rejected := Unity.new().read_container(broken, limits)
		_check(rejected.has("error") and not rejected.has("root"), "Rejects a container with %s" % label)
	for label in ["blob past the end", "wrong blob size", "index list instead of object", "missing surface"]:
		var other := SceneFile.new()
		var damaged := _scene(other)
		match label:
			"blob past the end": damaged.surfaces[0].position.offset = 1 << 40
			"wrong blob size": damaged.surfaces[0].index.size = 8
			"index list instead of object": damaged.surfaces[0] = [1, 2, 3]
			"missing surface": damaged.renderers[0].surfaces[0].surface = 99
		damaged.renderers.remove_at(1)
		other.save(output.path_join("broken.t3ds"), damaged)
		var refused := Unity.new().read_container(output.path_join("broken.t3ds"), limits)
		_check(refused.get("error") == "Scene holds no usable geometry", "Skips geometry with %s" % label)

	var fake := output.path_join("fake.unity3d")
	var header := "UnityFS".to_ascii_buffer()
	header.append(0)
	header.resize(256)
	var fake_file := FileAccess.open(fake, FileAccess.WRITE)
	fake_file.store_buffer(header)
	fake_file.close()
	_check(Unity.is_bundle(fake) and not Unity.is_bundle(path), "Bundles are recognised by signature, not by extension")
	var executable := ProjectSettings.globalize_path("res://../../build/unity-scene/windows/unity_scene_unpack.exe")
	Unity.unpacker_executable = ""
	_check(Loader.new().load_scene(fake, Budget.LOW, {"use_cache": false, "cache_dir": output.path_join("cache")}).get("error") == "Unity scenes are not supported on this build",
		"Without an unpacker the format is reported as unsupported")
	if FileAccess.file_exists(executable):
		Unity.unpacker_executable = executable
		var refused := Loader.new().load_scene(fake, Budget.LOW, {"use_cache": false, "cache_dir": output.path_join("cache")})
		_check(refused.has("error") and not refused.has("root"), "Native unpacker rejects an empty bundle (%s)" % refused.get("error"))
		var sample := OS.get_environment("THRU3D_UNITY_SAMPLE")
		if not sample.is_empty(): _sample(sample)
		else: print("Scene import (Unity): real bundle not checked; set THRU3D_UNITY_SAMPLE")
	else:
		print("Scene import (Unity): native unpacker not built; native checks skipped")
	_finish()

func _sample(path: String) -> void:
	var options := {"cache_dir": output.path_join("cache-sample")}
	DirAccess.make_dir_recursive_absolute(options.cache_dir)
	for file in DirAccess.get_directories_at(options.cache_dir):
		for name in DirAccess.get_files_at(options.cache_dir.path_join(file)): DirAccess.remove_absolute(options.cache_dir.path_join(file).path_join(name))
	for tier in [Budget.LOW, Budget.HIGH]:
		var limits := Budget.limits(tier)
		var started := Time.get_ticks_msec()
		var first := Loader.new().load_scene(path, tier, options)
		var took := Time.get_ticks_msec() - started
		_check(first.has("root") and not first.get("cached", true), "Real bundle imports on the %s tier" % tier)
		if not first.has("root"):
			push_error(str(first.get("error")))
			continue
		var info: Dictionary = first.info
		print("Scene import (Unity) %s: %d ms, %d meshes, %d triangles, %d batches, %d culled" % [tier, took, info.stats.meshes, info.stats.triangles, info.stats.batches, info.actions.meshes_culled])
		_check(info.source == "unity" and info.stats.triangles > 0 and info.stats.triangles <= limits.triangles and info.stats.batches <= limits.batches and info.over_budget.is_empty(),
			"Real bundle fits the %s budget after culling" % tier)
		_check(info.stats.largest_texture <= maxi(limits.texture_size, limits.sky_width) and info.sky is Sky, "Real bundle textures respect the %s limits and the sky is kept" % tier)
		_check(info.layout.source == "marker", "Real bundle places the viewer from its scripts")
		first.root.free()
		started = Time.get_ticks_msec()
		var second := Loader.new().load_scene(path, tier, options)
		_check(second.get("cached", false) and second.info.stats.triangles == info.stats.triangles and second.info.sky is Sky,
			"Real bundle reopens from the cache (%d ms)" % (Time.get_ticks_msec() - started))
		if second.has("root"): second.root.free()

func _finish() -> void:
	var file := FileAccess.open(output.path_join("summary.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": checks, "failures": failures, "passed": failures.is_empty()}, "\t"))
	file.close()
	for failure in failures: push_error(failure)
	print("Scene import (Unity): %d checks, %d failures" % [checks.size(), failures.size()])
	quit(0 if failures.is_empty() else 1)
