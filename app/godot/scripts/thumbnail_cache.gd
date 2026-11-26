extends RefCounted
## Pictures for library tiles. Played videos get a frame of the displayed picture (see capture).
## DLNA items prefer the cover their server offers, with the played frame as fallback. Nothing
## here opens or reads a video file. Settings > clear cache empties the directory.

const Privacy := preload("res://scripts/media_privacy.gd")
const References := preload("res://scripts/thumbnail_references.gd")
static var _private_images: Dictionary = {}
static var _private_speculative: Dictionary = {}
const DIRECTORY := "user://thumbnails"
const SIZE := Vector2i(320, 180)
const SHADER_2D := preload("res://shaders/thumbnail.gdshader")
const SHADER_OES := preload("res://shaders/thumbnail_oes.gdshader")
const KEEP_TEXTURES := 96
const MAX_BYTES := 256 * 1024 * 1024
const SPECULATIVE_BYTES := 64 * 1024 * 1024
const INDEX_FILE := DIRECTORY + "/index.bin"
const INDEX_PENDING := INDEX_FILE + ".pending"

static var _textures: Dictionary = {} # file path -> ImageTexture, most recent last
static var _protected: Dictionary = {} # the current recent entries survive normal browsing
static var _reads: Dictionary = {}
static var _misses: Dictionary = {}
static var _read_task := -1
static var _read_key := ""
static var _read_local := false
static var _read_result: Image
static var _read_discard := false
static var _last_upload_frame := -1
static var loaded_key := ""
static var revision := 0
static var generation := 0
static var _records: Dictionary = {} # generated filename -> bytes, timestamp, locality and quality
static var _disk_bytes := 0
static var _speculative_bytes := 0
static var _index_loaded := false
static var _index_task := -1
static var _index_result: Dictionary
static var _index_save_at := 0
static var _index_save_task := -1
static var _index_save_generation := -1
static var _index_save_ok := false
static var _index_touched := false
static var _pending_writes: Dictionary = {}
static var _write_frame := -1
enum ClearScope { NONE, NETWORK, ALL }
static var _clear_scope := ClearScope.NONE
static var _active_clear := ClearScope.NONE
static var _clear_local: Dictionary = {}
static var _clear_task := -1
static var _removed_on_clear: Array[String] = []

static func protect_keys(keys: Array) -> void:
	_protected.clear()
	for key in keys.slice(0, 32):
		if key is String and not key.is_empty(): _protected[path_for(key)] = true

static func path_for(key: String) -> String:
	return _digest_path(key.sha1_text())

static func _digest_path(digest: String) -> String:
	return DIRECTORY.path_join(digest + ".jpg")

static func relocate(old_uri: String, new_uri: String) -> void:
	if not clearing() and old_uri != new_uri:
		relocate_digest(old_uri.sha1_text(), new_uri)
		References.relocate_picture(old_uri, new_uri)

static func relocate_digest(old: String, new_uri: String) -> void:
	var next := new_uri.sha1_text()
	if clearing() or old == next or not _valid_digest(old): return
	_ensure_index()
	_invalidate(old)
	_invalidate(next)
	_pending_writes.erase(new_uri)
	var old_path := _digest_path(old)
	var new_path := _digest_path(next)
	_textures.erase(old_path); _textures.erase(new_path)
	if _private_images.has(old):
		_private_images[next] = _private_images[old]
		_private_images.erase(old)
		_private_speculative[next] = _private_speculative.get(old, false)
		_private_speculative.erase(old)
	var record: Dictionary = _records.get(old_path.get_file(), {}).duplicate()
	if record.is_empty(): return
	if not Privacy.cache_allowed(new_uri):
		_remove_file(old_path.get_file())
	elif DirAccess.rename_absolute(old_path, new_path) == OK:
		_untrack(old_path.get_file())
		_untrack(new_path.get_file())
		record.local = Privacy.is_local(new_uri)
		_track(new_path.get_file(), record)

static func has(key: String) -> bool:
	if clearing() or key.is_empty() or Privacy.protected_uri(key): return false
	if _pending_writes.has(key): return true
	return has_digest(key.sha1_text(), Privacy.is_local(key), Privacy.cache_allowed(key))

