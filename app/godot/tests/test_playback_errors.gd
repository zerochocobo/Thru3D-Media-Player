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

class ExternalLibrary extends Node3D:
	var status := ""
	func refresh() -> void: pass

class ExternalHost extends "res://scripts/main.gd":
	func _close_current_media(_restore_browser: bool = true) -> void:
		_external_video_uri = ""
		video.media.error = ""
		video.media.error_report = {}

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	I18n.use("zh")
	var main := Main.new()
	var video := Video.new()
	root.add_child(video); video.set_process(false)
	var external := ExternalHost.new()
	var library := ExternalLibrary.new()
	external.recent_menu = library
	external.video = video
	video.local_uri = "externalvideo://fixture/video"
	external._external_video_uri = video.local_uri
	video.media.error_report = {"reason": "tls_failed"}
	video.media.error = Errors.message(video.media.error_report)
	external._on_video_playback_failed()
	check(library.status == I18n.t(Errors.REASONS.tls_failed), "External failure preserves the certificate diagnosis after closing the video")
	video.local_uri = ""
	library.free(); external.free()
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
	var unavailable := {"code": "MPV_FRAME_PIPELINE_FAILED", "reason": "http_error", "stage": "opening",
		"http_status": 503, "mpv_code": -13, "detail": "MPV playback: loading failed",
		"native_detail": "MPV playback: loading failed"}
	video._on_error(21, JSON.stringify(unavailable))
	check(menu._info.text.contains(I18n.t(Errors.REASONS.http_error)), "An HTTP 503 shows the media server failure")
	check(Errors.details(video.media.error_report).contains("HTTP 503"), "The failed open retains HTTP 503 in its details")
	for text in ["https://user:pass@nas/video?token=secret", "smb://user:pass@nas/folder/file", "Cookie: secret", "Authorization: Bearer secret", "password=secret", "{\"token\":\"secret\"}"]:
		check(not Errors.details({"message": text}).contains("secret"), "Details redact credentials: " + text.get_slice(":", 0))
	check(not Errors.clean({"message": "https://nas/?token=private"}).message.contains("private"), "Saved and logged reports use the same redaction boundary")
	menu.dismiss(); video.media.begin(10); I18n.use("zh")
	video._access_request = 42
	video._access_pending = {"uri": "content://documents/movie.strm", "title": "movie.strm"}
	video._on_local_access(42, JSON.stringify({"uri": "content://documents/movie.strm", "state": "error", "error": "LOCAL_DOCUMENT_MISSING"}))
	check(menu.visible and menu._failure_open and video.picker_error == "LOCAL_DOCUMENT_MISSING", "A missing document grant is also reported visibly")
	var usb_doc := "content://com.android.externalstorage.documents/tree/1234-ABCD%3A/document/1234-ABCD%3Amovie.mp4"
	check(Main.usb_takeover_offer(true, usb_doc, "LOCAL_DOCUMENT_PROVIDER_FAILED", "", {}) 		and Main.usb_takeover_offer(true, usb_doc, "", "", {"reason": "storage_provider_failed"}), "PICO provider failures on system storage offer the USB takeover")
	check(not Main.usb_takeover_offer(false, usb_doc, "LOCAL_DOCUMENT_PROVIDER_FAILED", "", {}) 		and not Main.usb_takeover_offer(true, "content://media/external/video/1", "LOCAL_DOCUMENT_PROVIDER_FAILED", "", {}) 		and not Main.usb_takeover_offer(true, usb_doc, "LOCAL_DOCUMENT_MISSING", "", {"reason": "not_found"}), "Other devices, sources and failures keep the plain error")
	var offer_state: Callable = menu.state_provider
	var requested: Array[String] = []
	menu.action_requested.connect(func(operation): requested.append(operation))
	menu.state_provider = func(): return offer_state.call().merged({"usb_takeover_offer": true}, true)
	menu.show_playback_error()
	var takeover: Array = menu._buttons.filter(func(button): return button.target == Menu.USB_TAKEOVER)
	var details: Array = menu._buttons.filter(func(button): return button.target == Menu.ERROR_DETAILS)
	check(takeover.size() == 1 and details.size() == 1 and takeover[0].node.position.y > details[0].node.position.y + 0.06, "The takeover sits above error details without overlap")
	if takeover.size() == 1:
		var hit := menu.ray_hit(takeover[0].node.global_position + menu.global_transform.basis.z, -menu.global_transform.basis.z)
		if not hit.is_empty(): menu._activate_hit(hit)
	check(requested == ["usb_takeover"] and not menu._failure_open, "One ray press requests the takeover and closes the failure dialog")
	menu.state_provider = offer_state; menu.show_playback_error()
	check(not menu._buttons.any(func(button): return button.target == Menu.USB_TAKEOVER), "Without the offer the failure dialog shows no takeover")
	menu.dismiss()
	menu.state_provider = func(): return offer_state.call().merged({"usb_takeover_offer": true, "error": "x", "has_video": true}, true)
	menu.refresh()
	var bar_open: Array = menu._buttons.filter(func(button): return button.target == Menu.ERROR_OPEN)
	var bar_takeover: Array = menu._buttons.filter(func(button): return button.target == Menu.USB_TAKEOVER)
	check(bar_open.size() == 1 and bar_takeover.size() == 1 and bar_takeover[0].node.position.x > bar_open[0].node.position.x, "The takeover sits beside the failure entry in the control bar")
	requested.clear()
	menu._activate(Menu.USB_TAKEOVER)
	check(requested == ["usb_takeover"], "The control bar takeover works without opening the failure dialog")
	menu.state_provider = offer_state; menu.dismiss()
	menu.dismiss()
	# The failure's log in one tap: the button follows its upload; the owner sends each failure once.
	var upload := {}
	menu.state_provider = func(): return offer_state.call().merged({"diagnostic_upload": upload}, true)
	requested.clear()
	menu.show_playback_error()
	var log_button := func() -> Dictionary:
		var found: Array = menu._buttons.filter(func(button): return button.target == Menu.FAILURE_LOG)
		return found[0] if found.size() == 1 else {}
	var caption := func(button: Dictionary) -> String:
		for child in button.node.get_children(): if child is Label3D: return child.text
		return ""
	details = menu._buttons.filter(func(button): return button.target == Menu.ERROR_DETAILS)
	check(not log_button.call().is_empty() and log_button.call().enabled and log_button.call().node.position.y > details[0].node.position.y + 0.06
		and caption.call(log_button.call()) == I18n.t("Send log") and menu._tips.has(Menu.FAILURE_LOG), "A failure offers its log above the details")
	menu._activate(Menu.FAILURE_LOG)
	check(requested == ["diagnostic_upload"] and menu._failure_open, "One press asks the owner to upload this failure's log")
	upload["busy"] = "upload"; menu.refresh_values()
	requested.clear(); menu._activate(Menu.FAILURE_LOG)
	check(not log_button.call().enabled and caption.call(log_button.call()) == I18n.t("Uploading…") and requested.is_empty(), "No second upload while one is under way")
	upload.erase("busy"); upload["code"] = "7F2K9QXM"; menu.refresh_values(); menu._activate(Menu.FAILURE_LOG)
	check(caption.call(log_button.call()) == I18n.t("Uploaded · code %s") % "7F2K9QXM" and requested.is_empty()
		and str(menu._tips.get(Menu.FAILURE_LOG, "")).contains("ffskyteam@gmail.com"), "A sent log shows the code and where to quote it")
	upload.erase("code"); upload["error"] = I18n.t("Could not upload"); menu.refresh_values(); menu._activate(Menu.FAILURE_LOG)
	check(caption.call(log_button.call()).contains(I18n.t("Save log")) and requested == ["diagnostic_save"], "A failed upload offers saving the log instead")
	menu.state_provider = offer_state; menu.dismiss()
	# The owner files the report under the failure and answers each requester in order.
	check(Errors.report_category({"reason": "link_expired"}) == "files_network" and Errors.report_category({"code": "STRM_READ_TIMEOUT"}) == "files_network"
		and Errors.report_category({}, "LOCAL_DOCUMENT_MISSING") == "files_network" and Errors.report_category({"reason": "ai_gpu_unavailable"}) == "picture"
		and Errors.report_category({"reason": "audio_output_failed"}) == "audio_subtitles" and Errors.report_category({"reason": "decoder_failed"}) == "playback"
		and Errors.report_category({"code": "MPV_PLAYBACK_STUCK"}) == "playback", "The problem type follows the failure")
	check(Main.source_scheme("smb://user:pass@nas/a.mkv") == "smb" and Main.source_scheme("/storage/emulated/0/a.mkv") == "file"
		and Main.source_scheme("HTTPS://x/y") == "https" and Main.source_scheme("") == "" and Main.source_scheme("a b://x") == "other", "Only the source's scheme is reported")
	video.local_uri = "content://com.android.providers/document/1"
	var filed := main._failure_report()
	check(filed.category == "files_network" and filed.trigger == "failure_panel" and filed.source == "content" and filed.error == "LOCAL_DOCUMENT_MISSING"
		and not str(filed).contains("com.android"), "A picker failure is filed under files without its address")
	main.quick_upload = {"identity": "video:1:x", "busy": "upload"}
	main._diagnostic_origins.assign(["quick", "settings"])
	main.diagnostic_state = {"busy": "save"}
	main._on_diagnostic_log(JSON.stringify({"action": "upload", "ok": true, "code": "AB12CD34"}))
	main._on_diagnostic_log(JSON.stringify({"action": "save", "ok": true, "path": "Download/Thru3D/logs/a.txt"}))
	check(main.quick_upload.get("code") == "AB12CD34" and not main.quick_upload.has("busy") and not main.diagnostic_state.has("code")
		and main.diagnostic_state.get("path") == "Download/Thru3D/logs/a.txt", "Each log result reaches whoever asked for it")
	main.quick_upload = {"identity": "video:1:x", "busy": "upload"}; main._diagnostic_origins.assign(["quick"])
	main._on_diagnostic_log(JSON.stringify({"action": "upload", "ok": false, "error": "rate_limited"}))
	check(main.quick_upload.get("error") == I18n.t("Too many uploads, try again later"), "A refused one-tap upload says why")
	video.picker_error = ""
	# Ordinary files share visible failures, output and rebuffer deadlines with STRM.
	video.local_uri = "smb://saved/ordinary.mkv"
	for detail in ["TLS certificate verification failed", "Video decoder could not be started", "MPV playback: loading failed"]:
		video.media.begin(11); menu.dismiss()
		video._on_error(11, JSON.stringify({"code": "MPV_FRAME_PIPELINE_FAILED", "message": detail}))
		check(menu.visible and not video.media.error.is_empty(), "Ordinary video failure is visible: " + detail)
	# A splice that changes the picture size mid-file reopens past it; the same spot a third time is a real failure.
	video.local_uri = "smb://saved/spliced.ts"
	var splice := JSON.stringify({"code": "MPV_FRAME_PIPELINE_FAILED", "reason": "source_format_changed"})
	video.media.begin(30); video.media.frame_counter = 5; video.control.observed_position_ms = 28780; menu.dismiss()
	video._on_error(30, splice)
	check(video._recover and video._recover_ms == 29780 and not menu.visible, "A mid-file size change reopens one second later")
	video._recover = false; video.media.begin(31); video.media.frame_counter = 5; video.control.observed_position_ms = 28780
	video._on_error(31, splice)
	check(video._recover and video._recover_ms == 32780 and not menu.visible, "The same splice again reopens further on")
	video._recover = false; video.media.begin(32); video.media.frame_counter = 5; video.control.observed_position_ms = 28780
	video._on_error(32, splice)
	check(not video._recover and menu.visible and not video.media.error.is_empty(), "A splice that keeps failing is shown")
	video.media.begin(33); video.media.frame_counter = 5; video.control.observed_position_ms = 300000; menu.dismiss()
	video._on_error(33, splice)
	check(video._recover and video._recover_ms == 301000, "A later splice in the same file starts over")
	video._recover = false; video.local_uri = "smb://saved/odd.ts"; video.media.begin(34); menu.dismiss()
	video._on_error(34, splice)
	check(not video._recover and menu.visible, "A format the first frame already lacks is not retried")
	video.local_uri = "smb://saved/restart.ts"; video.media.begin(35); video.media.frame_counter = 5; video.control.observed_position_ms = 28780; menu.dismiss()
	video._on_error(35, JSON.stringify({"code": "MPV_FRAME_PIPELINE_FAILED", "reason": "source_frame_lost"}))
	check(video._recover and video._recover_ms == 29780 and not menu.visible, "A decoder restart that loses queued frames reopens too")
	video._recover = false; video.local_uri = "smb://saved/ordinary.mkv"
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
	I18n.use("zh")
	video.picker_error = "LOCAL_DOCUMENT_PROVIDER_FAILED"
	check(main._menu_error() == "系统文件服务打开失败，请重试。", "Provider preflight failure stays distinct from missing or revoked access")
	check(Errors.message({"reason":"storage_provider_failed"}) != Errors.REASONS.not_found, "Provider RPC failures do not claim the file was removed")
	# Decoder limits reach the user as numbers, through the same clean() boundary as the bridge report.
	var decoder := {"hardware": true, "decoder": "c2.qti.av1.decoder", "mime": "video/av01", "device": "Quest 3",
		"max_width": 8192, "max_height": 8192, "peak_width": 8192, "peak_height": 4320, "peak_fps": 48, "max_height_at_width": 4608, "exceeded": true,
		"note": "https://secret.example/x?token=1"}
	var oversized := Errors.clean({"reason": "resolution_unsupported", "stage": "decoding",
		"video": {"codec": "av1", "width": 7680, "height": 7680, "fps": 59.94}, "decoder": decoder})
	check(Errors.message(oversized) == "视频 AV1 7680×7680 59.94fps 超出播放器支持范围（最高 8192×4320）。", "Player limit names both sizes: " + Errors.message(oversized))
	var lines := Errors.details(oversized)
	check("视频：AV1 7680×7680 59.94fps" in lines and "解码器：c2.qti.av1.decoder · video/av01 · Quest 3" in lines, "Details name the video and decoder: " + lines)
	check("硬解上限：8192×8192 · 8192×4320@48 · 7680×4608" in lines and "播放器上限：8192×4320 px" in lines, "Details name both limits: " + lines)
	check(not "secret" in str(oversized), "Decoder strings pass the redaction boundary")
	oversized.reason = "decoder_capacity_exceeded"
	check(Errors.message(oversized) == "视频 AV1 7680×7680 59.94fps 超出本机硬件解码能力（最高 8192×4320 48fps）。", "Hardware limit names the device's peak: " + Errors.message(oversized))
	oversized.decoder = {"hardware": false, "mime": "video/av01", "device": "Quest 2", "exceeded": true}
	check(Errors.message(oversized) == "本机没有可解码视频 AV1 7680×7680 59.94fps 的硬件解码器。", "Missing hardware decoder is named")
	check("解码器：无硬件解码器 · video/av01 · Quest 2" in Errors.details(oversized), "Details say no hardware decoder")
	check(Errors.message({"reason": "resolution_unsupported"}) == Errors.REASONS.resolution_unsupported,"Without parameters the fixed reason remains")
	var timed_out := Errors.clean({"reason": "output_timeout", "stage": "output", "output_wait": {"cache_bytes_per_second": 0, "paused_for_cache": false, "path": "/private"}})
	check(timed_out.output_wait.cache_bytes_per_second == 0 and timed_out.output_wait.paused_for_cache == false, "An output timeout retains the last cache observation")
	check(not timed_out.output_wait.has("path"), "Only known cache measurements enter the timeout report")
	check(Errors.message(timed_out) == Errors.REASONS.output_timeout, "Output timeout shows the observed error")
	# An 8K59.94 HEVC start past the advertised 48 fps keeps output_timeout in the report and names the limit to the user.
	var rate_only := Errors.clean({"reason": "output_timeout", "stage": "output", "video": {"codec": "hevc", "width": 8192, "height": 4096, "fps": 59.94},
		"decoder": {"hardware": true, "decoder": "c2.qti.hevc.decoder", "mime": "video/hevc", "peak_width": 8192, "peak_height": 4320, "peak_fps": 48,
		"size_supported": true, "rate_supported": false, "exceeded": true}})
	check(rate_only.reason == "output_timeout", "The report keeps the observed output error")
	check(Errors.message(rate_only) == "视频 HEVC 8192×4096 59.94fps 超出本机硬件解码能力（最高 8192×4320 48fps）。", "The user still sees the advertised limit: " + Errors.message(rate_only))
	rate_only.reason = "video_output_failed"
	check("48fps" in Errors.message(rate_only), "A video output failure past the limit names it too")
	rate_only.decoder.exceeded = false
	check(Errors.message(rate_only) == Errors.REASONS.video_output_failed, "Within the limit the output error stays")
	# The media-library 404 context must survive the clean() that guards logged and saved reports.
	var server_404 := {"reason": "not_found", "stage": "resolving", "http_status": 404, "media_server": {"provider": "emby",
		"request": "server_original_range", "redirect": "same_host", "has_base_path": true, "explicit_version": false,
		"note": "https://nas.example/emby?api_key=secret", "nested": {"path": "/private"}}}
	var kept: Dictionary = Errors.clean(server_404).get("media_server", {})
	check(kept.get("provider") == "emby" and kept.get("request") == "server_original_range" and kept.get("redirect") == "same_host"
		and kept.get("has_base_path") == true and kept.get("explicit_version") == false, "Media server request context is kept: " + str(kept))
	check(not "secret" in str(kept) and not kept.has("nested"), "Media server context passes the redaction boundary")
	check(Errors.message(Errors.clean(server_404)) == Errors.message({"reason": "not_found", "stage": "resolving", "http_status": 404}),
		"Request context does not change the user message")
	# A cloud read failure keeps where the loopback read failed, its timing and earlier successes.
	var cloud_500 := {"reason": "http_error", "stage": "reading", "http_status": 500, "cloud": {"provider": "quark",
		"step": "link", "error": "dns", "elapsed_ms": 5, "attempts": 1, "from_start": true, "sources_ok": 1, "since_ok_s": 13,
		"note": "https://cdn.example/file?token=secret", "nested": {"path": "/private"}}}
	var cloud: Dictionary = Errors.clean(cloud_500).get("cloud", {})
	check(cloud.get("provider") == "quark" and cloud.get("step") == "link" and cloud.get("error") == "dns" and cloud.get("elapsed_ms") == 5
		and cloud.get("attempts") == 1 and cloud.get("from_start") == true and cloud.get("sources_ok") == 1 and cloud.get("since_ok_s") == 13,
		"Cloud read context is kept: " + str(cloud))
	check(not "secret" in str(cloud) and not cloud.has("nested"), "Cloud read context passes the redaction boundary")
	# A stalled source reaches the exported log with labels, marks, the native wait and module names only.
	var stalled := {"kind": "close_stuck", "scheme": "smb", "stage": "core_terminate", "closing_ms": 51000, "first_frame": false,
		"detail": "smb://nas/share?token=secret", "nested": [1, 2],
		"startup": {"worker_started_ms": 1, "native_created_ms": 812, "note": {"deep": true}},
		"native": {"stage": "core_terminate", "decoder": "hardware", "last_log_ms": 50500,
			"recent_modules": ["vd", "ao/aaudio", 5, "ffmpeg/demuxer-with-a-very-long-module-name"],
			"control_call": "snapshot", "control_call_ms": 17000, "core_recent_modules": ["af", "ao/aaudio", "smb://nas/x"],
			"core_last_log_ms": 16900, "core_decoder": "unknown"}}
	var cleaned := Errors.clean_source_diagnostic(stalled, 4)
	check(cleaned.session_id == 4 and cleaned.kind == "close_stuck" and cleaned.closing_ms == 51000 and cleaned.first_frame == false,
		"Stalled-source labels and numbers are kept: " + str(cleaned))
	check(cleaned.startup == {"worker_started_ms": 1, "native_created_ms": 812}, "Startup marks are kept one level down: " + str(cleaned.startup))
	check(cleaned.native.recent_modules == ["vd", "ao/aaudio", "ffmpeg/demuxer-with-a-ve"] and cleaned.native.last_log_ms == 50500,
		"MPV modules are short names only: " + str(cleaned.native))
	check(cleaned.native.control_call == "snapshot" and cleaned.native.control_call_ms == 17000 and cleaned.native.core_last_log_ms == 16900
		and cleaned.native.core_recent_modules.slice(0, 2) == ["af", "ao/aaudio"], "The blocking call and the core's own trail are kept: " + str(cleaned.native))
	check(not cleaned.has("nested") and not "secret" in str(cleaned), "Stalled-source records pass the redaction boundary")
	var Log := preload("res://scripts/diagnostic_log.gd")
	var Privacy := preload("res://scripts/media_privacy.gd")
	var saved_log := [Log.path, Log.rotated_path, Privacy.mode, Privacy.vault]
	var log_dir := OS.get_user_data_dir().path_join("tests/playback_errors_source_diagnostic")
	DirAccess.make_dir_recursive_absolute(log_dir)
	Log.path = log_dir.path_join("events.jsonl"); Log.rotated_path = log_dir.path_join("events.1.jsonl")
	if FileAccess.file_exists(Log.path): DirAccess.remove_absolute(Log.path)
	Privacy.mode = Privacy.ALL; Privacy.vault = null
	video.media.begin(9) # Another session is current: a replaced source still reports.
	video._on_source_diagnostic(4, JSON.stringify(stalled))
	var logged: Variant = JSON.parse_string(FileAccess.get_file_as_string(Log.path).strip_edges().get_slice("\n", 0))
	check(logged is Dictionary and logged.event == "mpv_source_diagnostic" and logged.details.session_id == 4
		and logged.details.native.stage == "core_terminate" and not "secret" in str(logged), "Stalled source is written to the exported log: " + str(logged))
	Log.path = saved_log[0]; Log.rotated_path = saved_log[1]; Privacy.mode = saved_log[2]; Privacy.vault = saved_log[3]
	main.free(); menu.free(); video.free()
	if failures.is_empty(): print("Playback error checks passed: ", checks); quit(0)
	else:
		for failure in failures: push_error(failure)
		quit(1)
