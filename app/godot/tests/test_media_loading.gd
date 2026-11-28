extends SceneTree
const Loading := preload("res://scripts/media_loading.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Photo := preload("res://scripts/photo_display.gd")
const PhotoMenu := preload("res://scripts/photo_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
class Host extends RefCounted:
	var status := {"remote": true, "phase": "reading", "elapsed_ms": 15000, "bytes_per_second": 8200000}
	func get_mpv_loading_status(_id: int) -> String: return JSON.stringify(status)
	func close_mpv_video(_id: int) -> void: pass
func check(value: bool, reason: String) -> void:
	checks += 1
	if not value: failures.append(reason)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language)
		for phase in Loading.PHASES:
			var caption := Loading.caption({"remote": true, "phase": phase, "elapsed_ms": 15000, "bytes_per_second": 8200000})
			check(caption.contains("15 s") and caption.contains("8.2 MB/s") and caption.contains(I18n.t(Loading.PHASES[phase])), "Stage, time and actual throughput are visible: " + language + phase)
			if language != "en": check(I18n.t(Loading.PHASES[phase]) != Loading.PHASES[phase], "Loading stage is localized")
	check(Loading.caption({"remote": false, "bytes_per_second": 100000}).is_empty(), "Local media has no network transfer display")
	check(not Loading.caption({"remote": true, "phase": "connecting"}).contains("/s"), "Connecting has no fabricated speed")
	check(Loading.caption({"remote": true, "bytes_per_second": 0}).contains("0 KB/s"), "A stopped transfer visibly falls to zero")
	for uri in ["smb://saved/movie.mp4", "cloud://115/movie.mkv", "medialib://server/scene/7", "https://test/media", "http://test/photo.jpg"]: check(Loading.remote(uri), "Every remote file type is included")
	for uri in ["file:///sdcard/movie.mp4", "content://documents/movie"]: check(not Loading.remote(uri), "Local sources are excluded")
	var video := Video.new(); root.add_child(video); video.set_process(false)
	video.media.begin(7); video.local_uri = "smb://saved/movie.mp4"; video._waiting_first = true
	video._loading_started_ms = Time.get_ticks_msec() - 15000; video.platform = Host.new()
	video._poll_loading(Time.get_ticks_msec())
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false)
	menu.state_provider = func(): return {"has_video": true, "loading_caption": video.loading_caption()}
	menu.toggle()
	check(menu._status_text().contains("8.2 MB/s"), "Ordinary remote video shows native transfer status in the transport")
	check(menu._status.visible and menu._status.text.contains("8.2 MB/s"), "The actual default transport contains the visible loading label")
	video.local_uri = "http://192.0.2.1:8200/MediaItems/42.mp4"
	video.platform.status = {"remote": true, "phase": "reading"}
	video._poll_loading(Time.get_ticks_msec() + 501)
	video.media.playback = {"details": {"cache_speed": "2300000"}}
	check(video.loading_caption().contains("2.3 MB/s"), "DLNA HTTP media shows MPV's measured input rate")
	video.media.playback = {}
	video._waiting_first = false; video.media.state = "playing"
	check(video.loading_caption().is_empty(), "The first frame ends the opening display")
	menu.refresh_values()
	check(not menu._status.visible, "The actual transport removes loading text after the first frame")
	video.requested_play = true; video.media.playback = {"details": {"paused_for_cache": "yes"}}
	video._poll_loading(Time.get_ticks_msec() + 501)
	check(video.loading_caption().contains(I18n.t("Buffering…")), "Rebuffering restores the visible status")
	video.picker_error = Video.CHECKING_ACCESS
	check(video.loading_caption() == I18n.t(Video.CHECKING_ACCESS), "A document access check shows as loading progress")
	menu.state_provider = func(): return {"has_video": true, "error": "", "loading_caption": video.loading_caption()}
	menu.refresh_values()
	check(menu._status_text() == I18n.t(Video.CHECKING_ACCESS), "A document access check is not reported as a playback failure")
	menu.state_provider = func(): return {"has_video": true, "loading_caption": video.loading_caption()}
	video.picker_error = ""
	video.media.state = "failed"; video.media.error = "Playback failed"
	check(video.loading_caption().is_empty(), "An error replaces loading instead of remaining pending")
	video.media.begin(8); video._waiting_first = true; video._loading_poll_ms = 0; video._loading_bytes = -1
	video.local_uri = "file:///sdcard/Download/test.strm"
	video._opening_deadline_ms = 1000; video.platform.status = {"remote": true, "phase": "reading_disc", "bytes": 1000, "bytes_per_second": 1000}
	video._poll_loading(900)
	check(not video.loading_caption().is_empty(), "A local STRM pointing to network media still shows network loading")
	check(video._opening_deadline_ms == 60900, "Actual remote reads extend the first-frame deadline, including slow ISO opens")
	video._poll_loading(1401)
	check(video._opening_deadline_ms == 60900, "A stale positive speed cannot extend the deadline without new bytes")
	video.platform.status.bytes = 2000; video._poll_loading(1902)
	check(video._opening_deadline_ms == 61902, "Further actual data keeps the request pending")
	video._check_open_timeout(61901)
	check(video.media.error.is_empty(), "An active slow read remains pending until its inactivity deadline")
	# A cold Alpha model holds the first frame while it compiles (UU4VEVGZ: 40 s against a 30 s wait).
	video.media.begin(9); video._waiting_first = true; video._loading_poll_ms = 0; video._loading_bytes = -1
	video.local_uri = "file:///sdcard/Movies/test.mp4"; video._opening_deadline_ms = 0
	video._loading_started_ms = 100000; video._output_deadline_ms = 130000
	video.platform.status = {"remote": false, "phase": "reading", "alpha_model_preparing": true}
	video._poll_loading(129000)
	check(video._output_deadline_ms == 159000, "A compiling Alpha model keeps the first-frame wait pending")
	check(video.loading_caption() == I18n.t("Preparing the model"), "The wait says the model is being prepared")
	video._poll_loading(455000)
	check(video._output_deadline_ms == 100000 + Video.ALPHA_MODEL_WAIT_MS, "The model wait has an upper limit")
	video._loading_poll_ms = 0; video._poll_loading(470000)
	check(video._output_deadline_ms == 100000 + Video.ALPHA_MODEL_WAIT_MS, "Polling past the limit does not extend it")
	video.media.begin(10); video._waiting_first = true; video._loading_poll_ms = 0
	video._loading_started_ms = 100000; video._output_deadline_ms = 130000
	video.platform.status = {"remote": false, "phase": "reading"}
	video._poll_loading(129000)
	check(video._output_deadline_ms == 130000, "A ready model leaves the ordinary first-frame wait unchanged")
	check(video.loading_caption() != I18n.t("Preparing the model"), "No model caption once the model is ready")
	var photo := Photo.new(); photo.loading = true; photo._loading_status = {"remote": true, "phase": "reading", "bytes_per_second": 2400000}
	photo._loading_started_ms = Time.get_ticks_msec() - 15000
	var photo_menu := PhotoMenu.new(); photo_menu._state = photo.snapshot()
	check(photo_menu._photo_status().contains("2.4 MB/s"), "Remote images use the same visible transfer status")
	photo.free(); photo_menu.free(); video.free(); menu.free()
	print("Media loading checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
