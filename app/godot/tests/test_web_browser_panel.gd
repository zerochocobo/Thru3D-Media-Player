extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_video_panel.gd")
const Browser := preload("res://scripts/web_browser_panel.gd")
class Platform extends Fixture.Platform:
	var browser := {"url": "https://www.youtube.com/watch?v=jNQXAC9IVRw", "title": "Video", "progress": 100, "back": true, "videos": [{"width": 1920, "height": 1080, "time": 42.5, "playing": true}], "active": true, "playing": true, "native_supported": true}
	var actions: Array = []
	var pointers: Array = []
	var inputs: Array = []
	var library := {"bookmarks": [], "history": []}
	var library_commands: Array = []
	var browser_commands: Array = []
	var beta_requests := 0
	func web_video_resolve_beta(url: String) -> int:
		beta_requests += 1
		return web_video_resolve(url)
	func web_browser_command(value: String) -> void:
		var command: Dictionary = JSON.parse_string(value); browser_commands.append(command)
		if command.action == "network_capture": browser.network_capture_enabled = bool(command.enabled)
		if command.action == "pause_tab": browser.pause_token = command.pause_token
	func web_browser_library_edit(request: String) -> int:
		library_commands.append(JSON.parse_string(request)); return library_commands.size()
	func web_browser_input(action: String, text: String) -> void: inputs.append([action, text])
	func web_browser_status() -> String: return JSON.stringify(browser)
	func web_browser_navigate(url: String) -> void: browser.url = url
	func web_browser_action(action: String) -> void: actions.append(action)
	func web_browser_pointer(action: String, x: float, y: float, scroll: float) -> void: pointers.append([action, x, y, scroll])
	func web_browser_library() -> String: return JSON.stringify(library)
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var platform := Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	check(menu.rows.any(func(row): return row.get("web_browser") == "open"), "Browser appears when platform supports it")
	menu.web_browser.open("https://www.youtube.com/watch?v=jNQXAC9IVRw")
	menu.web_browser.tick()
	check(menu.web_browser.active(), "Browser is active inside web section")
	check(not menu.web_browser.input_host()._buttons.any(func(button): return button.target == Browser.BASE + 18), "Beta is hidden on unadapted sites")
	platform.browser.bilibili_beta_available = true
	platform.browser.videos[0].bilibili_ready = true
	menu.web_browser.next_poll = 0; menu.web_browser.tick(); menu.refresh()
	var beta_buttons: Array = menu.web_browser.input_host()._buttons.filter(func(button): return button.target in [Browser.BASE + 6, Browser.BASE + 18])
	check(beta_buttons.size() == 2 and not beta_buttons[0].rect.intersects(beta_buttons[1].rect), "Legacy and Beta have separate non-overlapping targets")
	menu.web_browser.prefetch_uri = platform.browser.url
	menu.web_browser.prefetch_result = {"state": "ready", "uri": platform.browser.url}
	menu.web_browser.prefetch_ms = Time.get_ticks_msec()
	menu.web_browser.action(Browser.BASE + 18)
	check(platform.beta_requests == 0 and menu.web_browser.handoff_waiting_pause and menu.web_video.pending == 0,
		"Beta pauses the webpage before starting resolution")
	platform.browser.playing = false; platform.browser.videos[0].playing = false
	menu.web_browser.next_poll = 0; menu.web_browser.tick()
	check(platform.beta_requests == 1 and menu.web_browser.handoff_beta and menu.web_video.pending > 0, "Beta starts its own resolver instead of reusing a ready legacy prefetch")
	var beta_pending := menu.web_video.pending
	menu.web_browser.action(Browser.BASE + 6)
	check(menu.web_video.pending == beta_pending, "Disabled legacy target cannot cancel Beta")
	menu.web_browser.action(Browser.BASE + 18)
	check(not menu.web_browser.handoff and menu.web_video.pending == 0, "Beta button cancels its own pending request")
	menu.web_browser.action(Browser.BASE + 6)
	check(platform.beta_requests == 1 and not menu.web_browser.handoff_beta and menu.web_video.pending > 0, "Legacy button still starts only its original resolver")
	menu.web_browser.action(Browser.BASE + 6)
	platform.browser.bilibili_beta_available = false
	menu.web_browser.next_poll = 0; menu.web_browser.tick(); menu.refresh()
	menu.web_browser.action(Browser.BASE + 18)
	check(platform.beta_requests == 1, "A stale Beta target cannot resolve an unavailable site")
	platform.browser.playing = true; platform.browser.videos[0].playing = true
	platform.browser.network_capture_available = false; platform.browser.network_capture_enabled = false
	menu.web_browser.next_poll = 0; menu.web_browser.tick()
	check(not menu.web_browser.input_host()._buttons.any(func(button): return button.target == Browser.BASE + 15), "Marked native sites hide the toolbar detection entry")
	menu.web_browser.tabs_open = true; menu.refresh()
	check(not menu.web_browser.input_host()._buttons.any(func(button): return button.target == Browser.BASE + 15), "Marked native sites also hide the tab-menu detection entry")
	var commands_before := platform.browser_commands.size()
	menu.web_browser.action(Browser.BASE + 15)
	check(platform.browser_commands.size() == commands_before, "A stale hidden detection target cannot change the site preference")
	menu.web_browser.tabs_open = false; menu.refresh()
	platform.browser.network_capture_available = true; platform.browser.network_capture_enabled = false
	menu.web_browser.next_poll = 0; menu.web_browser.tick()
	check(menu.web_browser.input_host()._buttons.any(func(button): return button.target == Browser.BASE + 15 and button.enabled), "This site's media detection has a ray-selectable toggle")
	menu.web_browser.tabs_open = true; menu.refresh()
	check(menu.web_browser.input_host()._buttons.any(func(button): return button.target == Browser.BASE + 15), "Unmarked sites show the tab-menu detection entry even when manually off")
	menu.web_browser.tabs_open = false; menu.refresh()
	menu.web_browser.action(Browser.BASE + 15); menu.web_browser.next_poll = 0; menu.web_browser.tick()
	var capture_command: Dictionary = platform.browser_commands.back()
	check(capture_command.action == "network_capture" and int(capture_command.window) == 1 and capture_command.enabled == true, "The toggle enables only the current window's site")
	check(menu.web_browser.data.network_capture_enabled, "The UI reflects the confirmed native preference")
	menu.web_browser.action(Browser.BASE + 15); menu.web_browser.next_poll = 0; menu.web_browser.tick()
	check(not menu.web_browser.data.network_capture_enabled, "A second press switches detection off")
	platform.browser.editing = true; menu.web_browser.next_poll = 0; menu.web_browser.tick()
	check(not menu.web_browser.input_host()._buttons.any(func(button): return button.target == Browser.KEY), "System input does not draw a second ray keyboard")
	check(not menu.web_browser.action(Browser.KEY), "Old ray keys cannot commit into a system editor")
	menu._activate(Browser.KEY_CONTROL + 7)
	check(platform.inputs.back() == ["close", ""], "Keyboard close does not mirror web field content")
	platform.browser.editing = false; menu.web_browser.next_poll = 0; menu.web_browser.tick()
	check(not menu.web_browser.action(Browser.KEY), "Unfocused page cannot receive stale ray key input")
	check(menu.web_browser.input_host()._buttons.any(func(button): return button.target == Browser.WEB), "Browser body participates in ray hit testing")
	check(menu.web_browser.uv(Vector3(Browser.RECT.position.x, Browser.RECT.end.y, 0)).is_equal_approx(Vector2.ZERO), "Top-left ray maps to top-left pixels")
	check(menu.web_browser.uv(Vector3(Browser.RECT.end.x, Browser.RECT.position.y, 0)).is_equal_approx(Vector2.ONE), "Bottom-right ray maps to bottom-right pixels")
	var center := Browser.RECT.get_center()
	var host: Node3D = menu.web_browser.input_host()
	var ray := host.to_global(Vector3(center.x, center.y, 1))
	var direction := -host.global_basis.z
	check(menu.press_pointer("left", ray, direction, true), "Trigger captures web page")
	check(menu.has_pointer_capture() and platform.pointers.back()[0] == "down", "Native receives pointer down")
	menu.stick_scroll(1, 0.1)
	check(platform.pointers.back()[0] == "down", "Stick cannot scroll during pointer capture")
	menu.release_pointer("left", ray, direction, true)
	check(not menu.has_pointer_capture() and platform.pointers.back()[0] == "up", "Pointer release reaches native")
	menu.stick_scroll(1, 0.1)
	check(platform.pointers.back()[0] == "scroll", "Stick scrolls the page after release")
	menu.web_browser.action(Browser.BASE + 6)
	check(menu.web_browser.handoff and menu.web_video.pending > 0, "Play in player resolves asynchronously")
	platform.browser.url = "https://www.youtube.com/"
	menu.web_browser.next_poll = 0; menu.web_browser.tick()
	check(not menu.web_browser.handoff and menu.web_video.pending == 0, "Navigation cancels a pending handoff")
	menu.web_browser.data.url = "https://www.youtube.com/watch?v=jNQXAC9IVRw"
	platform.browser.url = menu.web_browser.data.url
	menu.web_browser.action(Browser.BASE + 6)
	var chosen: Array = []
	menu.chosen.connect(func(uri, title): chosen.append([uri, title]))
	platform.web_state = {"id": menu.web_video.pending, "state": "ready", "uri": platform.browser.url, "title": "Video", "height": 1080}
	menu.web_video.next_poll = 0; menu.web_video.tick()
	menu.web_browser.next_poll = 0; menu.web_browser.tick()
	check(chosen.is_empty() and platform.browser_commands.back().action == "pause_tab", "Resolved video waits for its source tab to pause")
	platform.browser.active = false
	menu.web_browser.next_poll = 0; menu.web_browser.tick()
	check(chosen.is_empty(), "Inactive browser alone is not proof that audio stopped")
	platform.browser.playing = false
	menu.web_browser.next_poll = 0; menu.web_browser.tick()
	check(chosen.size() == 1 and not menu.visible, "Native handoff follows the web pause acknowledgement")
	check(menu.collections.selected_entry.get("start_ms") == 42500, "Native handoff retains the browser video position")
	menu.toggle(); menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	menu.web_browser.open(platform.browser.url); menu.web_browser.next_poll = 0; menu.web_browser.tick()
	platform.browser.windows = [{"id": 1, "tab_id": 1, "url": platform.browser.url, "title": "Video", "progress": 100,
		"videos": [{"id": "1", "playing": true, "time": 10.0}]}]
	menu.web_browser.next_poll = 0; menu.web_browser.tick()
	var drawn: String = menu.web_browser._signature
	platform.browser.windows[0].videos[0].time = 10.25
	menu.web_browser.next_poll = 0; menu.web_browser.tick()
	check(menu.web_browser._signature == drawn, "Advancing web playback time does not redraw the browser chrome")
	platform.browser.windows[0].title = "Next"
	menu.web_browser.next_poll = 0; menu.web_browser.tick()
	check(menu.web_browser._signature != drawn, "A visible title change still redraws the chrome")
	menu.web_browser.action(Browser.BASE + 6)
	menu._activate(Menu.NAV_BASE + Menu.Section.RECENT)
	check(not menu.web_browser.opened and menu.web_video.pending == 0, "Leaving browser cancels extraction and hides browser")
	check(platform.actions.back() == "hibernate", "Leaving browser unloads page sessions")
	menu.free(); platform.free()
	print("Web browser panel: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
