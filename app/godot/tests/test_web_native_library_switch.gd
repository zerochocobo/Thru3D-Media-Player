extends SceneTree
const Compact := preload("res://tests/test_compact_library.gd")
const BrowserFixture := preload("res://tests/test_web_browser_panel.gd")
const Main := preload("res://scripts/main.gd")

class Bridge extends BrowserFixture.Platform:
	var calls: Array = []
	var next_session := 0
	var cast_offer := {}
	var cast_active := 0
	var cast_events: Array = []
	var external_request := {}
	func mpv_supported() -> bool: return true
	func open_mpv_video(uri: String, start: int, _stereo: bool, _profile: String, _alpha: bool, _vulkan: bool, _depth: bool = false, _tb: bool = false, _exact: bool = false) -> int:
		next_session += 1; calls.append(["open", uri]); return next_session
	func close_mpv_video(id: int) -> void: calls.append(["close", id])
	func set_mpv_playing(_id: int, _playing: bool) -> void: pass
	func dlna_receiver_enable(enabled: bool) -> bool: return enabled
	func dlna_receiver_accept(id: int) -> String:
		if id != int(cast_offer.get("token", 0)): return "{}"
		cast_active = id; var accepted := cast_offer.duplicate(); cast_offer = {}; return JSON.stringify(accepted)
	func dlna_receiver_detach() -> void: cast_active = 0
	func dlna_receiver_poll() -> String:
		var events := cast_events.duplicate(); cast_events.clear()
		return JSON.stringify({"running":true,"active_token":cast_active,"events":events})
	func dlna_receiver_publish(_value: String) -> void: pass
	func external_playback_poll() -> String:
		var value := external_request.duplicate(); external_request.clear(); return JSON.stringify(value)

var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: run.call_deferred()
func poll(browser: RefCounted) -> void:
	browser.next_poll = 0; browser.tick()
func handoff(main: Node3D, bridge: Bridge) -> void:
	var library: Node3D = main.recent_menu
	main._show_full_library(); library._activate(library.NAV_BASE + library.Section.WEB)
	var browser: RefCounted = library.web_browser
	bridge.browser = {"url":"https://www.bilibili.com/video/BVfixture/", "tab_id":11,"navigation":3,"focused_window":1,
		"active":true,"playing":true,"bilibili_beta_available":true,"pause_confirmed":true,
		"videos":[{"selection":"main","bilibili_ready":true,"playing":true,"time":26.0}]}
	browser.open(); poll(browser); browser._begin_handoff(true, "main")
	bridge.browser.playing = false; bridge.browser.videos[0].playing = false; poll(browser)
	bridge.web_state = {"id":library.web_video.pending,"state":"ready","uri":"webvideo://capture/fixture","title":"Browser video"}
	library.web_video.next_poll = 0; library.web_video.tick(); poll(browser)
	check(main.video.local_uri == "webvideo://capture/fixture" and browser.playback_return.get("retained", false), "A real browser Beta handoff opens in Main and retains its live document")
	main.video.media.state = "playing"; main.video.media.frame_counter = 1; main.video._waiting_first = false
func choose_file(main: Node3D, uri: String) -> void:
	var library: Node3D = main.recent_menu
	main._show_recent_menu()
	await process_frame
	check(library.visible and library.get_parent() == main.player_menu, "The current movie opens the attached resource library")
	var alive: bool = library.web_browser.windows.values().all(func(window):
		return is_instance_valid(window) and not window.is_queued_for_deletion() and is_instance_valid(window.surface) and not window.surface.is_queued_for_deletion())
	check(alive, "Reparenting the library preserves independent browser windows and Surfaces across frames")
	library.section = library.Section.LOCAL; library._local_stack = [{"id":"/disk","title":"Disk"}]
	library._local_entries = [{"uri":uri,"title":uri.get_file()}]; library.refresh()
	var tile: Dictionary = library._buttons.filter(func(button): return button.target == library.ROW_BASE)[0]
	var origin: Vector3 = tile.node.global_position + tile.node.global_basis.z * 0.3
	var direction: Vector3 = -tile.node.global_basis.z
	check(library.press_pointer("right_hand", origin, direction, true), "The real resource row captures a ray press")
	library.release_pointer("right_hand", origin, direction, true)
	var deadline := Time.get_ticks_msec() + 3000
	while main.photo_active and main.photo.loading and Time.get_ticks_msec() < deadline:
		main.photo._process(0.016)
		await process_frame
	check(main._viewer().local_uri == uri, "Releasing the resource row replaces the media: %s -> %s" % [uri, main._viewer().local_uri])
