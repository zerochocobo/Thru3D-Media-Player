extends SceneTree
const Player := preload("res://scripts/mpv_video_display.gd")
const Tasks := preload("res://scripts/subtitle_tasks.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const Main := preload("res://scripts/main.gd")
var checks := 0
var failures: Array[String] = []
var output := ""

class Host extends "res://tests/test_file_mode_memory.gd".Host:
	var configurations: Array = []
	var playing: Array = []
	var closed: Array = []
	var commands: Array = []
	var narration: Array = []
	var ready: Array = []
	var reject_enabled := false
	var revisions: Array = []
	var report := {"epoch": 1, "state": "ready", "buffered": true, "cues": []}
	func open_mpv_video(uri: String, start: int, stereo: bool, profile: String, alpha: bool, vulkan: bool, depth: bool = false, top: bool = false, exact: bool = false) -> int:
		var id := super.open_mpv_video(uri, start, stereo, profile, alpha, vulkan, depth, top, exact)
		next_id += 1
		return id
	func set_mpv_playing(id: int, value: bool) -> void: playing.append([id, value])
	func revise_mpv_video(id: int, _stereo: bool, _alpha: bool, _profile: String, _position: int, _depth: bool = false, _top: bool = false, _exact: bool = false) -> int:
		var next := next_id; next_id += 1; revisions.append([id, next]); return next
	func close_mpv_video(id: int) -> void: closed.append(id)
	func freeze_mpv_pair(_id: int, _token: int, _request: int) -> bool: return true
	func detach_mpv_pair(_id: int, _token: int) -> void: pass
	func release_mpv_frozen_frame(_id: int) -> void: pass
	func set_mpv_listening(id: int, value: String) -> bool:
		var config: Dictionary = JSON.parse_string(value)
		configurations.append({"id": id, "value": config}); return not config.enabled or not reject_enabled
	func get_mpv_listening(_id: int) -> String: return JSON.stringify(report)
	func listening_ready(id: int, epoch: int) -> void: ready.append([id, epoch])
	func set_mpv_subtitle(_id: int, _track: int) -> bool: return true
	func set_mpv_narration(_id: int, value: String) -> bool: narration.append(JSON.parse_string(value)); return true
	func get_mpv_subtitle_bitmap(_id: int, _version: int) -> PackedByteArray: return PackedByteArray([255, 255, 255, 255])
	func subtitle_tasks_request(value: String) -> bool: commands.append(JSON.parse_string(value)); return true
	func subtitle_tasks_status() -> String: return '{"jobs":[],"loaded":true}'
	func subtitle_translation_work() -> String: return '{}'

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label); push_error(label)

func _initialize() -> void: run.call_deferred()

func player() -> Node3D:
	var value := Player.new(); root.add_child(value); value.set_process(false)
	value.platform = Host.new(); value.history_enabled = false
	for memory in [value.mode_memory, value.track_memory, value.subtitle_timing, value.subtitle_encoding, value.audio_timing, value.whisper_memory, value.narration.memory, value.recent_files]: memory.read_only = true
	value.listening.memory = preload("res://scripts/file_listening_memory.gd").new(output.path_join(str(value.get_instance_id())))
	return value

func details(value: Node3D, seekable: String = "yes") -> void:
	value.control.observe(5000, 120000)
	value.media.playback = {"details": {"seekable": seekable, "partially_seekable": "no", "paused": "no", "position_seconds": "5", "duration_seconds": "120",
		"audio_track_id": "1", "audio_tracks": [{"id": 1, "stream_index": 0}], "subtitle_tracks": [{"id": 2, "codec": "subrip", "language": "en"}]}}
	value.media.last_pair = {"session_id": value.media.session_id}; value.media.state = "playing"
	value._waiting_first = false; value.panel.visible = true
	value._subtitle_poll_ms = Time.get_ticks_msec() + 60000; value._subtitle_received_ms = Time.get_ticks_msec()
	value.subtitles.select(2); value.subtitles.text = "Authored subtitle"

