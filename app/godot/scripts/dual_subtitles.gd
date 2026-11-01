extends RefCounted
## Optional second text track. The existing single-track path stays authoritative.
const State := preload("res://scripts/mpv_subtitle_state.gd")
const Timing := preload("res://scripts/file_subtitle_timing.gd")
const Tracks := preload("res://scripts/file_track_memory.gd")
const Methods := preload("res://scripts/platform_methods.gd")
const Style := preload("res://scripts/subtitle_style.gd")
const CHANNEL := "secondary_subtitle"
var video: Node
var enabled := false
var editing_secondary := false
var state := State.new()
var timing_key := ""
var restore_attempted := false
var bound_session := 0

func _init(owner: Node) -> void: video = owner

func primary_id() -> int:
	var id: int = video.subtitles.requested_track
	if id < 0: id = int(video.media.playback.get("details", {}).get("subtitle", {}).get("track_id", 0))
	return id

func supported() -> bool:
	return video.cast_token == 0 and Methods.supports(video.platform, "set_mpv_secondary_subtitle")

func available() -> bool:
	if not supported() or video.listening.active() or video.disc.menu_session: return false
	for track in video.subtitle_tracks():
		if int(track.id) == primary_id(): return State.text_codec(str(track.get("codec", "")))
	return false

func reset() -> void:
	if state.requested_track > 0 and bound_session == video.media.session_id:
		if supported() and video.media.accepts(bound_session): video.platform.set_mpv_secondary_subtitle(bound_session, 0, 0.0)
		if video.narration.source_secondary: video.narration.set_option("narration_enabled", false)
	enabled = false; editing_secondary = false; timing_key = ""; restore_attempted = false
	bound_session = 0
	state.select(0); state.set_delay(0.0); state.clear(true)

func set_enabled(value: bool) -> bool:
	if value:
		if not available(): return false
		enabled = true; editing_secondary = true
	else:
		if state.requested_track > 0 and not select(0): return false
		elif enabled or video._track_restore.has(CHANNEL): video._remember_track(CHANNEL, 0)
		enabled = false; editing_secondary = false
		video._track_restore.erase(CHANNEL)
		if video._subtitle_load_secondary:
			video._subtitle_load_request = 0; video._subtitle_loaded_track = 0; video.subtitle_file_loading = ""
	video.changed.emit()
	return true

func select(id: int, remember: bool = true) -> bool:
	if id < 0 or not supported() or not video.media.accepts(video.media.session_id): return false
	var track: Dictionary = {}
	if id > 0:
		if not available() or id == primary_id(): return false
		for item in video.subtitle_tracks():
			if int(item.id) == id and State.text_codec(str(item.get("codec", ""))): track = item; break
		if track.is_empty() or (not remember and not video.subtitle_encoding_ready(id)): return false
	var key: String = Timing.track_key(track)
	var seconds: float = video.subtitle_timing.for_track(video.local_uri, key) if video._remember_file and not key.is_empty() else 0.0
	if not video.platform.set_mpv_secondary_subtitle(video.media.session_id, id, seconds): return false
	bound_session = video.media.session_id
	var previous := state.requested_track
	state.select(id); state.set_delay(seconds); timing_key = key
	if previous > 0 and (video.narration.source_secondary or video.narration.source == previous):
		if id > 0: video.narration.source = id
		else:
			video.narration.set_option("narration_enabled", false)
			if remember and video._remember_file and video.narration.memory.remember(video.local_uri, video.narration._values()): video.narration.memory.save()
	if id > 0: enabled = true
	if remember:
		video._remember_track(CHANNEL, id)
		if video._subtitle_load_secondary:
			video._subtitle_load_request = 0; video._subtitle_loaded_track = 0; video.subtitle_file_loading = ""
	video._subtitle_poll_ms = 0
	video.changed.emit()
	return true

func set_delay(seconds: float) -> bool:
	if not is_finite(seconds) or state.requested_track <= 0 or not video.media.accepts(video.media.session_id): return false
	var value := Timing.delay(seconds)
	if not video.platform.set_mpv_secondary_subtitle(video.media.session_id, state.requested_track, value): return false
	state.set_delay(value); video._subtitle_poll_ms = 0; video.changed.emit()
	return true

func observe(snapshot: Dictionary) -> void:
	if not enabled: return
	var secondary: Variant = snapshot.get("secondary", {})
	if not secondary is Dictionary or secondary.is_empty(): state.clear(); return
	var cue: Dictionary = secondary.duplicate()
	for key in ["session_id", "generation", "mpv_source_handle", "age_ms"]: cue[key] = snapshot.get(key, -1)
	cue.required_command_id = snapshot.get("required_secondary_command_id", 0)
	state.observe(cue, video.media.session_id, video.media.last_pair)

func compose(primary: String, line: int) -> String:
	var first := Style.display_text(primary, line)
	if not enabled or video.listening.active(): return first
	var second := Style.display_text(state.text, line)
	if first.is_empty(): return second
	return first if second.is_empty() else first + "\n" + second

func restore() -> void:
	if not video._track_restore.has(CHANNEL) or not available(): return
	var choice: Dictionary = video._track_restore[CHANNEL]
	var id := Tracks.resolve(choice, video._raw_tracks("subtitle"))
	if id == Tracks.UNRESOLVED:
		if restore_attempted or video._subtitle_load_request > 0: return
		var uri := str(choice.get("uri", "")); var filename := str(choice.get("file", ""))
		if uri.is_empty() and filename.is_empty(): return
		restore_attempted = true
		if not uri.is_empty(): video.select_subtitle_uri(uri, true, true)
		else: video.select_subtitle_file(filename, true, true)
	elif select(id, false):
		video._track_choices[CHANNEL] = Tracks.describe(id, video._raw_tracks("subtitle"))
		video._track_restore.erase(CHANNEL)

func snapshot() -> Dictionary:
	var shown: bool = enabled and not video.listening.active()
	return {"dual_subtitles_available": available(), "dual_subtitles_enabled": shown,
		"subtitle_edit_secondary": shown and editing_secondary,
		"secondary_subtitle_track": state.requested_track, "secondary_subtitle_delay": state.requested_delay,
		"secondary_subtitle_timing_key": timing_key}
