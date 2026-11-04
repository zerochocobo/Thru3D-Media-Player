extends SceneTree
const Main = preload("res://scripts/main.gd")
const Video = preload("res://scripts/mpv_video_display.gd")
const Menu = preload("res://scripts/player_menu.gd")
const I18n = preload("res://scripts/i18n.gd")
class Host extends RefCounted:
	var listening := []
	var narration := []
	func set_mpv_listening(_id: int, value: String) -> bool: listening.append(JSON.parse_string(value)); return true
	func get_mpv_listening(_id: int) -> String: return '{"state":"off"}'
	func set_mpv_narration(_id: int, value: String) -> bool: narration.append(JSON.parse_string(value)); return true
	func close_mpv_video(_id: int) -> void: pass
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func button(menu: Node3D, target: int) -> Dictionary:
	for item in menu._buttons:
		if item.target == target: return item
	return {}
func field(menu: Node3D, key: String) -> int:
	for id in menu.choices.targets:
		if menu.choices.targets[id].get("key") == key: return id
	return -1
func tap(menu: Node3D, target: int) -> bool:
	var entry := button(menu, target)
	if entry.is_empty(): return false
	var origin: Vector3 = entry.node.to_global(Vector3(0, 0, 0.4))
	var direction: Vector3 = -entry.node.global_basis.z
	if menu.ray_hit(origin, direction).get("target", -1) != target: return false
	menu.press_pointer("right_hand", origin, direction, true)
	menu.release_pointer("right_hand", origin, direction, true)
	return true
func choose(menu: Node3D, key: String, value: Variant) -> bool:
	for id in menu.choices.targets:
		if menu.choices.targets[id].get("key") == key and menu.choices.targets[id].kind == "open":
			if not tap(menu, id): return false
			break
	for step in 24:
		for id in menu.choices.targets:
			var item: Dictionary = menu.choices.targets[id]
			if item.get("key") == key and item.kind == "choose" and item.value == value: return tap(menu, id)
		if menu.choices.opened.is_empty(): return false
		menu.choices.offset += 1; menu.refresh()
	return false
