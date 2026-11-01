extends SceneTree
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Main := preload("res://scripts/main.gd")
const Tracks := preload("res://scripts/file_track_memory.gd")
const Timing := preload("res://scripts/file_subtitle_timing.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
const I18n := preload("res://scripts/i18n.gd")
const URI := "file:///dual-subtitles/lesson.mkv"
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	var primary: Array = []
	var secondary: Array = []
	var speech: Array = []
	var loads: Array = []
	var packet := {}
	var accept := true
	func set_mpv_subtitle(_session: int, id: int) -> bool: primary.append(id); return accept
	func set_mpv_subtitle_delay(_session: int, _seconds: float) -> bool: return accept
	func set_mpv_secondary_subtitle(_session: int, id: int, seconds: float) -> bool: secondary.append([id, seconds]); return accept
	func get_mpv_subtitles(_session: int, _after: int) -> String: return JSON.stringify(packet) if not packet.is_empty() else ""
	func set_mpv_narration(_session: int, json: String) -> bool: speech.append(JSON.parse_string(json)); return true
	func set_mpv_listening(_session: int, _json: String) -> bool: return true
	func list_mpv_subtitle_files(_session: int, _request: int) -> bool: return true
	func load_mpv_subtitle_file(session: int, request: int, name: String) -> bool: loads.append([session, request, name]); return true
	func load_mpv_subtitle_uri(session: int, request: int, uri: String) -> bool: loads.append([session, request, uri]); return true
	func close_mpv_video(_session: int) -> void: pass

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func click(menu: Node3D, id: int) -> void:
	var matches: Array = menu._buttons.filter(func(b): return b.target == id)
	check(matches.size() == 1 and matches[0].enabled, "Unique enabled ray target %d" % id)
	if matches.is_empty() or not matches[0].enabled: return
	var node: Node3D = matches[0].node
	var from := node.to_global(Vector3(0, 0, 1))
	var direction := -node.global_basis.z
	menu.press_pointer("right_hand", from, direction, true)
	menu.release_pointer("right_hand", from, direction, true)

func cue(sequence: int, delay: float = 0.0) -> Dictionary:
	return {"sequence": sequence, "session_id": 7, "generation": 2, "mpv_source_handle": 9, "source_epoch": 4,
		"age_ms": 0, "timeline_valid": true, "required_command_id": 1, "command_id": 1,
		"track_id": 1, "delay_seconds": 0.0, "start_seconds": "10", "end_seconds": "11", "position_seconds": "10.5", "text": "English original",
		"required_secondary_command_id": 2, "secondary": {"sequence": sequence, "source_epoch": 4,
			"timeline_valid": true, "command_id": 2, "track_id": 2, "delay_seconds": delay,
			"start_seconds": "9", "end_seconds": "12", "position_seconds": "10.5", "text": "中文对照"}}

func _initialize() -> void: call_deferred("run")

func run() -> void:
	Privacy.configure(Privacy.ALL)
	var folder := ProjectSettings.globalize_path("res://../../build/output/dual-subtitles/session-%d" % Time.get_ticks_usec())
	var video := Video.new(); root.add_child(video); video.set_process(false)
	var host := Host.new(); video.platform = host
	video.local_uri = URI; video.media.begin(7); video.media.state = "playing"; video._remember_file = true
	video.track_memory = Tracks.new(folder + "/tracks"); video.subtitle_timing = Timing.new(folder + "/timing")
	video.narration.memory = video.NarrationSettings.Memory.new(folder + "/speech")
	video.media.playback = {"details": {"pgs_supported": true, "subtitle_tracks": [
		{"id": 1, "codec": "subrip", "language": "eng", "title": "English"},
		{"id": 2, "codec": "subrip", "language": "zho", "title": "中文"},
		{"id": 3, "codec": "ass", "language": "jpn", "title": "日本語"},
		{"id": 4, "codec": "hdmv_pgs_subtitle", "language": "eng", "title": "PGS"}]}}
	check(video.set_subtitle_track(1), "Existing primary selection still succeeds")
	check(not video.dual_subtitles.enabled and host.secondary.is_empty(), "Ordinary selection sends no companion commands")
	check(not video.track_memory.lookup(URI).has("secondary_subtitle"), "Old users acquire no optional selection record")
	check(video.dual_subtitles.compose("one\ntwo", 2) == "two", "Single-track line filtering remains unchanged")
	var main := Main.new(); main.video = video; main.settings_path = folder + "/settings.cfg"
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false); main.player_menu = menu
	menu.state_provider = main._menu_state
	menu.setting_requested.connect(main._on_player_setting)
	menu.subtitle_requested.connect(video.set_subtitle_track)
	menu.secondary_subtitle_requested.connect(video.dual_subtitles.select)
	menu.visible = false; menu.toggle(); menu._activate(110)
	check(not menu._buttons.any(func(b): return b.target in [Menu.SUBTITLE_PRIMARY, Menu.SUBTITLE_SECONDARY]), "Default panel hides all slot controls")
	var original_width: float = menu._subtitle_panel_bounds.size.x
	click(menu, Menu.SUBTITLE_DUAL)
	check(video.dual_subtitles.enabled and video.dual_subtitles.editing_secondary and host.secondary.is_empty(), "Button opts in without guessing a second language")
	check(is_equal_approx(menu._subtitle_panel_bounds.size.x, original_width), "Enabling dual subtitles preserves panel width")
	click(menu, Menu.SUBTITLE_ROW + 2)
	check(video.subtitles.requested_track == 1 and video.dual_subtitles.state.requested_track == 2, "Ray selection changes only the companion")
	check(host.primary.size() == 1 and host.secondary.size() == 1, "Companion selection never reselects the primary")
	check(not video.dual_subtitles.select(1) and not video.dual_subtitles.select(4), "Duplicate and bitmap companions are rejected")
	check(not video.set_subtitle_track(999) and video.dual_subtitles.enabled, "Invalid primary selection preserves the companion")
	video.media.last_pair = {"session_id": 7, "generation": 2, "mpv_source_handle": 9, "source_epoch": 4}
	video._waiting_first = false; video.panel.visible = true
	host.packet = cue(1); video._subtitle_poll_ms = 0; video._poll_subtitles()
	check(video.caption.text == "English original\n中文对照", "Production display composes both independently timed cues")
	check(video.dual_subtitles.compose("first\nsecond", 2) == "second\n中文对照", "Line selection applies inside each track before composition")
	check(video.dual_subtitles.set_delay(0.7) and is_zero_approx(video.subtitle_delay), "Secondary timing leaves the primary delay unchanged")
	host.packet = cue(2); video._subtitle_poll_ms = 0; video._poll_subtitles()
	check(video.caption.text == "English original", "A stale companion delay cannot revive text or clear the primary")
	host.packet = cue(3, 0.7); video._subtitle_poll_ms = 0; video._poll_subtitles()
	check(video.caption.text.ends_with("中文对照"), "Matching delayed companion is displayed")
	host.packet = cue(4, 0.7); host.packet.end_seconds = "10.5"; video._subtitle_poll_ms = 0; video._poll_subtitles()
	check(video.caption.text == "中文对照", "An independently ended primary does not terminate the translation")
	for fence in ["session_id", "generation", "mpv_source_handle", "source_epoch"]:
		var packet := cue(10 + checks, 0.7); packet[fence] = 99
		if fence == "source_epoch": packet.secondary.source_epoch = 99
		var previous: String = video.dual_subtitles.state.text
		video.dual_subtitles.observe(packet)
		check(video.dual_subtitles.state.text == previous if fence == "session_id" else video.dual_subtitles.state.text.is_empty(), "Companion rejects stale source fence " + fence)
	video.narration.load_settings(ConfigFile.new())
	check(video.narration.set_option("narration_enabled", true), "Existing narration can be enabled with dual display")
	video.narration.set_option("narration_source", 2); video.narration.set_option("narration_language", "auto")
	video.narration.apply()
	check(host.speech.back().source == 2 and is_equal_approx(host.speech.back().source_delay, 0.7), "One TTS source uses the companion's own delay")
	check(video.narration.resolved_language() == "zh", "Automatic reading language follows the selected Chinese companion")
	video.narration.save(main.settings)
	check(not main.settings.has_section_key("narration", "source_secondary"), "Reading the companion never becomes a global default")
	video.narration.reset_source("file:///another-lesson.mkv")
	check(not video.narration.source_secondary and not video.narration.enabled, "Another video keeps the ordinary narration default")
	video.narration.reset_source(URI); video.narration.apply()
	check(video.narration.source_secondary and host.speech.back().source == 2, "Per-file narration follows the restored secondary role")
	check(video.dual_subtitles.select(0) and not video.narration.enabled, "Closing the spoken companion stops TTS instead of switching language")
	check(host.speech.back().enabled == false, "TTS receives an explicit stop")
	check(video.dual_subtitles.select(2), "Companion can be reselected")
	check(video.select_subtitle_file("lesson.fr.srt", false, true), "External picker captures the companion target")
	var request: int = host.loads.back()[1]
	video.dual_subtitles.editing_secondary = false
	video.media.playback.details.subtitle_tracks.append({"id": 6, "codec": "subrip", "language": "fra", "title": "French", "external": true, "source_file": "lesson.fr.srt"})
	video._on_subtitle_files(7, JSON.stringify({"operation": "load", "request": request, "state": "ready", "track_id": 6}))
	check(video.subtitles.requested_track == 1 and video.dual_subtitles.state.requested_track == 6, "Async file completion uses the captured slot after changing tabs")
	check(video.select_subtitle_file("late.srt", false, true), "Begin another optional load")
	request = host.loads.back()[1]
	check(video.dual_subtitles.set_enabled(false), "Explicit dual Off succeeds")
	video._on_subtitle_files(7, JSON.stringify({"operation": "load", "request": request, "state": "ready", "track_id": 6}))
	check(not video.dual_subtitles.enabled and video.dual_subtitles.state.requested_track == 0, "Late file completion cannot reenable dual subtitles")
	check(int(video.track_memory.lookup(URI).secondary_subtitle.id) == 0, "Explicit Off is persisted")
	check(video.dual_subtitles.select(2), "Select a saved companion")
	var saved: Dictionary = video.track_memory.lookup(URI)
	var reloaded := Tracks.new(folder + "/tracks"); reloaded.load_saved()
	check(reloaded.lookup(URI) == saved, "Primary and secondary survive a real settings-bank reload")
	video._queue_track_restore(saved); video._restore_tracks()
	check(video.subtitles.requested_track == 1 and video.dual_subtitles.state.requested_track == 2, "Production restore reopens the remembered pair")
	video.listening.enabled = true
	check(not video.dual_subtitles.snapshot().dual_subtitles_enabled and video.dual_subtitles.compose("live speech", 0) == "live speech", "Live captions temporarily own the original interface and display")
	video.listening.enabled = false
	check(video.dual_subtitles.snapshot().dual_subtitles_enabled and video.dual_subtitles.state.requested_track == 2, "Leaving live captions retains the selected subtitle pair")
	check(video.set_subtitle_track(4) and not video.dual_subtitles.enabled, "Selecting PGS returns safely to the original single-bitmap workflow")
	check(video.set_subtitle_track(1) and video.dual_subtitles.set_enabled(true), "Return to an optional text pair")
	for locale in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(locale); menu.refresh()
		check(menu._buttons.any(func(b): return b.target == Menu.SUBTITLE_DUAL), "Dual control remains available in " + locale)
	I18n.use("en")
	var old_narration: Dictionary = video.narration._values(); old_narration.erase("source_secondary")
	check(video.narration.memory._valid_value(old_narration), "Old narration settings remain readable")
	check(not video.narration.memory._normalize_value(old_narration).source_secondary, "Old narration settings default to the original primary")
	check(video.dual_subtitles.select(2), "Select before privacy checks")
	var before_privacy: Dictionary = video.track_memory.lookup(URI)
	Privacy.configure_file_settings(Privacy.NONE)
	check(video.dual_subtitles.select(3), "Per-file privacy does not prevent in-memory selection")
	Privacy.configure_file_settings(Privacy.ALL)
	check(video.track_memory.lookup(URI) == before_privacy, "Selection made with file settings disabled is not persisted")
	check(video.set_subtitle_track(0) and not video.dual_subtitles.enabled and video.dual_subtitles.state.requested_track == 0, "The original Off action still stops both subtitle tracks")
	menu.free(); main.free(); video.free()
	for failure in failures: printerr("FAIL: " + failure)
	print("Dual subtitles: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
