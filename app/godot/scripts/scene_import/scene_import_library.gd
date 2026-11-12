extends Node
## The viewer's own scene files: a private copy of each picked file plus a small catalog.
## Import results live in the cache beside it and are rebuilt from the copy when needed.
signal changed
const Cache := preload("res://scripts/scene_import/scene_import_cache.gd")
const Budget := preload("res://scripts/scene_import/scene_import_budget.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const EXTENSIONS := ["glb", "unity3d", "assetbundle", "bundle", "vrcw", "omission"]
const MAX_ENTRIES := 64
const MAX_BYTES := 768 * 1024 * 1024
var directory := "user://scene_import"
var platform: Object
var entries := {}
var busy := false
var error := ""
var adding := ""
var _request := 0
var _connected: Object
var _thread: Thread

static func supported(title: String) -> bool:
	return title.get_extension().to_lower() in EXTENSIONS

func _sources() -> String:
	return directory.path_join("sources")

func source_path(id: String) -> String:
	var entry: Dictionary = entries.get(id, {})
	return ProjectSettings.globalize_path(_sources().path_join(str(entry.get("file", "")))) if not entry.is_empty() else ""

func thumbnail_path(id: String) -> String:
	return ProjectSettings.globalize_path(directory.path_join("thumbs").path_join(id + ".jpg"))

func load_catalog() -> void:
	entries.clear()
	var parser := JSON.new()
	var file := FileAccess.open(directory.path_join("library.json"), FileAccess.READ)
	if file == null or file.get_length() > 1024 * 1024 or parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary: return
	var saved: Variant = parser.data.get("entries")
	if not saved is Dictionary: return
	for id in saved:
		var entry: Variant = saved[id]
		# Only names this library could have written, and only files that are still there.
		if not entry is Dictionary or not str(id).is_valid_hex_number() or str(entry.get("file", "")) != "%s.%s" % [id, str(entry.get("file", "")).get_extension()]: continue
		if not supported(str(entry.file)) or not FileAccess.file_exists(_sources().path_join(str(entry.file))): continue
		entries[str(id)] = {"title": str(entry.get("title", "")).left(160), "file": str(entry.file), "bytes": int(entry.get("bytes", 0)),
			"added": int(entry.get("added", 0)), "summary": entry.get("summary", {}) if entry.get("summary") is Dictionary else {}}

func save_catalog() -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var partial := directory.path_join("library.json.partial")
	var file := FileAccess.open(partial, FileAccess.WRITE)
	if file == null: return false
	file.store_string(JSON.stringify({"version": 1, "entries": entries}))
	file.close()
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(partial), ProjectSettings.globalize_path(directory.path_join("library.json"))) == OK

func rows() -> Array:
	var result: Array = []
	for id in entries:
		var item: Dictionary = entries[id].duplicate(true)
		item["id"] = id
		item["thumb"] = FileAccess.file_exists(thumbnail_path(id))
		result.append(item)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.added) < int(b.added))
	return result

func progress() -> float:
	if _request > 0 and Methods.supports(platform, "scene_file_import_progress"): return clampf(float(platform.scene_file_import_progress(_request)), -1.0, 1.0)
	return -1.0 if busy else 0.0

## Starts copying one picked file (media-library URI or a local path) into the library.
func add(uri: String, title: String) -> bool:
	if busy: return false
	error = ""
	if not supported(title): error = "Unsupported scene format"
	elif entries.size() >= MAX_ENTRIES: error = "Scene library is full"
	if not error.is_empty():
		changed.emit()
		return false
	adding = title
	if Methods.supports(platform, "import_scene_file"):
		if _connected != platform:
			_connected = platform
			platform.connect("scene_file_imported", _on_imported)
		_request = int(platform.import_scene_file(uri, title))
		if _request > 0:
			busy = true
			changed.emit()
			return true
		error = "Scene import unavailable"
		changed.emit()
		return false
	var path := uri.trim_prefix("file://")
	if not FileAccess.file_exists(path):
		error = "Scene import unavailable"
		changed.emit()
		return false
	busy = true
	_thread = Thread.new()
	_thread.start(_copy.bind(path))
	changed.emit()
	return true

func cancel() -> void:
	if _request > 0 and Methods.supports(platform, "cancel_scene_file_import"): platform.cancel_scene_file_import(_request)
	if _request > 0:
		_request = 0
		busy = false
		changed.emit()

