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
	for low in [false, true]:
		browser.configure_quality(low)
		var surface := preload("res://scripts/web_browser_surface.gd").new()
		surface.configure(primary, platform, 1)
		check(surface.pixels == (surface.LOW_END_PIXELS if low else surface.PIXELS), "Window starts with the runtime-selected raster quality")
		check(surface.pixels * (45 if low else 36) == Vector2i(1440, 900) * 60, "Both window qualities start with the same 1440x900 CSS layout")
		surface.free()
	browser.configure_quality(false)
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
	for corner in [primary.RESIZE_RIGHT, primary.RESIZE_BOTTOM, primary.RESIZE]:
		var button: Dictionary = primary._buttons.filter(func(item): return item.target == corner)[0]
		var old_pose: Transform3D = primary.global_transform
		var old_size: Vector2 = primary.page_size
		check(not button.rect.intersects(primary.page_rect()), "Resize target is wholly outside webpage")
		var local := Vector3(button.rect.get_center().x, button.rect.get_center().y, 0)
		var ray_start: Vector3 = old_pose * (local + Vector3(0, 0, 0.3))
		check(primary.press_pointer("left", ray_start, -old_pose.basis.z, true), "Lower corner starts resize " + str(corner))
		var enlarged: Vector3 = local + Vector3(0.4, -0.3, 0)
		primary.update_pointer("left", old_pose * (enlarged + Vector3(0, 0, 0.3)), -old_pose.basis.z, true)
		var expected := old_size + Vector2(0.0 if corner == primary.RESIZE_BOTTOM else 0.4, 0.0 if corner == primary.RESIZE_RIGHT else 0.3)
		if corner == primary.RESIZE_BOTTOM: expected.y = minf(expected.y, expected.x / primary.Surface.MIN_RATIO)
		check(primary.page_size.is_equal_approx(expected), "Right/bottom/corner independently resize width/height through ray input")
		check(primary.global_transform.is_equal_approx(old_pose), "Resize keeps the top-left anchor and toolbar scale fixed")
		var resized: Dictionary = primary.page_layout()
		var bottom_right: Vector3 = resized.pose * Vector3(resized.size.x * 0.49, -resized.size.y * 0.49, 0.3)
		check(primary.local_hit(bottom_right, -resized.pose.basis.z).get("target") == browser.WEB, "Website fullscreen corner remains clickable after resize")
		check(primary.page_point(bottom_right, -resized.pose.basis.z).distance_to(Vector2(0.99, 0.99)) < 0.001, "Resized ray coordinates match webpage pixels")
		primary.release_pointer("left", ray_start, -old_pose.basis.z, true)
		check(primary.drag.is_empty(), "Release ends corner capture")
		primary.page_size = primary.RECT.size; primary.recenter(); primary.refresh(); primary._process(0)
	verify_minimum_width(primary)
	verify_minimum_height(primary)
	check(not primary._buttons.any(func(button): return button.target >= browser.BASE + 9 and button.target <= browser.BASE + 13), "No redundant bottom controls return")
	for target in [browser.BASE + 2, browser.BASE + 4]:
		check(primary._buttons.any(func(button): return button.target == target), "Refresh, bookmark and cinema are exposed without a menu")
	check(not primary._buttons.any(func(button): return button.target == browser.BASE + 8), "Cinema action is absent outside cinema")
	browser.action(browser.BASE + 8)
	check(primary.mode == "floating", "Hidden cinema action cannot switch presentation")
	for dimensions in [Vector2(2.88, 0.45), Vector2(1.44, 1.8), Vector2(2.0, 0.7)]:
		dimensions = primary.clamp_page_size(dimensions)
		for low in [false, true]:
			var pixels := preload("res://scripts/web_browser_surface.gd").pixels_for(dimensions, low)
			check(absf(float(pixels.x) / pixels.y - dimensions.x / dimensions.y) < 0.01, "Wide/tall viewport preserves its aspect ratio")
			check(pixels.x * pixels.y <= (1920 * 1200 if low else 2560 * 1600) + 4096, "Viewport stays within the device pixel budget")
	var close: Dictionary = primary._buttons.filter(func(button): return button.target == browser.BASE + 5)[0]
	var address: Dictionary = primary._buttons.filter(func(button): return button.target == browser.BASE + 3)[0]
	check(close.rect.position.y > address.rect.end.y and address.rect.size.x >= 0.7, "Window close is separated above a readable address row")
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
	browser.refresh_windows()
	check(primary._buttons.any(func(button): return button.target == browser.BASE + 8), "Cinema action appears in the cinema scene")
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
	var retained_pose: Transform3D = primary.global_transform
	browser.next_poll = 0; browser.tick()
	check(browser.windows.size() == 2 and browser.windows[2].visible, "Detached tabs show a second window")
	var secondary: Node3D = browser.windows[2]
	var first_centre := primary.to_global(Vector3(0.13, 0, 0))
	var second_centre := secondary.to_global(Vector3(0.13, 0, 0))
	check(primary.global_transform.is_equal_approx(retained_pose), "Opening a peer preserves the existing window placement")
	check(first_centre.distance_to(second_centre) > 1.5, "New peer is placed away from the existing window")
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
	secondary.page_size = Vector2(2.2, 1.5); secondary.refresh()
	verify_title_drag(primary, secondary)
	verify_window_occlusion(primary, secondary)
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
	check(browser.window_action.get("command") == "move_tab", "Moving a tab opens a destination picker")
	browser.action(browser.WINDOW_TARGET)
	check(platform.commands.back().action == "move_tab" and platform.commands.back().destination == 0, "Tab can move into a new separate window")
	browser.focus_window(2); browser.action(browser.BASE + 210)
	browser.action(browser.WINDOW_TARGET + 1)
	check(platform.commands.back().action == "move_tab" and platform.commands.back().tab == 3 and platform.commands.back().destination == 1, "Detached tab can move to a selected peer")
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

