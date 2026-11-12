extends RefCounted
## Imported scenes stored as native Godot scenes so a second open skips glTF parsing.
## The key samples the file's content, so the same model from another share reuses the entry.
## 2: Unity surfaces read the screen light from global uniforms. 3: no imported lights on any tier.
const VERSION := 4
const ROOT := "user://scene_import"
const META := "scene_import"
const SAMPLE_BYTES := 1024 * 1024

static func key(path: String, tier: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return ""
	var size := file.get_length()
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(("%d|%s|%d|" % [VERSION, tier, size]).to_utf8_buffer())
	for offset in [0, maxi(size / 2 - SAMPLE_BYTES / 2, 0), maxi(size - SAMPLE_BYTES, 0)]:
		file.seek(offset)
		var sample := file.get_buffer(mini(SAMPLE_BYTES, size - offset))
		if not sample.is_empty(): hash.update(sample)
	return hash.finish().hex_encode().substr(0, 32)

static func _scene_path(entry_key: String, base: String) -> String:
	return base.path_join(entry_key).path_join("scene.scn")

static func restore(entry_key: String, base: String = ROOT) -> Node3D:
	var path := _scene_path(entry_key, base)
	if entry_key.is_empty() or not FileAccess.file_exists(path): return null
	# Main thread only: loading a scene from a worker thread (Godot 4.7.2) keeps it and every
	# texture in it alive for good. Background opens go through restore_async.
	var packed := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	return _instantiate(packed)

static func has(entry_key: String, base: String = ROOT) -> bool:
	return not entry_key.is_empty() and FileAccess.file_exists(_scene_path(entry_key, base))

## Call from the main thread: the engine's own loader threads read the file while frames keep
## coming, and the scene is instantiated back on the main thread.
static func restore_async(entry_key: String, base: String = ROOT) -> Node3D:
	var path := _scene_path(entry_key, base)
	var tree := Engine.get_main_loop() as SceneTree
	if not has(entry_key, base) or tree == null: return null
	if ResourceLoader.load_threaded_request(path, "PackedScene", true, ResourceLoader.CACHE_MODE_IGNORE) != OK: return null
	while ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS: await tree.process_frame
	if ResourceLoader.load_threaded_get_status(path) != ResourceLoader.THREAD_LOAD_LOADED: return null
	return _instantiate(ResourceLoader.load_threaded_get(path) as PackedScene)

static func _instantiate(packed: PackedScene) -> Node3D:
	var root := packed.instantiate() as Node3D if packed else null
	if root == null: return null
	var info: Variant = root.get_meta(META, null)
	if not info is Dictionary or info.get("version") != VERSION:
		root.free()
		return null
	return root

static func store(entry_key: String, root: Node3D, summary: Dictionary, base: String = ROOT) -> Error:
	if entry_key.is_empty(): return ERR_INVALID_PARAMETER
	var pending: Array[Node] = root.get_children()
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		node.owner = root
		pending.append_array(node.get_children())
	var packed := PackedScene.new()
	var result := packed.pack(root)
	if result != OK: return result
	var directory := base.path_join(entry_key)
	DirAccess.make_dir_recursive_absolute(directory)
	# Write beside the final name so an interrupted save never leaves a half scene behind.
	var partial := directory.path_join("scene.partial.scn")
	result = ResourceSaver.save(packed, partial, ResourceSaver.FLAG_COMPRESS)
	if result != OK: return result
	result = DirAccess.rename_absolute(partial, _scene_path(entry_key, base))
	if result != OK: return result
	var listing := FileAccess.open(directory.path_join("summary.json"), FileAccess.WRITE)
	if listing: listing.store_string(JSON.stringify(summary))
	return OK

## Summaries for a library view, without loading any scene.
static func entries(base: String = ROOT) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	for entry_key in DirAccess.get_directories_at(base):
		if not FileAccess.file_exists(_scene_path(entry_key, base)): continue
		var summary: Variant = JSON.parse_string(FileAccess.get_file_as_string(base.path_join(entry_key).path_join("summary.json")))
		var entry: Dictionary = summary if summary is Dictionary else {}
		entry["key"] = entry_key
		entry["bytes"] = FileAccess.get_size(_scene_path(entry_key, base))
		found.append(entry)
	return found

static func remove(entry_key: String, base: String = ROOT) -> void:
	if not entry_key.is_valid_hex_number(): return
	var directory := base.path_join(entry_key)
	if not DirAccess.dir_exists_absolute(directory): return
	for file in DirAccess.get_files_at(directory): DirAccess.remove_absolute(directory.path_join(file))
	DirAccess.remove_absolute(directory)
