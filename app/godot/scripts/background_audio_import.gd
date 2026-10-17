extends Node
## A completed private local copy is the only object passed to playback. No streaming fallback.
signal changed
signal completed(entry: Dictionary, destination: String)
const Catalog := preload("res://scripts/background_audio_catalog.gd")
const Methods := preload("res://scripts/platform_methods.gd")
var platform: Object
var directory := "user://background_audio/imports"
var busy := false
var error := ""
var progress := 0.0
var destination := ""
var _request := 0
var _thread: Thread
var _cancel := false
var _title := ""
var _connected: Object
var _poll := 0.0

func start(uri: String, title: String, playlist: String = "") -> bool:
	if busy: return false
	error = ""; progress = 0.0; destination = playlist; _cancel = false
	var filename := title.get_file()
	if not Catalog.supported(filename): error = "Use MP3, OGG, WAV, FLAC or DTS audio"; changed.emit(); return false
	_title = filename.get_basename().left(150) + "." + Catalog.extension(filename)
	if Methods.supports(platform, "import_background_audio"):
		if _connected != platform:
			_connected = platform
			platform.connect("background_audio_imported", _receive)
		_request = int(platform.import_background_audio(uri, _title))
		busy = _request > 0
	else:
		var path := uri.trim_prefix("file://").uri_decode() if uri.begins_with("file://") else uri
		if not FileAccess.file_exists(path): error = "Audio import unavailable"; changed.emit(); return false
		busy = true; _thread = Thread.new()
		if _thread.start(_copy.bind(path, _title)) != OK: busy = false; _thread = null
	if not busy: error = "Audio import unavailable"
	changed.emit(); return busy

func cancel() -> void:
	_cancel = true
	if _request > 0 and Methods.supports(platform, "cancel_background_audio_import"):
		platform.cancel_background_audio_import(_request)
	_request = 0
	if not _thread: busy = false
	error = ""; changed.emit()

func _copy(path: String, title: String) -> Dictionary:
	var input := FileAccess.open(path, FileAccess.READ)
	if not input or input.get_length() <= 0 or input.get_length() > Catalog.MAX_BYTES:
		return {"error": "Audio file is empty or larger than 64 MB"}
	DirAccess.make_dir_recursive_absolute(directory)
	var id := "import_%d_%d" % [int(Time.get_unix_time_from_system()), Time.get_ticks_usec()]
	var target := directory.path_join(id + "." + Catalog.extension(title))
	var partial := target + ".part"
	var output := FileAccess.open(partial, FileAccess.WRITE)
	if not output: return {"error": "Not enough space to save audio"}
	var ok := true
	while not _cancel and input.get_position() < input.get_length():
		var bytes := input.get_buffer(mini(65536, input.get_length() - input.get_position()))
		if bytes.is_empty(): ok = false; break
		output.store_buffer(bytes)
		if output.get_error() != OK: ok = false; break
		progress = float(input.get_position()) / input.get_length()
	output.flush(); output.close(); input.close()
	if not ok or _cancel:
		DirAccess.remove_absolute(partial); return {"cancelled": _cancel, "error": "Could not save audio"}
	# Validate before publishing. A failed import never becomes a selectable row.
	var stream := _load_partial(partial, Catalog.extension(title))
	if not stream or not is_finite(stream.get_length()) or stream.get_length() <= 0:
		DirAccess.remove_absolute(partial); return {"error": "Unsupported or damaged audio"}
	id = "import_" + FileAccess.get_sha256(partial)
	target = directory.path_join(id + "." + Catalog.extension(title))
	if _cancel:
		DirAccess.remove_absolute(partial); return {"cancelled": true}
	if FileAccess.file_exists(target):
		DirAccess.remove_absolute(partial)
		return {"state": "ready", "id": id, "path": target, "label": title, "created": false, "bytes": FileAccess.open(target, FileAccess.READ).get_length()}
	if DirAccess.rename_absolute(partial, target) != OK:
		DirAccess.remove_absolute(partial); return {"error": "Could not save audio"}
	return {"state": "ready", "id": id, "path": target, "label": title, "created": true, "bytes": FileAccess.open(target, FileAccess.READ).get_length()}

static func _load_partial(path: String, extension: String) -> AudioStream:
	match extension:
		"mp3": return AudioStreamMP3.load_from_file(path)
		"ogg": return AudioStreamOggVorbis.load_from_file(path)
		"wav": return AudioStreamWAV.load_from_file(path, {"force/max_rate": true, "force/max_rate_hz": 44100})
	return null

func _process(delta: float) -> void:
	if _thread and not _thread.is_alive():
		var result: Dictionary = _thread.wait_to_finish(); _thread = null
		_finish(result)
	if not busy: return
	_poll += delta
	if _poll >= 0.25:
		_poll = 0
		if _request > 0 and Methods.supports(platform, "background_audio_import_progress"):
			progress = clampf(float(platform.background_audio_import_progress(_request)), -1, 1)
		changed.emit()

func _receive(id: int, payload: String) -> void:
	if id != _request or not busy: return
	_request = 0
	var result: Variant = JSON.parse_string(payload)
	if result is Dictionary and result.get("state") == "ready":
		if result.get("decoded", false) and Methods.supports(platform, "load_background_audio"):
			_finish(result); return
		_thread = Thread.new()
		if _thread.start(_validate.bind(result)) == OK: return
		_thread = null
		result = {"error": "Audio import unavailable", "discard_path": result.path if result.get("created", false) else ""}
	_finish(result if result is Dictionary else {"error": "Audio import unavailable"})

func _validate(result: Dictionary) -> Dictionary:
	var stream := Catalog.load_audio(str(result.get("path", "")))
	return result if stream and is_finite(stream.get_length()) and stream.get_length() > 0 else {"error": "Unsupported or damaged audio", "discard_path": result.path if result.get("created", false) else ""}

func remove_copy(path: String) -> bool:
	if Methods.supports(platform, "remove_background_audio"): return bool(platform.remove_background_audio(path))
	if not path.simplify_path().begins_with(directory.simplify_path() + "/"): return false
	return not FileAccess.file_exists(path) or DirAccess.remove_absolute(path) == OK

func _finish(result: Dictionary) -> void:
	busy = false
	if not str(result.get("discard_path", "")).is_empty(): remove_copy(str(result.discard_path))
	if _cancel and result.get("state") == "ready" and result.get("created", false): remove_copy(str(result.path))
	if result.get("state") == "ready" and not _cancel:
		progress = 1.0; error = ""
		completed.emit(result, destination)
	elif not result.get("cancelled", false): error = str(result.get("error", "Audio import unavailable"))
	changed.emit()

func _exit_tree() -> void:
	cancel()
	if _thread: _thread.wait_to_finish()