static func has_digest(digest: String, local: bool, can_read_disk: bool = true) -> bool:
	if clearing() or not _valid_digest(digest) or _locked(): return false
	if not can_read_disk or not _disk_policy(local): return _private_images.has(digest)
	if _misses.has(digest): return false
	var path := _digest_path(digest)
	return _records.has(path.get_file()) if _index_loaded else FileAccess.file_exists(path)

static func has_played_picture(key: String) -> bool:
	if not has(key): return false
	if not Privacy.cache_allowed(key): return not _private_speculative.get(key.sha1_text(), false)
	if _pending_writes.has(key): return not _pending_writes[key].speculative
	var record: Dictionary = _records.get(path_for(key).get_file(), {})
	return record.get("quality") != "speculative"

static func texture(key: String) -> Texture2D:
	if clearing() or key.is_empty() or Privacy.protected_uri(key):
		return null
	return texture_by_digest(key.sha1_text(), Privacy.is_local(key), Privacy.cache_allowed(key))

static func texture_by_digest(digest: String, local: bool, can_read_disk: bool = true) -> Texture2D:
	if clearing() or not _valid_digest(digest) or _locked(): return null
	if not can_read_disk or not _disk_policy(local): return _private_images.get(digest)
	var path := _digest_path(digest)
	if _textures.has(path):
		var cached: Texture2D = _textures[path]
		_textures.erase(path)
		_textures[path] = cached
		_touch(path.get_file())
		return cached
	if _index_loaded and not _records.has(path.get_file()): return null
	if digest != _read_key and not _misses.has(digest) and not _reads.has(digest):
		_reads[digest] = local
		if _reads.size() > KEEP_TEXTURES: _reads.erase(_reads.keys()[0])
	return null

## Called on the render thread. A cold read owns its slot until the worker exits.
static func poll() -> void:
	References.poll()
	if not _poll_index(): return
	if clearing():
		_poll_clear()
		return
	if not _pending_writes.is_empty() and _write_frame != Engine.get_process_frames():
		var key: String = _pending_writes.keys().front()
		var pending: Dictionary = _pending_writes[key]
		_pending_writes.erase(key)
		_write_frame = Engine.get_process_frames()
		if Privacy.cache_allowed(key): store_encoded(key, pending.bytes, pending.speculative)
	if _read_task >= 0:
		if not WorkerThreadPool.is_task_completed(_read_task): return
		if _last_upload_frame == Engine.get_process_frames(): return
		WorkerThreadPool.wait_for_task_completion(_read_task)
		_read_task = -1
		if not _read_discard and _disk_policy(_read_local):
			if _read_result and not _read_result.is_empty():
				_remember_texture(_digest_path(_read_key), _read_result)
				_touch(_digest_path(_read_key).get_file())
				_last_upload_frame = Engine.get_process_frames()
				loaded_key = _read_key
				revision += 1
			else:
				_remove_file(_digest_path(_read_key).get_file())
				_misses[_read_key] = true
				if _misses.size() > KEEP_TEXTURES * 4: _misses.erase(_misses.keys()[0])
		_read_result = null
		_read_key = ""
	if _reads.is_empty(): return
	_read_key = _reads.keys().back()
	_read_local = _reads[_read_key]
	var path := _digest_path(_read_key)
	_reads.erase(_read_key)
	if not _records.has(path.get_file()):
		_read_key = ""
		return
	_read_discard = false
	_read_task = WorkerThreadPool.add_task(_read_image.bind(path))

static func _read_image(path: String) -> void:
	# Cache files are small, generated JPEGs. The worker owns its Image until joined.
	var file := FileAccess.open(path, FileAccess.READ)
	if not file or file.get_length() <= 0 or file.get_length() > 512 * 1024: return
	var bytes := file.get_buffer(file.get_length())
	var image := Image.new()
	if image.load_jpg_from_buffer(bytes) == OK and image.get_size() == SIZE:
		_read_result = image

static func _remember_texture(path: String, image: Image) -> void:
	_textures.erase(path)
	_textures[path] = ImageTexture.create_from_image(image)
	while _textures.size() > KEEP_TEXTURES:
		_textures.erase(_textures.keys()[0])

