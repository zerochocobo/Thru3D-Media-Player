extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_windows.gd")
const Focus := preload("res://scripts/web_browser_focus.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: run.call_deferred()
func ray(host: Node3D, uv: Vector2) -> Vector3:
	var page: Dictionary = host.page_layout()
	return page.pose * Vector3((uv.x - 0.5) * page.size.x, (0.5 - uv.y) * page.size.y, 0.5)
func run() -> void:
	var platform := Fixture.Platform.new()
	platform.browser.merge({"tab_id": 1, "loading": false, "start_page": false}, true)
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	var browser: RefCounted = menu.web_browser
	browser.open(); browser.tick()
	var host: Node3D = browser.windows[1]
	host._process(0)
	var size: Vector2 = host.page_size
	var direction: Vector3 = -host.page_layout().pose.basis.z
	var before: Array = platform.actions.duplicate()
	# The menu capture's mono cursor projection must not remap an independent XR page.
	var eye := Node3D.new(); root.add_child(eye)
	host.set_meta("menu_mono_pointer", {"eye": eye, "distance": 0.7})
	var wanted := Vector2(0.73, 0.22)
	var actual_page: Dictionary = host.page_layout()
	var actual_target: Vector3 = actual_page.pose * Vector3((wanted.x - 0.5) * actual_page.size.x, (0.5 - wanted.y) * actual_page.size.y, 0)
	var controller_origin: Vector3 = actual_page.pose * Vector3(0.35, -0.2, 0.8)
	check(not host._mono_pointer_projection().is_empty(), "Fixture carries the real mono toolbar projection")
	check(host.page_point(controller_origin, actual_target - controller_origin).distance_to(wanted) < 0.001,
		"Independent webpage uses the controller ray rather than the toolbar's mono capture ray")
	host.set_meta("menu_mono_pointer", {"eye": eye, "distance": 100.0})
	check(host.page_point(controller_origin, actual_target - controller_origin).distance_to(wanted) < 0.001,
		"The real distant toolbar cursor endpoint does not shift page coordinates")
	host.toggle_focus()
	var select_start := Vector2(0.2, 0.2)
	var select_end := Vector2(0.65, 0.65)
	var select_a: Vector3 = actual_page.pose * Vector3((select_start.x - 0.5) * actual_page.size.x, (0.5 - select_start.y) * actual_page.size.y, 0)
	var select_b: Vector3 = actual_page.pose * Vector3((select_end.x - 0.5) * actual_page.size.x, (0.5 - select_end.y) * actual_page.size.y, 0)
	host.press_pointer("left", controller_origin, select_a - controller_origin, true)
	host.update_pointer("left", controller_origin, select_b - controller_origin, true)
	host.release_pointer("left", controller_origin, select_b - controller_origin, true)
	check(host.focus_crop().is_equal_approx(Rect2(select_start, select_end - select_start)), "Actual off-axis trigger drag retains the rectangle drawn on the independent page")
	host.toggle_focus()
	host.remove_meta("menu_mono_pointer"); eye.free()
	for beta in [false, true]:
		platform.browser.bilibili_beta_available = beta
		browser.next_poll = 0; browser.tick(); host.refresh()
		host.effect_controls.sync(); host.effect_controls.visible = true
		var button: Dictionary = host.effect_controls._buttons.filter(func(item): return item.target == host.SELECT)[0]
		check(button.enabled, "Focus is available with both toolbar variants")
		for peer in host.effect_controls._buttons:
			if peer != button: check(not peer.rect.intersects(button.rect), "Focus control does not overlap another target")
	browser.action(host.SELECT)
	check(host.selecting and not host.is_focused(), "Focus enters selection without altering the page")
	var from := Vector2(0.75, 0.70)
	var to := Vector2(0.20, 0.15)
	host.press_pointer("left", ray(host, from), direction, true)
	host.update_pointer("left", ray(host, to), direction, true)
	host._process(0)
	check(host._feedback.get_node("selection4").visible, "Dragging renders a selection border")
	host.stick_scroll(1, 0.1)
	host.release_pointer("left", ray(host, to), direction, true)
	check(platform.pointers.is_empty(), "Selection and its stick motion never click or scroll the website")
	check(host.is_focused() and not host.selecting and host.focus_crop().is_equal_approx(Rect2(0.20, 0.15, 0.55, 0.55)), "Reverse-direction drag creates the expected crop")
	check(host.page_size == size and platform.actions == before, "Applying crop neither reflows the viewport nor navigates/reloads")
	host._process(0)
	var crop: Rect2 = host.focus_crop()
	var full: Dictionary = host.full_page_layout()
	var fitted: Dictionary = host.page_layout()
	check(fitted.size.x <= full.size.x and fitted.size.y <= full.size.y, "Crop fits within the window")
	var cursor := Vector2(0.35, 0.80)
	host.press_pointer("right", ray(host, cursor), direction, true)
	host.release_pointer("right", ray(host, cursor), direction, true)
	var event: Array = platform.pointers.back()
	check(event[0] == "up" and Vector2(event[1], event[2]).distance_to(Focus.map_point(cursor, crop)) < 0.001, "Real trigger routes through the crop back to source coordinates")
	host._process(0)
	check(host._feedback.get_node("press").visible, "Page press shows immediate local feedback")
	browser.scroll(1, 0.1)
	event = platform.pointers.back()
	check(event[0] == "scroll" and Vector2(event[1], event[2]).distance_to(Focus.map_point(cursor, crop)) < 0.001, "Scrolling targets the cropped website location")
	check(host.focus_crop() == crop, "Scrolling retains the fixed viewport crop")
	browser.focus_regions[1] = Rect2(0.2, 0.1, 0.2, 0.7); host.refresh(); host._process(0)
	var bar_ray: Vector3 = full.pose * Vector3(-full.size.x * 0.4, 0, 0.5)
	var bar_hit: Dictionary = host.local_hit(bar_ray, direction)
	check(not bar_hit.is_empty() and not bar_hit.get("enabled", true), "Letterbox bars block clicks through to peer windows")
	browser.cinema_provider = func(): return {"position": [0, 3, -12], "width": 10.0, "height": 5.625}
	host.set_mode("cinema"); host.refresh(); host._process(0)
	var cinema_ray := ray(host, Vector2(0.4, 0.6))
	check(host.page_point(cinema_ray, -host.page_layout().pose.basis.z).distance_to(Vector2(0.4, 0.6)) < 0.001, "Cinema focus preserves input coordinates on the distant screen")
	host.set_mode("floating"); browser.focus_regions[1] = crop; host.refresh(); host._process(0)
	browser.data.tab_id = 2; host.refresh()
	check(not host.is_focused(), "A different tab starts with the full page")
	browser.data.tab_id = 1; host.refresh()
	check(host.focus_crop() == crop, "Returning to a tab restores its region")
	browser.action(host.SELECT)
	check(not host.is_focused() and host.page_layout().size == full.size and platform.actions == before, "One click exits without navigation or scroll restoration")
	browser.action(host.SELECT)
	host.press_pointer("left", ray(host, Vector2(0.4, 0.4)), direction, true)
	host.release_pointer("left", ray(host, Vector2(0.401, 0.401)), direction, true)
	check(host.selecting and not host.is_focused(), "Accidental tiny selections do not magnify or click the page")
	host.toggle_focus()
	check(not host.selecting, "Selection can be cancelled in one click")
	host.toggle_focus(); browser.data.navigation = 2; host.sync_page_state()
	check(not host.selecting and host.drag.is_empty(), "Navigation cancels an in-flight selection")
	check(not Focus.valid(Rect2(NAN, 0, 0.2, 0.2)) and not Focus.valid(Rect2(0.9, 0, 0.5, 0.5)), "Invalid and out-of-bounds crops are rejected")
	for low in [true, false]:
		for dimensions in [Vector2(1.44, 0.9), Vector2(2.4, 0.65), Vector2(1.44, 1.8)]:
			var pixels := Vector2(host.Surface.pixels_for(dimensions, low))
			var area := Rect2(0.17, 0.21, 0.37, 0.63)
			var shown := Focus.fitted(dimensions, pixels, area)
			var extent: Vector2 = area.size * dimensions
			check(absf(shown.x / shown.y - extent.x / extent.y) < 0.001, "Focus preserves the selected visible aspect at both tiers and window shapes")
	browser.data.merge({"loading": true, "progress": 30}, true); host._process(0)
	check(host._progress.visible and is_equal_approx(host._progress_value, 0.3), "Real loading progress appears at the page edge")
	browser.data.merge({"loading": false, "progress": 100}, true); host._process(0)
	check(host._progress.visible and host._progress_value == 1, "Completion briefly fills the bar")
	host._progress_until = 0; host._process(0)
	check(not host._progress.visible, "Completed progress clears without rebuilding the chrome")
	browser.data.error = "page_load_failed"; host._process(0)
	check(host._progress.visible, "Failed load has a bounded error indicator")
	for state in [{}, {"url": ""}, {"url": "about:blank", "loading": true}, {"url": "about:blank", "start_page": false}, {"url": "about:blank", "error": "page_load_failed"}, {"url": "https://example.com", "loading": true}]:
		browser.data = state
		check(not browser.start_page.active(1), "Transient/missing/loading/error snapshots never show featured sites: " + str(state))
	browser.data = {"url": "about:blank", "tab_id": 7, "start_page": true}
	check(browser.start_page.active(1), "An intentional new tab still shows the start page")
	browser._navigate("https://example.com")
	check(not browser.start_page.active(1), "Start-page click hides cards before the native snapshot changes")
	menu.free(); platform.free(); await process_frame
	print("Browser focus and feedback: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
