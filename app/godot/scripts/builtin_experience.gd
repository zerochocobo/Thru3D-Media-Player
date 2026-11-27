extends RefCounted
## The library owns the virtual directory. Native decoders receive ordinary private files.
const FOLDER := "builtin://experience"
# Advance only when there is a new experience worth introducing.
const GUIDE_VERSION := 1
const PACK := "res://data/experience.dat"

var cache_dir := "user://builtin_experience"
var _zip := ZIPReader.new()
var _catalog: Dictionary = {}
var _paths := {}
var _pictures := {}

func _init() -> void:
	if _zip.open(PACK) == OK:
		var data: Variant = JSON.parse_string(_zip.read_file("catalog.json").get_string_from_utf8())
		if data is Dictionary: _catalog = data
	if _catalog.is_empty(): push_error("Unable to open bundled experience catalog")

func title(language: String) -> String:
	return str(_catalog.get("collection", {}).get(language, "Try Thru3D"))

func entries(language: String, books: bool) -> Array:
	var result := []
	for item in _catalog.get("items", []):
		if item.kind == "book" and not books: continue
		var file := str(item.get("file", ""))
		for edition in item.get("editions", []):
			if edition.locale == language: file = edition.file; break
		if file.is_empty(): continue
		var path := _private_file(file)
		var uri := ""
		if not path.is_empty():
			var encoded := path.uri_encode().replace("%2F", "/").replace("%3A", ":")
			uri = ("file://" if path.begins_with("/") else "file:///") + encoded
		result.append({"title": item.title.get(language, item.title.en), "kind": item.kind,
			"uri": uri, "size": _catalog.files[file].size, "enabled": not uri.is_empty(),
			"experience_thumbnail": item.thumbnail, "experience_action": item.get("experience", "")})
	return result

func _private_file(file: String) -> String:
	if _paths.has(file): return _paths[file]
	var path := ProjectSettings.globalize_path(cache_dir.path_join(file))
	var digest: String = _catalog.files[file].sha256
	if not FileAccess.file_exists(path) or FileAccess.get_sha256(path) != digest:
		if DirAccess.make_dir_recursive_absolute(path.get_base_dir()) != OK: return ""
		var pending := path + ".tmp"
		var output := FileAccess.open(pending, FileAccess.WRITE)
		if not output: return ""
		output.store_buffer(_zip.read_file(file))
		output.close()
		if FileAccess.get_sha256(pending) != digest or DirAccess.rename_absolute(pending, path) != OK:
			DirAccess.remove_absolute(pending)
			return ""
	_paths[file] = path
	return path

func thumbnail(file: String) -> Texture2D:
	if not _pictures.has(file):
		var image := Image.new()
		if image.load_jpg_from_buffer(_zip.read_file(file)) != OK: return null
		_pictures[file] = ImageTexture.create_from_image(image)
	return _pictures[file]
