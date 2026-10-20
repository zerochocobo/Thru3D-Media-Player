extends Node
## Spatial previews keep aspect ratio and alpha. Never share the main photo request/depth queue.
signal preview_ready(uri: String)
const Info := preload("res://scripts/image_info.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const DIRECTORY := "user://photo_gallery_previews"
const PREVIEW_EDGE := 384
const MAX_TEXTURE_BYTES := 32 * 1024 * 1024
const MAX_DISK_BYTES := 64 * 1024 * 1024
const MAX_FILES := 128
var platform: Object
var _connected: Object
var _textures := {}
var _metadata := {}
var _wanted: Array[Dictionary] = []
var _failed := {}
var _request := 0
var _serial := 0
var _active := {}
var _thread: Thread
var _job := {}

func texture(uri: String) -> Texture2D:
	return _textures.get(uri, {}).get("texture")

func metadata(uri: String) -> Dictionary:
	return _metadata.get(uri, _textures.get(uri, {}).get("info", {}))

func retry(uri: String) -> void:
	# A transient transfer/decode failure is retried only on explicit selection, never each frame.
	_failed.erase(uri)

func request(entries: Array[Dictionary]) -> void:
	_wanted = entries.duplicate(true)
	var keys := entries.map(func(entry): return str(entry.uri))
	for uri in _textures.keys():
		if uri not in keys: _textures.erase(uri)
	if not _active.is_empty() and str(_active.uri) not in keys: _cancel()

func clear() -> void:
	_cancel(); _wanted.clear(); _textures.clear(); _metadata.clear(); _failed.clear()

func _cancel() -> void:
	_serial += 1
	if _request > 0 and Methods.supports(platform, "cancel_photo_preview"): platform.cancel_photo_preview(_request)
	_request = 0; _active = {}

func _process(_delta: float) -> void:
	if platform != _connected:
		if is_instance_valid(_connected) and _connected.has_signal("photo_preview_ready") and _connected.is_connected("photo_preview_ready", _on_ready):
			_connected.disconnect("photo_preview_ready", _on_ready)
		_connected = platform
		if is_instance_valid(platform) and platform.has_signal("photo_preview_ready"): platform.connect("photo_preview_ready", _on_ready)
	if _thread and not _thread.is_alive():
		var result: Dictionary = _thread.wait_to_finish(); _thread = null
		if int(_job.serial) == _serial and not _active.is_empty():
			var uri := str(_active.uri)
			if result.has("image"):
				var image: Image = result.image
				_trim(image.get_data_size())
				if _metadata.size() >= 512: _metadata.erase(_metadata.keys()[0])
				_metadata[uri] = result.info
				_textures[uri] = {"texture": ImageTexture.create_from_image(image), "info": result.info, "bytes": image.get_data_size()}
			elif _job.info.get("cached", false):
				var cached := DIRECTORY.path_join(uri.sha256_text() + ".png")
				DirAccess.remove_absolute(cached); DirAccess.remove_absolute(cached + ".json")
			else: _failed[uri] = true
			_active = {}; _request = 0; preview_ready.emit(uri)
		_release(int(_job.get("id", 0))); _job = {}
	if _active.is_empty() and not _thread:
		for entry in _wanted:
			var uri := str(entry.uri)
			if _textures.has(uri) or _failed.has(uri): continue
			_active = entry; _serial += 1
			var path := DIRECTORY.path_join(uri.sha256_text() + ".png")
			var meta := path + ".json"
			if preload("res://scripts/media_privacy.gd").cache_allowed(uri) and FileAccess.file_exists(path) and FileAccess.file_exists(meta):
				var info: Variant = JSON.parse_string(FileAccess.get_file_as_string(meta))
				if info is Dictionary:
					info["path"] = ProjectSettings.globalize_path(path); info["cached"] = true
					_start(info, 0); break
			if Methods.supports(platform, "open_photo_preview"):
				_request = int(platform.open_photo_preview(uri))
				if _request <= 0: _failed[uri] = true; _active = {}
			else:
				_start({"path": uri.trim_prefix("file://").uri_decode()}, 0)
			break

func _on_ready(id: int, payload: String) -> void:
	if id != _request or _active.is_empty(): _release(id); return
	var info: Variant = JSON.parse_string(payload)
	if not info is Dictionary or info.get("state") != "ready":
		_failed[str(_active.uri)] = true; _active = {}; _request = 0; _release(id); return
	_start(info, id)

func _start(info: Dictionary, id: int) -> void:
	_job = {"info": info, "id": id, "serial": _serial, "uri": str(_active.uri)}
	_thread = Thread.new()
	if _thread.start(_decode.bind(_job)) != OK:
		_thread = null; _failed[str(_active.uri)] = true; _active = {}; _request = 0; _release(id)

static func _decode(job: Dictionary) -> Dictionary:
	var info: Dictionary = job.info.duplicate(true)
	var path := str(info.get("path", ""))
	if not path.is_absolute_path() or not FileAccess.file_exists(path): return {}
	var header := Info.read_header(path)
	if header.is_empty() or int(header.width) * int(header.height) > 32 * 1024 * 1024 or int(header.width) > 8192 or int(header.height) > 8192: return {}
	var image := Image.new()
	var bytes := FileAccess.get_file_as_bytes(path)
	var code := image.load_jpg_from_buffer(bytes) if header.codec == "jpg" else (image.load_png_from_buffer(bytes) if header.codec == "png" else image.load_webp_from_buffer(bytes))
	if code != OK or image.is_empty(): return {}
	if not info.get("cached", false):
		Info.orient(image, int(info.get("orientation", header.get("orientation", 1))))
		info.merge(header, false)
		var ratio := minf(1.0, float(PREVIEW_EDGE) / maxf(image.get_width(), image.get_height()))
		image.resize(maxi(1, roundi(image.get_width() * ratio)), maxi(1, roundi(image.get_height() * ratio)), Image.INTERPOLATE_BILINEAR)
		info["orientation"] = 1
		if not preload("res://scripts/media_privacy.gd").cache_allowed(str(job.uri)):
			image.generate_mipmaps(); return {"image": image, "info": info}
		DirAccess.make_dir_recursive_absolute(DIRECTORY)
		var target := DIRECTORY.path_join(str(job.uri).sha256_text() + ".png")
		if image.save_png(target) == OK:
			var file := FileAccess.open(target + ".json", FileAccess.WRITE)
			if file: file.store_string(JSON.stringify(info))
			_prune_disk(target)
	# Old 512px disk previews share the same bounded GPU budget as newly decoded ones.
	var shrink := minf(1.0, float(PREVIEW_EDGE) / maxf(image.get_width(), image.get_height()))
	if shrink < 1.0: image.resize(maxi(1, roundi(image.get_width() * shrink)), maxi(1, roundi(image.get_height() * shrink)), Image.INTERPOLATE_BILINEAR)
	image.generate_mipmaps()
	return {"image": image, "info": info}

static func _prune_disk(protected: String) -> void:
	var directory := DirAccess.open(DIRECTORY)
	if not directory: return
	var files := []; var total := 0
	for name in directory.get_files():
		if name.length() != 68 or not name.ends_with(".png"): continue
		var path := DIRECTORY.path_join(name)
		var handle := FileAccess.open(path, FileAccess.READ)
		if not handle: continue
		var bytes := handle.get_length(); total += bytes; handle = null
		files.append({"path": path, "bytes": bytes, "modified": FileAccess.get_modified_time(path)})
	files.sort_custom(func(a, b): return int(a.modified) < int(b.modified))
	var count := files.size()
	for file in files:
		if count <= MAX_FILES and total <= MAX_DISK_BYTES: break
		if str(file.path) == protected: continue
		if DirAccess.remove_absolute(str(file.path)) == OK:
			DirAccess.remove_absolute(str(file.path) + ".json"); count -= 1; total -= int(file.bytes)

static func disk_usage() -> Vector2i:
	var usage := Vector2i.ZERO
	var directory := DirAccess.open(DIRECTORY)
	if not directory: return usage
	for name in directory.get_files():
		if not _cache_file(name): continue
		var handle := FileAccess.open(DIRECTORY.path_join(name), FileAccess.READ)
		if handle: usage += Vector2i(1, handle.get_length())
	return usage

static func _cache_file(name: String) -> bool:
	var stem := name.trim_suffix(".json").trim_suffix(".png")
	return stem.length() == 64 and stem.is_valid_hex_number() and (name.ends_with(".png") or name.ends_with(".png.json"))

static func clear_disk() -> void:
	var directory := DirAccess.open(DIRECTORY)
	if not directory: return
	for name in directory.get_files():
		if _cache_file(name): directory.remove(name)

func _trim(incoming: int) -> void:
	var bytes := incoming
	for item in _textures.values(): bytes += int(item.bytes)
	while bytes > MAX_TEXTURE_BYTES and not _textures.is_empty():
		var uri: String = _textures.keys()[0]; bytes -= int(_textures[uri].bytes); _textures.erase(uri)

func _release(id: int) -> void:
	if id > 0 and Methods.supports(platform, "release_photo_preview"): platform.release_photo_preview(id)

func _exit_tree() -> void:
	clear()
	if _thread: _thread.wait_to_finish(); _thread = null; _release(int(_job.get("id", 0)))