func verify_minimum_width(window: Node3D) -> void:
	for edge in [window.RESIZE_RIGHT, window.RESIZE_BOTTOM, window.RESIZE]:
		window.page_size = Vector2(2.4, 1.8) if edge == window.RESIZE_RIGHT else window.RECT.size
		window.refresh(); window._process(0)
		var original: Vector2 = window.page_size
		var button: Dictionary = window._buttons.filter(func(item): return item.target == edge)[0]
		var pose: Transform3D = window.global_transform
		var start := Vector3(button.rect.get_center().x, button.rect.get_center().y, 0.3)
		check(window.press_pointer("left", pose * start, -pose.basis.z, true), "Edge captures before reaching desktop minimum")
		window.update_pointer("left", pose * (start + Vector3(-10, -10, 0)), -pose.basis.z, true)
		var bounded: Vector2 = window.page_size
		var logical: Vector2i = window.Surface.logical_for(bounded)
		check(logical.x >= 1280 and logical.x < 1283, "Right, bottom and corner drags stop at the shared desktop minimum")
		check((is_equal_approx(bounded.y, original.y) if edge == window.RESIZE_RIGHT else is_equal_approx(bounded.x, original.x)), "Minimum-width stop preserves the untouched axis")
		window.update_pointer("left", pose * (start + Vector3(-20, -20, 0)), -pose.basis.z, true)
		check(window.page_size.is_equal_approx(bounded), "Further outward dragging cannot shrink the logical viewport")
		check(window.global_transform.is_equal_approx(pose), "Minimum-width stop keeps the top-left anchor fixed")
		window.release_pointer("left", pose * start, -pose.basis.z, true)
	window.page_size = window.RECT.size; window.recenter(); window.refresh(); window._process(0)