func _copy(path: String) -> Dictionary:
	var input := FileAccess.open(path, FileAccess.READ)
	if input == null or input.get_length() <= 0 or input.get_length() > MAX_BYTES: return {"state": "error", "error": "Scene import unavailable"}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_sources()))
	var target := _sources().path_join("%d.%s" % [Time.get_ticks_usec(), path.get_extension().to_lower()])
	var output := FileAccess.open(target, FileAccess.WRITE)
	if output == null: return {"state": "error", "error": "Could not save scene"}
	while input.get_position() < input.get_length():
		output.store_buffer(input.get_buffer(mini(1024 * 1024, input.get_length() - input.get_position())))
		if output.get_error() != OK:
			output.close()
			DirAccess.remove_absolute(ProjectSettings.globalize_path(target))
			return {"state": "error", "error": "Could not save scene"}
	output.close()
	return {"state": "ready", "path": ProjectSettings.globalize_path(target), "bytes": input.get_length()}

func _process(_delta: float) -> void:
	if _thread and not _thread.is_alive():
		var result: Dictionary = _thread.wait_to_finish()
		_thread = null
		_finish(result)

func _on_imported(id: int, payload: String) -> void:
	if id != _request: return
	_request = 0
	var parser := JSON.new()
	_finish(parser.data if parser.parse(payload) == OK and parser.data is Dictionary else {"state": "error"})

func _finish(result: Dictionary) -> void:
	busy = false
	if result.get("state", "") != "ready":
		if not result.get("cancelled", false): error = str(result.get("error", "Could not download scene")).left(120)
		changed.emit()
		return
	var saved := str(result.get("path", ""))
	var id := Cache.key(saved, "source")
	if id.is_empty():
		DirAccess.remove_absolute(saved)
		error = "Could not save scene"
	elif entries.has(id):
		# The same file again: keep the first copy.
		DirAccess.remove_absolute(saved)
	else:
		var file := "%s.%s" % [id, saved.get_extension().to_lower()]
		if DirAccess.rename_absolute(saved, ProjectSettings.globalize_path(_sources().path_join(file))) != OK:
			DirAccess.remove_absolute(saved)
			error = "Could not save scene"
		else:
			entries[id] = {"title": adding.get_basename().left(160), "file": file, "bytes": int(result.get("bytes", 0)), "added": int(Time.get_unix_time_from_system()), "summary": {}}
			if not save_catalog():
				DirAccess.remove_absolute(ProjectSettings.globalize_path(_sources().path_join(file)))
				entries.erase(id)
				error = "Could not save scene"
	changed.emit()

## What the last import of this scene produced, kept for the card (triangles, what was cut).
func note_summary(id: String, tier: String, info: Dictionary) -> void:
	if not entries.has(id): return
	var stats: Dictionary = info.get("stats", {})
	var actions: Dictionary = info.get("actions", {})
	entries[id].summary[tier] = {"triangles": int(stats.get("triangles", 0)), "batches": int(stats.get("batches", 0)),
		"texture_bytes": int(stats.get("texture_bytes", 0)), "culled": int(actions.get("meshes_culled", 0)),
		"over_budget": info.get("over_budget", []), "source": str(info.get("source", ""))}
	save_catalog()

func rename(id: String, title: String) -> bool:
	var clean := title.strip_edges().replace("
", " ").replace("", " ").left(80)
	if not entries.has(id) or clean.is_empty(): return false
	var previous: String = entries[id].title
	entries[id].title = clean
	if not save_catalog():
		entries[id].title = previous
		return false
	changed.emit()
	return true

func remove(ids: Array) -> bool:
	for id in ids:
		if not entries.has(str(id)): continue
		var path := source_path(str(id))
		for tier in [Budget.LOW, Budget.HIGH]: Cache.remove(Cache.key(path, tier), directory)
		DirAccess.remove_absolute(path)
		if FileAccess.file_exists(thumbnail_path(str(id))): DirAccess.remove_absolute(thumbnail_path(str(id)))
		entries.erase(str(id))
	var saved := save_catalog()
	if not saved: error = "Could not save scene library"
	changed.emit()
	return saved

func _exit_tree() -> void:
	if _thread: _thread.wait_to_finish()
