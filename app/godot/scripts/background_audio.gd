extends Node
## One application-wide transport. Music and field recordings replace each other.
signal changed
signal preferences_changed
const Catalog := preload("res://scripts/background_audio_catalog.gd")
const Importer := preload("res://scripts/background_audio_import.gd")
const Library := preload("res://scripts/audio_library.gd")
const MODES := ["sequence", "list", "single", "shuffle"]
var library := Library.new()
var importer := Importer.new()
var directory := "user://background_audio"
var queue: Array[String] = []
var queue_name := ""
var queue_source := ""
var current := ""
var volume := 45.0
var mode := "sequence"
var _mode_selected := false
var _queue_finished := false
var paused := true
var video_active := false
var focused := true
var error := ""
var player: AudioStreamPlayer
var _thread: Thread
var _job := ""
var _generation := 0
var _job_generation := 0
var _loaded := ""
var _resume_position := 0.0
var _remembered_duration := 0.0
var _checkpoint := 0.0
var _entry_gain := 0.0
var _end_pending := false
var _shuffle_history: Array[String] = []
var _shuffle_bag: Array[String] = []
var pending_imports: Array[Dictionary] = []
var failed_imports: Array[Dictionary] = []
var _import_job := {}
var _bus := "Thru3D Background"
var _owns_bus := false
var _native_token := 0
var _native_loading := false
var _native_ended := false
var _native_poll := 0.0

func _ready() -> void:
	if AudioServer.get_bus_index(_bus) < 0:
		AudioServer.add_bus(); var index := AudioServer.bus_count - 1
		AudioServer.set_bus_name(index, _bus)
		var limiter := AudioEffectLimiter.new(); limiter.ceiling_db = -1.0
		AudioServer.add_bus_effect(index, limiter); _owns_bus = true
	player = AudioStreamPlayer.new(); player.name = "GlobalAudio"; player.bus = _bus
	add_child(player); player.finished.connect(_finished)
	library.directory = directory; library.load_library()
	queue = library.valid_ids(queue)
	if library.resolve(current).is_empty(): current = ""; _resume_position = 0.0
	if not current.is_empty() and not queue.has(current): queue.append(current)
	importer.completed.connect(_import_completed)
	importer.changed.connect(_import_changed); add_child(importer)
	# Restoring a session is silent and does not allocate an audio stream.
	_apply_context()

func load_settings(settings: ConfigFile) -> void:
	var section := "audio_player"
	if settings.has_section(section):
		current = str(settings.get_value(section, "current", ""))
		var ids: Variant = settings.get_value(section, "queue", [])
		if ids is Array:
			for id in ids: queue.append(str(id))
		queue_source = str(settings.get_value(section, "source", "")); queue_name = str(settings.get_value(section, "name", ""))
		mode = str(settings.get_value(section, "mode", "list"))
		_mode_selected = bool(settings.get_value(section, "mode_selected", true))
		volume = _number(settings.get_value(section, "volume", 45), 45, 0, 100)
		_resume_position = _number(settings.get_value(section, "position", 0), 0, 0, 86400)
		_remembered_duration = _number(settings.get_value(section, "duration", 0), 0, 0, 86400)
	else:
		# Migrate both old choices as a silent queue, never simultaneous voices.
		for kind in ["music", "ambience"]:
			var id := str(settings.get_value("background_audio", kind, ""))
			if not id.is_empty() and not queue.has(id): queue.append(id)
		current = queue[0] if not queue.is_empty() else ""
		var kind := "music" if not str(settings.get_value("background_audio", "music", "")).is_empty() else "ambience"
		volume = _number(settings.get_value("background_audio", kind + "_volume", 45), 45, 0, 100)
	if mode not in MODES: mode = "list"
	_queue_finished = _remembered_duration > 0 and _resume_position >= _remembered_duration
	paused = true

static func _number(value: Variant, fallback: float, minimum: float, maximum: float) -> float:
	return clampf(float(value), minimum, maximum) if (value is int or value is float) and is_finite(float(value)) else fallback

