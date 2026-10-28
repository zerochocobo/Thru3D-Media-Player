extends SceneTree
const Listening := preload("res://scripts/live_interpretation.gd")
const Memory := preload("res://scripts/file_listening_memory.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Main := preload("res://scripts/main.gd")
const Style := preload("res://scripts/subtitle_style.gd")
const Player := preload("res://scripts/mpv_video_display.gd")
class Platform extends RefCounted:
	var configurations := []
	var narration := []
	var ready := []
	var report := {"epoch": 1, "buffered": true, "state": "ready", "cues": []}
	func set_mpv_listening(_id: int, value: String) -> bool: configurations.append(JSON.parse_string(value)); return true
	func get_mpv_listening(_id: int) -> String: return JSON.stringify(report)
	func listening_ready(_id: int, epoch: int) -> void: ready.append(epoch)
	func set_mpv_narration(_id: int, value: String) -> bool: narration.append(JSON.parse_string(value)); return true
	func set_mpv_subtitle(_id: int, _track: int) -> bool: return true
	func set_mpv_subtitle_delay(_id: int, _delay: float) -> bool: return true
	func close_mpv_video(_id: int) -> void: pass
	func get_mpv_subtitle_bitmap(_id: int, _version: int) -> PackedByteArray: return PackedByteArray([255, 255, 255, 255])
	func list_mpv_subtitle_files(_id: int, _request: int) -> bool: return true
	func load_mpv_subtitle_file(_id: int, _request: int, _filename: String) -> bool: return true
class Video extends Node3D:
	var platform := Platform.new()
	var media := {"session_id": 1, "playback": {"details": {"audio_tracks": [{"id": 1}]}}}
	var cast_token := 0
	var disc := {"menu_session": false}
	var tracks := []
	var subtitle_files := []
	var subtitle_file_loading := ""
	var subtitle_line := 0
	func subtitle_tracks() -> Array: return tracks
var checks := 0
var failures := []
func check(value: bool, label: String) -> void:
	checks += 1
	if not value: failures.append(label); push_error(label)
func tap(menu: Node3D, target: int) -> bool:
	for button in menu._buttons:
		if button.target != target: continue
		var origin: Vector3 = button.node.to_global(Vector3(0, 0, 1))
		menu.press_pointer("left_hand", origin, -menu.global_basis.z, true)
		menu.release_pointer("left_hand", origin, -menu.global_basis.z, true)
		return true
	return false
func choose(menu: Node3D, key: String, value: Variant) -> bool:
	for target in menu.choices.targets:
		var field: Dictionary = menu.choices.targets[target]
		if field.key == key and field.kind == "open": tap(menu, target); break
	for target in menu.choices.targets:
		var field: Dictionary = menu.choices.targets[target]
		if field.key == key and field.kind == "choose" and field.value == value: return tap(menu, target)
	return false
func _initialize() -> void: run.call_deferred()
func run() -> void:
	check(Listening.status_label("source_busy") == "Source connection limit reached. Try again shortly.", "CDN connection limit has a distinct status")
	check(Listening.status_label("audio_error") == "Unable to open the audio track", "Audio opening failure is distinct from model availability")
	var video := Video.new(); root.add_child(video)
	var item := Listening.new(video)
	item.memory = Memory.new("user://live-interpretation-test")
	Privacy.configure_file_settings("all")
	var settings := ConfigFile.new()
	item.load_settings(settings); item.reset_source("file:///movie-a.mp4")
	check(item.source == "ja" and item.target == "" and not item.enabled, "Japanese default; no global opt-in or translation")
	check(item.set_option("listening_lead", 8.0) and item.lead == 8, "JSON integer-valued float uses the same lookahead choices as the UI")
	check(not item.set_option("listening_lead", 8.5) and item.lead == 8, "Fractional lookahead remains invalid")
	settings.set_value("live_interpretation", "lead", 20.0); item.load_settings(settings)
	check(item.lead == 20, "Legacy numeric preference restores without falling back to twelve")
	settings.erase_section("live_interpretation"); item.load_settings(settings)
	check(item.available() and item.set_option("listening_enabled", true), "No subtitles exposes listening")
	item.set_option("listening_source", "en"); item.set_option("listening_lead", 20); item.save(settings)
	check(not settings.has_section_key("live_interpretation", "enabled"), "Activation never saved globally")
	item.reset_source("file:///movie-b.mp4")
	check(not item.enabled and item.source == "en" and item.lead == 20, "Next video off, global choices retained")
	item.reset_source("file:///movie-a.mp4")
	check(item.enabled, "Original video's activation restored")
	video.tracks = [{"id": 2, "language": "en"}]; check(item.available() and item.active(), "Embedded subtitles do not block listening")
	video.tracks.clear(); video.subtitle_files = ["movie.srt"]; check(item.available(), "Sidecar candidates do not block listening")
	video.subtitle_files.clear(); video.cast_token = 3; check(not item.available(), "Ephemeral casting does not inherit activation")
	video.cast_token = 0
	video.media.playback.details.audio_tracks = []; item._poll_at = Time.get_ticks_msec() + 60000; item.tick()
	check(item.active() and video.platform.configurations[-1].enabled, "A seek's empty track list keeps the running session and its model")
	check(not item.available(), "Switching on still requires an audio track")
	check(item.snapshot().listening_available, "Running listening switch remains visible while seek metadata is empty")
	var sent: Dictionary = video.platform.configurations[-1]
	check(sent.media == Memory.key_for("file:///movie-a.mp4") and sent.persist and not sent.network, "Recognized text may persist per file under the per-file settings policy")
	Privacy.configure_file_settings("none"); item._payload = ""; item.tick()
	check(not video.platform.configurations[-1].persist, "No per-file memory keeps recognized text in memory only")
	Privacy.configure_file_settings("all"); item._payload = ""; item.tick()
	video.media.playback.details.audio_tracks = [{"id": 1}]
	var cue := {"start": 5.0, "end": 7.0, "text": "Hello"}
	video.platform.report.cues = [cue]; item._poll_at = 0; item.tick()
	check(item.text_at(4.99) == "" and item.text_at(5.0) == "Hello" and item.text_at(7.0) == "", "Media-time cue; never early or after end")
	check(video.platform.ready == [1], "Original-only startup releases after lookahead")
	item.report.position = 5.0; item.report.playing = false; item.report.age = 0.1
	check(item.playback_position(9.0) == 5.0, "Paused audio clock does not extrapolate")
	item.report.playing = true; item.report.speed = 2.0
	check(item.playback_position(9.0) >= 5.2 and item.playback_position(9.0) < 5.4, "Audible clock extrapolates at playback speed")
	item.report.age = 0.6
	check(item.playback_position(9.0) == 9.0, "Stale audio report falls back to presented frame")
	item.target = "zh-Hans"
	var key: String = item.Protocol.cache_key("Hello", "en", "zh-Hans")
	item.translator.cache[key] = {"text": "你好"}
	check(item.text_at(6) == "你好\nHello", "Translation above original")
	check(Style.display_text(item.text_at(6), 1) == "你好" and Style.display_text(item.text_at(6), 2) == "Hello", "Shared line selection chooses translation or original")
	item.report.state = "preparing"; item.report.phase = "models"; item.report.model_progress = 25
	check(item.preparation_caption().ends_with("25%"), "Model verification shows measured progress")
	item.report.phase = "recognition"; item.report.buffer_progress = 40; item.report.buffered = false
	check(item.preparation_caption().ends_with("40%"), "Ahead buffer shows measured progress")
	item.report.phase = "task"; item.report.cache_progress = 48
	check(item.preparation_caption() == Listening.I18n.t("Pre-generating · %d%%") % 48, "A pre-generation task for this film shows its progress, not a model check")
	item.report.phase = "model_load"
	check(not "%" in item.preparation_caption(), "Unknown model load progress is not fabricated")
	item.report.state = "ready"; item.report.buffered = true
	check(item.preparation_caption().is_empty(), "Ready subtitles clear preparation feedback")
	video.platform.report.epoch = 2; video.platform.report.cues = []; item._poll_at = 0; item.tick()
	check(item.text_at(6).is_empty() and item.translator.cache.has(key), "Seek clears old cues while retaining bounded translation cache")
	var client = item.translator; client.enabled = true
	client.cache.clear()
	client.observe_sentences([cue, cue], "en", "zh-Hans")
	check(client.jobs.size() == 1 and client.jobs[0].size() == 1, "Repeated final sentences merge to one request")
	client.cache[key] = {"text": "你好"}; client._signature = ""; client.observe_sentences([cue], "en", "zh-Hans")
	check(client.jobs.is_empty(), "Cached sentence never retranslates")
	client.cache.clear(); client._signature = ""; client.observe_sentences([cue], "en", "en")
	check(client.jobs.is_empty(), "Matching language requires no provider")
	check(client.request_spacing_ms == 2000, "Video translation requests spaced at least two seconds")
	# Both providers cooling down: keep the sentence queued, never fail it unsent.
	client._signature = ""; client.observe_sentences([cue], "en", "zh-Hans")
	client._cooldown = {"Bing": Time.get_ticks_msec() + 60000, "Edge": Time.get_ticks_msec() + 30000}
	client._next_at = 0; client.tick(true)
	check(client.failed.is_empty() and client.jobs.size() == 1 and client.current.is_empty() and client._next_at >= Time.get_ticks_msec() + 29000,
		"Cooling providers requeue sentences until the earliest one is available")
	client.failed[key] = Time.get_ticks_msec() - client.RETRY_MS - 1; client.jobs.clear(); client._signature = ""
	client.observe_sentences([cue], "en", "zh-Hans")
	check(client.jobs.size() == 1, "A failed sentence is retried after the retry interval")
	client.jobs.clear(); client.failed[key] = Time.get_ticks_msec() - client.RETRY_MS - 1; client._next_at = 0
	client.tick(true)
	check(client.jobs.size() == 1, "A failed line still on screen retries without new text arriving")
	client.failed.clear(); client.jobs.clear(); client._cooldown = {"Bing": 0, "Edge": 0}
	# Head-locked status without opening the control bar.
	var saved_target: String = item.target; var saved_report: Dictionary = item.report
	item.target = ""; item.report = {"state": "ready", "buffered": true, "ahead": 12.4, "cues": []}
	check(item.status_caption(100.0) == Listening.I18n.t("Transcribing · %d s ahead") % 12, "Silent stretches show that transcription is running")
	item.report.phase = "task"
	check(item.status_caption(100.0) == Listening.I18n.t("Pre-generated · %d s ahead") % 12, "Subtitles read from a pre-generation task say so")
	item.report.erase("phase")
	item.report.cues = [{"start": 99.0, "end": 101.0, "text": "Hello"}]
	check(item.status_caption(100.0).is_empty(), "A shown subtitle needs no status")
	item.target = "zh-Hans"; item.report.cues = []
	client.entries = [{"key": key}]; client.jobs = [[{"key": key}]]
	check(item.status_caption(100.0) == Listening.I18n.t("Translating · %d pending") % 1, "Queued translation is visible")
	client._cooldown = {"Bing": Time.get_ticks_msec() + 30000, "Edge": Time.get_ticks_msec() + 45000}
	check(item.status_caption(100.0) == Listening.I18n.t("Translation busy · retrying in %d s, showing original") % 30, "Provider cooldown explains the original text")
	client._cooldown = {"Bing": 0, "Edge": 0}; client.jobs.clear(); client.failed[key] = Time.get_ticks_msec()
	check(item.status_caption(100.0) == Listening.I18n.t("Some lines untranslated · showing original"), "Failed lines are explained")
	client.failed.clear(); item.report.cues = [{"start": 99.0, "end": 101.0, "text": "Hello"}]
	var shown_key: String = item.Protocol.cache_key(item.Protocol.normalize("Hello", item.Protocol.language(item.source)), item.Protocol.language(item.source), item.target)
	client.cache[shown_key] = {"text": "你好"}
	check(item.status_caption(100.0).is_empty(), "A translated shown line needs no status")
	client.cache.erase(shown_key)
	client.jobs = [[{"key": key}]]
	check(item.status_caption(100.0) == Listening.I18n.t("Translating · %d pending") % 1, "A shown original still being translated says so")
	client.jobs.clear()
	check(item.status_caption(100.0) == Listening.I18n.t("Some lines untranslated · showing original"), "A shown original with no translation work is explained")
	item.report.state = "preparing"; item.report.phase = "recognition"; client.jobs = [[{"key": key}], [{"key": "other"}]]
	check(item.preparation_caption() == Listening.I18n.t("Translating · %d pending") % 2, "Preparing translation counts its queue")
	client.jobs.clear()
	item.report = {"state": "audio_error"}
	check(item.status_caption(100.0) == Listening.I18n.t("Unable to open the audio track"), "Errors stay visible without the control bar")
	client.failed.clear(); client.entries = []; item.target = saved_target; item.report = saved_report
	check(Listening.rows({"listening_available": false}).is_empty(), "Unsupported playback has no listening controls")
	var rows := Listening.rows({"listening_available": true, "listening_enabled": true})
	check(rows.size() == 4 and rows.all(func(row): return not str(row.field.key).begins_with("narration")), "Source, translation and lead controls; no TTS")
	var menu := Menu.new()
	menu.state_provider = func():
		var state := {"has_video": true, "title": "Video", "duration_ms": 240000, "subtitle_options": [], "subtitle_track": 0}
		state.merge(item.snapshot()); return state
	menu.setting_requested.connect(func(key, value):
		if key == "subtitle_line": video.subtitle_line = value
		else: item.set_option(key, value); item.save(settings))
	root.add_child(menu); menu.toggle(); menu.set_process(false); menu._subtitle_open = true; menu.refresh(); menu._activate(menu.SUBTITLE_LISTENING)
	check(menu._buttons.all(func(button): return button.target != menu.SUBTITLE_ROW), "Listening is the only on/off control without subtitles")
	var controls: Array = menu._subtitle_controls()
	check(controls[0].field.key == "listening_enabled" and menu._subtitle_groups().back().group == "appearance", "Listening controls use their right pane while appearance stays on the left")
	menu._subtitle_appearance_open = true; menu.refresh(); controls = menu._subtitle_controls()
	check(not controls.any(func(row): return row.get("field", {}).get("key", "") == "listening_enabled") and menu._subtitle_group_states.has("listening"), "Appearance replaces detail controls while listening state remains on the left")
	check(controls.any(func(row): return row.get("field", {}).get("key", "") == "subtitle_line"), "Listening exposes the shared subtitle line control")
	check(choose(menu, "subtitle_line", 2) and video.subtitle_line == 2, "Ray selects original-only line through shared control")
	menu._activate(menu.SUBTITLE_LISTENING)
	check(choose(menu, "listening_source", "ja") and item.source == "ja", "Ray source selection commits")
	menu.refresh()
	check(choose(menu, "listening_target", "") and item.target == "", "Ray selects original only")
	menu.refresh()
	check(choose(menu, "listening_lead", 8) and item.lead == 8, "Ray lookahead selection commits")
	menu.refresh()
	check(choose(menu, "listening_enabled", false) and not item.enabled, "Ray switch disables listening")
	menu.refresh(); controls = menu._subtitle_controls()
	check(controls.size() == 1 and controls[0].field.key == "listening_enabled", "Appearance is offered only after enabling listening")
	check(menu._buttons.all(func(button): return button.target != menu.SUBTITLE_ROW), "Disabled listening does not add a redundant Off row")
	var with_subtitles := {"has_video": true, "subtitle_options": [{"id": 1, "title": "English", "codec": "subrip"}], "subtitle_track": 1,
		"listening_available": true, "listening_enabled": false, "narration_available": true,
		"subtitle_files_available": true, "subtitle_files_state": "ready", "subtitle_files": ["movie.en.srt"]}
	menu.state_provider = func(): return with_subtitles
	menu.refresh()
	check(menu._buttons.any(func(button): return button.target == menu.SUBTITLE_ROW), "Authored subtitles retain their Off choice")
	controls = menu._subtitle_controls()
	check(controls[0].field.key == "listening_enabled" and menu._subtitle_groups().any(func(group): return group.group == "appearance"), "Embedded subtitles retain listening and appearance entries")
	check(menu._subtitle_groups().any(func(group): return group.group == "narration" and group.enabled), "Authored subtitle narration remains available with listening off")
	check(choose(menu, "listening_enabled", true) and item.enabled, "Ray can enable listening with authored subtitles present")
	with_subtitles.listening_enabled = true; menu._subtitle_appearance_open = true
	with_subtitles.subtitle_options[0].codec = "hdmv_pgs_subtitle"; menu.refresh()
	controls = menu._subtitle_controls()
	check(controls.any(func(row): return row.get("field", {}).get("key", "") == "subtitle_line"), "A selected PGS track does not hide live text appearance controls")
	check(controls.all(func(row): return not str(row.get("field", {}).get("key", "")).begins_with("narration_")), "Listening does not offer authored subtitle narration")
	menu._subtitle_files_open = true; menu.refresh(); menu._activate(menu.SUBTITLE_LISTENING)
	check(menu._subtitle_controls()[0].field.key == "listening_enabled" and choose(menu, "listening_enabled", false), "Listening switch remains usable while browsing sidecars")
	item.set_option("listening_enabled", true); item._poll_at = 0; item.tick()
	video.subtitle_file_loading = "file:///movie.srt"; item.tick()
	check(item.available() and video.platform.configurations[-1].enabled, "Pending subtitle import keeps listening available and running")
	video.subtitle_file_loading = ""; item._poll_at = 0; item.tick()
	check(item.available() and video.platform.configurations[-1].enabled, "Cancelled or failed import leaves listening running")
	video.tracks = [{"id": 7, "external": true, "codec": "subrip"}]; item.tick()
	check(item.available() and video.platform.configurations[-1].enabled, "Automatic external subtitle discovery does not stop listening")
	video.tracks.clear()
	var restored := Listening.new(video); restored.memory = Memory.new(item.memory.directory); restored.memory.load_saved(); restored.load_settings(settings)
	restored.reset_source("file:///movie-a.mp4")
	check(not restored.enabled and restored.source == "ja" and restored.lead == 8, "Reload restores global choices and per-video off")
	Privacy.configure_file_settings("none")
	check(not restored.memory.remember("file:///private.mp4", {"enabled": true}), "Privacy disables new activation persistence")
	Privacy.configure_file_settings("all")
	check_player_switching()
	restored.translator.close(); menu.free()
	item.memory.entries.clear(); item.memory.dirty = true; item.memory.save()
	item.translator.close(); video.free()
	print("Live interpretation: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func check_player_switching() -> void:
	var player := Player.new(); root.add_child(player); player.set_process(false)
	var host := Platform.new(); player.platform = host
	player.media.begin(19); player.local_uri = "file:///listening-switch.mp4"
	player._remember_file = false; player.listening.memory.read_only = true
	player.media.playback = {"details": {"audio_tracks": [{"id": 1}], "subtitle_tracks": [{"id": 2, "codec": "subrip", "language": "en"}]}}
	player.media.last_pair = {"session_id": 19}; player._waiting_first = false; player.panel.visible = true
	player._subtitle_poll_ms = Time.get_ticks_msec() + 60000; player._subtitle_received_ms = Time.get_ticks_msec()
	player.subtitles.select(2); player.subtitles.text = "Authored English"
	player.narration.enabled = true; player.narration.hide_subtitles = true; player.narration.apply()
	check(host.narration.back().enabled and player.narration.hides_display(), "Original text subtitle supports narration before switching")
	check(player.listening.set_option("listening_enabled", true), "Production controller enables listening over an embedded track")
	player.listening.report = {"cues": [{"start": 0.0, "end": 10.0, "text": "Live text"}]}
	player.narration.apply(); player._poll_subtitles()
	check(not host.narration.back().enabled and player.narration.enabled and not player.narration.hides_display(), "Listening suspends TTS without erasing narration preferences")
	check(player.caption.visible and player.caption.text == "Live text" and player.subtitles.requested_track == 2, "Live text owns the display and retains the original track")
	player.listening.set_option("listening_enabled", false); player.narration.hide_subtitles = false
	player.narration.apply(); player._poll_subtitles()
	check(host.narration.back().enabled and player.caption.text == "Authored English", "Turning listening off restores original text and narration")
	player.subtitles.text = ""; player.subtitles.bitmap = {"visible": true, "version": 1, "x": 0, "y": 0, "width": 1, "height": 1, "canvas_width": 1, "canvas_height": 1}
	player._poll_subtitles()
	check(player.bitmap_subtitles.texture != null, "Original bitmap subtitle is displayed before switching")
	player.listening.set_option("listening_enabled", true); player._poll_subtitles()
	check(player.bitmap_subtitles.texture == null and not player.material.get_shader_parameter("bitmap_subtitle_enabled"), "Listening removes bitmap overlays even while preparing")
	player.listening.set_option("listening_enabled", false); player._poll_subtitles()
	check(player.bitmap_subtitles.texture != null, "Turning listening off restores original bitmap display")
	player.listening.set_option("listening_enabled", true)
	check(player.set_subtitle_track(0) and not player.listening.enabled, "Manual subtitle Off exits listening")
	player.listening.set_option("listening_enabled", true)
	check(player.set_subtitle_track(2) and not player.listening.enabled, "Manual embedded track selection exits listening")
	player.listening.set_option("listening_enabled", true)
	player.subtitles.select(0); player.subtitle_files.append("movie.en.srt")
	check(player.select_subtitle_file("movie.en.srt") and player.listening.active(), "Import keeps listening running until a replacement is ready")
	player.media.playback.details.subtitle_tracks.append({"id": 7, "codec": "subrip", "external": true})
	player._on_subtitle_files(19, JSON.stringify({"operation": "load", "request": player._subtitle_load_request, "state": "ready", "track_id": 7}))
	check(player.subtitles.requested_track == 7 and not player.listening.enabled and player.listening.available(), "Successful manual import exits listening but retains its entry")
	player.free()
