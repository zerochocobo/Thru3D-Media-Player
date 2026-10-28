extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")
class Platform extends Fixture.Platform:
	var commands: Array = []
	func web_browser_command(value: String) -> void: commands.append(JSON.parse_string(value))
	func web_browser_window_pointer(id: int, action: String, x: float, y: float, scroll: float) -> void: pointers.append([action, x, y, scroll, id])
var failures: Array[String] = []
var checks := 0
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var platform := Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	var browser: RefCounted = menu.web_browser
	browser.open("https://example.com/a"); browser.tick()
	var primary: Node3D = browser.windows[1]
	check(primary.get_parent() == root, "Window is outside the library transform tree")
	var pose: Transform3D = primary.global_transform
	menu.position += Vector3(3, 1, 2)
	check(primary.global_transform == pose, "Moving library does not move browser")
	check(not menu._backdrop.visible and not menu._side.visible, "Browser replaces library chrome")
	menu.session_controls_provider = func(): return {"cinema_visible": true, "passthrough_visible": true}
	menu.refresh_session_controls(true); menu.refresh_music_quick_controls()
	check(menu._buttons.is_empty() and not menu.device_status.visible, "Periodic library refresh cannot recreate controls behind browser")
	var old_point: Vector3 = primary.page_layout().pose.origin
	primary.adjust_distance(0.5)
	check(primary.page_layout().pose.origin.distance_to(old_point) > 0.49, "Distance changes independent window pose")
	primary.adjust_size(100)
	check(is_equal_approx(primary.global_basis.get_scale().x, 2.5), "Size has an upper bound")
	primary.adjust_size(-100)
	check(is_equal_approx(primary.global_basis.get_scale().x, 0.6), "Size has a lower bound")
	primary.recenter(); primary._process(0)
	for corner in [primary.RESIZE_LEFT, primary.RESIZE]:
		var button: Dictionary = primary._buttons.filter(func(item): return item.target == corner)[0]
		var old_pose: Transform3D = primary.global_transform
		var centre: Vector3 = old_pose * primary.CENTRE
		var local := Vector3(button.rect.get_center().x, button.rect.get_center().y, 0)
		var ray_start: Vector3 = old_pose * (local + Vector3(0, 0, 0.3))
		check(primary.press_pointer("left", ray_start, -old_pose.basis.z, true), "Lower corner starts resize " + str(corner))
		var enlarged: Vector3 = primary.CENTRE + (local - primary.CENTRE) * 1.3
		primary.update_pointer("left", old_pose * (enlarged + Vector3(0, 0, 0.3)), -old_pose.basis.z, true)
		check(is_equal_approx(primary.global_basis.get_scale().x, old_pose.basis.get_scale().x * 1.3), "Both borders resize through the real ray path")
		check((primary.global_transform * primary.CENTRE).distance_to(centre) < 0.001, "Corner resize preserves panel centre")
		primary.release_pointer("left", ray_start, -old_pose.basis.z, true)
		check(primary.drag.is_empty(), "Release ends corner capture")
		primary.recenter(); primary._process(0)
	check(not primary._buttons.any(func(button): return button.target >= browser.BASE + 9 and button.target <= browser.BASE + 13), "No redundant bottom controls return")
	for target in [browser.BASE + 2, browser.BASE + 4, browser.BASE + 8]:
		check(primary._buttons.any(func(button): return button.target == target), "Refresh, bookmark and cinema are exposed without a menu")
	var close: Dictionary = primary._buttons.filter(func(button): return button.target == browser.BASE + 5)[0]
	var address: Dictionary = primary._buttons.filter(func(button): return button.target == browser.BASE + 3)[0]
	check(close.rect.get_center().y > address.rect.end.y and address.rect.size.x < 0.65, "Close occupies the narrow title row above a shorter URL field")
	verify_title_drag(primary, primary)
	var layout: Dictionary = primary.page_layout()
	var start: Vector3 = layout.pose * Vector3(-layout.size.x * 0.49, layout.size.y * 0.49, 0.2)
	var uv: Vector2 = primary.page_point(start, -layout.pose.basis.z)
	check(not primary.grab_hit(start, -layout.pose.basis.z).is_empty(), "Grip can grab the webpage body")
	var move := preload("res://scripts/interface_move.gd").new()
	var controller_pose := Transform3D(Basis.IDENTITY, primary.head().origin)
	move.begin("left", "grip", controller_pose, [{"node": primary, "kind": "detail", "key": "browser", "pose": primary.global_transform, "upright_facing": true, "face_center": primary.CENTRE}], start, primary.head())
	controller_pose.basis = Basis(Vector3.UP, 0.2) * Basis(Vector3.RIGHT, 0.15)
	move.update(controller_pose, primary.head(), null)
	var facing: Vector3 = primary.head().origin - primary.to_global(primary.CENTRE)
	check(primary.global_basis.z.normalized().dot(facing.normalized()) > 0.9999 and absf(primary.global_basis.x.y) < 0.001, "Off-centre grip faces whole window towards viewer without roll")
	move.cancel(); primary.recenter(); primary._process(0)
	check(uv.distance_to(Vector2(0.01, 0.01)) < 0.001, "Transformed corner maps to correct page pixel")
	var pose_before_cinema: Transform3D = primary.global_transform
	browser.cinema_provider = func(): return {"position": [0, 3, -12], "width": 10.0, "height": 5.625, "yaw": 0.0}
	browser.action(browser.BASE + 8)
	check(primary.on_screen(), "Cinema mode uses existing screen anchor")
	check(primary._backdrop.material_override.render_priority > 25 and primary._buttons.filter(func(button): return button.target != browser.WEB).all(func(button): return button.node.material_override.render_priority > 25), "Near cinema controls render after the distant page alpha hole")
	layout = primary.page_layout()
	check(is_equal_approx(layout.size.x / layout.size.y, 1.6), "Cinema fit preserves webpage aspect")
	check(layout.size.x <= 10 and layout.size.y <= 5.625, "Page stays inside cinema screen")
	check(layout.pose.origin.z < -11, "Page is on distant screen")
	var tools: Vector3 = primary.to_global(Vector3(0.13, 0.505, 0))
	var eye: Vector3 = primary.head().origin
	check(tools.distance_to(eye) < 2.0 and tools.y < eye.y and absf(tools.x - eye.x) < 0.001,
		"Cinema tools float near and below the viewer like the cinema playback bar, not on the far screen")
	check(primary._buttons.filter(func(button): return button.target != browser.WEB).all(func(button): return button.node.material_override.render_priority < 30) and primary._backdrop.material_override.render_priority < 30,
		"Cinema controls stay below the popup priority so they keep their sharp bar capture")
	var moved_bar: Transform3D = primary.global_transform.translated(Vector3(0.3, 0.2, 0))
	primary.global_transform = moved_bar; primary._process(0)
	check(primary.global_transform.is_equal_approx(moved_bar), "A dragged cinema bar stays where it was put")
	var far: Dictionary = primary.page_layout()
	check(primary._local_grab_hit(far.pose.origin + far.pose.basis.z * 2.0, -far.pose.basis.z).is_empty(), "Gripping the far page does not move the cinema controls")
	start = layout.pose * Vector3(layout.size.x * 0.25, 0, 0.2)
	uv = primary.page_point(start, -layout.pose.basis.z)
	check(uv.distance_to(Vector2(0.75, 0.5)) < 0.001, "Cinema ray shares compositor geometry")
	check(not platform.actions.has("reload"), "Changing display mode does not reload page")
	browser.action(browser.BASE + 8)
	check(primary.global_transform.is_equal_approx(pose_before_cinema), "Leaving cinema restores the floating pose")
	platform.browser.windows = [{"id": 1, "tab_id": 1, "url": "https://example.com/a", "title": "First"}, {"id": 2, "tab_id": 3, "url": "https://example.com/b", "title": "Second"}]
	platform.browser.tab_list = [{"id": 1, "window": 1, "url": "https://example.com/a", "title": "First"}, {"id": 7, "window": 1, "url": "https://example.com/c", "title": "Dormant", "sleeping": true}, {"id": 3, "window": 2, "url": "https://example.com/b", "title": "Second"}]
	platform.browser.focused_window = 1; platform.browser.tab_id = 1
	browser.next_poll = 0; browser.tick()
	check(browser.windows.size() == 2 and browser.windows[2].visible, "Detached tabs show a second window")
	var secondary: Node3D = browser.windows[2]
	var first_centre := primary.to_global(Vector3(0.13, 0, 0))
	var second_centre := secondary.to_global(Vector3(0.13, 0, 0))
	check(first_centre.x < 0 and second_centre.x > 0 and absf(first_centre.x + second_centre.x) < 0.001, "Default pair is symmetric around the viewer")
	check(is_equal_approx(first_centre.z, second_centre.z) and first_centre.distance_to(second_centre) > 1.5, "Default pair shares depth without overlapping")
	primary.adjust_distance(0.3)
	var adjusted: Transform3D = primary.global_transform
	browser.next_poll = 0; browser.tick()
	check(primary.global_transform.is_equal_approx(adjusted), "Status polling preserves manually adjusted pair placement")
	secondary.global_transform = Transform3D(Basis.IDENTITY, Vector3(3, 1.6, -2)); secondary._process(0)
	layout = secondary.page_layout(); start = layout.pose * Vector3(0, 0, 0.2)
	check(primary.press_pointer("left", start, -layout.pose.basis.z, true), "Input router can target second window")
	check(browser.focused_window == 2 and platform.commands.back().action == "focus" and int(platform.commands.back().window) == 2, "Cross-window click switches focus")
	check(platform.pointers.back()[4] == 2, "Pointer is tagged with owning window")
	primary.release_pointer("left", start, -layout.pose.basis.z, true)
	check(platform.pointers.back()[0] == "up" and browser.hand.is_empty(), "Release reaches captured second page")
	verify_title_drag(primary, secondary)
	browser.focus_window(1); browser.refresh_windows()
	var title_target: Dictionary = primary._buttons.filter(func(button): return button.target == browser.BASE + 201)[0]
	var tab_close: Dictionary = primary._buttons.filter(func(button): return button.target == browser.BASE + 221)[0]
	check(title_target.rect.get_center().y > 0.52 and is_equal_approx(tab_close.rect.get_center().y, title_target.rect.get_center().y), "Tab titles and close buttons occupy the top row")
	var close_origin: Vector3 = tab_close.node.global_position + primary.global_basis.z.normalized() * 0.2
	primary.press_pointer("right", close_origin, -primary.global_basis.z, true)
	check(platform.commands.back().action == "close" and platform.commands.back().tab == 7 and browser.opened, "Tab close targets only its ID and leaves the window open")
	var select_origin: Vector3 = title_target.node.global_position + primary.global_basis.z.normalized() * 0.2
	primary.press_pointer("right", select_origin, -primary.global_basis.z, true)
	check(platform.commands.back().action == "select" and platform.commands.back().tab == 7, "Exposed title selects the tab directly")
	var tab_list: Array = browser.data.tab_list.duplicate(true)
	browser.data.tab_list = []
	for id in [1, 7, 8, 9]:
		browser.data.tab_list.append({"id": id, "window": 1, "title": "Long title ".repeat(10), "url": "https://example.com/" + str(id)})
	browser.refresh_windows()
	check(primary._buttons.filter(func(button): return button.target >= browser.BASE + 200 and button.target <= browser.BASE + 203).size() == 4, "Four tab titles remain visible")
	var add_tab: Dictionary = primary._buttons.filter(func(button): return button.target == browser.BASE + 14)[0]
	check(not add_tab.enabled, "New tab respects the global four-tab limit")
	check(primary._buttons.filter(func(button): return button.target == browser.BASE + 203)[0].rect.end.x < add_tab.rect.position.x, "Last tab does not overlap window controls")
	var active_tab: Dictionary = primary._buttons.filter(func(button): return button.target == browser.BASE + 200)[0]
	check(active_tab.base_color != primary._buttons.filter(func(button): return button.target == browser.BASE + 201)[0].base_color, "Current tab stays highlighted")
	verify_title_drag(primary, primary)
	browser.data.tab_list = tab_list
	browser.tabs_open = true; browser.refresh_windows()
	check(primary._buttons.any(func(button): return button.target == browser.BASE + 201), "Dormant tab remains selectable")
	var tab_button: Dictionary = primary._buttons.filter(func(button): return button.target == browser.BASE + 201)[0]
	var captions: Array = tab_button.node.get_children().filter(func(node): return node is Label3D and not node.text.is_empty())
	check(captions.size() == 1 and captions[0].font_size == 26 * Menu.TEXT_RASTER_SCALE and is_zero_approx(captions[0].position.y), "Tab title uses larger centered single-row text")
	browser.action(browser.BASE + 201)
	check(platform.commands.back().action == "select" and int(platform.commands.back().window) == 1 and int(platform.commands.back().tab) == 7, "Selection sends stable ID")
	browser.action(browser.BASE + 210)
	check(platform.commands.back().action == "detach", "Tab can move into separate window")
	browser.focus_window(2); browser.action(browser.BASE + 210)
	check(platform.commands.back().action == "merge" and platform.commands.back().tab == 3, "Detached tab can merge back")
	browser.focus_window(1); browser.action(browser.BASE + 6)
	platform.browser.tab_id = 7; browser.next_poll = 0; browser.tick()
	check(not browser.handoff, "Tab change cancels source-bound extraction")
	for owner in [menu, secondary]:
		for pointer in owner._pointers.values(): pointer.line.visible = true; pointer.dot.visible = true
	primary.update_pointer("left", start, -layout.pose.basis.z, false)
	check([menu, secondary].all(func(owner): return owner._pointers.values().all(func(pointer): return not pointer.line.visible and not pointer.dot.visible)), "Switching pointer owner clears stale rays on library and peer")
	browser.close(); menu.refresh()
	check(platform.actions.back() == "hibernate", "Leaving requests session unloading, not just media pause")
	check(not primary.visible and not secondary.visible, "Closing browser hides both windows")
	check(menu._side.visible, "Closing browser restores library navigation")
	menu.refresh_session_controls(true)
	check(menu._buttons.any(func(button): return button.target == Menu.CINEMA_LIGHTS), "Library shortcuts return after closing browser")
	menu.free(); platform.free(); await process_frame
	print("Browser windows: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)

func verify_title_drag(router: Node3D, window: Node3D) -> void:
	var pose: Transform3D = window.global_transform
	var title: Dictionary = window._buttons.filter(func(button): return button.target == window.MOVE)[0]
	var origin: Vector3 = window.head().origin
	var point: Vector3 = title.node.global_position
	var direction := (point - origin).normalized()
	check(router.press_pointer("left", origin, direction, true) and window.drag.get("kind") == window.MOVE, "Title trigger starts movement on window %d" % window.window_id)
	var moved_direction := Basis(Vector3.UP, 0.12) * Basis(Vector3.RIGHT, 0.08) * direction
	router.update_pointer("left", origin, moved_direction, true)
	check(not window.global_transform.is_equal_approx(pose), "Title drag moves the window")
	var facing: Vector3 = origin - window.to_global(window.CENTRE)
	check(window.global_basis.z.normalized().dot(facing.normalized()) > 0.9999 and absf(window.global_basis.x.y) < 0.001, "Title drag keeps panel centred towards viewer without roll")
	check(window.global_basis.get_scale().is_equal_approx(pose.basis.get_scale()), "Title drag preserves size")
	router.release_pointer("left", origin, moved_direction, true)
	check(window.drag.is_empty() and window.title_move.capture.is_empty(), "Trigger release ends movement")
	window.global_transform = pose; window._process(0)
	router.press_pointer("left", origin, direction, true)
	router.update_pointer("left", origin, direction, false)
	check(window.drag.is_empty() and window.title_move.capture.is_empty(), "Tracking loss cancels title movement")