func position() -> float:
	if _native_token > 0: return _resume_position
	return player.get_playback_position() if is_instance_valid(player) and player.playing else _resume_position

func duration() -> float:
	if _native_token > 0: return _remembered_duration
	return player.stream.get_length() if is_instance_valid(player) and player.stream else _remembered_duration

func save_settings(settings: ConfigFile) -> void:
	settings.set_value("audio_player", "mode_selected", _mode_selected)
	for key in ["music", "ambience", "music_volume", "ambience_volume", "paused"]:
		if settings.has_section_key("background_audio", key): settings.erase_section_key("background_audio", key)
	for pair in [["current", current], ["queue", queue], ["source", queue_source], ["name", queue_name], ["mode", mode], ["volume", volume], ["position", position()], ["duration", duration()]]:
		settings.set_value("audio_player", pair[0], pair[1])

func blocked() -> bool: return paused or video_active or not focused

func _apply_context() -> void:
	if not is_instance_valid(player): return
	player.stream_paused = blocked()
	_apply_gain()
	if _end_pending and not blocked(): _end_pending = false; adjacent(1, true)

func _apply_gain() -> void:
	var tail := clampf((duration() - position()) / 0.12, 0, 1) if duration() > 0 else 1.0
	player.volume_linear = volume / 100.0 * minf(_entry_gain, tail)
	if _native_token > 0:
		importer.platform.control_background_audio(_native_token, not blocked(), volume * minf(_entry_gain, tail), -1.0)

func _stop_native() -> void:
	if _native_token > 0 and is_instance_valid(importer.platform): importer.platform.stop_background_audio()
	_native_token = 0; _native_loading = false; _native_ended = false

func set_context(video: bool, has_focus: bool) -> void:
	if video_active == video and focused == has_focus: return
	video_active = video; focused = has_focus
	_apply_context(); changed.emit()

func set_volume(value: Variant) -> bool:
	if not (value is int or value is float) or not is_finite(float(value)): return false
	volume = clampf(float(value), 0, 100); _apply_context(); _notify(); return true

func set_mode(value: String) -> bool:
	if value not in MODES: return false
	mode = value; _mode_selected = true; _shuffle_bag.clear(); _shuffle_history.clear(); _notify(); return true

func play_playlist(id: String, track: String = "") -> bool:
	var row := library.playlist(id)
	if row.is_empty() or row.tracks.is_empty(): return false
	if track.is_empty(): track = str(row.tracks[0])
	return play_tracks(row.tracks, track, str(row.label), id, "single" if id == "ambience" else "sequence")

func rename_playlist(id: String, label: String) -> bool:
	if not library.rename_playlist(id, label): return false
	if queue_source == id: queue_name = str(library.playlist(id).label)
	_notify(); return true

func play_tracks(ids: Array, track: String, label: String = "", source: String = "", default_mode: String = "") -> bool:
	var valid := library.valid_ids(ids)
	if not valid.has(track): return false
	queue = valid; queue_name = label; queue_source = source
	_shuffle_bag.clear(); _shuffle_history.clear()
	if not _mode_selected and default_mode in MODES: mode = default_mode
	return select_track(track)

func select_track(id: String) -> bool:
	if library.resolve(id).is_empty(): return false
	_stop_native()
	if not queue.has(id): queue.append(id)
	current = id; paused = false; error = ""; _resume_position = 0.0; _remembered_duration = 0.0; _entry_gain = 0.0; _end_pending = false
	_queue_finished = false
	_generation += 1; _loaded = ""
	if is_instance_valid(player): player.stop(); player.stream = null
	_request(); _notify(); return true

func toggle_pause() -> void:
	if current.is_empty():
		play_playlist("calm"); return
	if paused and _queue_finished:
		select_track(queue[0] if mode == "sequence" and not queue.is_empty() else current); return
	paused = not paused
	if not paused and _loaded != current: _request()
	elif not paused and player.stream and not player.playing: player.play(_resume_position)
	_apply_context(); _notify()

