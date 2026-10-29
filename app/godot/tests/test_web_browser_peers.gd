extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_windows.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func snapshot(platform: Object, browser: RefCounted, entries: Array, selected: Dictionary, focus: int) -> void:
	platform.browser.tab_list = entries
	platform.browser.windows = []
	for id in range(1, 5):
		var tab: int = selected.get(id, 0)
		platform.browser.windows.append({"id": id, "tab_id": tab, "url": "https://example.com/" + str(tab), "title": "Page " + str(tab)})
	platform.browser.focused_window = focus
	platform.browser.tab_id = selected.get(focus, 0)
	platform.browser.active = not selected.is_empty()
	browser.next_poll = 0; browser.tick()
func entry(id: int, window: int) -> Dictionary:
	return {"id": id, "window": window, "title": "Page " + str(id), "url": "https://example.com/" + str(id)}
func run() -> void:
	var platform := Fixture.Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	var browser: RefCounted = menu.web_browser
	platform.browser.windows = []; platform.browser.active = false; platform.browser.max_windows = 4
	browser.open(); browser.tick()
	check(browser.opened and browser.input_host() != menu, "Opening retains a browser input router before native resume finishes")
	var entries: Array = []; var selected := {}; var poses := {}
	for id in range(1, 5):
		entries.append(entry(10 + id, id)); selected[id] = 10 + id
		snapshot(platform, browser, entries, selected, id)
		check(browser.live_window_ids().size() == id, "Status supports %d visible peer windows" % id)
		for previous in poses: check(browser.windows[previous].global_transform.is_equal_approx(poses[previous]), "Adding a peer preserves every survivor's placement")
		poses[id] = browser.windows[id].global_transform
	browser.tabs_open = true; browser.refresh_windows()
	var fourth: Node3D = browser.windows[4]
	check(not fourth._buttons.filter(func(button): return button.target == browser.BASE + 17)[0].enabled, "Four windows disable creating a fifth")
	browser.cinema_provider = func(): return {"position": [0, 3, -12], "width": 10.0, "height": 5.625}
	browser.windows[3].set_mode("cinema"); poses[3] = browser.windows[3].global_transform
	browser.focus_window(1); browser.action(browser.BASE + 5)
	check(platform.commands.back().action == "close_window" and platform.commands.back().window == 1, "First window close uses the same explicit close operation as every peer")
	entries = [entry(12, 2), entry(13, 3), entry(14, 4)]
	snapshot(platform, browser, entries, {2: 12, 3: 13, 4: 14}, 2)
	check(browser.opened and not browser.windows[1].visible and browser.input_host().window_id == 2, "Closing window one leaves the browser open with a surviving input router")
	for id in [2, 3, 4]: check(browser.windows[id].global_transform.is_equal_approx(poses[id]), "Closing another window preserves survivor %d placement" % id)
	check(browser.windows[3].on_screen(), "Closing a floating peer retains the cinema page")
	var page: Dictionary = fourth.page_layout()
	var origin: Vector3 = page.pose.origin + page.pose.basis.z * 0.2
	var router: Node3D = browser.input_host()
	check(router.press_pointer("left", origin, -page.pose.basis.z, true), "A router other than window one can target window four")
	check(platform.pointers.back()[4] == 4 and browser.focused_window == 4, "Page input reaches the fourth window")
	router.release_pointer("left", origin, -page.pose.basis.z, true)
	browser.action(browser.BASE + 16)
	check(browser.window_action.get("command") == "merge_window", "Window merge is a separate menu operation")
	for id in [2, 3]: check(fourth._buttons.any(func(button): return button.target == browser.WINDOW_TARGET + id), "Merge picker includes peer %d" % id)
	check(not fourth._buttons.any(func(button): return button.target == browser.WINDOW_TARGET + 4 or button.target == browser.WINDOW_TARGET + 1), "Merge picker excludes self and closed windows")
	browser.action(browser.WINDOW_TARGET + 2)
	check(platform.commands.back().action == "merge_window" and platform.commands.back().destination == 2, "Merge sends the chosen stable destination")
	snapshot(platform, browser, [entry(12, 2), entry(14, 2), entry(13, 3)], {2: 12, 3: 13}, 2)
	check(not fourth.visible and browser.windows[2].global_transform.is_equal_approx(poses[2]) and browser.window_state(2).tab_id == 12, "Merge removes source without changing target pose or selected page")
	check(browser.windows[3].on_screen() and browser.windows[3].global_transform.is_equal_approx(poses[3]), "Merge leaves unrelated cinema controls in place")
	browser.action(browser.BASE + 210)
	check(not browser.window_action.is_empty(), "Tab destination picker is open before a native focus change")
	snapshot(platform, browser, [entry(12, 2), entry(14, 2), entry(13, 3)], {2: 12, 3: 13}, 3)
	check(browser.window_action.is_empty() and not browser.tabs_open, "Native focus changes dismiss a stale source picker before another window can be merged")
	check(not browser.windows[2]._buttons.any(func(button): return button.target >= browser.WINDOW_TARGET and button.target <= browser.WINDOW_TARGET + 4), "Dismissal redraws even if the focused pages share the same chrome fields")
	browser.focus_window(2); platform.browser.focused_window = 2
	platform.browser.max_windows = 2; browser.next_poll = 0; browser.tick()
	browser.tabs_open = true; browser.refresh_windows()
	check(not browser.windows[2]._buttons.filter(func(button): return button.target == browser.BASE + 17)[0].enabled, "Low device tier keeps a two-window ceiling")
	browser.focus_window(3); browser.action(browser.BASE + 220)
	check(platform.commands.back().action == "close" and platform.commands.back().tab == 13, "Tab close remains distinct from window merge")
	snapshot(platform, browser, [entry(12, 2), entry(14, 2)], {2: 12}, 2)
	check(not browser.windows[3].visible and browser.windows[2].global_transform.is_equal_approx(poses[2]), "Closing the last tab hides only its window")
	browser.action(browser.BASE + 5)
	snapshot(platform, browser, [], {}, 1)
	check(not browser.opened and browser.windows.values().all(func(item): return not item.visible), "Closing the last window returns to the browser library without a blank replacement")
	browser.open()
	snapshot(platform, browser, [entry(21, 1)], {1: 21}, 1)
	check(browser.live_window_ids() == [1] and browser.windows.values().filter(func(item): return item.visible).size() == 1, "Reopening after explicit closes shows only the new session")
	snapshot(platform, browser, [entry(21, 1), entry(23, 3)], {1: 21, 3: 23}, 3)
	var saved_pose: Transform3D = browser.windows[3].global_transform
	browser.close()
	check(platform.actions.back() == "hibernate", "Leaving the library still hibernates unclosed sessions")
	browser.open(); browser.tick()
	check(browser.live_window_ids() == [1, 3] and browser.windows[3].global_transform.is_equal_approx(saved_pose), "Resume restores unclosed peers without moving them")
	menu.free(); platform.free(); await process_frame
	print("Browser peers: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