func verify_minimum_height(window: Node3D) -> void:
	for low in [false, true]:
		window.browser.configure_quality(low)
		for edge in [window.RESIZE_RIGHT, window.RESIZE_BOTTOM, window.RESIZE]:
			window.page_size = window.RECT.size
			window.refresh(); window._process(0)
			var original: Vector2 = window.page_size
			var button: Dictionary = window._buttons.filter(func(item): return item.target == edge)[0]
			var pose: Transform3D = window.global_transform
			var start := Vector3(button.rect.get_center().x, button.rect.get_center().y, 0.3)
			check(window.press_pointer("left", pose * start, -pose.basis.z, true), "Edge captures before reaching minimum height")
			window.update_pointer("left", pose * (start + Vector3(10, 10, 0)), -pose.basis.z, true)
			var bounded: Vector2 = window.page_size
			var logical: Vector2i = window.Surface.logical_for(bounded)
			var pixels: Vector2i = window.Surface.pixels_for(bounded, low)
			check(logical.y == 720 and pixels * (45 if low else 36) == logical * 60, "Each resize handle stops at the same 720 CSS height on both device tiers")
			check(logical.x >= 1280 and pixels.x * pixels.y <= (1920 * 1200 if low else 2560 * 1600), "Minimum height preserves minimum width and raster budget")
			if edge != window.RESIZE:
				check((is_equal_approx(bounded.y, original.y) if edge == window.RESIZE_RIGHT else is_equal_approx(bounded.x, original.x)), "Minimum-height stop preserves the untouched axis")
			window.update_pointer("left", pose * (start + Vector3(20, 20, 0)), -pose.basis.z, true)
			check(window.page_size.is_equal_approx(bounded), "Further dragging cannot flatten the window below minimum height")
			check(window.global_transform.is_equal_approx(pose), "Minimum-height stop keeps the top-left anchor fixed")
			var layout: Dictionary = window.page_layout()
			var point: Vector3 = layout.pose * Vector3(layout.size.x * 0.49, -layout.size.y * 0.49, 0.3)
			check(window.page_point(point, -layout.pose.basis.z).distance_to(Vector2(0.99, 0.99)) < 0.001, "Ray coordinates still cover the bottom-right corner at minimum height")
			window.release_pointer("left", pose * start, -pose.basis.z, true)
			check(window.drag.is_empty(), "Release ends capture at the height limit")
	window.browser.configure_quality(false)
	window.page_size = window.RECT.size; window.recenter(); window.refresh(); window._process(0)