func seek(seconds: Variant) -> bool:
	if not (seconds is int or seconds is float) or not is_finite(float(seconds)) or duration() <= 0: return false
	_resume_position = clampf(float(seconds), 0, maxf(0, duration() - 0.02))
	_queue_finished = false; _end_pending = false
	if player.stream: player.seek(_resume_position)
	if _native_token > 0:
		if _native_ended: _loaded = ""; _request()
		else: importer.platform.control_background_audio(_native_token, not blocked(), volume * _entry_gain, _resume_position)
	_notify(); return true

func can_advance(step: int) -> bool:
	if queue.is_empty(): return false
	return mode != "sequence" or (queue.find(current) + step >= 0 and queue.find(current) + step < queue.size())

func adjacent(step: int, automatic: bool = false) -> bool:
	if queue.is_empty(): return false
	if mode == "sequence" and not can_advance(step):
		if automatic:
			_resume_position = duration(); _remembered_duration = duration()
			paused = true; _queue_finished = true; _end_pending = false
			player.stop(); _notify()
		return false
	var target := current
	if automatic and (mode == "single" or queue.size() == 1):
		if player.stream and _loaded == current:
			_resume_position = 0; _entry_gain = 0; _end_pending = false
			player.play(); _apply_context(); _notify(); return true
		return select_track(target)
	if mode == "shuffle" and queue.size() > 1:
		if step < 0 and not _shuffle_history.is_empty():
			target = _shuffle_history.pop_back(); _shuffle_bag.erase(target)
		else:
			if _shuffle_bag.is_empty():
				_shuffle_bag = queue.duplicate(); _shuffle_bag.erase(current); _shuffle_bag.shuffle()
			target = _shuffle_bag.pop_back(); _shuffle_history.append(current)
	else: target = queue[posmod(queue.find(current) + step, queue.size())]
	return select_track(target)

func _finished() -> void:
	if not blocked(): adjacent(1, true)
	else: _end_pending = true

func _request() -> void:
	if _thread or current.is_empty() or not is_inside_tree(): return
	var row := library.resolve(current)
	if row.is_empty(): return
	if not str(row.path).begins_with("res://") and Importer.Methods.supports(importer.platform, "load_background_audio"):
		_native_token = int(importer.platform.load_background_audio(str(row.path), _resume_position))
		_native_loading = _native_token > 0; _native_ended = false
		if _native_loading: _apply_context()
		else: error = "Unsupported or damaged audio"; paused = true; _notify()
		return
	_job = current; _job_generation = _generation; _thread = Thread.new()
	if _thread.start(Catalog.load_audio.bind(str(row.path))) != OK:
		_thread = null; error = "Audio file unavailable"; paused = true; _notify()

func _process(delta: float) -> void:
	if _native_token > 0:
		_native_poll += delta
		if _native_poll >= 0.08:
			_native_poll = 0.0
			var state: Variant = JSON.parse_string(str(importer.platform.background_audio_status()))
			if state is Dictionary and int(state.get("generation", 0)) == _native_token:
				var status := str(state.get("state", ""))
				if status == "failed":
					_stop_native(); paused = true; error = "Unsupported or damaged audio"; _notify()
				elif status == "ready" or (status == "ended" and not _native_ended):
					_resume_position = _number(state.get("position", 0), _resume_position, 0, 86400)
					_remembered_duration = _number(state.get("duration", 0), _remembered_duration, 0, 86400)
					if _native_loading: _native_loading = false; _loaded = current; changed.emit()
					if status == "ended" and not _native_ended:
						_native_ended = true; _finished()
	if _thread and not _thread.is_alive():
		var stream: AudioStream = _thread.wait_to_finish(); _thread = null
		if _job != current or _job_generation != _generation:
			if not paused: _request()
		elif not stream or not is_finite(stream.get_length()) or stream.get_length() <= 0:
			error = "Unsupported or damaged audio"; paused = true; _notify()
		else:
			_loaded = current; player.stream = stream; _remembered_duration = stream.get_length()
			_resume_position = clampf(_resume_position, 0, maxf(0, stream.get_length() - 0.02))
			_apply_context(); player.play(_resume_position); _apply_context(); changed.emit()
	if not blocked() and (player.playing or (_native_token > 0 and not _native_loading and not _native_ended)):
		_entry_gain = minf(1, _entry_gain + delta / 0.35); _apply_gain()
		_checkpoint += delta
		if _checkpoint >= 5: _checkpoint = 0; preferences_changed.emit()