func poll(value: Node3D) -> void:
	value.listening._poll_at = 0; value.listening.tick()

func tap(menu: Node3D, target: int) -> bool:
	for button: Dictionary in menu._buttons:
		if button.target != target: continue
		var origin: Vector3 = button.node.to_global(Vector3(0, 0, 1))
		menu.press_pointer("left_hand", origin, -menu.global_basis.z, true)
		menu.release_pointer("left_hand", origin, -menu.global_basis.z, true)
		return true
	return false

func run() -> void:
	output = ProjectSettings.globalize_path("res://../../build/output/cast-listening-host/" + str(Time.get_ticks_usec()))
	Privacy.configure_file_settings("all")
	var value := player(); var host: RefCounted = value.platform
	var uri := "http://192.0.2.1/film.mp4"
	value.listening.memory.remember(uri, {"enabled": true}); value.listening.memory.save()
	var original_memory: Dictionary = value.listening.memory.entries.duplicate(true)
	check(value.open_cast(uri, "Cast", 10, 5000), "Open cast through production player")
	details(value)
	check(not value.listening.enabled, "Cast never inherits an ordinary URL's activation")
	check(value.listening.available(), "Seekable cast with audio offers live captions")
	poll(value)
	check(not host.configurations.back().value.enabled, "Cast remains explicitly off until selected")
	check(host.configurations.back().value.media == "" and not host.configurations.back().value.persist, "Even off, cast configuration carries no durable identity")
	var initial_configs: int = host.configurations.size(); poll(value)
	check(host.configurations.size() == initial_configs, "Disabled cast does not repeatedly configure native recognition")
	var opens: int = host.calls.size(); var playing: int = host.playing.size()
	check(value.listening.set_option("listening_enabled", true), "User enables live captions on a seekable cast")
	host.report.cues = [{"start": 0.0, "end": 10.0, "text": "Live subtitle"}]; poll(value)
	check(host.configurations.back().value.enabled and host.configurations.back().value.network, "Cast recognition enabled as a network source")
	check(host.configurations.back().value.media == "" and not host.configurations.back().value.persist, "Active cast recognition cannot use file or shared subtitle cache")
	for privacy in ["none", "local", "all"]:
		Privacy.configure_file_settings(privacy); poll(value)
		check(host.configurations.back().value.media == "" and not host.configurations.back().value.persist, "Privacy changes cannot promote cast text to persistent cache: " + privacy)
	check(host.calls.size() == opens and host.playing.size() == playing, "Enabling recognition neither reopens nor pauses the player")
	value._poll_subtitles()
	check(value.caption.text == "Live subtitle" and value.subtitles.requested_track == 2, "Cast captions temporarily replace the original display")
	var session: int = value.media.session_id
	value._reopen_after_context_loss(uri, "Cast", 5000, false, session); details(value); poll(value)
	check(value.media.session_id != session and value.cast_token == 10 and value.listening.active(), "Decoder context recovery retains explicitly enabled cast listening")
	check(host.configurations.back().value.media == "" and not host.configurations.back().value.persist, "Internal recovery keeps cast text ephemeral")
	opens = host.calls.size(); playing = host.playing.size()
	value.media.playback.details.audio_tracks = []; value.media.playback.details.erase("seekable")
	poll(value)
	check(value.listening.active() and value.listening.snapshot().listening_available and host.configurations.back().value.enabled, "Seek metadata gap keeps loaded recognition and its switch")
	details(value)
	var tasks := Tasks.new(value)
	check(tasks.supported() and not tasks.enqueue(), "Cast cannot enqueue a whole-film job; global task service remains")
	check(not tasks.command({"operation": "enqueue", "session_id": value.media.session_id, "media": Tasks.Memory.key_for(uri)}), "Generic enqueue command cannot bypass cast restriction")
	check(not host.commands.any(func(row): return row.operation == "enqueue"), "No cast enqueue reaches Android")
	tasks.report = {"jobs": [{"id": "old", "media": Tasks.Memory.key_for(uri), "language": "ja", "target": "", "state": "listening"}]}
	check(tasks.snapshot().subtitle_task.is_empty() and not tasks.snapshot().subtitle_task_supported, "Ordinary same-URL job is absent from the cast panel")
	check(tasks.snapshot().subtitle_tasks.jobs.size() == 1, "Existing global jobs are preserved")
	tasks.tick()
	check(host.commands.back().media == "" and host.commands.back().network and host.commands.back().playing and host.commands.back().listening, "Cast task context isolates identity and retains playback priority")
	check(tasks.command({"operation": "cancel", "id": "old"}), "Global task management still works while casting")
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false)
	menu.state_provider = func():
		var state := {"has_video": true, "title": "Cast", "subtitle_options": [], "subtitle_track": 2}
		state.merge(value.listening.snapshot()); state.merge(tasks.snapshot()); return state
	menu.setting_requested.connect(func(key, setting): value.listening.set_option(key, setting))
	menu.toggle(); menu._subtitle_open = true; menu.refresh()
	check(tap(menu, menu.SUBTITLE_LISTENING), "Controller ray opens the cast listening pane")
	check(not menu._buttons.any(func(button): return button.target in [menu.SUBTITLE_GENERATE, menu.SUBTITLE_TASK_CANCEL]), "Cast listening pane offers no pregeneration or unrelated cancel")
	menu.free()
	value.listening.save(ConfigFile.new())
	check(value.listening.memory.entries == original_memory and not value.listening.memory.dirty, "Cast settings do not alter ordinary URL preferences")
	check(value.set_subtitle_track(0) and not value.listening.enabled, "Manual subtitle Off exits cast recognition")
	check(value.listening.memory.entries == original_memory and not value.listening.memory.dirty, "Manual Off cannot persist cast activation")
	value.listening.set_option("listening_enabled", true)
	check(value.set_subtitle_track(2) and not value.listening.enabled, "Manual authored track also exits cast recognition")
	check(value.listening.memory.entries == original_memory, "Manual authored track cannot overwrite a matching library URL")
	details(value) # Native subtitle polling supplies text again after a manual selection.
	value.narration.enabled = true; value.narration.hide_subtitles = false
	for state in ["audio_error", "unsupported_audio", "source_error", "source_busy", "listening_error"]:
		value.listening.set_option("listening_enabled", true); value.narration.apply()
		check(not host.narration.back().enabled and value.narration.enabled, "Cast recognition temporarily suspends narration: " + state)
		host.report = {"epoch": 2, "state": state}; poll(value); value.narration.apply()
		check(not value.listening.active() and not value.listening.enabled and not host.configurations.back().value.enabled, "Terminal failure stops only cast recognition: " + state)
		value._poll_subtitles()
		check(value.caption.text == "Authored subtitle" and not value.listening.status_caption(5).is_empty(), "Failure restores authored subtitles and a concise status: " + state)
		check(host.narration.back().enabled and value.narration.enabled, "Failure restores original narration preference: " + state)
	check(host.calls.size() == opens and host.playing.size() == playing, "Recognition failures leave video connection and playback intent alone")
	host.report = {"epoch": 3, "state": "ready", "buffered": true, "cues": []}
	host.reject_enabled = true; value.listening.set_option("listening_enabled", true); poll(value)
	check(not value.listening.enabled and not host.configurations.back().value.enabled, "Native refusal exits cast recognition without a retry loop")
	host.reject_enabled = false
	value.listening.set_option("listening_enabled", true); poll(value)
	check(value.listening.status_caption(5) != value.listening.I18n.t("Live subtitles unavailable"), "Explicit retry clears previous failure notice")
	value.subtitles.text = ""; value.subtitles.bitmap = {"visible": true, "version": 1, "x": 0, "y": 0, "width": 1, "height": 1, "canvas_width": 1, "canvas_height": 1}
	value._poll_subtitles(); check(value.bitmap_subtitles.texture == null, "Cast recognition hides authored bitmap overlays")
	host.report = {"epoch": 4, "state": "audio_error"}; poll(value); value._poll_subtitles()
	check(value.bitmap_subtitles.texture != null and not value.listening.active(), "Cast failure restores original bitmap overlay")
	value.listening._failure_until = Time.get_ticks_msec() - 1
	check(value.listening.snapshot().listening_notice.is_empty(), "Failure notice expires without keeping live captions enabled")
	value.listening.set_option("listening_enabled", true)
	value.listening.translator.cache["old"] = {"text": "Old translation"}
	value.cast_token = 0 # Renderer finish clears ownership before closing the player.
	value.listening.save(ConfigFile.new()); poll(value)
	check(not value.listening.active() and value.listening.translator.cache.is_empty(), "Losing cast ownership cancels recognition and translated text")
	check(value.listening.memory.entries == original_memory and host.configurations.back().value.media == "", "Detached old source stays ephemeral until close")
	check(value.open_cast(uri, "Next cast", 11, 0), "Same-URL new cast opens")
	details(value)
	check(not value.listening.enabled and value.listening.report.is_empty() and value.listening.translator.cache.is_empty(), "Same-URL new cast starts clean and off")
	host.report.cues = [{"start": 0.0, "end": 10.0, "text": "Old session"}]; poll(value)
	check(value.listening.text_at(5).is_empty(), "Late previous report cannot appear in a new disabled cast")
	value.listening.set_option("listening_enabled", true); value.cast_token = 12; poll(value)
	check(not value.listening.active() and not host.configurations.back().value.enabled, "Different renderer token cannot inherit running recognition")
	value.cast_token = 0; check(value.open_local(uri, "Library film"), "Return to ordinary same-URL media")
	details(value); poll(value)
	check(value.listening.active() and host.configurations.back().value.media == Tasks.Memory.key_for(uri) and host.configurations.back().value.persist, "Library playback restores original activation and durable cache")
	check(tasks.enqueue(), "Ordinary media retains whole-film generation")
	host.report = {"epoch": 5, "state": "audio_error"}; poll(value)
	check(value.listening.active() and value.listening.enabled, "Ordinary playback retains its existing error-state behavior")
	for seek in ["no", "yes"]:
		value.open_cast(uri, "Unsupported", 20, 0); details(value, seek)
		if seek == "yes": value.media.playback.details.partially_seekable = "yes"
		check(not value.listening.available() and not value.listening.set_option("listening_enabled", true), "Nonseekable or partially seekable casts cannot start recognition")
	value.open_cast(uri, "Unknown duration", 21, 0); details(value); value.control.duration_ms = 0
	check(not value.listening.available(), "Unknown-duration cast cannot start recognition")
	value.open_cast(uri, "No audio", 22, 0); details(value); value.media.playback.details.audio_tracks = []
	check(not value.listening.available(), "Silent cast offers no listening switch")
	value.open_cast("file:///untrusted.mp4", "Not HTTP", 24, 0); details(value)
	check(not value.listening.available(), "Cast listening never widens the supported URL schemes")
	value.open_cast(uri, "Replaced session", 25, 0); details(value); value.listening.set_option("listening_enabled", true)
	value.media.session_id += 100; poll(value)
	check(not value.listening.active() and not host.configurations.back().value.enabled, "Replaced MPV session cannot inherit recognition under the same renderer token")
	value.open_cast(uri, "Disc menu", 23, 0); details(value); value.disc.menu_session = true
	check(not value.listening.available(), "Disc menu restriction remains")
	value.disc.menu_session = false
	tasks.translator.close(); value.free()
	check_revision_menu()
	print("Cast listening: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func check_revision_menu() -> void:
	var value := player(); var host: RefCounted = value.platform
	var app := Main.new(); app.video = value; app.subtitle_tasks = Tasks.new(value)
	value.open_cast("http://192.0.2.1/revision.mp4", "Cast revision", 41, 0); details(value)
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false)
	menu.state_provider = app._menu_state
	menu.toggle(); menu._subtitle_open = true; menu.refresh()
	check(menu._buttons.any(func(button): return button.target == menu.SUBTITLE_LISTENING and button.enabled), "Production Main offers the cast listening entry before a revision")
	var before: int = value.media.session_id
	value._request_revision(); details(value); poll(value); menu.refresh()
	check(value.media.session_id != before and host.revisions.size() == 1, "Production revision returns a new session over the same source")
	check(app._menu_state().get("listening_available", false), "Processing revision does not hide an unopened cast listening entry")
	check(menu._buttons.any(func(button): return button.target == menu.SUBTITLE_LISTENING and button.enabled), "Production menu retains the actual entry after revision")
	value.set_alpha(true); details(value); menu.refresh_values()
	check(menu._buttons.any(func(button): return button.target == menu.SUBTITLE_LISTENING and button.enabled), "User entering Alpha before listening still sees its entry")
	check(value.listening.set_option("listening_enabled", true), "User can first enable listening while already in Alpha passthrough")
	value._request_revision(); details(value); poll(value); menu.refresh()
	check(value.listening.active() and host.configurations.back().value.enabled, "Running cast listening follows legitimate processing revisions")
	for playing_intent in [true, false]:
		value.requested_play = playing_intent
		for effect in [["depth", true], ["alpha", true], ["alpha", false], ["depth", true], ["depth", false], ["alpha", true], ["depth", true]]:
			value.mode_transition.cancel() # The host supplies ready metadata, without an animated GPU-frame handoff.
			var old_session: int = value.media.session_id
			var open_count: int = host.calls.size()
			var track: int = value.subtitles.requested_track
			var portrait_depth: bool = effect[0] == "depth" and value.portrait_requested()
			var accepted: bool = value.set_alpha(effect[1]) if effect[0] == "alpha" else value.set_depth(effect[1])
			check(accepted and host.calls.size() == open_count, "3D/Alpha operation never reopens the cast: " + str(effect))
			check((value.media.session_id == old_session) if portrait_depth else (value.media.session_id != old_session), "Portrait relief keeps its session; processing changes adopt the new session")
			check(value.cast_token == 41 and value.requested_play == playing_intent and value.subtitles.requested_track == track, "3D/Alpha transition retains cast, pause intent and subtitle track")
			details(value); value.media.playback.details.paused = "no" if playing_intent else "yes"; poll(value); menu.refresh_values()
			check(value.listening.active() and app._menu_state().listening_enabled and menu._buttons.any(func(button): return button.target == menu.SUBTITLE_LISTENING and button.enabled), "3D/Alpha transition retains enabled listening and the production menu entry")
	value.set_depth(false); details(value); value.set_projection(1); details(value); value.set_stereo_layout(1); details(value)
	value.set_alpha(true); details(value); value.set_packed_mask(true); details(value); poll(value); menu.refresh_values()
	check(value.packed_mask_on() and not value.alpha_requested and value.listening.active(), "Native packed Alpha replacing AI Alpha retains cast listening")
	value.set_packed_mask(false); details(value); poll(value)
	check(not value.packed_mask_on() and value.listening.active(), "Leaving native packed Alpha retains cast listening")
	var binding := preload("res://tests/test_video_mode_transition.gd").ProbeBinding.new()
	binding.bind(value.material, {"session_id": value.media.session_id, "slot_token": 8, "width": 1920, "height": 1080, "stereo_sbs": true, "color_target": "texture"})
	value._binding = binding; value.media.last_pair = binding.ticket.duplicate(true); value.media.frame_counter = 2
	value.vr_passthrough.binding = preload("res://tests/test_video_mode_transition.gd").ProbeBinding.new()
	value._pending_revision.clear(); value._waiting_first = false; value.panel.visible = true
	for resume in [true, false]:
		value.requested_play = resume
		check(value.vr_passthrough.begin(Transform3D.IDENTITY), "Cast can enter temporary passthrough while listening is enabled")
		check(value.vr_passthrough.active() and value.listening.active() and value.cast_token == 41, "Temporary passthrough retains listening ownership")
		value.vr_passthrough.finish(true); poll(value); menu.refresh_values()
		check(not value.vr_passthrough.active() and value.requested_play == resume and app._menu_state().listening_enabled, "Leaving temporary passthrough restores playback intent and listening entry")
	for seek in ["no", "yes"]:
		value.open_cast("http://192.0.2.1/limited.mp4", "Limited cast", 42, 0); details(value, seek)
		if seek == "yes": value.media.playback.details.partially_seekable = "yes"
		menu.refresh(); menu._subtitle_open = true; menu.refresh()
		check(menu._buttons.any(func(button): return button.target == menu.SUBTITLE_LISTENING and button.enabled), "Unsupported cast retains a configurable listening entry")
		check(not str(menu._tips.get(menu.SUBTITLE_LISTENING, "")).is_empty(), "Unavailable cast entry has a reason tooltip")
		var entries: Array = menu._buttons.filter(func(button): return button.target == menu.SUBTITLE_LISTENING)
		if not entries.is_empty():
			menu._set_subtitle_detail(""); menu.refresh()
			entries = menu._buttons.filter(func(button): return button.target == menu.SUBTITLE_LISTENING)
			var origin: Vector3 = entries[0].node.to_global(Vector3(0, 0, 1))
			var hit: Dictionary = menu.ray_hit(origin, -menu.global_basis.z)
			check(hit.get("target") == menu.SUBTITLE_LISTENING and hit.get("enabled", false), "Ray can open configuration without starting recognition")
			tap(menu, menu.SUBTITLE_LISTENING)
			check(not value.listening.enabled and menu._subtitle_detail_group() == "listening", "Opening unavailable configuration never activates recognition")
			var switches: Array = menu.choices.targets.keys().filter(func(id): return menu.choices.targets[id].get("key") == "listening_enabled")
			check(switches.size() == 1 and menu._buttons.any(func(button): return button.target == switches[0] and not button.enabled), "Unavailable cast switch remains disabled")
			if not switches.is_empty():
				tap(menu, switches[0])
				check(not value.listening.enabled, "Disabled switch consumes a real ray press without starting recognition")
			menu.cancel_pointer("left_hand")
		check(is_instance_valid(menu._subtitle_status_label) and not menu._subtitle_status_label.text.is_empty(), "Unavailable reason is also visible without a hover")
		check(not value.listening.set_option("listening_enabled", true), "Visible unavailable entry cannot bypass runtime eligibility")
	value.control.duration_ms = 0; value.media.playback.details.audio_tracks = []
	menu.refresh_values()
	check(menu._buttons.any(func(button): return button.target == menu.SUBTITLE_LISTENING and button.enabled), "Metadata not ready keeps configuration accessible")
	check(menu._tips.get(menu.SUBTITLE_LISTENING, "") == value.listening.I18n.t("Audio track unavailable"), "Metadata reason refreshes even while eligibility stays false")
	details(value); menu.refresh_values()
	check(menu._buttons.any(func(button): return button.target == menu.SUBTITLE_LISTENING and button.enabled), "Entry becomes actionable when actual metadata is ready")
	app.subtitle_tasks.translator.close(); app.subtitle_tasks = null; app.video = null
	app.free(); menu.free(); value.free()