func verify_window_occlusion(router: Node3D, secondary: Node3D) -> void:
	var browser: RefCounted = router.browser
	var poses := [router.global_transform, secondary.global_transform]
	var sizes := [router.page_size, secondary.page_size]
	var eye: Vector3 = router.head().origin
	# Exercise either window in front, including the secondary's empty chrome.
	for front in [router, secondary]:
		var rear: Node3D = secondary if front == router else router
		for scale_factor in [0.6, 1.0, 2.5]:
			front.page_size = Vector2(2.2, 1.5)
			var basis := (Basis(Vector3.UP, 0.12) * Basis(Vector3.RIGHT, -0.08)).scaled(Vector3.ONE * scale_factor)
			front.global_transform = Transform3D(basis, eye + Vector3(0, -0.3, -2.5))
			rear.page_size = rear.MAX_PAGE
			rear.global_transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 2.5), eye + Vector3(0, 1.5, -7))
			browser.focus_window(rear.window_id); browser.refresh_windows()
			for window in [front, rear]: window._process(0)
			# These are blank parts of the header, outside the small dotted handle.
			for local in [Vector3(0.13 + (front.page_size.x - front.RECT.size.x) / 2, 0.698, 0), Vector3(front.page_rect().end.x - 0.05, 0.698, 0)]:
				var point: Vector3 = front.to_global(local)
				var direction := (point - eye).normalized()
				var hit: Dictionary = router.ray_hit(eye, direction)
				check(int(hit.get("window", 0)) == front.window_id and int(hit.get("target", -1)) == front.MOVE, "Blank header belongs to the nearer window and can drag")
				router.update_pointer("left", eye, direction, true)
				var dot: Node3D = router._pointers.left.dot
				check(dot.visible and dot.global_position.distance_to(point) < 0.025, "Ray stops on the front header, including the secondary window")
				var grab: Dictionary = router.grab_hit(eye, direction)
				check(int(grab.get("window", 0)) == front.window_id, "Grip and trigger agree on the visible front window")
				var before: Transform3D = front.global_transform
				var rear_before: Transform3D = rear.global_transform
				var pointers: int = browser.menu.platform.pointers.size()
				check(router.press_pointer("left", eye, direction, true) and front.drag.get("kind") == front.MOVE, "Blank header starts a trigger drag")
				var moved := Basis(Vector3.UP, 0.08) * direction
				router.update_pointer("left", eye, moved, true)
				check(not front.global_transform.is_equal_approx(before) and rear.global_transform.is_equal_approx(rear_before), "Dragging the header moves only its owning window")
				check(browser.menu.platform.pointers.size() == pointers, "Header drag never sends webpage input behind it")
				router.release_pointer("left", eye, moved, true)
				check(front.drag.is_empty(), "Release ends blank-header capture")
				front.global_transform = before; front._process(0)
			# Disabled controls must remain inert instead of becoming drag handles.
			browser.focus_window(rear.window_id)
			var disabled: Dictionary = front._buttons.filter(func(button): return button.target == browser.BASE + 1)[0]
			var direction: Vector3 = (disabled.node.global_position - eye).normalized()
			var hit: Dictionary = router.ray_hit(eye, direction)
			check(int(hit.get("window", 0)) == front.window_id and not hit.get("enabled", true), "Disabled chrome blocks the rear window")
			var commands: int = browser.menu.platform.commands.size()
			var actions: int = browser.menu.platform.actions.size()
			check(router.press_pointer("left", eye, direction, true) and front.drag.is_empty(), "Disabled chrome consumes a press without starting a drag")
			router._activate_hit(hit)
			check(browser.menu.platform.commands.size() == commands and browser.menu.platform.actions.size() == actions, "Disabled chrome performs no action or focus change")
			var reload: Dictionary = front._buttons.filter(func(button): return button.target == browser.BASE + 2)[0]
			direction = (reload.node.global_position - eye).normalized()
			hit = router.ray_hit(eye, direction)
			check(int(hit.get("window", 0)) == front.window_id and int(hit.get("target", -1)) == browser.BASE + 2, "Enabled controls stay in front of the header drag surface")
			router.press_pointer("left", eye, direction, true)
			check(browser.focused_window == front.window_id and browser.menu.platform.actions.back() == "reload" and front.drag.is_empty(), "Front window reload still activates without dragging")
			# Side borders block clicks but remain grabbable; the page stays clickable.
			# Aim at the outer edge: the page is slightly raised and can visually
			# cover the inner border when the panel is large and viewed obliquely.
			var edge := Vector3(front.page_rect().position.x - 0.009, -0.1, 0)
			direction = (front.to_global(edge) - eye).normalized()
			hit = router.ray_hit(eye, direction)
			check(int(hit.get("window", 0)) == front.window_id and int(hit.get("target", 0)) == front.NONE, "Window border occludes the rear webpage")
			var pointers: int = browser.menu.platform.pointers.size()
			router.press_pointer("left", eye, direction, true)
			check(browser.menu.platform.pointers.size() == pointers and browser.hand.is_empty(), "Border press cannot click through to a webpage")
			router.release_pointer("left", eye, direction, true)
			var page: Dictionary = front.page_layout()
			direction = (page.pose.origin - eye).normalized()
			hit = router.ray_hit(eye, direction)
			check(int(hit.get("window", 0)) == front.window_id and int(hit.get("target", -1)) == front.WEB, "Visible webpage still owns page input")
			# The tabs overlay has empty background too, but it is not a title bar.
			browser.focus_window(front.window_id); browser.tabs_open = true; browser.refresh_windows()
			direction = (front.to_global(Vector3(-0.50, -0.20, 0)) - eye).normalized()
			hit = router.ray_hit(eye, direction)
			check(int(hit.get("window", 0)) == front.window_id and int(hit.get("target", 0)) == front.NONE, "Tabs background blocks rear content without becoming a drag handle")
			browser.tabs_open = false; browser.refresh_windows()
	for i in 2:
		var window: Node3D = [router, secondary][i]
		window.global_transform = poses[i]; window.page_size = sizes[i]
	browser.refresh_windows()
	for window in [router, secondary]: window._process(0)

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
