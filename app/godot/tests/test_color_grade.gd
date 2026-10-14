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
	menu.dismiss()
	check(commits == 5 and menu._adjust_hand.is_empty(), "Dismiss saves active drag")
	menu.visible = true; menu.section = 1; menu._adjustment = "color_grade"; menu.refresh()
	check(Grade.PRESETS == ["Original", "Warm", "Cool", "Custom"] and menu._preset_buttons.size() == 4 and not menu._buttons.any(func(button): return button.target == 414), "Exactly four visible presets with no stale fifth target")
	grade.adjust("red_gain", 1.5); var retained := grade.custom.duplicate()
	menu._activate(412)
	check(grade.preset == "Cool" and grade.values().temperature == 8000, "Third button selects Cool")
	menu._activate(413)
	check(grade.preset == "Custom" and grade.custom == retained, "Fourth button selects retained Custom")
	menu._activate(414)
	check(grade.preset == "Custom" and grade.custom == retained, "Old fifth button is safely ignored")
	menu.free()
	for failure in failures: push_error(failure)
	print("Color grading and distance controls: ", "passed" if failures.is_empty() else failures)
	quit(0 if failures.is_empty() else 1)
