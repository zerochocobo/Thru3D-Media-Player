extends SceneTree
const Grade := preload("res://scripts/color_grade.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
var failures: Array[String] = []
var grade := Grade.new()
var distance := 5.0
var commits := 0

func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message)

func distance_origin(menu: Node3D, fraction: float) -> Vector3:
	for target in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[target]
		if item.get("kind") != "slider" or item.get("key") != "subtitle_distance": continue
		var slider: Dictionary = menu.choices.sliders[target]
		return slider.node.to_global(Vector3(float(slider.left) + float(slider.width) * fraction, 0, 1))
	return Vector3.ZERO

## Mean difference (0-255) between the shader grade and the compositor applying layer_terms() in linear light.
func _layer_error(g) -> float:
	var shader: Dictionary = g.linear_terms()
	var layer: Dictionary = g.layer_terms()
	var total := 0.0
	var count := 0
	for step in 33:
		var x := step / 32.0
		for channel in 3:
			var want := clampf(shader.scale[channel] * x + shader.bias[channel], 0.0, 1.0)
			var got: float = g._to_encoded(layer.scale[channel] * g._to_linear(x) + layer.bias[channel])
			total += absf(got - want) * 255.0
			count += 1
	return total / count
## Every node a redraw builds, plus the panel and its footer, that is on show.
func shown_nodes(menu: Node3D) -> Array:
	var nodes: Array = [menu._backdrop, menu.device_status] + menu._labels + menu._decorations
	for button in menu._buttons: nodes.append(button.node)
	return nodes.filter(func(node): return is_instance_valid(node) and node.is_visible_in_tree()).map(func(node): return node.get_instance_id())

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	grade.adjust("exposure", 0.75)
	var saved := grade.snapshot()
	grade.select("Warm")
	check(grade.values().temperature == 4000, "Warm preset")
	grade.select("Custom")
	check(grade.values().exposure == 0.75, "Preset selection must retain custom")
	var config := ConfigFile.new()
	config.set_value("video", "color_grade", saved)
	var reloaded := ConfigFile.new()
	check(reloaded.parse(config.encode_to_text()) == OK, "Config round trip")
	grade.restore(reloaded.get_value("video", "color_grade"))
	check(grade.snapshot() == saved, "Restart restores preset and custom values")
	grade.restore({"preset": "Daylight", "custom": {"red_gain": 1.5, "exposure": 0.75}})
	check(grade.preset == "Original" and grade.values() == Grade.DEFAULTS and grade.custom.red_gain == 1.5 and grade.custom.exposure == 0.75, "Legacy Daylight becomes Original without losing remembered custom grading")
	grade.select("Custom")
	check(grade.values().red_gain == 1.5 and grade.values().exposure == 0.75, "Migrated custom look remains selectable")
	grade.restore({"preset": "broken", "custom": {"exposure": INF, "gamma": -3, "red_gain": "bad", "blue_offset": 8}})
	check(grade.preset == "Original" and grade.custom.exposure == 0 and grade.custom.gamma == 0.7
		and grade.custom.red_gain == 1 and is_equal_approx(grade.custom.blue_offset, 0.2), "Invalid saved settings clamp safely")
	# The compositor's per-channel scale/bias reproduces the shader grade while it is linear.
	grade.reset_custom()
	grade.select("Custom")
	for key in ["temperature", "tint", "exposure", "contrast", "red_gain", "blue_offset"]:
		grade.adjust(key, {"temperature": 5200.0, "tint": 12.0, "exposure": 0.4, "contrast": 1.25, "red_gain": 1.1, "blue_offset": -0.05}[key])
	var terms: Dictionary = grade.linear_terms()
	var linear_ok := not terms.is_empty()
	var p := grade.values()
	for sample in [Vector3(0.1, 0.5, 0.9), Vector3(0.0, 0.0, 0.0), Vector3(0.7, 0.2, 0.4)]:
		var shader: Vector3 = (sample * grade.gain() - Vector3.ONE * 0.5) * p.contrast + Vector3.ONE * 0.5 + Vector3(p.red_offset, p.green_offset, p.blue_offset)
		linear_ok = linear_ok and (sample * terms.scale + terms.bias).is_equal_approx(shader)
	check(linear_ok, "Linear grade equals the compositor scale and bias")
	check(_layer_error(grade) < 8.0, "Compositor (linear light) terms stay within a few levels of the shader grade")
	grade.adjust("saturation", 1.2)
	check(grade.linear_terms().is_empty(), "Saturation cannot be a per-channel scale")
	grade.adjust("saturation", 1.0)
	grade.adjust("gamma", 0.9)
	check(grade.linear_terms().is_empty(), "Gamma cannot be a per-channel scale")
	grade.reset_custom()
	grade.select("Original")
	check(grade.linear_terms().scale == Vector3.ONE and grade.linear_terms().bias == Vector3.ZERO, "Original is the identity")
	grade.select("Warm")
	check(not grade.linear_terms().is_empty() and grade.linear_terms().scale.x > grade.linear_terms().scale.z, "Warm preset stays linear and warmer")
	check(_layer_error(grade) < 1.5, "Gain-only presets are near exact on the compositor")
	grade.select("Cool")
	grade.adjust("contrast", 1.2)
	check(grade.preset == "Custom" and grade.custom.temperature == 8000, "Editing starts with displayed preset")
	grade.reset_custom()
	check(grade.values() == Grade.DEFAULTS, "Explicit custom reset")
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/video_rvm_pair.gdshader")
	grade.adjust("exposure", 1)
	grade.apply(material)
	preload("res://scripts/pair_texture_binding.gd")._use_shader(material, load("res://shaders/video_rvm_pair_oes.gdshader"))
	check(material.get_shader_parameter("grade_enabled") and material.get_shader_parameter("grade_gain").is_equal_approx(Vector3.ONE * 2), "OES switch preserves grading")
	var video := Video.new()
	video.subtitle_distance = 1
	check(video.subtitle_distance == 1, "Near subtitle distance is retained for close stereo video")
	video.subtitle_distance = 0.01
	check(is_equal_approx(video.subtitle_distance, 0.1), "Subtitle minimum")
	video.subtitle_distance = INF
	check(video.subtitle_distance == 5, "Invalid subtitle depth defaults to 5m")
	video.subtitle_distance = 100
	check(video.subtitle_distance == 5, "Subtitle maximum")
	video.free()
	var menu := Menu.new()
	menu.state_provider = func(): return {"has_video": true, "geometry": 1, "subtitle_distance": distance, "color_grade": grade.snapshot(), "grade_values": grade.values()}
	menu.adjustment_requested.connect(func(key: String, value: Variant):
		if key == "subtitle_distance": distance = value
		elif key == "grade_preset": grade.select(value)
		elif key == "grade_reset": grade.reset_custom()
		else: grade.adjust(key, value))
	menu.adjustment_committed.connect(func(): commits += 1)
	menu.setting_requested.connect(func(key, value):
		if key == "subtitle_distance": distance = float(value); commits += 1)
	root.add_child(menu)
	menu.toggle()
	menu.section = 0; menu._subtitle_open = true; menu.refresh()
	menu._activate(Menu.SUBTITLE_APPEARANCE)
	check(menu.choices.targets.values().any(func(item): return item.get("key") == "subtitle_distance"), "Subtitle popup contains the distance slider")
	menu.press_pointer("right", distance_origin(menu, 1.0), -menu.global_basis.z, true)
	check(distance == 5 and commits == 0, "Ray press previews subtitle depth")
	menu.update_pointer("left", distance_origin(menu, 0.0), -menu.global_basis.z, true)
	check(distance == 5, "Other hand cannot move active slider")
	menu.release_pointer("right", Vector3.ZERO, Vector3.ZERO, true)
	check(commits == 1 and menu.choices.capture.is_empty(), "Release saves and ends drag")
	menu.press_pointer("right", distance_origin(menu, 0.0), -menu.global_basis.z, true)
	check(is_equal_approx(distance, 0.1), "Distance slider reaches near endpoint")
	menu.release_pointer("right", Vector3.ZERO, Vector3.ZERO, true)
	menu.press_pointer("right", distance_origin(menu, 0.5), -menu.global_basis.z, true)
	check(absf(distance - 2.55) < 0.06, "Slider midpoint maps linearly to metres")
	menu.release_pointer("right", Vector3.ZERO, Vector3.ZERO, true)
	menu._subtitle_open = false; menu.section = 1; menu.refresh()
	menu._activate(Menu.SETTINGS_TILE + Menu.OPERATIONS[1].find("color_grade"))
	menu._activate(411)
	check(grade.preset == "Warm", "Preset selection")
	var exposure_row: Dictionary = menu._adjust_rows.values().filter(func(row): return row.key == "exposure")[0]
	var exposure_at: Vector3 = exposure_row.button.node.position
	menu.press_pointer("right", menu.to_global(Vector3(exposure_at.x, exposure_at.y, 1)), -menu.global_basis.z, true)
	check(grade.preset == "Custom", "Dragging exposure selects custom")
	# A held picture slider clears the menu off the picture and keeps its own row.
	var exposure_origin: Vector3 = menu.to_global(Vector3(exposure_at.x, exposure_at.y, 1))
	var forward: Vector3 = -menu.global_basis.z
	var shown_before := shown_nodes(menu)
	var hold := func() -> void:
		menu._adjust_pressed_ms -= Menu.ADJUST_CLEAR_MS
		menu.update_pointer("right", exposure_origin, forward, true)
	var cleared := func() -> bool: return not menu._adjust_cleared.is_empty() and not menu._backdrop.visible
	var restored := func() -> bool: return menu._adjust_cleared.is_empty() and shown_nodes(menu) == shown_before
	hold.call()
	check(restored.call(), "Without the app's word that the trigger is down the menu stays")
	var held := [true]
	menu.pointer_held = func(hand: String) -> bool: return held[0] and hand == "right"
	menu.update_pointer("right", exposure_origin, forward, true)
	check(cleared.call(), "A held picture slider clears the menu")
	exposure_row = menu._adjust_rows.values().filter(func(row): return row.key == "exposure")[0]
	check([exposure_row.button.node, exposure_row.heading, exposure_row.label, exposure_row.track, exposure_row.knob].all(func(node): return node.is_visible_in_tree()), "The held slider's own row stays")
	var other_row: Dictionary = menu._adjust_rows.values().filter(func(row): return row.key != "exposure")[0]
	check(not other_row.knob.is_visible_in_tree() and not other_row.heading.is_visible_in_tree(), "Other sliders leave with the menu")
	# The periodic value pass shows every row's fill again; the hold hides it again that frame.
	menu._adjust_rows.values().map(func(row): row.fill.visible = true)
	menu._refresh_ms = 0
	menu._process(0.0)
	check(menu._adjust_rows.values().all(func(row): return row.key == "exposure" or not row.fill.is_visible_in_tree()) and not menu._backdrop.visible,
		"A value refresh during the hold keeps the other sliders hidden")
	menu.release_pointer("right", exposure_origin, forward, true)
	menu._process(0.0)
	check(restored.call(), "Releasing the slider brings back exactly what was shown")
	menu.press_pointer("right", exposure_origin, forward, true)
	menu.update_pointer("right", exposure_origin, forward, true)
	check(restored.call(), "A tap on a slider leaves the menu in place")
	hold.call()
	check(cleared.call(), "The menu clears again on the next hold")
	# Every way a hold can end without its release reaching the menu.
	held[0] = false
	menu._process(0.0)
	check(restored.call(), "A release routed elsewhere brings the menu back on the next frame")
	held[0] = true
	menu.update_pointer("right", exposure_origin, forward, true)
	check(cleared.call(), "A trigger still down clears it again")
	menu._adjust_seen_ms -= Menu.ADJUST_CLEAR_LOST_MS + 1
	menu._process(0.0)
	check(restored.call(), "A ray no longer routed to the menu brings it back")
	menu.update_pointer("right", exposure_origin, forward, true)
	check(cleared.call(), "The ray's return clears it again")
	menu.refresh()
	menu.update_pointer("right", exposure_origin, forward, true)
	exposure_row = menu._adjust_rows.values().filter(func(row): return row.key == "exposure")[0]
	check(cleared.call() and exposure_row.knob.is_visible_in_tree() and shown_nodes(menu).size() < shown_before.size(), "A redraw under the held slider stays cleared around the new row")
	menu.press_pointer("left", exposure_origin, forward, true)
	check(menu._adjust_cleared.is_empty() and menu._backdrop.visible and not menu._adjust_hand.is_empty(), "The other hand's trigger brings the menu back without ending the drag")
	hold.call()
	check(menu._adjust_cleared.is_empty(), "The menu then stays for the rest of that hold")
	menu.release_pointer("right", exposure_origin, forward, true)
	commits -= 1
	menu.press_pointer("right", exposure_origin, forward, true)
	hold.call()
	check(cleared.call(), "A new hold clears the menu again")
	menu.visible = false
	check(menu._adjust_cleared.is_empty() and menu._backdrop.visible, "Hiding the menu itself restores its parts")
	menu.visible = true
	menu.cancel_for_hand_lock("right")
	check(menu._adjust_cleared.is_empty() and menu._adjust_hand.is_empty(), "A hand lock ends the hold with the menu shown")
	menu.press_pointer("right", exposure_origin, forward, true)
	hold.call()
	check(cleared.call(), "Hold before dismissing")
	menu.dismiss()
	check(menu._adjust_cleared.is_empty() and menu._backdrop.visible, "Dismissing a held slider restores the hidden menu")
	commits -= 1
	check(["exposure", "saturation", "picture_sharpness", "depth_position", "alpha_feather", "view_zoom", "stereo_focus", "screen_curve"].all(func(key): return menu._clears_menu(key)), "Picture sliders clear the menu")
	check(not ["screen_distance", "screen_scale", "screen_rotation", "portrait_distance", "portrait_scale", "cinema_picture_size", "playback_speed", "alpha_fps", "bar_transparency", "gallery_scale", "gallery_distance", "inspect_magnification"].any(func(key): return menu._clears_menu(key)), "Placement, pace and the menu's own look keep the menu")
	check(commits == 5 and menu._adjust_hand.is_empty(), "Dismiss saves active drag")
	menu.visible = true; menu._open_picture_controls()
	check(Grade.PRESETS == ["Original", "Warm", "Cool", "Custom"] and menu._preset_buttons.size() == 4 and not menu._buttons.any(func(button): return button.target == 414), "Exactly four visible presets with no stale fifth target")
	grade.adjust("red_gain", 1.5); var retained := grade.custom.duplicate()
	menu._activate(412)
	check(grade.preset == "Cool" and grade.values().temperature == 8000, "Third button selects Cool")
	menu._activate(413)
	check(grade.preset == "Custom" and grade.custom == retained, "Fourth button selects retained Custom")
	menu._activate(414)
	check(grade.preset == "Custom" and grade.custom == retained, "Old fifth button is safely ignored")
	# A held colour preset applies on the press, then clears the menu down to the preset row.
	var preset_press := func(target: int) -> Array:
		var node: Node3D = menu._buttons.filter(func(button): return button.target == target)[0].node
		return [node.global_position + menu.global_basis.z, -menu.global_basis.z]
	held[0] = true
	var aim: Array = preset_press.call(412)
	shown_before = shown_nodes(menu)
	menu.press_pointer("right", aim[0], aim[1], true)
	check(grade.preset == "Cool", "A preset applies on the press")
	menu._process(0.0)
	check(menu._adjust_cleared.is_empty(), "A preset tap leaves the menu in place")
	menu._adjust_pressed_ms -= Menu.ADJUST_CLEAR_MS
	menu._process(0.0)
	var presets_shown := menu._buttons.filter(func(button): return menu._grade_preset_target(button.target)).all(func(button): return button.node.is_visible_in_tree())
	check(cleared.call() and presets_shown and shown_nodes(menu).size() < shown_before.size(), "A held preset clears the menu but keeps the preset row")
	menu.release_pointer("right", aim[0], aim[1], true)
	menu._process(0.0)
	check(menu._adjust_cleared.is_empty() and menu._backdrop.visible and grade.preset == "Cool", "Releasing a held preset brings the menu back and keeps the preset")
	menu.press_pointer("right", aim[0], aim[1], true)
	menu._adjust_pressed_ms -= Menu.ADJUST_CLEAR_MS
	held[0] = false
	menu._process(0.0)
	check(menu._adjust_cleared.is_empty() and menu._backdrop.visible, "A preset release routed elsewhere brings the menu back")
	menu.release_pointer("right", aim[0], aim[1], true)
	# A held denoise level applies once the hold is long enough; a tap commits on its release.
	var denoise := [0]
	menu.state_provider = func(): return {"has_video": true, "geometry": 0, "color_grade": grade.snapshot(), "grade_values": grade.values(),
		"picture_quality_supported": true, "picture_quality_available": true, "picture_quality": true, "picture_denoise": denoise[0]}
	menu.choices.changed.connect(func(key, value): if key == "picture_denoise": denoise[0] = int(value))
	menu._picture_tab = 0
	menu.refresh()
	var level := func(value: int) -> Dictionary:
		var found := menu._buttons.filter(func(button): var item: Dictionary = menu.choices.targets.get(button.target, {}); return item.get("key") == "picture_denoise" and item.get("value") == value)
		return found[0] if not found.is_empty() else {}
	check(not level.call(2).is_empty(), "Denoise levels are drawn")
	if not level.call(2).is_empty():
		var at: Vector3 = level.call(2).node.global_position + menu.global_basis.z
		held[0] = true
		menu.press_pointer("right", at, -menu.global_basis.z, true)
		menu._process(0.0)
		check(denoise[0] == 0 and menu._adjust_cleared.is_empty(), "A fresh denoise press changes nothing yet")
		menu._adjust_pressed_ms -= Menu.ADJUST_CLEAR_MS
		menu._process(0.0)
		menu.refresh()
		menu._process(0.0)
		var levels_shown: bool = [0, 1, 2, 3].all(func(value): return not level.call(value).is_empty() and level.call(value).node.is_visible_in_tree())
		check(denoise[0] == 2 and cleared.call() and levels_shown, "A held denoise level applies and clears the menu down to its row")
		menu.release_pointer("right", at, -menu.global_basis.z, true)
		menu._process(0.0)
		check(menu._adjust_cleared.is_empty() and menu._backdrop.visible and denoise[0] == 2, "Releasing it brings the menu back with the level kept")
		at = level.call(1).node.global_position + menu.global_basis.z
		menu.press_pointer("right", at, -menu.global_basis.z, true)
		menu.release_pointer("right", at, -menu.global_basis.z, true)
		menu._process(0.0)
		check(denoise[0] == 1 and menu._adjust_cleared.is_empty(), "A denoise tap still picks its level on release")
	# A held subtitle slider clears the menu down to itself, like the picture sliders.
	menu.state_provider = func(): return {"has_video": true, "geometry": 1, "subtitle_distance": distance, "color_grade": grade.snapshot(), "grade_values": grade.values()}
	menu._adjustment = ""; menu.section = 0; menu._subtitle_open = true; menu.refresh()
	menu._activate(Menu.SUBTITLE_APPEARANCE)
	held[0] = true
	var subtitle_at := distance_origin(menu, 0.5)
	check(subtitle_at != Vector3.ZERO, "The subtitle distance slider is drawn")
	menu.press_pointer("right", subtitle_at, forward, true)
	menu._process(0.0)
	check(menu._adjust_cleared.is_empty() and menu.choices.capture.get("hand", "") == "right", "A fresh subtitle slider press keeps the menu")
	menu._adjust_pressed_ms -= Menu.ADJUST_CLEAR_MS
	menu.update_pointer("right", subtitle_at, forward, true)
	var subtitle_slider := func() -> Array: return menu._buttons.filter(func(button):
		var item: Dictionary = menu.choices.targets.get(button.target, {}); return item.get("kind") == "slider" and item.get("key") == "subtitle_distance")
	check(cleared.call() and subtitle_slider.call().size() == 1 and subtitle_slider.call()[0].node.is_visible_in_tree(), "A held subtitle slider clears the menu but keeps itself")
	menu.refresh()
	menu._process(0.0)
	check(cleared.call() and subtitle_slider.call()[0].node.is_visible_in_tree(), "A redraw under the held subtitle slider stays cleared")
	# Tooltips stay away from a hand holding its trigger, and come back once it lets go.
	var tip_target: int = subtitle_slider.call()[0].target
	menu._tips[tip_target] = "Distance"
	menu._hover = {"right": tip_target}
	menu._update_tooltip()
	check(menu._tooltip == null or not menu._tooltip.visible, "No tooltip under a held trigger")
	held[0] = false
	menu._update_tooltip()
	check(menu._tooltip != null and menu._tooltip.visible, "The tooltip shows once the trigger is up")
	held[0] = true
	menu.release_pointer("right", subtitle_at, forward, true)
	menu._process(0.0)
	check(menu._adjust_cleared.is_empty() and menu._backdrop.visible and menu.choices.capture.is_empty(), "Releasing the subtitle slider brings the menu back")
	menu.press_pointer("right", subtitle_at, forward, true)
	menu._adjust_pressed_ms -= Menu.ADJUST_CLEAR_MS
	menu.press_pointer("left", subtitle_at, forward, true)
	menu._process(0.0)
	check(menu._adjust_cleared.is_empty() and menu._backdrop.visible, "The other hand's trigger brings the menu back during a subtitle hold")
	menu.release_pointer("right", subtitle_at, forward, true)
	# Subtitle options take the held-choice path: the held one applies and the menu clears to its row.
	var picked := {}
	menu.choices.changed.connect(func(key, value): picked[key] = value)
	var option := func(key: String, value: Variant) -> Dictionary:
		var found := menu._buttons.filter(func(button): var item: Dictionary = menu.choices.targets.get(button.target, {}); return item.get("kind") == "choose" and item.get("key") == key and item.get("value") == value)
		return found[0] if not found.is_empty() else {}
	check(not option.call("subtitle_direction", 1).is_empty(), "Subtitle direction options are drawn")
	if not option.call("subtitle_direction", 1).is_empty():
		var at: Vector3 = option.call("subtitle_direction", 1).node.global_position + menu.global_basis.z
		menu.press_pointer("right", at, forward, true)
		menu._adjust_pressed_ms -= Menu.ADJUST_CLEAR_MS
		menu._process(0.0)
		menu.refresh()
		menu._process(0.0)
		check(picked.get("subtitle_direction") == 1 and cleared.call() and option.call("subtitle_direction", 0).node.is_visible_in_tree(),
			"A held subtitle direction applies and clears the menu down to its options")
		menu.release_pointer("right", at, forward, true)
		menu._process(0.0)
		check(menu._adjust_cleared.is_empty() and menu._backdrop.visible, "Releasing the subtitle option brings the menu back")
	menu.free()
	for failure in failures: push_error(failure)
	print("Color grading and distance controls: ", "passed" if failures.is_empty() else failures)
	quit(0 if failures.is_empty() else 1)
