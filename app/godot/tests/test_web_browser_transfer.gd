extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func poll(browser: RefCounted) -> void: browser.next_poll = 0; browser.tick()
func address(host: Node) -> String:
	var button: Node = host._buttons.filter(func(item): return item.target == host.browser.BASE + 3)[0].node
	return str(button.get_children().filter(func(item): return item is Label3D)[0].text)
func run() -> void:
	var platform := Fixture.Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	var browser: RefCounted = menu.web_browser
	var source := {"id": 1, "tab_id": 11, "navigation": 3, "url": "https://www.youtube.com/watch?v=jNQXAC9IVRw", "title": "Movie", "playing": true, "videos": [{"time": 42.5, "playing": true}]}
	var peer := {"id": 2, "tab_id": 22, "navigation": 5, "url": "https://example.com/notes", "title": "Notes", "playing": false}
	platform.browser.merge(source, true)
	platform.browser.merge({"focused_window": 1, "windows": [source, peer], "tab_list": [{"id": 11, "window": 1, "url": source.url}, {"id": 22, "window": 2, "url": peer.url}]}, true)
	browser.open(); poll(browser)
	var first: Node3D = browser.windows[1]; var second: Node3D = browser.windows[2]
	var peer_pose: Transform3D = second.global_transform
	var peer_address := address(second)
	var selected: Array = []
	menu.chosen.connect(func(uri, title): selected.append([uri, title]))
	browser.action(browser.BASE + 6); poll(browser)
	check(platform.web_id == 1 and browser.handoff, "Only one extraction starts for one window press")
	check(first._tips[browser.BASE + 6] == browser.I18n.t("Cancel"), "Only the source window offers transfer cancellation")
	check(second._tips[browser.BASE + 6] == browser.I18n.t("Play in player") and address(second) == peer_address, "Peer window keeps its ordinary action and address while extraction runs")
	check(not second._buttons.filter(func(item): return item.target == browser.BASE + 6)[0].enabled, "A peer cannot cancel or duplicate the in-flight transfer")
	platform.web_state = {"id": menu.web_video.pending, "state": "error", "error_code": "site_rejected"}
	menu.web_video.next_poll = 0; menu.web_video.tick(); poll(browser)
	check(not browser.handoff and browser.owns_handoff(first, browser.handoff_error) and not browser.owns_handoff(second, browser.handoff_error), "Extraction failure belongs only to its original document")
	check(address(second) == peer_address and selected.is_empty(), "A failed transfer never paints an error or starts playback in a peer")
	browser.action(browser.BASE + 6)
	platform.web_state = {"id": menu.web_video.pending, "state": "ready", "uri": source.url, "title": "Movie"}
	menu.web_video.next_poll = 0; menu.web_video.tick(); poll(browser)
	var command: Dictionary = platform.browser_commands.back()
	check(command.action == "pause_tab" and command.window == 1 and command.tab == 11 and command.navigation == 3, "Successful extraction pauses only its exact source tab and navigation")
	check(not platform.actions.has("pause") and selected.is_empty(), "No global pause is sent and playback waits for the source acknowledgement")
	platform.browser.windows[0].playing = false
	# The aggregate flag must not block acknowledgement of this paused source.
	platform.browser.playing = true
	poll(browser)
	check(selected.size() == 1 and menu.visible and browser.active(), "One source acknowledgement starts one player transfer while leaving peer browsing visible")
	check(menu.collections.selected_entry.get("keep_browser", false) and menu.collections.selected_entry.start_ms == 42500, "The native open receives the selected page progress and peer-preservation intent")
	check(second.visible and second.global_transform.is_equal_approx(peer_pose) and not platform.actions.has("hibernate"), "The peer remains at its original pose without session unloading")
	check(platform.web_id == 2, "The retry still performs one extraction per user action")
	menu.free(); platform.free(); await process_frame
	print("Browser transfer: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
