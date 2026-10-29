extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")
const Main := preload("res://scripts/main.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const ModeFixture := preload("res://tests/test_file_mode_memory.gd")

class Platform extends Fixture.Platform:
	var commands: Array = []
	var acknowledge_capture := true
	func web_browser_command(value: String) -> void:
		var command: Dictionary = JSON.parse_string(value); commands.append(command)
		if command.action == "pause_tab": browser.pause_token = command.pause_token
		if command.action == "capture_video" and acknowledge_capture: browser.captured_fullscreen_request = command.request
		if command.action == "restore_video":
			browser.active = true; browser.playing = bool(command.play)
			if command.get("exit_fullscreen", false): browser.fullscreen_video = false

class ProbeMain extends Main:
	var restored := 0
	func _show_full_library() -> void:
		restored += 1; recent_menu.visible = true

class ReturnVideo extends Video:
	var closed := 0
	func pause_playback() -> void: requested_play = false
	func close_video() -> void: closed += 1; media.close(); control.close()

class ProjectionHost extends ModeFixture.Host:
	var projection := {}
	func web_video_projection(_uri: String) -> String: return JSON.stringify(projection)

var checks := 0
var failures: Array[String] = []
var platform: Platform
var menu: Node3D
var selected: Array = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func poll() -> void:
	menu.web_browser.next_poll = 0; menu.web_browser.tick()
func fullscreen(request: int) -> void:
	platform.browser.merge({"tab_id": 1, "navigation": 5, "focused_window": 1,
		"fullscreen_video": true, "fullscreen_request": request, "active": true, "playing": true,
		"videos": [{"id": "1", "fullscreen": true, "width": 1920, "height": 1080, "playing": true, "time": 43.25},
			{"id": "2", "width": 7680, "height": 4320, "playing": true, "time": 1.0}]}, true)
	poll()
func resolve_ready() -> void:
	platform.web_state = {"id": menu.web_video.pending, "state": "ready", "uri": platform.browser.url,
		"title": "Video", "height": 2160, "geometry": 1, "stereo_mode": 2}
	menu.web_video.next_poll = 0; menu.web_video.tick(); poll(); poll()
func acknowledge_pause() -> void:
	# A browser engine may exit DOM fullscreen when its session becomes inactive.
	platform.browser.active = false; platform.browser.playing = false; platform.browser.fullscreen_video = false; poll()

func _initialize() -> void: call_deferred("run")
func run() -> void:
	platform = Platform.new(); menu = Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	menu.web_browser.open(platform.browser.url); poll()
	menu.chosen.connect(func(uri, title): selected.append([uri, title]))
	platform.browser.fullscreen = true; poll()
	check(menu.web_video.pending == 0, "A page fullscreen event alone does not take over non-video content")
	fullscreen(1)
	check(menu.web_browser.handoff and menu.web_browser.handoff_auto, "Video fullscreen automatically starts the existing asynchronous resolver")
	var first := platform.web_id; poll(); poll()
	check(platform.web_id == first and not platform.actions.has("pause"), "Polling does not duplicate extraction or stop web playback while resolving")
	platform.web_state = {"id": menu.web_video.pending, "state": "error"}
	menu.web_video.next_poll = 0; menu.web_video.tick(); poll()
	check(not menu.web_browser.handoff and menu.web_video.result.is_empty() and platform.browser.playing, "Extraction failure leaves web playback uninterrupted")
	poll(); check(platform.web_id == first, "A failed fullscreen entry is attempted once")
	fullscreen(2); resolve_ready()
	check(platform.commands[-2].action == "capture_video" and platform.commands[-2].request == 2, "Return target is captured before pausing the source tab")
	check(platform.commands.back().action == "pause_tab" and selected.is_empty(), "Native playback waits for the source tab audio acknowledgement")
	check(menu.web_browser.handoff_start_ms == 43250, "Fullscreen video position wins over a larger playing advertisement")
	acknowledge_pause()
	check(selected.size() == 1 and not menu.visible, "Acknowledged fullscreen handoff starts native playback")
	check(menu.collections.selected_entry.get("web_fullscreen", false), "Native open receives the format-driven fullscreen marker")
	check(not menu.web_browser.playback_return.is_empty(), "Closing the browser UI retains its exact return context")
	var origin: String = platform.browser.url
	var main := ProbeMain.new(); var video := ReturnVideo.new()
	main.recent_menu = menu; main.video = video
	video.local_uri = origin; video.media.begin(7)
	main._on_video_playback_failed(); await process_frame
	check(main.restored == 1 and video.closed == 1, "Native startup failure closes native playback and reopens the browser once")
	var returned: Dictionary = platform.commands.back()
	check(returned.action == "restore_video" and returned.origin == origin and returned.navigation == 5 and returned.tab == 1,
		"Recovery addresses the original tab and document without navigating a URL")
	check(returned.play and returned.position_ms == 43250 and not returned.exit_fullscreen, "Startup failure resumes the original web position in fullscreen")
	poll(); check(platform.web_id == first + 1, "Failure return does not immediately trigger another native takeover")
	fullscreen(3); resolve_ready(); acknowledge_pause()
	video.local_uri = origin; video.media.begin(8); video.media.frame_counter = 1; video.control.observe(67000, 120000)
	main.playback_mode = "repeat_one"
	main._close_current_media()
	returned = platform.commands.back()
	check(main.restored == 2 and returned.position_ms == 67000, "User exit returns the native playback progress to the same page")
	check(not returned.play and returned.exit_fullscreen, "User exit leaves the web video paused and exits its fullscreen")
	check(menu.web_browser.playback_return.is_empty(), "Return context is consumed exactly once")
	check(video.loop_enabled, "Returning from fullscreen restores the ordinary playback loop preference")
	fullscreen(4); resolve_ready(); acknowledge_pause()
	video.local_uri = origin; video.media.begin(9); video.media.frame_counter = 1; video.control.observe(120000, 120000)
	main._on_video_completed(); await process_frame
	check(main.restored == 3 and not platform.commands.back().play, "Natural completion returns to the web page without replaying it")
	fullscreen(5); resolve_ready()
	menu.web_browser.handoff_started_ms = Time.get_ticks_msec() - 90001
	poll()
	check(not menu.web_browser.handoff and platform.commands.back().action == "restore_video" and platform.commands.back().play,
		"Missing web pause acknowledgement falls back to web playback")
	fullscreen(6)
	platform.browser.navigation = 6; poll()
	check(not menu.web_browser.handoff and menu.web_video.pending == 0, "A new document cancels extraction bound to the old page")
	fullscreen(7)
	platform.browser.videos[0].protected = true
	menu.web_browser._cancel_handoff(); menu.web_browser.fullscreen_seen.erase(1); poll()
	check(not menu.web_browser.handoff, "Protected fullscreen video stays with the website")
	platform.acknowledge_capture = false
	fullscreen(8); resolve_ready()
	check(menu.web_browser.pause_started == 0, "Web playback is not paused before the return target is acknowledged")
	menu.web_browser.capture_started_ms = -10000; poll()
	check(not menu.web_browser.handoff and platform.browser.playing, "Missing capture acknowledgement falls back without interrupting the page")
	platform.acknowledge_capture = true
	fullscreen(9); resolve_ready()
	platform.browser.navigation = 6; platform.browser.active = false; poll()
	check(not menu.web_browser.handoff and platform.commands.back().action == "resume_tab", "A document change cancels only the addressed pause without resuming peer windows")
	menu.web_browser.playback_return = {"native_uri": origin}
	menu.web_browser.playback_selected("file:///different.mp4")
	check(menu.web_browser.playback_return.is_empty(), "Choosing another source discards the old web return")
	prefetch_checks()
	await manual_return_checks(main, video)
	server_play_checks()
	video.free(); main.free(); menu.free(); platform.free()
	await process_frame
	await format_checks()
	print("Web fullscreen handoff: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)

func server_play_checks() -> void:
	var browser: RefCounted = menu.web_browser
	var origin := "http://192.168.1.20:8096/web/index.html#!/videoosd"
	menu.visible = true; menu.section = Menu.Section.WEB
	platform.browser.merge({"url": origin, "tab_id": 1, "navigation": 50, "focused_window": 1,
		"fullscreen": false, "fullscreen_video": true, "fullscreen_request": 90, "active": true, "playing": true,
		"videos": [{"id": "1", "server_play": true, "fullscreen": true, "playing": true, "time": 31.0}]}, true)
	browser.open()
	browser.prefetch_uri = origin; browser.prefetch_ms = Time.get_ticks_msec()
	browser.prefetch_result = {"state": "ready", "uri": "old-server-version"}
	poll()
	check(browser.handoff and browser.handoff_auto and menu.web_video.pending > 0, "Server play starts native resolution without a DOM fullscreen request")
	check(menu.web_video.result.is_empty(), "A new server play cannot reuse another episode/version cached on the same page")
	var native_uri := "http://192.168.1.20:8096/web/index.html#thru3d-video=21&MediaSourceId=version_2"
	platform.web_state = {"id": menu.web_video.pending, "state": "ready", "uri": native_uri, "title": "Server movie"}
	menu.web_video.next_poll = 0; menu.web_video.tick(); poll(); poll(); acknowledge_pause()
	check(browser.has_playback_return(native_uri), "Credential-free server identity retains its original webpage return")
	browser.restore_playback(false, 67000)
	check(platform.commands.back().action == "restore_video" and platform.commands.back().origin == origin and platform.commands.back().position_ms == 67000,
		"Server playback returns to the captured page at native progress")

func manual_return_checks(main: ProbeMain, video: ReturnVideo) -> void:
	var restores := main.restored
	var origin := "https://www.youtube.com/watch?v=jNQXAC9IVRw"
	for exit_mode in ["close", "failure", "completed"]:
		menu.visible = true; menu.section = Menu.Section.WEB
		platform.browser.merge({"url": origin, "tab_id": 3, "navigation": 40, "focused_window": 2,
			"fullscreen_video": false, "active": true, "playing": true,
			"videos": [{"id": "1", "width": 1920, "height": 1080, "playing": true, "time": 12.0}]}, true)
		menu.web_browser.open(); poll()
		var captures := platform.commands.filter(func(command): return command.action == "capture_video").size()
		menu.web_browser.action(menu.web_browser.BASE + 6); resolve_ready(); acknowledge_pause()
		check(not menu.visible and menu.web_browser.has_playback_return(origin), "Button handoff retains a return target: " + exit_mode)
		check(menu.collections.selected_entry.get("web_handoff", false) and not menu.collections.selected_entry.get("web_fullscreen", false),
			"Manual handoff retains its own projection behavior")
		check(platform.commands.filter(func(command): return command.action == "capture_video").size() == captures,
			"Manual handoff does not require a fullscreen capture")
		menu.web_browser.playback_selected(origin, menu.collections.selected_entry.get("web_handoff", false))
		check(menu.web_browser.has_playback_return(origin), "Selecting the handoff preserves its return context")
		video.local_uri = origin; video.media.begin(10 + restores); video.media.frame_counter = 1; video.control.observe(67000, 120000)
		match exit_mode:
			"close": main._close_current_media()
			"failure": main._on_video_playback_failed(); await process_frame
			"completed": main._on_video_completed(); await process_frame
		restores += 1
		check(main.restored == restores and menu.web_browser.active(), "Manual playback returns to the browser: " + exit_mode)
		var returned: Dictionary = platform.commands.back()
		check(returned.action == "select" and returned.tab == 3 and returned.window == 2,
			"Manual return selects the original tab and window without reloading its URL")
		check(menu.web_browser.playback_return.is_empty(), "Manual return is consumed exactly once")
		main._return_to_web_video(false, origin)
		check(main.restored == restores, "A late completion cannot reopen the returned browser")
	menu.web_browser.playback_return = {"native_uri": origin}
	menu.web_browser.playback_selected(origin)
	check(menu.web_browser.playback_return.is_empty(), "Opening the same URL outside the browser drops the old return context")

func watch(url: String, navigation: int) -> void:
	menu.web_browser._cancel_handoff()
	platform.browser.merge({"url": url, "tab_id": 1, "navigation": navigation, "active": true, "playing": true,
		"native_supported": true, "fullscreen_video": false, "videos": [{"id": "1", "width": 1920, "height": 1080, "playing": true, "time": 5.0}]}, true)
	poll(); menu.web_browser.playing_since = Time.get_ticks_msec() - 3001; poll()
func finish_resolve(state: String) -> void:
	platform.web_state = {"id": menu.web_video.pending, "state": state, "uri": platform.browser.url, "title": "Video", "height": 1080}
	menu.web_video.next_poll = 0; menu.web_video.tick(); poll()

func prefetch_checks() -> void:
	menu.visible = true; menu.section = Menu.Section.WEB; menu.web_browser.opened = true
	var before: int = platform.web_id
	watch("https://www.bilibili.com/video/BV1xx411c7mD/", 20)
	check(platform.web_id == before + 1 and menu.web_video.pending > 0 and not menu.web_browser.handoff, "A steadily playing supported video is resolved in the background")
	finish_resolve("error")
	check(menu.web_video.result.is_empty() and menu.web_browser.prefetch_id == 0, "A background failure is never shown on the page")
	menu.web_browser.playing_since = Time.get_ticks_msec() - 3001; poll()
	check(platform.web_id == before + 1, "A failed background attempt is not repeated for the same page")
	watch("https://www.bilibili.com/video/BV1yy411c7mD/", 21)
	finish_resolve("ready")
	check(menu.web_video.result.is_empty() and menu.web_browser.prefetch_result.get("state", "") == "ready", "A finished background result is kept silently")
	var resolved: int = platform.web_id
	fullscreen(30)
	check(menu.web_browser.handoff and platform.web_id == resolved, "Fullscreen reuses the finished result without another extraction")
	poll()
	check(platform.commands[-2].action == "capture_video" and platform.commands[-2].request == 30, "The reused result captures the return before its tab pause")
	watch("https://www.bilibili.com/video/BV1zz411c7mD/", 22)
	var inflight: int = menu.web_video.pending
	check(inflight > 0, "Another page starts its own background resolution")
	fullscreen(31)
	check(menu.web_browser.handoff and menu.web_video.pending == inflight and platform.web_id == resolved + 1, "Fullscreen adopts the running extraction instead of restarting it")
	resolve_ready()
	check(platform.commands.back().action == "pause_tab", "The adopted result pauses only the source tab")
	watch("https://www.bilibili.com/video/BV1ww411c7mD/", 23)
	check(menu.web_video.pending > 0, "Background resolution starts for the next page")
	platform.browser.url = "https://www.bilibili.com/"; poll()
	check(menu.web_video.pending == 0 and menu.web_browser.prefetch_id == 0, "Leaving the page cancels its background resolution")
	watch("https://www.bilibili.com/video/BV1xx411c7mD/", 24)
	platform.browser.videos[0].media_epoch = "frame:video:1"
	poll()
	check(menu.web_video.pending == 0, "A changed media epoch cancels a stale in-flight resolution")
	menu.web_browser.playing_since = Time.get_ticks_msec() - 3001; poll(); finish_resolve("ready")
	check(not menu.web_browser.prefetch_result.is_empty(), "The current media epoch can cache its own resolution")
	platform.browser.videos[0].network_media = true; poll()
	check(menu.web_browser.prefetch_result.is_empty(), "Newly observed network media supersedes a cached extractor result")
	menu.web_browser.playing_since = Time.get_ticks_msec() - 3001; poll(); finish_resolve("ready")
	platform.browser.videos[0].width = 640; platform.browser.videos[0].height = 360; poll()
	check(menu.web_browser.prefetch_result.is_empty(), "Newly known browser dimensions invalidate an unchecked cached representation")
	menu.web_browser.playing_since = Time.get_ticks_msec() - 3001; poll(); finish_resolve("ready")
	platform.browser.videos[0].width = 3840; platform.browser.videos[0].height = 2160; poll()
	check(menu.web_browser.prefetch_result.is_empty(), "Switching to member 4K at the same URL and media epoch invalidates the lower quality cache")
	menu.web_browser.playing_since = Time.get_ticks_msec() - 3001; poll(); finish_resolve("ready")
	platform.browser.videos[0].media_epoch = "frame:video:2"; poll()
	check(menu.web_browser.prefetch_result.is_empty(), "SPA replacement at the same URL cannot reuse the previous movie")
	menu.web_browser._cancel_handoff()

func format_checks() -> void:
	var host := ProjectionHost.new(); var player := Video.new(); root.add_child(player); player.set_process(false)
	player.platform = host; player.history_enabled = false
	var directory := ProjectSettings.globalize_path("res://../../build/output/web-fullscreen-20261028/modes")
	player.mode_memory.directory = directory; player.mode_memory.entries.clear()
	var uri := "https://www.youtube.com/watch?v=jNQXAC9IVRw"
	player.mode_memory.remember(uri, {"geometry": 1, "stereo_sbs": true, "depth_requested": true})
	player.mode_lock = {"geometry": 3, "layout": 1, "fisheye_fov": 180}
	check(player.open_library(uri, "Misleading VR180 SBS title", {"web_handoff": true, "web_fullscreen": true, "start_ms": 43250}), "Fullscreen dispatch uses the normal native open")
	check(player.geometry == 0 and not player.stereo_sbs and not player.depth_requested and player._layout_pending == null,
		"A flat stream overrides remembered/locked VR modes and title guesses")
	check(host.calls.back()[1] == 43250, "Format selection preserves the requested browser progress")
	for captured_uri in ["webvideo://capture/opaque-fixture", "http://server.test:8096/web#thru3d-video=21"]:
		check(player.open_library(captured_uri, "Captured video", {"web_handoff": true, "start_ms": 27000}), "Captured identities use the existing native open")
		check(host.calls.back()[1] == 27000, "HTTP server and opaque capture identities preserve webpage progress")
	for format in [[1, 2, false], [3, 1, true], [3, 0, false]]:
		host.projection = {"version": 1, "kind": "equirectangular", "geometry": format[0], "stereo_mode": format[1],
			"bounds": [0, 0, 0, 0], "pose": [0, 0, 0]}
		player.open_library(uri, "Video", {"web_handoff": true, "web_fullscreen": true})
		check(player.geometry == format[0] and player.stereo_sbs == (format[1] != 0) and player.top_bottom == format[2],
			"Source metadata selects VR180/360 and mono/LR/TB correctly: " + str(format))
	player.close_video(); player.free(); await process_frame
