extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Accounts := preload("res://scripts/account_panel.gd")
const Filter := preload("res://scripts/web_pointer_filter.gd")
const Surface := preload("res://scripts/account_login_surface.gd")
class Platform extends "res://tests/account_platform_fixture.gd":
	var frame_calls := 0
	func account_web_frame(_id: int) -> PackedByteArray: frame_calls += 1; return PackedByteArray()
var checks := 0
var failures: Array[String] = []
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)
func origin(menu: Node3D, point: Vector2) -> Vector3: return menu.to_global(Vector3(point.x, point.y, 1))
func at_uv(rect: Rect2, uv: Vector2) -> Vector3:
	return Vector3(rect.position.x + rect.size.x * uv.x, rect.end.y - rect.size.y * uv.y, 0)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var platform := Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.visible = true
	menu.section = Menu.Section.CLOUD
	var panel: RefCounted = menu.account_panel
	panel.start("cloud", "quark_open")
	var state: Dictionary = platform.account_sessions[panel.session]
	state.state = "web"
	state.web = {"renderer": "gecko", "surface_id": "fixture-session", "width": 440, "height": 600,
		"pixel_units": 4, "desktop": false, "editing": false, "system_keyboard": true, "status": "", "navigation": 1}
	state.revision += 1; panel.poll()
	check(panel.web_gecko(), "Quark snapshot selects the dedicated producer")
	var rect: Rect2 = panel.web_rect()
	check(is_equal_approx(rect.size.x / rect.size.y, 440.0 / 600.0) and is_equal_approx(rect.size.x, 1.2), "Mobile form preserves its phone layout on a comfortable physical surface")
	check(rect.get_area() <= 0.563 * (1.6 * 1.6 * 600.0 / 440.0), "Phone page area shrinks by at least 43 percent without changing CSS or cropping")
	check(menu._backdrop.mesh.size.x <= 1.68 and menu._backdrop.mesh.size.y < 2.3, "Phone chrome fits the smaller page envelope")
	check(Surface.pixel_size(state.web) == Vector2i(587, 800), "Low-end phone Surface rounds only after density conversion")
	check(Surface.pixel_size({"width": 440, "height": 600, "pixel_units": 5}) == Vector2i(733, 1000), "High-quality phone Surface preserves the requested logical width")
	panel.tick(0.3); panel.tick(0.3)
	check(platform.frame_calls == 0, "Gecko never enters the old JPEG polling path")
	check(menu._backdrop.material_override.get_shader_parameter("surface_color").a == 0.0, "Login leaves the native webpage visible through its chrome")
	for language in ["en", "zh", "zh_Hant", "ja"]:
		menu.I18n.use(language); menu.refresh()
		var buttons: Array = menu._buttons.filter(func(b): return b.target != Accounts.WEB)
		for i in buttons.size():
			var a: Dictionary = buttons[i]
			if a.target >= Accounts.BASE and a.target < Accounts.FIELD:
				check(a.rect.size.x >= 0.14 and a.rect.size.y >= 0.14, language + " login toolbar has large targets")
			for j in range(i + 1, buttons.size()): check(not a.rect.intersects(buttons[j].rect), language + " toolbar targets do not overlap")
		check(not menu._buttons.any(func(b): return b.target >= Accounts.KEY and b.target < Accounts.KEY + 40), "System keyboard does not get a second ray keyboard")
	menu.I18n.use("en")
	var dir := -menu.global_basis.z
	var start := Vector2(rect.position.x + 0.1, 0)
	menu.update_pointer("right_hand", origin(menu, start), dir, true)
	menu.press_pointer("right_hand", origin(menu, start), dir, true)
	check(panel.web_hand == "right_hand" and platform.web_calls.back()[1] == "down", "Real ray press captures one webpage pointer")
	var count: int = platform.web_calls.size()
	menu.press_pointer("left_hand", origin(menu, start), dir, true)
	menu.release_pointer("left_hand", origin(menu, start), dir, true)
	menu.stick_scroll(1.0, 0.016)
	panel.action(Accounts.BASE + 30); panel.action(Accounts.BASE + 29)
	check(platform.web_calls.size() == count and not panel.web_selecting, "Other hand, scroll and mode changes cannot interrupt a captured drag")
	var last_x: float = platform.web_calls.back()[2]
	for i in range(1, 26):
		var point := start + Vector2(float(i) / 25 * (rect.size.x - 0.2), 0)
		menu.update_pointer("right_hand", origin(menu, point), dir, true)
		var call: Array = platform.web_calls.back()
		check(call[1] == "move" and call[2] >= last_x, "Held ray sends continuous ordered movement")
		last_x = call[2]
		var dot: Vector3 = menu._pointer("right_hand").dot.position
		var expected: Vector2 = panel.web_uv(dot)
		check(Vector2(call[2], call[3]).distance_to(expected) < 0.001, "Displayed reticle and injected coordinates share the same filter")
		if i == 12: state.web.progress = 55; panel.poll()
	menu.release_pointer("right_hand", origin(menu, start + Vector2(rect.size.x - 0.2, 0)), dir, true)
	check(panel.web_hand.is_empty() and platform.web_calls.back()[1] == "up", "Release ends exactly the owning pointer")
	# Angled rays must use the actual page plane at down, move and up, even without a prior hover.
	var angled_origin := menu.to_global(Vector3(-0.8, 0.3, 1.0))
	for event in ["down", "move", "up"]:
		var aim := Vector3(0.1 if event == "down" else 0.18 if event == "move" else 0.25, 0.05, 0.007)
		var angled_dir := (menu.to_global(aim) - angled_origin).normalized()
		if event == "down": menu.press_pointer("right_hand", angled_origin, angled_dir, true)
		elif event == "move": menu.update_pointer("right_hand", angled_origin, angled_dir, true)
		else: menu.release_pointer("right_hand", angled_origin, angled_dir, true)
		var sent: Array = platform.web_calls.back()
		var visible_uv: Vector2 = panel.web_uv(menu._pointer("right_hand").dot.position)
		check(sent[1] == event and Vector2(sent[2], sent[3]).distance_to(visible_uv) < 0.0001, "Angled " + event + " shares reticle coordinates")
	state.web.failed = true; panel.poll(); count = platform.web_calls.size()
	menu.press_pointer("right_hand", origin(menu, Vector2.ZERO), dir, true)
	check(platform.web_calls.size() == count and panel.web_hand.is_empty(), "Unavailable page cannot capture or receive a press")
	state.web.failed = false; panel.poll()
	state.web.editing = true; panel.poll()
	check(panel.web_rect() == rect, "Keyboard focus cannot move or resize the webpage")
	var refresh: Dictionary = menu._buttons.filter(func(b): return b.target == Accounts.BASE + 18).front()
	menu.press_pointer("right_hand", origin(menu, refresh.rect.get_center()), dir, true)
	menu.release_pointer("right_hand", origin(menu, refresh.rect.get_center()), dir, true)
	check(platform.web_calls.back()[1] == "reload", "Refreshing an editing page follows the production toolbar ray path")
	panel.action(Accounts.BASE + 29)
	count = platform.web_calls.size()
	panel.web_press("right_hand", at_uv(rect, Vector2(0.5, 0.5)))
	panel.web_release("right_hand", at_uv(rect, Vector2(0.5, 0.5)))
	check(panel.web_focus == Rect2(0.25, 0.25, 0.5, 0.5), "A single point selection gives fixed 2x focus")
	check(platform.web_calls.size() == count, "Selecting focus never clicks the underlying verification page")
	for uv in [Vector2.ZERO, Vector2.ONE, Vector2(0.5, 0.5), Vector2(0, 1), Vector2(1, 0)]:
		check(panel.web_uv(at_uv(panel.web_rect(), uv)).distance_to(Vector2(0.25, 0.25) + uv * 0.5) < 0.00001, "Focused corners and centre address their original source pixels")
	var crop: Rect2 = panel.web_focus
	menu.press_pointer("right_hand", origin(menu, Vector2(-0.4, 0)), dir, true)
	menu.update_pointer("right_hand", origin(menu, Vector2(0.4, 0)), dir, true)
	check(panel.web_focus == crop and platform.web_calls.back()[1] == "move", "Focused drag keeps crop and viewport fixed")
	menu.update_pointer("right_hand", origin(menu, Vector2(5, 0)), dir, true)
	check(is_equal_approx(float(platform.web_calls.back()[2]), crop.end.x), "Leaving the selected area clamps to its visible edge")
	menu.update_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)
	check(platform.web_calls.back()[1] == "cancel" and panel.web_hand.is_empty(), "Tracking loss cancels the same drag")
	count = platform.web_calls.size()
	menu.update_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)
	check(platform.web_calls.size() == count, "Tracking loss cannot duplicate cancellation")
	panel.action(Accounts.BASE + 29); panel.action(Accounts.BASE + 29)
	panel.web_press("left_hand", at_uv(rect, Vector2(0.8, 0.7)))
	panel.web_move("left_hand", at_uv(rect, Vector2(0.2, 0.3)))
	panel.web_release("left_hand", at_uv(rect, Vector2(0.2, 0.3)))
	check(panel.web_focus.position.distance_to(Vector2(0.2, 0.3)) < 0.0001 and panel.web_focus.size.distance_to(Vector2(0.6, 0.4)) < 0.0001, "Reverse frame selection fits the complete chosen region")
	check(is_equal_approx(panel.web_rect().size.x / panel.web_rect().size.y, 440.0 * 0.6 / (600.0 * 0.4)), "Non-square crop is fitted without stretching")
	menu.press_pointer("left_hand", origin(menu, Vector2.ZERO), dir, true)
	state.web.navigation = 2; panel.poll()
	check(panel.web_focus == Accounts.Focus.FULL and panel.web_hand.is_empty() and platform.web_calls.back()[1] == "cancel", "New document retires old selection and active input")
	panel.action(Accounts.BASE + 30)
	check(platform.web_calls.back()[1] == "desktop", "Desktop switch is an explicit session action")
	state.web.desktop = true; state.web.width = 1200; state.web.height = 720; panel.poll()
	check(is_equal_approx(panel.web_rect().size.x / panel.web_rect().size.y, 1200.0 / 720), "Desktop fallback keeps correct source aspect")
	count = platform.web_calls.size()
	check(not menu._buttons.any(func(b): return b.target == Accounts.BASE + 31), "Compatibility sign-in is hidden")
	panel.action(Accounts.BASE + 31)
	check(platform.web_calls.size() == count, "Retired compatibility target cannot switch renderers")
	state.web = {"width": 1200, "height": 720}; panel.poll(); panel.tick(0.3)
	check(not panel.web_gecko() and platform.frame_calls == 1, "Existing legacy cookie accounts retain their image bridge")
	check(menu._backdrop.material_override.get_shader_parameter("surface_color") == menu.PANEL, "Compatibility sign-in restores the standard panel background")
	state.web = {"renderer": "gecko", "surface_id": "fixture-reopen", "width": 440, "height": 600}; panel.poll()
	menu._activate(menu.CLOSE)
	check(not panel.active() and not menu.visible, "Top-right close exits the login session")
	menu.toggle()
	check(menu._backdrop.material_override.get_shader_parameter("surface_color") == menu.PANEL, "Reopening the library after login restores its opaque background")
	panel.start("cloud", "quark_open"); state = platform.account_sessions[panel.session]
	state.state = "web"; state.web = {"renderer": "gecko", "width": 440, "height": 600}; panel.poll()
	menu.section = Menu.Section.RECENT
	panel.action(Accounts.BASE)
	check(menu._backdrop.material_override.get_shader_parameter("surface_color") == menu.PANEL, "Back from login restores the library background too")
	for provider in ["115_open", "baidu", "aliyun_open", "quark_open", "onedrive"]:
		panel.start("cloud", provider); menu.visible = true
		state = platform.account_sessions[panel.session]
		var desktop_only: bool = provider == "baidu"
		state.state = "web"; state.web = {"renderer": "gecko", "surface_id": provider + "-session", "width": 1200 if desktop_only else 440, "height": 720 if desktop_only else 600, "desktop": desktop_only, "desktop_only": desktop_only}
		panel.poll(); panel.tick(0.3)
		check(panel.web_gecko() and is_equal_approx(panel.web_rect().size.x, 1.8 if desktop_only else 1.2), provider + " starts in its supported layout")
		check(menu._buttons.any(func(b): return b.target == Accounts.BASE + 30) != desktop_only, provider + " only shows supported layout switches")
		check(not menu._buttons.any(func(b): return b.target == Accounts.BASE + 31), provider + " hides compatibility sign-in")
		panel.action(Accounts.BASE + 29)
		panel.web_press("right_hand", at_uv(panel.web_rect(), Vector2(0.5, 0.5)))
		panel.web_release("right_hand", at_uv(panel.web_rect(), Vector2(0.5, 0.5)))
		check(panel.web_focus != Accounts.Focus.FULL, provider + " supports local focus")
		count = platform.web_calls.size()
		panel.action(Accounts.BASE + 30)
		if desktop_only:
			check(platform.web_calls.size() == count and panel.web_focus != Accounts.Focus.FULL, "Baidu ignores stale mobile-switch targets without disturbing focus")
		else: check(platform.web_calls.back()[1] == "desktop" and panel.web_focus == Accounts.Focus.FULL, provider + " supports the desktop switch")
		state.web.desktop = true; state.web.width = 1200; state.web.height = 720; panel.poll()
		check(is_equal_approx(panel.web_rect().size.x, 1.8), provider + " uses the desktop surface dimensions")
		var login_session: int = panel.session
		var login_identity: String = state.web.surface_id
		state.web.navigation = 3; panel.poll()
		for resume_round in 3:
			panel.lifecycle("pause")
			menu.dismiss()
			menu.set_compact(false)
			panel.lifecycle("resume")
			check(panel.session == login_session and panel.view == "web" and not login_session in platform.account_cancels, provider + " preserves its login across temporary hiding and repeated resume")
			check(menu.visible and state.web.surface_id == login_identity and state.web.navigation == 3, provider + " resumes the same document without reloading")
		menu._activate(menu.CLOSE)
		check(not panel.active() and login_session in platform.account_cancels, provider + " still exits through the explicit close button")
		menu.visible = true
		panel.close(); menu.refresh()
	var filter := Filter.new(); var time := 1000000
	var raw_energy := 0.0; var smooth_energy := 0.0
	for i in 200:
		time += 13889
		var raw := Vector2(0.0007 if i % 2 else -0.0007, 0)
		var smooth := filter.sample(raw, time)
		if i > 20: raw_energy += raw.length_squared(); smooth_energy += smooth.length_squared()
	check(smooth_energy < raw_energy * 0.4, "Steady hand jitter is damped without page-dependent snapping")
	var fast := filter.sample(Vector2(0.05, 0), time + 13889)
	check(fast.x > 0.045, "Deliberate movement follows within the next sample")
	filter.reset(); check(filter.sample(Vector2(0.8, 0.2), time + 27778) == Vector2(0.8, 0.2), "Reacquisition cannot inherit the old pointer position")
	menu.free(); platform.free()
	print("Account Gecko checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