func _notify() -> void:
	preferences_changed.emit(); changed.emit()

func import_tracks(files: Array, destination: String = "") -> void:
	for file in files:
		if file is Dictionary and not str(file.get("uri", "")).is_empty():
			pending_imports.append({"uri": str(file.uri), "title": str(file.get("title", "")), "destination": destination})
	_next_import()

func _next_import() -> void:
	if importer.busy or not _import_job.is_empty(): return
	if pending_imports.is_empty(): changed.emit(); return
	error = ""
	_import_job = pending_imports.pop_front()
	importer.start(_import_job.uri, _import_job.title, _import_job.destination)
	changed.emit()

func _import_changed() -> void:
	if not importer.busy and not _import_job.is_empty():
		if not importer.error.is_empty(): failed_imports.append(_import_job.duplicate())
		_import_job.clear(); call_deferred("_next_import")
	changed.emit()

func _import_completed(entry: Dictionary, destination: String) -> void:
	if not library.add_import(entry, destination):
		if entry.get("created", false): importer.remove_copy(str(entry.path))
		error = library.error; failed_imports.append(_import_job.duplicate())
	# Importing never changes current, queue, position or pause intent.
	_import_job.clear(); changed.emit(); call_deferred("_next_import")

func cancel_imports() -> void:
	pending_imports.clear(); _import_job.clear(); importer.cancel(); changed.emit()

func retry_imports() -> void:
	pending_imports.append_array(failed_imports); failed_imports.clear(); _next_import()

func remove_import(id: String) -> bool:
	var entry := library.resolve(id)
	if not id.begins_with("import_") or entry.is_empty(): return false
	var old_entries := library.imports.duplicate(true); var old_lists := library.playlists.duplicate(true)
	if not library.forget_import(id): error = library.error; changed.emit(); return false
	if not importer.remove_copy(str(entry.path)):
		library.commit(old_entries, old_lists); error = "Could not remove local audio"; changed.emit(); return false
	queue.erase(id); _shuffle_bag.erase(id); _shuffle_history.assign(_shuffle_history.filter(func(value): return value != id))
	if current == id:
		_stop_native()
		current = ""; paused = true; _resume_position = 0; _remembered_duration = 0; _generation += 1; _loaded = ""
		player.stop(); player.stream = null
	_notify(); return true

func snapshot() -> Dictionary:
	var row := library.resolve(current)
	return {"audio_current": current, "audio_title": str(row.get("label", "Choose audio")), "audio_volume": volume,
		"audio_mode": mode, "audio_paused": paused, "audio_active": not blocked() and not current.is_empty() and _loaded == current,
		"audio_blocked": video_active or not focused, "audio_loading": _thread != null or _native_loading, "audio_position": position(), "audio_duration": duration(),
		"audio_queue": queue.duplicate(), "audio_queue_name": queue_name, "audio_queue_source": queue_source,
		"audio_importing": importer.busy or not pending_imports.is_empty(), "audio_progress": importer.progress,
		"audio_pending": pending_imports.size(), "audio_failed": failed_imports.size(), "audio_revision": library.revision,
		"audio_error": error if not error.is_empty() else (library.error if not library.error.is_empty() else importer.error)}

func _exit_tree() -> void:
	_resume_position = position(); _remembered_duration = duration()
	_stop_native()
	if _thread: _thread.wait_to_finish(); _thread = null
	if is_instance_valid(player): player.stop(); player.stream = null
	if _owns_bus:
		var index := AudioServer.get_bus_index(_bus)
		if index > 0: AudioServer.remove_bus(index)
