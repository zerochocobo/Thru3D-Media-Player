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
	menu.state_provider = func(): return {"error": I18n.t(video.picker_error if not video.picker_error.is_empty() else video.media.error), "title": "电影.SBS.strm", "error_report": video.media.error_report}
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
		check(menu.visible and menu._failure_open and menu.section == 0, "Failure automatically opens its own dialog: " + code)
		check(not menu._buttons.any(func(button): return button.target == 12), "Failure dialog does not require an Info tab")
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
	for report in [{"code": "MPV_LOCAL_SOURCE_FAILED"}, {"message": "MPV playback: loading failed", "mpv_code": -13},
		{"message": "Failed loading https://nas/403_permission_video.mkv"}, {}]:
		check(Errors.message(report) == "Media loading failed. No specific cause was reported.", "Unknown failures do not invent a permission problem")
	for reason in Errors.REASONS:
		check(Errors.message({"reason": reason}) == Errors.REASONS[reason], "Structured reason has an exact message: " + reason)
	check(Errors.message({"code": "MPV_RVM_FAILED", "reason": "unknown"}) == Errors.REASONS.ai_processing_failed,
		"Older RVM reports name AI passthrough instead of blaming the media")
	I18n.use("zh")
	var ai_report := {"code": "MPV_RVM_FAILED", "reason": "ai_gpu_unavailable", "stage": "ai_initialization",
		"detail": "MNN OpenCL backend unavailable; refusing CPU execution; platform_or_driver (-1001)"}
	check(Errors.message(ai_report) == Errors.REASONS.ai_gpu_unavailable, "GPU startup failure gives an actionable effect message")
	check(Errors.details(ai_report).contains("初始化 AI 透视") and Errors.details(ai_report).contains("platform_or_driver (-1001)"),
		"AI details localize the actual stage and preserve the driver status")
	for mpv_code in Errors.MPV_REASONS:
		check(Errors.message({"mpv_code": mpv_code}) == Errors.REASONS[Errors.MPV_REASONS[mpv_code]], "Numeric native errors survive without text heuristics")
	for language in ["zh", "zh_Hant", "ja"]:
		I18n.use(language)
		for text in Errors.REASONS.values(): check(I18n.t(text) != text, "Localized structured error: " + language)
	I18n.use("zh")
	video.media.begin(20)
	video.media.logical_session_id = 200; video.media.generation = 2
	video._on_error(20, JSON.stringify({"session_id": 20, "logical_session_id": 200, "generation": 1, "reason": "access_denied"}))
	check(video.media.error.is_empty() and video.media.error_report.is_empty(), "A late generation cannot fail the current video")
	var original := {"code": "MPV_FRAME_PIPELINE_FAILED", "reason": "access_denied", "stage": "reading", "http_status": 403, "mpv_code": -13,
		"detail": "Upstream HTTP 403", "native_detail": "MPV playback: loading failed"}
	video._on_error(20, JSON.stringify(original))
	check(video.media.error_report == Errors.clean(original), "Failure keeps all structured fields after native cleanup")
	check(not menu._error_details_open, "A new failure starts with its short reason")
	check(not menu._info.text.contains("403") and not menu._info.text.contains("MPV_"), "Technical information stays out of the short reason")
	menu._activate(Menu.ERROR_DETAILS)
	check(menu._error_details_open, "Ray button expands the details")
	var expanded_detail := Errors.details(video.media.error_report)
	check(expanded_detail.contains("HTTP 403") and expanded_detail.contains("MPV -13") and expanded_detail.contains("Upstream HTTP 403"), "Expanded details retain upstream and native evidence")
	check(not menu.allows_playback_sticks(), "Error details do not enable playback stick shortcuts")
	check(menu.navigate_back() and not menu._error_details_open and menu._failure_open, "Back first collapses the details")
	menu._activate(Menu.ERROR_DETAILS); menu._activate(Menu.ERROR_DETAILS)
	check(not menu._error_details_open, "Ray button also collapses details")
	menu._activate(Menu.ERROR_DETAILS); menu.dismiss()
	check(not menu._error_details_open, "Dismissing the panel collapses details")
	menu.show_playback_error(); menu._activate(Menu.ERROR_DETAILS)
	menu._activate(Menu.SETTINGS_CLOSE)
	check(not menu._failure_open, "Close dismisses the independent error dialog")
	check(menu._buttons.any(func(button): return button.target == Menu.ERROR_OPEN), "The playback bar offers a direct error entry")
	var error_entry := menu.ray_hit(menu.to_global(Vector3(0, 0.1, 1)), -menu.global_transform.basis.z)
	check(int(error_entry.get("target", -1)) == Menu.ERROR_OPEN, "The failure entry is reachable by the controller ray")
	if not error_entry.is_empty(): menu._activate_hit(error_entry)
	check(menu._failure_open and not menu._error_details_open, "The playback bar reopens the error without visiting Info")
	video.media.begin(21)
	menu.refresh()
	check(video.media.error_report.is_empty(), "Opening another source clears old diagnostics")
	check(not menu._failure_open, "Starting another source closes the previous failure dialog")
	video._on_error(20, JSON.stringify(original))
	check(video.media.error_report.is_empty(), "A late previous-source failure cannot replace current diagnostics")
	for text in ["https://user:pass@nas/video?token=secret", "smb://user:pass@nas/folder/file", "Cookie: secret", "Authorization: Bearer secret", "password=secret", "{\"token\":\"secret\"}"]:
		check(not Errors.details({"message": text}).contains("secret"), "Details redact credentials: " + text.get_slice(":", 0))
	check(not Errors.clean({"message": "https://nas/?token=private"}).message.contains("private"), "Saved and logged reports use the same redaction boundary")
	menu.dismiss(); video.media.begin(10); I18n.use("zh")
	video._access_request = 42
	video._access_pending = {"uri": "content://documents/movie.strm", "title": "movie.strm"}
	video._on_local_access(42, JSON.stringify({"uri": "content://documents/movie.strm", "state": "error", "error": "LOCAL_DOCUMENT_MISSING"}))
	check(menu.visible and menu._failure_open and video.picker_error == "LOCAL_DOCUMENT_MISSING", "A missing document grant is also reported visibly")
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
