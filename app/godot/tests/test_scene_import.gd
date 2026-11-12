extends SceneTree
## Imported-scene pipeline against GLB fixtures generated here (no third-party assets).
const Loader := preload("res://scripts/scene_import/scene_import_loader.gd")
const Budget := preload("res://scripts/scene_import/scene_import_budget.gd")
const Cache := preload("res://scripts/scene_import/scene_import_cache.gd")
const SkyLoader := preload("res://scripts/scene_import/scene_import_sky.gd")
var checks: Array[Dictionary] = []
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../build/output/scene-import")
var fixtures := output.path_join("fixtures")
var cache := output.path_join("cache")

func _initialize() -> void:
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	checks.append({"label": label, "passed": ok})
	if not ok: failures.append(label)

func _texture(size: int, seed_value: int) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	image.fill(Color.from_hsv(fmod(seed_value * 0.17, 1.0), 0.6, 0.8))
	for step in 64: image.set_pixel((step * 37 + seed_value) % size, (step * 91) % size, Color.WHITE)
	return ImageTexture.create_from_image(image)

func _box(name: String, position: Vector3, size: Vector3, texture: Texture2D, subdivide: int = 0) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.subdivide_width = subdivide
	mesh.subdivide_height = subdivide
	mesh.subdivide_depth = subdivide
	var material := StandardMaterial3D.new()
	material.albedo_texture = texture
	material.metallic = 1.0  # As glTF leaves it when a metal map is expected.
	mesh.material = material
	var instance := MeshInstance3D.new()
	instance.name = name
	instance.mesh = mesh
	instance.position = position
	return instance

## Floor slab, a plinth in the middle, and a row of detailed boxes receding along -Z.
func _fixture(path: String, markers: bool, texture_size: int = 2048) -> void:
	var scene := Node3D.new()
	scene.name = "Fixture"
	scene.add_child(_box("Floor", Vector3(0, -0.5, -20), Vector3(30, 1, 60), _texture(64, 1)))
	scene.add_child(_box("Plinth", Vector3(0, 0.25, -20), Vector3(2, 0.5, 2), _texture(64, 2)))
	for index in 6:
		scene.add_child(_box("Tower%d" % index, Vector3(8, 2, -5.0 - index * 8.0), Vector3(2, 4, 2), _texture(texture_size if index == 0 else 64, 3 + index), 12))
	var lamp := OmniLight3D.new()
	lamp.name = "Lamp"
	scene.add_child(lamp)
	var second := DirectionalLight3D.new()
	second.name = "Sun"
	scene.add_child(second)
	var camera := Camera3D.new()
	camera.name = "ShotCamera"
	scene.add_child(camera)
	if markers:
		var spawn := Node3D.new()
		spawn.name = "thru3d_spawn"
		spawn.position = Vector3(1, 0, 2)
		scene.add_child(spawn)
		var screen := Node3D.new()
		screen.name = "thru3d_screen"
		screen.position = Vector3(1, 3, -9)
		screen.scale = Vector3(10, 10, 10)
		scene.add_child(screen)
	for node in scene.get_children(): node.owner = scene
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	_check(document.append_from_scene(scene, state) == OK and document.write_to_filesystem(state, path) == OK,
		"Fixture %s exports" % path.get_file())
	scene.free()

func _bytes(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)