func _initialize() -> void: run.call_deferred()
func run() -> void:
	I18n.use("en")
	var host := Host.new()
	var video := Video.new(); root.add_child(video); video.set_process(false); video.platform = host
	video.local_uri = "file:///subtitle-configuration.mkv"; video.media.begin(9); video.media.state = "playing"
	video.media.playback = {"details": {"duration_seconds": "120", "audio_tracks": [{"id": 1}], "subtitle_tracks": [{"id": 2, "codec": "subrip", "language": "en"}]}}
	video.subtitles.select(0); video.listening.reset_source(video.local_uri)
	video.listening.memory = video.listening.Memory.new(ProjectSettings.globalize_path("res://../../build/output/subtitle-first-batch-20261104/listening-memory"))
	video.narration.memory = video.NarrationSettings.Memory.new(ProjectSettings.globalize_path("res://../../build/output/subtitle-first-batch-20261104/narration-memory"))
	video.listening.enabled = false; video.narration.enabled = false
	var app := Main.new(); app.video = video
	app.settings_path = ProjectSettings.globalize_path("res://../../build/output/subtitle-first-batch-20261104/configuration.cfg")
	var menu := Menu.new(); app.player_menu = menu; menu.state_provider = app._menu_state
	menu.setting_requested.connect(app._on_player_setting)
	root.add_child(menu); menu.set_process(false); menu.toggle(); menu._activate(110)
	check(menu._subtitle_detail_group() == "listening", "No authored selection opens listening preferences by default")
	for language in ["zh", "en", "ja"]:
		check(choose(menu, "listening_source", language), "Ray configures disabled listening language " + language)
		video.listening.tick()
		check(not video.listening.enabled and host.listening.all(func(value): return not value.enabled), "Disabled language changes never request model startup")
	check(choose(menu, "listening_target", "zh-Hans") and choose(menu, "listening_lead", 20), "Translation and pre-read can be configured before enabling")
	video.listening.tick()
	check(not video.listening.translator.enabled and video.listening.translator._request == null, "Preconfiguration never submits online translation")
	check(choose(menu, "listening_enabled", true), "Existing switch starts after configuration")
	video.listening.tick()
	var starts: Array = host.listening.filter(func(value): return value.enabled)
	check(starts.size() == 1 and starts[0].language == "ja" and starts[0].target == "zh-Hans" and starts[0].lead == 20, "Only final settings are sent with the first enable request")
	check(choose(menu, "listening_enabled", false), "Existing switch stops listening")
	check(tap(menu, menu.SUBTITLE_NARRATION), "Narration preferences remain accessible without a text subtitle")
	var blocked := field(menu, "narration_enabled")
	check(blocked >= 0 and not button(menu, blocked).enabled, "Missing text only disables the narration start switch")
	check(tap(menu, blocked) and not video.narration.enabled, "Real ray cannot activate an unavailable narration switch")
	for language in ["zh", "en", "ja"]:
		check(choose(menu, "narration_language", language), "Ray preconfigures narration language " + language)
	check(choose(menu, "narration_voice", "Umiri"), "Voice selection works before enabling")
	check(host.narration.is_empty() and not video.narration.enabled, "Disabled narration preferences never request speech or model startup")
	check(not button(menu, menu.NARRATION_PREVIEW).enabled, "Preview retains existing text-subtitle requirement")
	check(tap(menu, menu.SUBTITLE_CLOSE) and tap(menu, 110) and menu._subtitle_detail_group() == "narration", "Reopening remembers the last detail without enabling its feature")
	check(tap(menu, menu.SUBTITLE_DETAIL_CLOSE) and menu._subtitle_detail_group().is_empty(), "Explicit folding still works")
	check(tap(menu, menu.SUBTITLE_CLOSE) and tap(menu, 110) and menu._subtitle_detail_group() == "narration", "Next opening restores details even after explicit folding")
	video.subtitles.select(2); menu.refresh_values()
	check(button(menu, field(menu, "narration_enabled")).enabled, "Valid text metadata enables the existing start action")
	check(choose(menu, "narration_enabled", true) and host.narration.back().enabled and host.narration.back().language == "ja" and host.narration.back().voice_override == "Umiri", "Narration starts with final configured language and voice")
	check(tap(menu, menu.SUBTITLE_LISTENING) and choose(menu, "listening_enabled", true), "Listening remains independently selectable")
	video.narration.apply(); menu.refresh_values()
	check(video.narration.enabled and not host.narration.back().enabled, "Existing suspend-and-restore narration semantics are unchanged")
	check(tap(menu, menu.SUBTITLE_NARRATION) and not button(menu, field(menu, "narration_enabled")).enabled, "Suspended narration permits configuration but does not bypass mutual exclusion")
	check(tap(menu, menu.SUBTITLE_LISTENING) and choose(menu, "listening_enabled", false), "Stop listening through the existing switch")
	video.narration.apply()
	check(host.narration.back().enabled, "Existing narration auto-resume remains unchanged in this UI-only batch")
	var saved := ConfigFile.new(); check(saved.load(app.settings_path) == OK, "Existing settings persistence remains in use")
	check(saved.get_value("live_interpretation", "source") == "ja" and saved.get_value("live_interpretation", "target") == "zh-Hans" and saved.get_value("narration", "language") == "ja", "Preconfigured language preferences persist")
	check(not menu.allows_playback_sticks(), "Expanded detail retains playback shortcut isolation")
	var off_rows: Array = video.NarrationSettings.rows({"narration_enabled": false, "dual_subtitles_enabled": true, "secondary_subtitle_track": 2})
	check(off_rows.any(func(row): return row.field.key == "narration_language") and not off_rows.any(func(row): return row.field.key == "narration_source"), "Off exposes preferences without promising a secondary-track selection that the existing enable action resets")
	status_checks(video)
	if app.subtitle_tasks: app.subtitle_tasks.translator.close()
	app.subtitle_tasks = null; app.video = null
	app.free(); menu.free(); video.free()
	for message in failures: push_error(message)
	print("Subtitle configuration: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
func status_checks(video: Node3D) -> void:
	var listening: RefCounted = video.listening
	listening.enabled = true; listening.source = "en"; listening.target = "zh-Hans"
	listening.report = {"epoch": 31, "state": "ready", "ahead": 12.0, "position": 20.0, "cues": []}
	var before := JSON.stringify(listening.report)
	check(listening.status_caption(20.0).is_empty(), "First empty frame does not flash a warning")
	listening._empty_caption_since = Time.get_ticks_msec() - 4001
	check(listening.status_caption(20.0) == I18n.t("No text recognized for this segment"), "Empty cues cannot claim twelve seconds of prepared subtitles")
	check(listening.detail_caption(20.0) == "Audio processed · 12 s ahead\nUpcoming · 0 original / 0 translated", "Audio progress and actual text counts are separate")
	check(JSON.stringify(listening.report) == before, "Status inspection does not modify the native report")
	listening.report.cues = [{"start": 25.0, "end": 27.0, "text": "Hello"}]
	check(listening.status_caption(20.0) == I18n.t("Waiting for next subtitle") and listening.text_at(20.0).is_empty(), "Future cue is identified without being displayed early")
	check(listening.text_at(26.0) == "Hello", "Existing original fallback remains intact")
	var key: String = listening.Protocol.cache_key("Hello", "en", "zh-Hans")
	listening.translator.cache[key] = {"text": "你好"}
	listening.translator.failed["future"] = Time.get_ticks_msec(); listening.translator.entries = [{"key": "future"}]
	listening.translator.jobs = [[{"key": "future"}]]
	check(listening.status_caption(26.0).is_empty(), "Future translation failure does not obscure a translated current cue")
	check(listening.detail_caption(26.0).ends_with("1 original / 1 translated"), "Counts reflect actual current original and translation")
	check(listening.text_at(27.0).is_empty() and listening.detail_caption(27.0).ends_with("0 original / 0 translated"), "Expired lines are neither displayed late nor counted as upcoming")
	listening._empty_caption_since = Time.get_ticks_msec() - 4001; listening.report.epoch = 32
	check(listening.status_caption(27.0).is_empty(), "A new seek epoch resets only the gap hint")
	listening.report = {"state": "source_error"}
	check(listening.status_caption(27.0) == I18n.t("Unable to read audio from the source"), "Real source errors remain visible")
