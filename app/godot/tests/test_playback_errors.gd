extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
const Main := preload("res://scripts/main.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Errors := preload("res://scripts/playback_errors.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []

class Host extends RefCounted:
	var closed: Array[int] = []
	func close_mpv_video(id: int) -> void: closed.append(id)
	func mpv_supported() -> bool: return false

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	I18n.use("zh")
	var main := Main.new()
	var video := Video.new()
	root.add_child(video); video.set_process(false)
	main.video = video
	var host := Host.new()
	video.platform = host
	var menu := Menu.new()
	menu.state_provider = func(): return {"error": I18n.t(video.media.error), "title": "电影.SBS.strm"}
	root.add_child(menu); menu.set_process(false)
	main.video_menu = menu; main.player_menu = menu
	video.playback_failed.connect(main._on_video_playback_failed)
	for code in Errors.MESSAGES:
		menu.dismiss()
		video.media.begin(7); video._waiting_first = true
		video._opening_deadline_ms = 1000
		video._on_error(6, JSON.stringify({"code": code}))
		check(not menu.visible and video.media.error.is_empty(), "Stale error must not disturb the current source")
		video._on_error(7, JSON.stringify({"code": code, "message": "https://nas/?secret=private"}))
		check(menu.visible and menu.section == 2, "Failure opens a visible information panel: " + code)
		check(menu._info.text.contains(I18n.t(Errors.MESSAGES[code])), "Specific translated reason is visible: " + code)
		check(not menu._info.text.contains("private") and not menu._info.text.contains(code), "No tokens or diagnostic codes on the panel")
		check(not video._waiting_first and video._opening_deadline_ms == 0, "Failure ends the opening wait")
		check(menu._info.autowrap_mode != TextServer.AUTOWRAP_OFF, "Error text is wrapped without title truncation")
		video._on_state(7, JSON.stringify({"state": "ready"}))
		check(video.media.state == "failed", "Late native ready event cannot resurrect a failed source")
	video.media.begin(8); video._waiting_first = true; video._opening_deadline_ms = 100
	menu.dismiss()
	video._check_open_timeout(99)
	check(not menu.visible and host.closed.is_empty(), "Slow opening remains pending before its deadline")
	video._check_open_timeout(100)
	check(menu.visible and video.media.state == "failed" and host.closed == [8], "Timeout visibly fails and closes the native session")
	video._check_open_timeout(200)
	check(host.closed == [8], "Timeout closes the session only once")
	video.media.begin(9); video._waiting_first = false; video._opening_deadline_ms = 100
	video._check_open_timeout(200)
	check(video.media.error.is_empty() and host.closed == [8], "Presented first frame cancels the opening timer")
	for language in ["zh", "zh_Hant", "ja"]:
		I18n.use(language)
		for message in Errors.MESSAGES.values(): check(I18n.t(message) != message, "Localized failure: " + language)
	for report in [{"message": "MPV playback: loading failed"}, {"message": "MPV playback: unrecognized file format"}, {"message": "timeout"}, {}]:
		check(not Errors.message(report).is_empty(), "Unplayable media always has a useful explanation")
	menu.dismiss(); video.media.begin(10); I18n.use("zh")
	video._access_request = 42
	video._access_pending = {"uri": "content://documents/movie.strm", "title": "movie.strm"}
	video._on_local_access(42, JSON.stringify({"uri": "content://documents/movie.strm", "state": "error", "error": "LOCAL_DOCUMENT_MISSING"}))
	check(menu.visible and menu.section == 2 and video.picker_error == "LOCAL_DOCUMENT_MISSING", "A missing document grant is also reported visibly")
	video.picker_error = ""
	# Ordinary files share visible failures, output and rebuffer deadlines with STRM.
	video.local_uri = "smb://saved/ordinary.mkv"
	for detail in ["TLS certificate verification failed", "Video decoder could not be started", "MPV playback: loading failed"]:
		video.media.begin(11); menu.dismiss()
		video._on_error(11, JSON.stringify({"code": "MPV_FRAME_PIPELINE_FAILED", "message": detail}))
		check(menu.visible and not video.media.error.is_empty(), "Ordinary video failure is visible: " + detail)
	video.media.begin(12); video._waiting_first = true; video._output_deadline_ms = 500
	video._check_playback_timeout(499)
	check(video.media.error.is_empty(), "Output can still arrive before its deadline")
	video._check_playback_timeout(500)
	check(video.media.state == "failed" and host.closed.back() == 12, "Missing output fails visibly and closes the session")
	video.media.begin(13); video.media.frame_counter = 1; video._waiting_first = false
	video.media.playback = {"details": {"paused_for_cache": "yes"}}
	video.requested_play = false; video._check_playback_timeout(1000); video._check_playback_timeout(99000)
	check(video.media.error.is_empty() and video._buffering_deadline_ms == 0, "User pause never becomes a buffering error")
	video.requested_play = true; video._check_playback_timeout(1000); video._check_playback_timeout(31000)
	check(video.media.state == "failed" and host.closed.back() == 13, "Stalled buffering has a visible network error")
	main.free(); menu.free(); video.free()
	if failures.is_empty(): print("Playback error checks passed: ", checks); quit(0)
	else:
		for failure in failures: push_error(failure)
		quit(1)