func run() -> void:
	var main := Compact.Harness.new(); root.add_child(main)
	var bridge := Bridge.new()
	var video := Main.Video.new(); main.add_child(video); video.set_process(false); main.video = video; video.platform = bridge
	video.history_enabled = false
	var photo := Main.PhotoDisplay.new(); main.add_child(photo); photo.set_process(false); main.photo = photo
	var player := Main.PlayerMenu.new(); main.add_child(player); player.set_process(false)
	main.video_menu = player; main.player_menu = player; player.state_provider = main._menu_state
	var photo_menu := Compact.PhotoMenu.new(); main.add_child(photo_menu); photo_menu.set_process(false); main.photo_menu = photo_menu
	photo_menu.state_provider = photo.snapshot
	var library := Main.LibraryMenu.new(); main.add_child(library); library.set_process(false); main.recent_menu = library
	library.catalog = video.recent_files; library.current_file_provider = func(): return main._viewer().local_uri
	library.attach_platform(bridge); library.chosen.connect(main._on_library_chosen)
	main.cast_session.bind(main, bridge)
	for control in [player, photo_menu, library]: control.layout_head_provider = main._head_pose
	player.expanded_library = library; photo_menu.expanded_library = library
	var browser: RefCounted = library.web_browser
	handoff(main, bridge); await process_frame
	await choose_file(main, "file:///disk/next.mp4")
	check(browser.playback_return.is_empty(), "The new file does not retain a stale webpage return")
	check(bridge.browser_commands.any(func(command): return command.action == "release_retained_page"), "Replacement releases the original page's pause lease")
	check(bridge.calls.filter(func(call): return call[0] == "open").size() == 2, "Exactly one decoder open per selected source")
	for origin in ["dlna", "external"]:
		handoff(main, bridge); await process_frame
		var commands: int = bridge.browser_commands.size()
		if origin == "dlna":
			main.cast_session.enabled = true
			bridge.cast_offer = {"token":21,"uri":"http://sender.test/movie.mp4","title":"DLNA video"}
			main.cast_session.pending = {"token":21}; main.cast_session.accept()
			check(video.cast_token == 21 and video.local_uri == "http://sender.test/movie.mp4", "DLNA accepts through the production cast session")
		else:
			bridge.external_request = {"uri":"externalvideo://fixture/video","title":"External video","temporary":true}
			main._external_video_poll_ms = 0; main._poll_external_video()
			check(video.local_uri == "externalvideo://fixture/video", "External delivery uses the production poll and source switch")
		check(browser.playback_return.is_empty() and bridge.browser_commands.slice(commands).any(func(command): return command.action == "release_retained_page"),
			origin + ": source replacement releases the retained webpage lease")
		check(bridge.actions.back() == "hibernate", origin + ": browser teardown is queued before decoder startup")
		video.media.state = "playing"; video.media.frame_counter = 1; video._waiting_first = false
		await choose_file(main, "file:///disk/after-%s.mp4" % origin)
		check(main.cast_session.token == 0 and video.cast_token == 0 and bridge.cast_active == 0, origin + ": resource selection detaches sender ownership")
		bridge.cast_events.append({"action":"stop","token":21}); main.cast_session._next_poll = 0; main.cast_session.tick()
		main._return_to_web_video(true, "webvideo://capture/fixture")
		check(video.local_uri == "file:///disk/after-%s.mp4" % origin, origin + ": stale sender stop and webpage failure cannot close the new file")
	handoff(main, bridge); await process_frame
	var image_path := ProjectSettings.globalize_path("res://../../build/output/source-switch/next.png")
	var image := Image.create(32, 16, false, Image.FORMAT_RGB8); image.fill(Color.WHITE); image.save_png(image_path)
	await choose_file(main, "file://" + image_path)
	check(main.photo_active and video.media.state == "closed" and browser.playback_return.is_empty(), "A photo selection also closes browser playback and clears its return ownership")
	main.queue_free(); await process_frame; await process_frame
	check(browser.windows.is_empty(), "Destroying the actual library owner releases its independent windows")
	bridge.free(); await process_frame
	print("Browser native/library source switch: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