func _clear(directory: String) -> void:
	for sub in DirAccess.get_directories_at(directory): _clear(directory.path_join(sub))
	for file in DirAccess.get_files_at(directory): DirAccess.remove_absolute(directory.path_join(file))

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(fixtures)
	DirAccess.make_dir_recursive_absolute(cache)
	_clear(cache)
	var marked := fixtures.path_join("marked.glb")
	var plain := fixtures.path_join("plain.glb")
	_fixture(marked, true)
	_fixture(plain, false)
	var loader := Loader.new()
	var options := {"cache_dir": cache}

	var low := loader.load_scene(marked, Budget.LOW, options)
	_check(low.has("root") and not low.get("cached", true), "Marked scene loads on the low tier")
	if not low.has("root"):
		push_error(str(low.get("error")))
		_finish()
		return
	var info: Dictionary = low.info
	var root: Node3D = low.root
	_check(info.stats.meshes == 8 and info.stats.triangles > 5000, "Audit counts every mesh and its triangles (%d)" % info.stats.triangles)
	_check(root.find_children("*", "Camera3D", true, false).is_empty(), "Authoring cameras are removed")
	_check(info.stats.lights == 0 and info.actions.lights_removed == 2, "Low tier drops realtime lights")
	_check(root.find_children("*", "MeshInstance3D", true, false).all(func(node): return (node.mesh.surface_get_material(0) as BaseMaterial3D).metallic == 0.0),
		"Without lights no surface is left as bare metal, which ambient would show black")
	_check(info.stats.largest_texture <= 1024 and info.actions.textures_resized == 1,
		"Oversized texture is reduced to the tier limit (largest %d)" % info.stats.largest_texture)
	_check(info.layout.source == "marker" and (info.layout.spawn as Transform3D).origin.is_equal_approx(Vector3(1, 0, 2)),
		"Spawn marker places the viewer")
	_check(is_equal_approx(info.layout.screen_width, 10.0) and (info.layout.screen as Transform3D).origin.is_equal_approx(Vector3(1, 3, -9)),
		"Screen marker carries position and width")
	_check(info.over_budget.is_empty() and info.actions.meshes_culled == 0, "Scene inside the budget is left intact")
	root.free()

	var again := loader.load_scene(marked, Budget.LOW, options)
	_check(again.get("cached", false) and again.info.stats.triangles == info.stats.triangles
		and (again.info.layout.spawn as Transform3D).origin.is_equal_approx(Vector3(1, 0, 2)),
		"Second open comes from the cache with the same summary")
	if again.has("root"):
		_check(again.root.find_children("*", "MeshInstance3D", true, false).size() == 8, "Cached scene keeps its geometry")
		again.root.free()
	_check(Cache.entries(cache).size() == 1 and Cache.entries(cache)[0].get("name") == "marked.glb", "Cache lists the stored scene")

	var high := loader.load_scene(marked, Budget.HIGH, options)
	_check(high.has("root") and not high.cached and high.info.stats.lights == 0 and high.info.stats.largest_texture == 2048,
		"High tier is cached separately, also drops realtime lights, and keeps the 2K texture")
	if high.has("root"): high.root.free()
	var lamp_limits := Budget.limits(Budget.HIGH).duplicate()
	lamp_limits.lights = 1
	var lit := loader.load_scene(marked, Budget.HIGH, {"use_cache": false, "limits": lamp_limits})
	if lit.has("root"):
		var kept: Array[Node] = lit.root.find_children("*", "Light3D", true, false)
		_check(kept.size() == 1 and not (kept[0] as Light3D).shadow_enabled and lit.info.actions.lights_removed == 1, "A tier that allows a light keeps one, without shadows")
		lit.root.free()

	var open := loader.load_scene(plain, Budget.LOW, options)
	_check(open.has("root") and open.info.layout.source == "fallback", "Unmarked scene falls back to geometry")
	if open.has("root"):
		var spawn: Transform3D = open.info.layout.spawn
		_check(absf(spawn.origin.y) < 0.01 and absf(spawn.origin.z + 20.0) < 1.0, "Fallback stands on the floor, not on the plinth (y %.3f)" % spawn.origin.y)
		_check(open.info.layout.has("screen") and open.info.layout.screen_width >= 4.0, "Fallback proposes a screen position")
		open.root.free()

	var tight := Budget.limits(Budget.LOW).duplicate()
	tight.triangles = 9000
	var culled := loader.load_scene(marked, Budget.LOW, {"use_cache": false, "limits": tight})
	_check(culled.has("root") and culled.info.actions.meshes_culled > 0 and culled.info.stats.triangles <= 9000,
		"Over-budget scene loses far geometry until it fits (%d culled)" % culled.get("info", {}).get("actions", {}).get("meshes_culled", -1))
	if culled.has("root"):
		_check(culled.root.find_child("Tower0", true, false) != null and culled.root.find_child("Tower5", true, false) == null,
			"Culling removes the farthest objects first")
		culled.root.free()
	var tiny := Budget.limits(Budget.LOW).duplicate()
	tiny.triangles = 10
	tiny.texture_bytes = 3 * 1024 * 1024
	var crowded := loader.load_scene(marked, Budget.LOW, {"use_cache": false, "limits": tiny})
	_check(crowded.has("root") and crowded.info.stats.meshes == 1 and crowded.info.over_budget.has("triangles"),
		"A scene that cannot fit keeps its nearest object and is reported over budget")
	_check(crowded.has("root") and crowded.info.stats.largest_texture < 1024 and crowded.info.actions.texture_size < 1024,
		"Textures step down further when their total is over budget (edge %d)" % crowded.get("info", {}).get("actions", {}).get("texture_size", -1))
	if crowded.has("root"): crowded.root.free()
	var uncut := loader.load_scene(marked, Budget.LOW, {"use_cache": false, "limits": tight, "cull": false})
	_check(uncut.has("root") and uncut.info.over_budget.has("triangles"), "With culling off the scene is reported over budget")
	if uncut.has("root"): uncut.root.free()

	var sidecar := FileAccess.open(fixtures.path_join("plain.scene.json"), FileAccess.WRITE)
	sidecar.store_string(JSON.stringify({"spawn": [3, 0, -4], "spawn_yaw": 1.0, "screen": {"position": [3, 2, -12], "width": 6}}))
	sidecar.close()
	var described := loader.load_scene(plain, Budget.LOW, {"use_cache": false})
	_check(described.has("root") and described.info.layout.source == "sidecar"
		and (described.info.layout.spawn as Transform3D).origin.is_equal_approx(Vector3(3, 0, -4))
		and is_equal_approx(described.info.layout.screen_width, 6.0), "Sidecar description overrides the layout")
	if described.has("root"): described.root.free()
	DirAccess.remove_absolute(fixtures.path_join("plain.scene.json"))

	var source := FileAccess.get_file_as_bytes(marked)
	var cases := {}
	var magic := source.duplicate()
	magic.encode_u32(0, 0x12345678)
	cases["bad_magic.glb"] = magic
	var version := source.duplicate()
	version.encode_u32(4, 1)
	cases["bad_version.glb"] = version
	var overlong := source.duplicate()
	overlong.encode_u32(8, source.size() + 4096)
	cases["length_past_end.glb"] = overlong
	var chunk := source.duplicate()
	chunk.encode_u32(12, 0x7fffffff)
	cases["json_chunk_past_end.glb"] = chunk
	var kind := source.duplicate()
	kind.encode_u32(16, 0x004e4942)
	cases["first_chunk_not_json.glb"] = kind
	cases["truncated.glb"] = source.slice(0, 16)
	var garbage := source.duplicate()
	for offset in range(20, 60): garbage[offset] = 0x7b
	cases["broken_json.glb"] = garbage
	cases["not_a_scene.txt"] = "hello".to_utf8_buffer()
	for name in cases:
		_bytes(fixtures.path_join(name), cases[name])
		var rejected := loader.load_scene(fixtures.path_join(name), Budget.LOW, {"use_cache": false})
		_check(rejected.has("error") and not rejected.has("root"), "Rejects %s" % name)
	_check(loader.load_scene(fixtures.path_join("missing.glb"), Budget.LOW, {"use_cache": false}).has("error"), "Rejects a missing file")
	var small := Budget.limits(Budget.LOW).duplicate()
	small.file_bytes = 1024
	_check(loader.load_scene(marked, Budget.LOW, {"use_cache": false, "limits": small}).get("error") == "Model file too large", "Rejects files above the tier size limit")
	var dense: Dictionary = {"asset": {"version": "2.0"}, "accessors": [{"count": 60000000}], "meshes": [{"primitives": [{"indices": 0}]}], "nodes": []}
	var text := JSON.stringify(dense).to_utf8_buffer()
	while text.size() % 4 != 0: text.append(0x20)
	var packed := PackedByteArray()
	packed.resize(20)
	packed.encode_u32(0, 0x46546c67)
	packed.encode_u32(4, 2)
	packed.encode_u32(8, 20 + text.size())
	packed.encode_u32(12, text.size())
	packed.encode_u32(16, 0x4e4f534a)
	packed.append_array(text)
	_bytes(fixtures.path_join("dense.glb"), packed)
	_check(loader.load_scene(fixtures.path_join("dense.glb"), Budget.LOW, {"use_cache": false}).get("error") == "Scene is too detailed for this headset",
		"Rejects absurd triangle counts before parsing geometry")

	var key := Cache.key(marked, Budget.LOW)
	Cache.remove(key, cache)
	_check(Cache.restore(key, cache) == null and Cache.entries(cache).size() == 2, "Removing a cache entry leaves the others")

	var panorama := Image.create(8192, 64, false, Image.FORMAT_RGB8)
	panorama.fill(Color(0.2, 0.3, 0.6))
	panorama.save_png(fixtures.path_join("wide.png"))
	var sky := SkyLoader.load_sky(fixtures.path_join("wide.png"), Budget.LOW)
	_check(sky.has("sky") and (sky.texture as Texture2D).get_width() == 4096, "Sky panorama is capped at the tier width")
	_check(SkyLoader.load_sky(fixtures.path_join("marked.glb"), Budget.LOW).has("error"), "Sky loader rejects non-image files")

	var tool := ProjectSettings.globalize_path("res://../../build/unity-scene/windows/unity_scene_unpack.exe")
	if FileAccess.file_exists(tool):
		# The desktop tool stands in for the headset's encoder.
		Loader.texture_encoder = func(rgba: PackedByteArray, width: int, height: int, alpha: bool) -> PackedByteArray:
			var raw := FileAccess.open(output.path_join("encode.rgba"), FileAccess.WRITE)
			raw.store_buffer(rgba)
			raw.close()
			if OS.execute(tool, ["etc2", output.path_join("encode.rgba"), str(width), str(height), "1" if alpha else "0", "1", output.path_join("encode.etc2")]) != 0:
				return PackedByteArray()
			return FileAccess.get_file_as_bytes(output.path_join("encode.etc2"))
		var squeezed := loader.load_scene(marked, Budget.HIGH, {"use_cache": false})
		_check(squeezed.has("root") and squeezed.info.actions.textures_compressed == 8, "Decoded textures are compressed when an encoder is present (%d)" % squeezed.get("info", {}).get("actions", {}).get("textures_compressed", -1))
		if squeezed.has("root"):
			var tower := squeezed.root.find_child("Tower0", true, false) as MeshInstance3D
			var texture := (tower.mesh.surface_get_material(0) as BaseMaterial3D).albedo_texture as ImageTexture if tower else null
			_check(texture != null and texture.get_format() == Image.FORMAT_ETC2_RGB8 and texture.get_width() == 2048, "Compressed texture keeps its size in ETC2")
			if texture != null:
				var shown := texture.get_image()
				_check(shown.decompress() == OK and shown.get_pixel(1024, 1024).is_equal_approx(Color.from_hsv(fmod(3 * 0.17, 1.0), 0.6, 0.8)) or _near(shown.get_pixel(1024, 1024), Color.from_hsv(fmod(3 * 0.17, 1.0), 0.6, 0.8)), "Compressed texture decodes back to its colour")
			_check(squeezed.info.stats.texture_bytes * 4 < 30 * 1024 * 1024, "Compressed textures count at a fraction of their decoded size (%d bytes)" % squeezed.info.stats.texture_bytes)
			squeezed.root.free()
		Loader.texture_encoder = Callable()
	else:
		print("Scene import: native tool not built; texture compression not checked")

	loader.finished.connect(_threaded)
	loader.start(marked, Budget.HIGH, options)

static func _near(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.05 and absf(a.g - b.g) < 0.05 and absf(a.b - b.b) < 0.05

func _threaded(result: Dictionary) -> void:
	_check(result.has("root") and result.get("cached", false), "Worker-thread load reports back on the main thread")
	if result.has("root"): result.root.free()
	_finish.call_deferred()  # after the loader has released its worker bookkeeping

func _finish() -> void:
	var file := FileAccess.open(output.path_join("summary.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": checks, "failures": failures, "passed": failures.is_empty()}, "\t"))
	file.close()
	for failure in failures: push_error(failure)
	print("Scene import: %d checks, %d failures" % [checks.size(), failures.size()])
	quit(0 if failures.is_empty() else 1)