static func _invalidate(digest: String) -> void:
	_reads.erase(digest)
	_misses.erase(digest)
	if _read_key == digest: _read_discard = true

static func _valid_digest(value: String) -> bool:
	return value.length() == 40 and value.is_valid_hex_number()

static func _locked() -> bool:
	return Privacy.vault != null and Privacy.vault.protected and Privacy.vault.locked

static func _disk_policy(local: bool) -> bool:
	return (Privacy.vault == null or not Privacy.vault.protected) and (Privacy.mode == Privacy.ALL or (Privacy.mode == Privacy.LOCAL and local))

static func _poll_index() -> bool:
	if not _index_loaded:
		if _index_task < 0:
			_index_task = WorkerThreadPool.add_task(_read_index)
		if not WorkerThreadPool.is_task_completed(_index_task): return false
		_ensure_index()
	_poll_index_save()
	return true

static func ready() -> bool:
	return _index_loaded

static func reading() -> bool:
	return _read_task >= 0 or not _reads.is_empty()

static func can_upload() -> bool:
	return _last_upload_frame != Engine.get_process_frames()

static func _read_index() -> void:
	var records: Dictionary = {}
	var prior: Dictionary = {}
	var saved := FileAccess.open(INDEX_FILE, FileAccess.READ)
	if saved and saved.get_length() <= 16 * 1024 * 1024:
		var parsed: Variant = saved.get_var()
		if parsed is Dictionary: prior = parsed
	var directory := DirAccess.open(DIRECTORY)
	if directory:
		for name in directory.get_files():
			if name in ["index.bin.tmp", "index.bin.pending"] or _generated_image(name.trim_suffix(".tmp")) and name.ends_with(".tmp") or _generated_image(name.trim_suffix(".prefetch")) and name.ends_with(".prefetch"):
				directory.remove(name)
			if not _generated_image(name): continue
			var file := FileAccess.open(DIRECTORY.path_join(name), FileAccess.READ)
			if not file: continue
			var record: Dictionary = prior[name] if prior.get(name) is Dictionary else {}
			records[name] = {"bytes": file.get_length(), "local": bool(record.get("local", false)),
				"quality": "speculative" if record.get("quality") == "speculative" else "played",
				"used": int(record.get("used", FileAccess.get_modified_time(DIRECTORY.path_join(name)) * 1000))}
	var ordered := records.keys()
	ordered.sort_custom(func(a, b): return records[a].used < records[b].used)
	_index_result = {}
	for name in ordered: _index_result[name] = records[name]

static func _ensure_index() -> void:
	if _index_loaded: return
	if _index_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_index_task)
		_index_task = -1
	else:
		_read_index()
	for name in _index_result: _track(name, _index_result[name])
	_index_result.clear()
	_index_loaded = true
	if not clearing(): prune()

static func _generated_image(name: String) -> bool:
	return name.length() == 44 and name.ends_with(".jpg") and name.get_basename().is_valid_hex_number()

static func _dirty_index() -> void:
	if _index_save_at == 0: _index_save_at = Time.get_ticks_msec() + 1200

static func _poll_index_save() -> void:
	if _index_save_task >= 0:
		if not WorkerThreadPool.is_task_completed(_index_save_task): return
		WorkerThreadPool.wait_for_task_completion(_index_save_task)
		_index_save_task = -1
		if not _index_save_ok or _index_save_generation != generation or DirAccess.rename_absolute(INDEX_PENDING, INDEX_FILE) != OK:
			if FileAccess.file_exists(INDEX_PENDING): DirAccess.remove_absolute(INDEX_PENDING)
	if _clear_scope != ClearScope.NONE or _clear_task >= 0: return
	if _index_save_at <= 0 or Time.get_ticks_msec() < _index_save_at: return
	_index_save_at = 0
	if _records.is_empty():
		if FileAccess.file_exists(INDEX_FILE): DirAccess.remove_absolute(INDEX_FILE)
		return
	_index_save_generation = generation
	_index_touched = false
	_index_save_task = WorkerThreadPool.add_task(_write_index_snapshot.bind(_records.duplicate()))

static func _write_index_snapshot(records: Dictionary) -> void:
	_index_save_ok = _write_index(INDEX_PENDING, records)

