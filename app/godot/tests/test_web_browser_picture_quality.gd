extends SceneTree
## Browser picture quality mode: the player's look, where it applies, its region and the footer menu
## (no super resolution: the page raster keeps the three clarity tiers).
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_windows.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Focus := preload("res://scripts/web_browser_focus.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []
var checks := 0
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: run.call_deferred()
func near(a: PackedFloat32Array, b: Array) -> bool:
	if a.size() != b.size(): return false
	for i in a.size():
		if absf(a[i] - float(b[i])) > 0.0001: return false
	return true
func run() -> void:
	var platform := Fixture.Platform.new()
	var menu := Menu.new(); root.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	var browser: RefCounted = menu.web_browser
	browser.open("https://example.com/a"); browser.tick()
	var window: Node3D = browser.windows[1]
	var defaults := {"picture_quality": false, "picture_sharpness": 0.5, "picture_upscale": 0, "picture_denoise": 2,
		"color_grade": {"preset": "Original", "custom": {}}}
	browser.picture_provider = func() -> Variant: return defaults

	# The player's look, packed as the plugin reads it.
	var look: PackedFloat32Array = browser.picture_look()
	check(look.size() == 15, "The look has sharpen, grade and denoise values")
	check(is_equal_approx(look[0], Video.sharpen_strength(0.5)) and look[1] == 0.0, "Sharpness uses the player's strength curve; Original is ungraded")
	check(near(look.slice(13), [Video.DENOISE[2].x, Video.DENOISE[2].y]), "Denoise uses the player's levels")
	defaults.picture_sharpness = 0.0; defaults.picture_denoise = 0
	check(browser.picture_look().is_empty(), "A look that changes nothing sends nothing")
	defaults.color_grade = {"preset": "Warm", "custom": {}}
	look = browser.picture_look()
	check(look.size() == 15 and look[1] == 1.0 and look[2] > look[4], "A warm grade is sent with more red than blue gain")
	defaults.picture_sharpness = 1.0; defaults.color_grade = {"preset": "Original", "custom": {}}

	# Whenever it is on: sites such as Douyin have no fullscreen to wait for.
	check(not window.picture_enhanced(), "Off by default")
	browser.picture_quality = true
	var values: PackedFloat32Array = window.picture_values(false)
	check(window.picture_enhanced() and near(values.slice(15), [0, 0, 1, 1]), "On, an unfocused page is enhanced whole")
	window.web_fullscreen = true
	check(near(window.picture_values(false).slice(15), [0, 0, 1, 1]), "Fullscreen: the whole page")
	window.web_fullscreen = false
	var video := Rect2(0.2, 0.1, 0.5, 0.6)
	browser.focus_regions[window.focus_tab()] = video; browser.video_regions[window.focus_tab()] = video
	check(window.is_video_focused() and window.picture_enhanced(), "A focused video takes the mode")
	values = window.picture_values(false)
	check(near(values.slice(15), [0.2, 0.1, 0.5, 0.6]), "A 2D page is enhanced over the video's region only")
	var crop: Rect2 = window.focus_crop()
	var inner := Rect2((video.position - crop.position) / crop.size, video.size / crop.size)
	check(near(window.picture_values(true).slice(15), [inner.position.x, inner.position.y, inner.size.x, inner.size.y]),
		"A 3D pair's region is the video within the crop it shows")
	browser.focus_regions[window.focus_tab()] = Rect2(0.1, 0.1, 0.3, 0.3)
	check(near(window.picture_values(false).slice(15), [0.1, 0.1, 0.3, 0.3]), "A free focused region is enhanced alone too")
	browser.focus_regions[window.focus_tab()] = video
	window.picture_failed = true
	check(not window.picture_enhanced(), "A failed quality thread shows the page as it is")
	window.picture_failed = false
	window.selecting = true
	check(window.picture_enhanced(), "Drawing a region leaves the mode as it is")
	window.selecting = false

	# Footer menu at the right end of the button row.
	var controls: Node3D = window.effect_controls
	controls.refresh()
	var buttons: Array = controls._buttons.filter(func(button): return button.target == controls.PICTURE)
	var keyboard: Array = controls._buttons.filter(func(button): return button.target == controls.KEYBOARD)
	check(buttons.size() == 1 and keyboard.size() == 1 and buttons[0].rect.position.x > keyboard[0].rect.end.x,
		"The picture button sits right of the keyboard button")
	controls._activate(controls.PICTURE)
	check(window.picture_settings and not window.depth_settings, "The button opens the picture menu")
	var saved: Array = []
	var record := func(key: String, value: Variant) -> void: saved.append([key, value])
	menu.setting_changed.connect(record)
	for change in [["web_picture_quality", false], ["web_picture_sharpness", 80.0], ["web_picture_denoise", 1]]:
		window._depth_changed(change[0], change[1])
	check(saved == [["web_picture_quality", false], ["web_picture_sharpness", 80.0], ["web_picture_denoise", 1]],
		"The menu's switch, sharpness and denoise are app settings")
	menu.setting_changed.disconnect(record)
	browser.picture_quality = true
	window.refresh()
	var keys: Array = window.depth_choices.targets.values().map(func(item): return item.get("key", ""))
	check(not keys.has("web_clarity"), "The picture menu has no super resolution")
	var switch_label: Array = window._labels.filter(func(label): return label.text == I18n.t("Picture quality mode"))
	var title: Array = window._labels.filter(func(label): return label.text == I18n.t("Picture quality"))
	check(switch_label.size() == 1 and title.size() == 1 and switch_label[0].position.y < title[0].position.y - 0.05,
		"The switch has a row of its own under the title")

	# Holding a control clears the menu off the page and keeps that row, as in the player's menu.
	var targets_for := func(key: String) -> Array:
		return window.depth_choices.targets.keys().filter(func(target): return window.depth_choices.targets[target].get("key", "") == key)
	var denoise_targets: Array = targets_for.call("web_picture_denoise")
	check(denoise_targets.size() == 1 and window.depth_choices.targets[denoise_targets[0]].kind == "slider", "Denoise is a slider")
	var denoise: Dictionary = window.depth_choices.sliders[denoise_targets[0]]
	check(denoise.label.text == I18n.t("Off"), "The denoise slider names its level")
	window.depth_choices._refresh_slider(denoise_targets[0], 2.0)
	check(denoise.label.text == I18n.t("Medium"), "Each stop reads as the player's denoise level")
	var switch_targets: Array = targets_for.call("web_picture_quality")
	var held: int = switch_targets[0]
	saved.clear(); menu.setting_changed.connect(record)
	window.depth_choices.capture = {"hand": "right", "target": held, "item": window.depth_choices.targets[held].duplicate(true), "moved": false}
	window._sync_picture_hold()
	check(window._picture_nodes.all(func(node): return node.visible), "A press shorter than a hold keeps the menu")
	window._picture_hold.since = Time.get_ticks_msec() - 1000
	window._sync_picture_hold()
	check(saved == [["web_picture_quality", window.depth_choices.targets[held].value]], "A held switch applies once")
	window.depth_choices.capture.clear(); window._sync_picture_hold()
	check(window._picture_nodes.all(func(node): return node.visible), "Letting go brings the menu back")
	window.refresh()
	held = targets_for.call("web_picture_denoise")[0]
	window.depth_choices.capture = {"hand": "right", "target": held, "item": window.depth_choices.targets[held].duplicate(true), "moved": false}
	window._sync_picture_hold()
	window._picture_hold.since = Time.get_ticks_msec() - 1000
	window._sync_picture_hold()
	var row: Array = window._buttons.filter(func(button): return int(button.target) == held)
	check(row.size() == 1 and row[0].node.visible, "The held slider stays")
	check(window._picture_nodes.filter(func(node): return node.visible).size() == 1, "Everything else of the menu leaves the page")
	check(saved.size() == 1, "Holding a slider saves nothing until it is let go")
	window.depth_choices.capture.clear(); window._sync_picture_hold()
	menu.setting_changed.disconnect(record)
	window._depth_preview("web_picture_denoise", 3.0)
	check(near(browser.picture_look().slice(13), [Video.DENOISE[3].x, Video.DENOISE[3].y]), "A dragged denoise shows on the page before it is saved")
	window._depth_changed("web_picture_denoise", 3.0)
	check(browser.picture_preview.is_empty(), "Its release saves it and ends the preview")
	window._depth_preview("web_picture_sharpness", 150.0)
	check(is_equal_approx(browser.picture_look()[0], Video.sharpen_strength(1.5)), "A dragged sharpness shows on the page before it is saved")
	window._depth_changed("web_picture_sharpness", 150.0)
	check(browser.picture_preview.is_empty(), "The release saves it and ends the preview")
	window._activate(browser.BASE + 17)
	check(window.depth_settings and not window.picture_settings, "The settings popup replaces the picture menu")
	window._activate(browser.BASE + 17)

	# With the frame hidden (or the page blocked by person passthrough) the footer button still opens a visible menu.
	var close_hit := func() -> bool:
		var close: Array = window._buttons.filter(func(button): return button.target == controls.PICTURE)
		if close.size() != 1 or not close[0].node.is_visible_in_tree(): return false
		var origin: Vector3 = close[0].node.to_global(Vector3(0, 0, 1))
		return int(window.ray_hit(origin, -close[0].node.global_basis.z).get("target", -1)) == controls.PICTURE
	check(not window.on_screen(), "The fixture window floats in the room")
	window.set_toolbar_shown(false)
	check(window.chrome_hidden() and not window.picture_settings, "Hiding the frame closes the menus")
	controls._activate(controls.PICTURE)
	check(window.picture_settings and window._picture_nodes.size() > 0 and window._picture_nodes.all(func(node): return node.is_visible_in_tree()),
		"Frame hidden: the picture menu shows")
	check(close_hit.call(), "Frame hidden: the menu takes the ray")
	window.depth.matte = true; window.refresh()
	check(window.page_input_blocked() and window._picture_nodes.size() > 0 and close_hit.call(), "Person passthrough: the menu shows and takes the ray")
	window._activate(controls.PICTURE)
	check(not window.picture_settings and window.ray_hit(Vector3(0, 0, 1), Vector3(0, 0, -1)).is_empty(), "Closed, the blocked page takes no ray again")
	window.depth.matte = false; window.set_toolbar_shown(true)

	# An ultra clarity saved by the earlier build falls back to the default tier.
	browser.configure_quality(false, "ultra")
	check(browser.clarity == "high" and browser.pixel_units == 5, "A saved ultra clarity falls back to high")

	print("web browser picture quality checks: %d, failures: %d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)
