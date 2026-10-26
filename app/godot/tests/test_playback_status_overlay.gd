extends SceneTree

const Main := preload("res://scripts/main.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Overlay := preload("res://scripts/playback_status_overlay.gd")
const Fps := preload("res://scripts/fps_overlay.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
class ListeningPlatform extends RefCounted:
	func set_mpv_listening(_id: int, _value: String) -> bool: return true

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	I18n.use("en")
	var main := Main.new()
	var video := Video.new()
	root.add_child(video); video.set_process(false)
	main.video = video
	var menu := Menu.new()
	menu.state_provider = main._menu_state
	root.add_child(menu); menu.set_process(false)
	main.video_menu = menu; main.player_menu = menu
	var fps := Fps.new()
	root.add_child(fps); fps.set_shown(false); fps.set_process(false)
	main.fps_overlay = fps
	var overlay := Overlay.new()
	overlay.source = main._playback_status_sample
	root.add_child(overlay); overlay.set_process(false)
	main.playback_status_overlay = overlay
	video.changed.connect(main._on_video_changed)
	video.media.begin(7); video.media.state = "playing"
	video.local_uri = "smb://fixture/Share/movie.mp4"
	video.requested_play = true; video._waiting_first = false
	video._loading_status = {"remote": true, "phase": "reading", "bytes_per_second": 2300000}
	video.changed.emit()
	check(not overlay.visible and not menu.visible, "Uninterrupted playback has no status or transport")
	var previous_platform = video.platform
	video.platform = ListeningPlatform.new()
	video.media.playback = {"details": {"audio_tracks": [{"id": 1}]}}
	video.listening.enabled = true
	video.listening.report = {"state": "preparing", "phase": "models", "model_progress": 25}
	main._show_player_menu(); menu.refresh_values()
	check(menu._status.visible and menu._status.text.ends_with("25%"), "ASR preparation progress is visible on the playback control bar")
	var status_label := menu._status
	video.listening.report = {"state": "preparing", "phase": "recognition", "buffer_progress": 75}
	menu.refresh_values()
	check(menu._status == status_label and menu._status.text.ends_with("75%"), "Measured preparation progress updates without rebuilding the controls")
	check(video.requested_play and video.media.state == "playing", "Preparation feedback preserves video playback and never opens a modal")
	menu.state_provider = func():
		var sample: Dictionary = main._menu_state()
		sample.seek_feedback = {"phase": "done", "alpha": 0.05, "origin_ms": 0, "target_ms": 1000, "delta_ms": 1000}
		return sample
	menu.refresh_values()
	check(menu._status.text.ends_with("75%") and is_equal_approx(menu._status.modulate.a, 1.0), "Seek feedback fading never hides active ASR preparation progress")
	menu.state_provider = main._menu_state
	video.listening.set_option("listening_enabled", false); menu.refresh_values()
	check(not menu._status.visible, "Closing listening in its menu immediately clears preparation feedback")
	video.platform = previous_platform; video.media.playback = {}; menu.dismiss()
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language)
		for uri in ["smb://fixture/Share/movie.mp4", "http://127.0.0.1/dlna/movie", "cloud://fixture/movie.mp4", "medialib://fixture/movie"]:
			video.local_uri = uri
			video.media.playback = {"details": {"paused_for_cache": "yes"}}
			video.changed.emit()
			check(not menu.visible and overlay.visible and overlay.text.contains(I18n.t("Buffering…")), "Spontaneous buffering has passive feedback without opening controls: " + language + uri)
			check(overlay.text.contains("2.3 MB/s") and not fps.visible, "Real transfer rate remains visible with FPS disabled")
			video.media.playback = {}; video.changed.emit()
			check(not overlay.visible and overlay.text.is_empty() and not menu.visible, "Recovery clears feedback and preserves hidden controls")
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language)
		video.media.playback = {"narration": {"startup_hold": true}}
		video.changed.emit()
		if Menu.NarrationSettings.FEATURE_ENABLED:
			check(overlay.visible and overlay.text == I18n.t("Preparing narration…") and not menu.visible, "Opening narration preparation has localized passive feedback: " + language)
		else:
			check(not overlay.visible and overlay.text.is_empty(), "Withheld narration never shows a stale preparation status: " + language)
		video.requested_play = false; video.changed.emit()
		check(not overlay.visible, "A user pause hides automatic narration preparation feedback")
		video.requested_play = true
		video.media.playback = {"narration": {"startup_hold": false}}
		video.changed.emit()
		check(not overlay.visible and overlay.text.is_empty(), "Narration readiness or cancellation clears feedback")
	I18n.use("en")
	video.media.playback = {"details": {"paused_for_cache": "yes"}}
	main._show_player_menu(); video.changed.emit()
	check(menu.visible and menu._status.visible and menu._status.text.contains("Buffering") and not overlay.visible, "Visible controls exclusively own loading feedback")
	menu.dismiss(); overlay._process(Overlay.UPDATE_SECONDS)
	check(not menu.visible and overlay.visible, "Dismissing controls during buffering transfers feedback to the overlay")
	fps.set_shown(true); overlay.refresh()
	check(overlay.visible and overlay.position.y < fps.position.y - 0.02, "Status and FPS occupy separate lines")
	fps.set_shown(false); overlay.refresh()
	check(overlay.visible and is_equal_approx(overlay.position.y, fps.position.y), "Status uses the FPS position when FPS is hidden")
	main._show_player_menu(); overlay._process(Overlay.UPDATE_SECONDS)
	video.media.playback = {}; video.changed.emit()
	check(menu.visible and not menu._status.visible and not overlay.visible, "Recovery removes text without dismissing manually opened controls")
	menu.dismiss(); video.media.playback = {"details": {"paused_for_cache": "yes"}}
	video.requested_play = false; video.changed.emit()
	check(not overlay.visible, "User pause is not buffering")
	video.requested_play = true; video.changed.emit()
	check(overlay.visible, "Resuming a starved stream restores feedback")
	main.photo_active = true; overlay._process(Overlay.UPDATE_SECONDS)
	check(not overlay.visible, "Photo viewing hides old video feedback")
	main.photo_active = false
	video.media.begin(8); video.media.state = "playing"; video.changed.emit()
	check(not overlay.visible and overlay.text.is_empty(), "A new session cannot inherit old buffering text")
	video.media.playback = {"details": {"paused_for_cache": "yes"}}
	video.changed.emit(); video.media.state = "failed"; video.media.error = "Network failure"; video.changed.emit()
	check(not overlay.visible, "A real failure replaces the passive loading indicator")
	video.media.begin(9); video._waiting_first = true; video.changed.emit()
	check(overlay.visible and not menu.visible, "Initial network loading also respects hidden controls")
	video.media.close(); video.changed.emit()
	check(not overlay.visible and overlay.text.is_empty(), "Closing playback clears feedback")
	video.changed.disconnect(main._on_video_changed)
	main.free(); overlay.free(); fps.free(); menu.free(); video.free()
	for failure in failures: push_error(failure)
	print("Playback status overlay checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