static func _write_index(path: String, records: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file: return false
	file.store_var(records)
	var written := file.get_error() == OK and file.get_position() <= 16 * 1024 * 1024
	file.close()
	return written

static func _flush_index() -> void:
	_index_save_at = 0
	if _records.is_empty():
		if FileAccess.file_exists(INDEX_FILE): DirAccess.remove_absolute(INDEX_FILE)
		return
	var temporary := INDEX_FILE + ".tmp"
	if not _write_index(temporary, _records) or DirAccess.rename_absolute(temporary, INDEX_FILE) != OK:
		if FileAccess.file_exists(temporary): DirAccess.remove_absolute(temporary)

static func _touch(name: String) -> void:
	if not _records.has(name): return
	var now := int(Time.get_unix_time_from_system() * 1000.0)
	if now - int(_records[name].used) < 5000: return
	var record: Dictionary = _records[name].duplicate()
	record.used = now
	_records.erase(name)
	_records[name] = record
	_index_touched = true

static func _track(name: String, record: Dictionary) -> void:
	_records[name] = record
	_disk_bytes += int(record.bytes)
	if record.quality == "speculative": _speculative_bytes += int(record.bytes)
	_dirty_index()

static func _untrack(name: String) -> void:
	if not _records.has(name): return
	var record: Dictionary = _records[name]
	_disk_bytes -= int(record.bytes)
	if record.quality == "speculative": _speculative_bytes -= int(record.bytes)
	_records.erase(name)
	_dirty_index()

static func _remove_file(name: String) -> bool:
	var path := DIRECTORY.path_join(name)
	if DirAccess.remove_absolute(path) != OK and FileAccess.file_exists(path): return false
	_untrack(name)
	_textures.erase(path)
	var digest := name.get_basename()
	_reads.erase(digest)
	if _read_key == digest: _read_discard = true
	return true

## Fills SIZE (see fit) and stores it as the picture of [key].
static func store(key: String, image: Image, speculative: bool = false) -> bool:
	if clearing() or key.is_empty() or (Privacy.vault != null and Privacy.vault.protected and Privacy.vault.locked) or not image or image.is_empty():
		return false
	var picture := fit(image)
	if not Privacy.cache_allowed(key):
		return store_transient(key, picture, speculative)
	if not store_encoded(key, picture.save_jpg_to_buffer(0.85), speculative): return false
	_remember_texture(path_for(key), picture)
	return true

static func store_transient(key: String, picture: Image, speculative: bool) -> bool:
	if (clearing() or key.is_empty() or _locked() or Privacy.cache_allowed(key)
			or not picture or picture.get_size() != SIZE): return false
	var digest := key.sha1_text()
	if speculative and _private_images.has(digest) and not _private_speculative.get(digest, false): return false
	if speculative and not can_upload(): return false
	_private_images.erase(digest)
	_private_images[digest] = ImageTexture.create_from_image(picture)
	_private_speculative[digest] = speculative
	if speculative: _last_upload_frame = Engine.get_process_frames()
	if _private_images.size() > KEEP_TEXTURES:
		var oldest: String = _private_images.keys().front()
		_private_images.erase(oldest)
		_private_speculative.erase(oldest)
	return true

## Fills SIZE and encodes it: safe on a worker thread (no cache or file access).
static func encode(image: Image) -> PackedByteArray:
	if not image or image.is_empty(): return PackedByteArray()
	return fit(image).save_jpg_to_buffer(0.85)

## Stores a picture encode() made off the render thread.
static func store_encoded(key: String, jpg: PackedByteArray, speculative: bool = false) -> bool:
	if clearing() or key.is_empty() or jpg.is_empty() or jpg.size() > 512 * 1024: return false
	if Privacy.vault != null and Privacy.vault.protected and Privacy.vault.locked: return false
	if not Privacy.cache_allowed(key):
		var picture := Image.new()
		return store(key, picture, speculative) if picture.load_jpg_from_buffer(jpg) == OK else false
	if _index_task >= 0 and not WorkerThreadPool.is_task_completed(_index_task):
		if _pending_writes.size() >= 16 and not _pending_writes.has(key): return false
		if speculative and _pending_writes.has(key) and not _pending_writes[key].speculative: return false
		_pending_writes[key] = {"bytes": jpg, "speculative": speculative}
		return true
	_ensure_index()
	DirAccess.make_dir_recursive_absolute(DIRECTORY)
	var path := path_for(key)
	var temporary := path + ".tmp"
	if _write_jpeg(temporary, jpg) and _install_jpeg(key, temporary, jpg.size(), speculative): return true
	if FileAccess.file_exists(temporary): DirAccess.remove_absolute(temporary)
	return false

static func stage_prefetch(key: String, jpg: PackedByteArray) -> String:
	if key.is_empty() or jpg.is_empty() or jpg.size() > 512 * 1024: return ""
	if DirAccess.make_dir_recursive_absolute(DIRECTORY) != OK: return ""
	var directory := DirAccess.open(DIRECTORY)
	if not directory or directory.get_space_left() < 64 * 1024 * 1024: return ""
	var path := path_for(key) + ".prefetch"
	if _write_jpeg(path, jpg): return path
	if FileAccess.file_exists(path): DirAccess.remove_absolute(path)
	return ""

static func commit_prefetch(key: String, path: String, bytes: int, expected_generation: int) -> bool:
	if path != path_for(key) + ".prefetch" or bytes <= 0 or bytes > 512 * 1024: return false
	var stored := (expected_generation == generation and not clearing() and Privacy.cache_allowed(key)
		and _install_jpeg(key, path, bytes, true))
	if not stored and FileAccess.file_exists(path): DirAccess.remove_absolute(path)
	return stored

static func _write_jpeg(temporary: String, jpg: PackedByteArray) -> bool:
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if not file: return false
	file.store_buffer(jpg)
	var written := file.get_error() == OK and file.get_position() == jpg.size()
	file.close()
	return written

static func _install_jpeg(key: String, temporary: String, size: int, speculative: bool) -> bool:
	var path := path_for(key)
	var name := path.get_file()
	var old: Dictionary = _records.get(name, {})
	if speculative and old.get("quality") == "played": return false
	var additional := size - int(old.get("bytes", 0))
	var old_speculative := int(old.get("bytes", 0)) if old.get("quality") == "speculative" else 0
	if speculative:
		_evict(maxi(_disk_bytes + additional - MAX_BYTES, _speculative_bytes + size - old_speculative - SPECULATIVE_BYTES), true, path)
		if _speculative_bytes + size - old_speculative > SPECULATIVE_BYTES: return false
	else:
		prune(-1, MAX_BYTES - additional, path)
	if _disk_bytes + additional > MAX_BYTES or DirAccess.rename_absolute(temporary, path) != OK: return false
	_invalidate(key.sha1_text())
	_pending_writes.erase(key)
	_textures.erase(path)
	_untrack(name)
	_track(name, {"bytes": size, "used": int(Time.get_unix_time_from_system() * 1000.0),
		"local": Privacy.is_local(key), "quality": "speculative" if speculative else "played"})
	return true

static func prune(max_images: int = -1, max_bytes: int = MAX_BYTES, keep: String = "") -> void:
	_ensure_index()
	_evict(_speculative_bytes - SPECULATIVE_BYTES, true, keep)
	_evict(_disk_bytes - max_bytes, true, keep, max_images)
	_evict(_disk_bytes - max_bytes, false, keep, max_images)

static func _evict(bytes: int, speculative_only: bool, keep: String, max_images: int = -1) -> void:
	if bytes <= 0 and (max_images < 0 or _records.size() <= max_images): return
	for name in _records.keys():
		if bytes <= 0 and (max_images < 0 or _records.size() <= max_images): break
		var path := DIRECTORY.path_join(name)
		var record: Dictionary = _records[name]
		if path == keep or _protected.has(path) or (speculative_only and record.quality != "speculative"): continue
		if _remove_file(name): bytes -= int(record.bytes)

## Fills SIZE. Cropped (the default), every picture fills the tile from its centre, panoramas too.
## With [member whole] (Settings, "Preview shape") nothing is cropped: an upright poster or folder
## cover stands in the middle of the tile, a panorama keeps its ends. A whole picture lies over a
## blurred and darkened copy of itself instead of bars in a colour no theme agrees on (the user's
## choices, 2026-11-26). LocalThumbnailPrefetch.encode does the same for the pictures made natively.
static var whole := false
static func shown_whole(size: Vector2i) -> bool:
	return whole and size.x * SIZE.y != size.y * SIZE.x

static func fit(image: Image) -> Image:
	var picture := image.duplicate() as Image
	if picture.is_compressed():
		picture.decompress()
	picture.convert(Image.FORMAT_RGB8)
	var original := picture.get_size()
	var cropped := Vector2i(
		clampi(roundi(original.y * float(SIZE.x) / SIZE.y), 1, original.x),
		clampi(roundi(original.x * float(SIZE.y) / SIZE.x), 1, original.y))
	var filled := picture.get_region(Rect2i((original - cropped) / 2, cropped))
	filled.resize(SIZE.x, SIZE.y, Image.INTERPOLATE_BILINEAR)
	if not shown_whole(original): return filled
	filled.resize(BACKDROP.x, BACKDROP.y, Image.INTERPOLATE_BILINEAR)
	filled.resize(SIZE.x, SIZE.y, Image.INTERPOLATE_CUBIC)
	filled.adjust_bcs(BACKDROP_BRIGHTNESS, 1.0, 1.0)
	var scale := minf(float(SIZE.x) / original.x, float(SIZE.y) / original.y)
	var inner := Vector2i(clampi(roundi(original.x * scale), 1, SIZE.x), clampi(roundi(original.y * scale), 1, SIZE.y))
	picture.resize(inner.x, inner.y, Image.INTERPOLATE_LANCZOS)
	filled.blit_rect(picture, Rect2i(Vector2i.ZERO, inner), (SIZE - inner) / 2)
	return filled

## A whole picture's surround: the filled picture through this few pixels, at this brightness.
const BACKDROP := Vector2i(16, 9)
const BACKDROP_BRIGHTNESS := 0.45

## Files and bytes in the cache.
static func usage(include_metadata: bool = false) -> Vector2i:
	var dir := DirAccess.open(DIRECTORY)
	if not dir:
		return Vector2i.ZERO
	var files := 0
	var bytes := 0
	for name in dir.get_files():
		if not _generated_image(name) and not (include_metadata and name in ["index.bin", "references.bin"]): continue
		var file := FileAccess.open(DIRECTORY.path_join(name), FileAccess.READ)
		if file:
			files += 1
			bytes += file.get_length()
	return Vector2i(files, bytes)

static func clearing() -> bool:
	return _clear_scope != ClearScope.NONE or _clear_task >= 0 or References.clearing()

static func clear_in_background(network_only: bool = false, known_local: Array[String] = []) -> void:
	var scope := ClearScope.NETWORK if network_only else ClearScope.ALL
	if scope <= _active_clear or scope <= _clear_scope: return
	clear_memory()
	_clear_scope = scope
	for uri in known_local:
		if Privacy.is_local(uri): _clear_local[path_for(uri).get_file()] = true
	References.clear(network_only)

static func _poll_clear() -> void:
	if _clear_task >= 0 and WorkerThreadPool.is_task_completed(_clear_task):
		_finish_clear()
	if _clear_task >= 0 or _clear_scope == ClearScope.NONE: return
	if _read_task >= 0:
		if not WorkerThreadPool.is_task_completed(_read_task): return
		_discard_cold_read()
	_active_clear = _clear_scope
	_clear_scope = ClearScope.NONE
	for name: String in _clear_local:
		if _records.has(name):
			var record: Dictionary = _records[name].duplicate()
			record.local = true
			_records[name] = record
	_clear_local.clear()
	_clear_task = WorkerThreadPool.add_task(_erase_jpegs.bind(_records.duplicate(), _active_clear))

static func _erase_jpegs(records: Dictionary, scope: ClearScope) -> void:
	for name: String in records:
		if scope == ClearScope.NETWORK and records[name].local: continue
		var path := DIRECTORY.path_join(name)
		if DirAccess.remove_absolute(path) == OK or not FileAccess.file_exists(path):
			_removed_on_clear.append(name)

static func _finish_clear() -> void:
	WorkerThreadPool.wait_for_task_completion(_clear_task)
	_clear_task = -1
	_active_clear = ClearScope.NONE
	for name in _removed_on_clear: _untrack(name)
	_removed_on_clear.clear()
	_index_save_at = maxi(1, Time.get_ticks_msec())

static func clear(network_only: bool = false, known_local: Array[String] = []) -> void:
	clear_in_background(network_only, known_local)
	_wait_for_clear()
	_flush_index()

static func _wait_for_clear() -> void:
	_ensure_index()
	_discard_cold_read()
	if _clear_task >= 0: _finish_clear()
	if _clear_scope != ClearScope.NONE:
		_poll_clear()
		if _clear_task >= 0: _finish_clear()
	References.finish()

## Part of one eye that makes a 16:9 picture: the whole flat frame, the centre of VR180 /
## fisheye, a quarter of the 360 panorama. (x, y, width, height) in eye UV, row 0 on top.
static func crop_for(geometry: int, eye_size: Vector2) -> Vector4:
	var width: float = [1.0, 0.5, 0.5, 0.25][clampi(geometry, 0, 3)]
	var height := width * eye_size.x / maxf(1.0, eye_size.y) * float(SIZE.y) / SIZE.x
	if height > 1.0:
		width /= height
		height = 1.0
	return Vector4((1.0 - width) * 0.5, (1.0 - height) * 0.5, width, height)

## Renders the left eye of a bound video frame (an RGBA texture, or the decoder's external image)
## into SIZE. Call while that frame is bound; resolves after the frame is drawn.
static func capture(parent: Node, color: RID, decoder: bool, stereo_sbs: bool, crop: Vector4,
		uv_scale: Vector2 = Vector2.ONE, top_bottom: bool = false, size: Vector2i = SIZE) -> Image:
	var viewport := SubViewport.new()
	viewport.size = size
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1.0
	camera.position = Vector3(0, 0, 1)
	viewport.add_child(camera)
	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(float(size.x) / size.y, 1.0)
	quad.mesh = mesh
	var material := ShaderMaterial.new()
	material.shader = SHADER_OES if decoder else SHADER_2D
	material.set_shader_parameter("stereo_sbs", stereo_sbs)
	material.set_shader_parameter("top_bottom", top_bottom)
	material.set_shader_parameter("crop", crop)
	material.set_shader_parameter("color_uv_scale", uv_scale)
	quad.material_override = material
	viewport.add_child(quad)
	parent.add_child(viewport)
	RenderingServer.material_set_param(material.get_rid(), "color_texture", color)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	RenderingServer.material_set_param(material.get_rid(), "color_texture", null)
	viewport.queue_free()
	return image

static func clear_memory() -> void:
	generation += 1
	References.clear_memory()
	_textures.clear(); _private_images.clear()
	_private_speculative.clear()
	_reads.clear(); _misses.clear()
	_pending_writes.clear()
	_read_discard = true

static func finish() -> void:
	if _index_task >= 0: _ensure_index()
	if clearing(): _wait_for_clear()
	_discard_cold_read()
	if _index_save_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_index_save_task)
		_index_save_task = -1
		if FileAccess.file_exists(INDEX_PENDING): DirAccess.remove_absolute(INDEX_PENDING)
		_dirty_index()
	if _index_save_at > 0 or _index_touched: _flush_index()
	_index_touched = false
	References.finish()

static func _discard_cold_read() -> void:
	if _read_task < 0: return
	WorkerThreadPool.wait_for_task_completion(_read_task)
	_read_task = -1
	_read_key = ""
	_read_result = null

static func forget(uri: String) -> void:
	_pending_writes.erase(uri)
	forget_digest(uri.sha1_text())

static func forget_digest(digest: String, forget_references: bool = true) -> void:
	if not _valid_digest(digest): return
	_ensure_index()
	_invalidate(digest)
	for key: String in _pending_writes.keys():
		if key.sha1_text() == digest: _pending_writes.erase(key)
	_private_images.erase(digest)
	_private_speculative.erase(digest)
	_remove_file(_digest_path(digest).get_file())
	if forget_references: References.forget_digest(digest)
