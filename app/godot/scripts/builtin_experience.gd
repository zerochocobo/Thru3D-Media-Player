extends RefCounted
## The library owns the virtual directory. Native decoders receive ordinary private files.
const FOLDER := "builtin://experience"
# Advance only when there is a new experience worth introducing.
const GUIDE_VERSION := 1
const PACK := "res://data/experience.dat"
# Lists what the private copy holds; written only after every file verified.
const STAMP := ".ready.json"

var cache_dir := "user://builtin_experience"
var _catalog: Dictionary = {}
var _task := -1
var _paths := {}
var _images := {}
var _pictures := {}

func _init() -> void:
	var zip := ZIPReader.new()
	if zip.open(PACK) == OK:
		var data: Variant = JSON.parse_string(zip.read_file("catalog.json").get_string_from_utf8())
		if data is Dictionary: _catalog = data
		zip.close()
	if _catalog.is_empty(): push_error("Unable to open bundled experience catalog")

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _task >= 0: WorkerThreadPool.wait_for_task_completion(_task)

## Copies the files and decodes the cards away from the frame. Android keeps the pack
## deflated inside the APK, where every read of a member re-inflates from the start.
func prepare() -> void:
	if _task == -1 and not _catalog.is_empty(): _task = WorkerThreadPool.add_task(_prepare, false, "Experience files")

func _finish() -> void:
	prepare()
	if _task >= 0: WorkerThreadPool.wait_for_task_completion(_task); _task = -2

func title(language: String) -> String:
	return str(_catalog.get("collection", {}).get(language, "Try Thru3D"))

func entries(language: String, books: bool) -> Array:
	_finish()
	var result := []
	for item in _catalog.get("items", []):
		if item.kind == "book" and not books: continue
		var file := str(item.get("file", ""))
		for edition in item.get("editions", []):
			if edition.locale == language: file = edition.file; break
		if file.is_empty(): continue
		var path := str(_paths.get(file, ""))
		var uri := ""
		if not path.is_empty():
			var encoded := path.uri_encode().replace("%2F", "/").replace("%3A", ":")
			uri = ("file://" if path.begins_with("/") else "file:///") + encoded
		result.append({"title": item.title.get(language, item.title.en), "kind": item.kind,
			"uri": uri, "size": _catalog.files[file].size, "enabled": not uri.is_empty(),
			"experience_thumbnail": item.thumbnail, "experience_action": item.get("experience", "")})
	return result

func thumbnail(file: String) -> Texture2D:
	_finish()
	if not _pictures.has(file):
		var image: Image = _images.get(file)
		if not image: return null
		_pictures[file] = ImageTexture.create_from_image(image)
		_images.erase(file)
	return _pictures[file]

# Worker thread: touches only the cache directory and its own members until _finish().
func _prepare() -> void:
	var root := ProjectSettings.globalize_path(cache_dir)
	var digests := {}
	var cards := {}
	for item in _catalog.get("items", []):
		cards[str(item.thumbnail)] = true
		for file in [str(item.get("file", ""))] + item.get("editions", []).map(func(edition): return str(edition.file)):
			if not file.is_empty(): digests[file] = str(_catalog.files[file].sha256)
	for card in cards: digests[card] = str(_catalog.files[card].sha256)
	var ready: Array = digests.keys() if _stamped(root, digests) else _extract(root, digests)
	for file in ready: _paths[file] = root.path_join(file)
	for card in cards:
		if not _paths.has(card): continue
		var image := Image.load_from_file(_paths[card])
		if image: _images[card] = image

func _stamped(root: String, digests: Dictionary) -> bool:
	var saved: Variant = JSON.parse_string(FileAccess.get_file_as_string(root.path_join(STAMP)))
	if not saved is Dictionary or saved != digests: return false
	for file in digests:
		var handle := FileAccess.open(root.path_join(file), FileAccess.READ)
		if not handle or handle.get_length() != int(_catalog.files[file].size): return false
	return true

func _extract(root: String, digests: Dictionary) -> Array:
	var ready := []
	if DirAccess.make_dir_recursive_absolute(root) != OK: return ready
	DirAccess.remove_absolute(root.path_join(STAMP))
	# One sequential pass out of the APK; members are then read from a plain file.
	var pack := root.path_join(".pack.tmp")
	var source := FileAccess.open(PACK, FileAccess.READ)
	var copy := FileAccess.open(pack, FileAccess.WRITE)
	if not source or not copy: return ready
	while source.get_position() < source.get_length():
		copy.store_buffer(source.get_buffer(1 << 20))
	copy.close(); source.close()
	var zip := ZIPReader.new()
	var complete := zip.open(pack) == OK
	for file in digests:
		if not complete: break
		var path := root.path_join(file)
		var data := zip.read_file(file)
		var hashing := HashingContext.new()
		hashing.start(HashingContext.HASH_SHA256); hashing.update(data)
		if hashing.finish().hex_encode() != digests[file] or DirAccess.make_dir_recursive_absolute(path.get_base_dir()) != OK:
			complete = false; break
		var pending := path + ".tmp"
		var output := FileAccess.open(pending, FileAccess.WRITE)
		if not output: complete = false; break
		output.store_buffer(data)
		output.close()
		if DirAccess.rename_absolute(pending, path) != OK:
			DirAccess.remove_absolute(pending); complete = false
		else: ready.append(file)
	zip.close()
	DirAccess.remove_absolute(pack)
	if complete:
		var stamp := FileAccess.open(root.path_join(STAMP), FileAccess.WRITE)
		if stamp: stamp.store_string(JSON.stringify(digests))
	return ready
