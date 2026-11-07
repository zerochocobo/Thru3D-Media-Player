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
	check(menu.web_video.pending == 0, "Page fullscreen stays in the browser")
	var origins := ["https://www.youtube.com/watch?v=jNQXAC9IVRw", "https://www.bilibili.com/video/BV1xx411c7mD/",
		"https://weibo.com/123456/POST1", "https://v.qq.com/x/page/q326831cny0.html",
		"https://www.mgtv.com/b/822501/24773688.html", "https://v.youku.com/v_show/id_XOTUxMzg4NDMy.html"]
	for index in origins.size():
		platform.browser.url = origins[index]
		fullscreen(index + 1); poll()
		check(not menu.web_browser.handoff and menu.web_video.pending == 0 and selected.is_empty(),
			"Video fullscreen never starts native resolution: " + str(index))
		check(menu.web_browser.active() and platform.browser.playing and not platform.commands.any(func(command): return command.action in ["pause_tab", "capture_video", "retain_page"]),
			"Fullscreen keeps web audio, document and UI active: " + str(index))
	platform.browser.fullscreen_video = false; poll()
	await create_timer(3.1).timeout; poll()
	check(platform.web_id == 0 and menu.web_video.result.is_empty(), "Ordinary playback no longer runs background extraction")
	fullscreen(20)
	var host: Node3D = menu.web_browser.windows[1]
	host.depth.config_path = "user://web_fullscreen_depth_%d.cfg" % OS.get_process_id()
	host.depth.enabled = false; host._activate(menu.web_browser.BASE + 16); poll()
	check(host.depth.enabled and menu.web_browser.active() and not menu.web_browser.handoff and platform.browser.fullscreen_video,
		"Fullscreen webpage conversion stays in the same browser window")
	host.depth.enabled = false
	DirAccess.remove_absolute(ProjectSettings.globalize_path(host.depth.config_path))
	platform.browser.url = "https://www.bilibili.com/video/BV1xx411c7mD/"
	platform.browser.bilibili_beta_available = true; platform.browser.videos[0].bilibili_ready = true; poll()
	menu.web_browser.action(menu.web_browser.BASE + 18)
	check(menu.web_browser.handoff and menu.web_browser.handoff_waiting_pause and menu.web_video.pending == 0,
		"Explicit Beta still pauses before resolving while the website is fullscreen")
	platform.browser.playing = false; platform.browser.videos[0].playing = false; poll()
	check(platform.beta_requests == 1 and menu.web_video.pending > 0, "Only the clicked Beta starts its native resolver")
	menu.web_browser._cancel_handoff(); platform.browser.bilibili_beta_available = false
	var main := ProbeMain.new(); var video := ReturnVideo.new()
	main.recent_menu = menu; main.video = video
	await manual_return_checks(main, video)
	await server_play_checks()
	video.free(); main.free(); menu.free(); platform.free(); await process_frame
	await format_checks()
	print("Web fullscreen remains in browser: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)

func server_play_checks() -> void:
	var origins := ["http://192.168.1.20:8096/web/index.html#!/videoosd", "http://192.168.1.20:8096/jellyfin/web/#/video",
		"http://192.168.1.20:32400/web/index.html#!/server/local/details?key=%2Flibrary%2Fmetadata%2F4"]
	menu.visible = true; menu.section = Menu.Section.WEB
	for index in origins.size():
		platform.browser.merge({"url": origins[index], "tab_id": 1, "navigation": 50 + index, "focused_window": 1,
			"fullscreen_video": true, "fullscreen_request": 90 + index, "active": true, "playing": true,
			"videos": [{"id": str(index + 1), "server_media": true, "server_play": true, "fullscreen": true,
				"playing": true, "time": 31.0, "width": 8192, "height": 4096}]}, true)
		menu.web_browser.open(); poll(); poll()
		check(not menu.web_browser.handoff and menu.web_video.pending == 0 and menu.web_browser.active() and platform.browser.playing,
			"Media-server play/fullscreen stays with its webpage: " + str(index))

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
		check(platform.commands[-2].action == "resume_retained_page" and returned.action == "resume_tab" and returned.tab == 3 and returned.window == 2,
			"Manual return rebinds the retained tab and releases its pause without reloading")
		check(returned.restore_paused == (exit_mode == "failure") and not returned.was_playing,
			"Manual return restores the original playing state only after native failure")
		check(menu.web_browser.playback_return.is_empty(), "Manual return is consumed exactly once")
		main._return_to_web_video(false, origin)
		check(main.restored == restores, "A late completion cannot reopen the returned browser")
	menu.web_browser.playback_return = {"native_uri": origin}
	menu.web_browser.playback_selected(origin)
	check(menu.web_browser.playback_return.is_empty(), "Opening the same URL outside the browser drops the old return context")

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
