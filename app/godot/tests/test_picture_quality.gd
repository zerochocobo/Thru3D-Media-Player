extends SceneTree
## Picture quality mode: gamma and saturation wait for the mode, and the menu shows that.
const Grade := preload("res://scripts/color_grade.gd")
const Main := preload("res://scripts/main.gd")
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []
func check(value: bool, message: String) -> void:
	if not value: failures.append(message)
func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	_alpha_blockers()
	var grade := Grade.new()
	check(not grade.uses_curves(), "A fresh grade uses no gamma or saturation")
	grade.adjust("contrast", 1.2)
	check(not grade.uses_curves() and not grade.linear_terms().is_empty(), "Contrast alone stays linear")
	grade.adjust("saturation", 1.4)
	grade.adjust("gamma", 0.8)
	check(grade.uses_curves() and grade.linear_terms().is_empty(), "Gamma and saturation are not linear")
	grade.curves_locked = true
	check(is_equal_approx(grade.values().saturation, 1.0) and is_equal_approx(grade.values().gamma, 1.0), "Locked curves have no effect")
	check(is_equal_approx(grade.values().contrast, 1.2), "Locking keeps the linear controls")
	check(is_equal_approx(grade.values(true).saturation, 1.4) and is_equal_approx(grade.values(true).gamma, 0.8), "Locked curves keep their saved values")
	check(not grade.linear_terms().is_empty(), "A locked grade fits the compositor layer")
	check(grade.uses_curves(), "The saved look still counts as using curves while locked")
	grade.curves_locked = false
	check(is_equal_approx(grade.values().saturation, 1.4), "Unlocking restores the curves")
	var saved := Grade.new()
	saved.restore(grade.snapshot())
	check(saved.uses_curves(), "A restored look reports its curves")
	saved.select("Warm")
	check(not saved.uses_curves(), "Presets use no curves")
	saved.curves_locked = true
	saved.adjust("exposure", 0.5)
	check(is_equal_approx(saved.custom.temperature, 4000.0), "The first edit while locked starts from the preset")

	const Display := preload("res://scripts/mpv_video_display.gd")
	const Video := Display
	check(Display.upscale_size(Vector2i(1280, 720), 0, 1, 1, Display.Upscale.MODERATE) == Vector2i(2560, 1440), "Moderate stops at twice the size")
	check(Display.upscale_size(Vector2i(4096, 2048), 1, 2, 1, Display.Upscale.MODERATE) == Vector2i(5760, 2880), "Moderate equals maximum within twice the size")
	check(Display.upscale_size(Vector2i(1280, 720), 0, 1, 1, Display.Upscale.OFF) == Vector2i(1280, 720), "Off enlarges nothing")
	for case in [
			[Vector2i(1920, 1080), 0, 1, 1, Vector2i(3840, 2160), "1080p becomes 4K"],
			[Vector2i(1280, 720), 0, 1, 1, Vector2i(3840, 2160), "720p becomes 4K"],
			[Vector2i(2560, 1080), 0, 1, 1, Vector2i(3840, 1620), "A 21:9 picture keeps its shape"],
			[Vector2i(1080, 1920), 0, 1, 1, Vector2i(2160, 3840), "A portrait picture becomes an upright 4K"],
			[Vector2i(3840, 2160), 0, 1, 1, Vector2i(3840, 2160), "4K stays"],
			[Vector2i(3840, 1080), 0, 2, 1, Vector2i(7680, 2160), "Each eye of a full side-by-side 3D picture becomes 4K"],
			[Vector2i(4096, 2048), 1, 2, 1, Vector2i(5760, 2880), "4K VR180 becomes 6K"],
			[Vector2i(5760, 2880), 1, 2, 1, Vector2i(5760, 2880), "6K VR180 stays"],
			[Vector2i(8192, 4096), 1, 2, 1, Vector2i(8192, 4096), "8K VR180 stays"],
			[Vector2i(3840, 1920), 2, 1, 1, Vector2i(5760, 2880), "A 4K 360 picture becomes 6K"],
			[Vector2i(3840, 3840), 2, 1, 2, Vector2i(5760, 5760), "Each eye of a top-bottom 360 picture becomes 6K"],
			[Vector2i(5760, 5760), 2, 1, 2, Vector2i(5760, 5760), "A 6K top-bottom 360 picture stays"],
			[Vector2i(3840, 3840), 0, 1, 1, Vector2i(3840, 3840), "The same 3840 x 3840 file played flat stays"],
			[Vector2i(3840, 3840), 0, 1, 2, Vector2i(3840, 3840), "Played as flat top-bottom 3D it stays"],
			[Vector2i(3840, 3840), 1, 1, 2, Vector2i(3840, 3840), "Played as VR180 top-bottom it stays"],
			[Vector2i(3840, 3840), 2, 1, 1, Vector2i(3840, 3840), "Played as one-eyed 360 it stays"],
			[Vector2i(0, 0), 0, 1, 1, Vector2i(0, 0), "An unknown size stays unknown"]]:
		var size: Vector2i = Display.upscale_size(case[0], case[1], case[2], case[3])
		check(size == case[4], "%s (got %s)" % [case[5], size])
	var four_three: Vector2i = Display.upscale_size(Vector2i(1440, 1080), 0, 1, 1)
	check(absf(four_three.x * four_three.y - 3840.0 * 2160.0) < 3840.0 * 2160.0 * 0.01 and four_three.x < 3840, "A 4:3 picture gets 4K's pixels, not its width")
	I18n.use("en")
	var menu := Menu.new()
	var state := {"has_video": true, "geometry": 1, "stereo": true, "layer_available": true, "grade_on_layer": true,
		"picture_quality_supported": true, "picture_quality_available": true, "picture_quality": false, "picture_sharpness": 50.0,
		"grade_curves_locked": true, "grade_values": Grade.DEFAULTS.duplicate(), "color_grade": {"preset": "Custom"}}
	menu.state_provider = func(): return state
	root.add_child(menu)
	menu.toggle()
	menu.section = 1
	menu.refresh()
	check(menu._adjust_rows.has(Menu.PICTURE_SHARPNESS), "The settings page shows the sharpness slider")
	check(not menu._adjust_rows[Menu.PICTURE_SHARPNESS].button.enabled, "Sharpness is locked while the mode is off")
	check("Picture quality mode" in menu.text_snapshot(), "The settings page names the mode")
	state.picture_quality = true
	state.grade_curves_locked = false
	menu.refresh()
	check(menu._adjust_rows[Menu.PICTURE_SHARPNESS].button.enabled, "Sharpness unlocks with the mode")
	menu._set_adjustment_at(-10.0)
	var span: Vector3 = menu._adjust_rows[Menu.PICTURE_SHARPNESS].span
	check(is_equal_approx(span.x, 0.0) and is_equal_approx(span.y, 200.0), "Sharpness runs from 0% to 200%")
	check(is_zero_approx(Video.sharpen_strength(0.0)), "0% is no sharpening")
	check(is_equal_approx(Video.sharpen_strength(1.0), 1.0) and is_equal_approx(Video.sharpen_strength(2.0), 2.0), "100% is all of RCAS; above it the excess passes on")
	check(Video.sharpen_strength(0.5) > 0.7 and Video.sharpen_strength(0.5) < 0.8 and Video.sharpen_strength(0.1) > 0.3, "The lower half of the slider is evened out")
	var option := func(key: String, value: int) -> Dictionary:
		return menu._buttons.filter(func(button): var target: Dictionary = menu.choices.targets.get(button.target, {}); return target.get("key", "") == key and int(target.get("value", -1)) == value)[0]
	check(option.call("picture_upscale", 2).enabled and option.call("picture_denoise", 3).enabled, "Super resolution and denoise are on offer with the mode on")
	state.picture_upscale_sizes = {"source": Vector2i(1280, 720), "moderate": Vector2i(2560, 1440), "maximum": Vector2i(3840, 2160), "vr": false}
	menu.refresh()
	check("1280×720" in menu._tips[option.call("picture_upscale", 1).target] and "2560×1440" in menu._tips[option.call("picture_upscale", 1).target], "Moderate names this video's size and twice it")
	check("3840×2160" in menu._tips[option.call("picture_upscale", 2).target], "Maximum names the size it reaches")
	state.picture_upscale_sizes = {"source": Vector2i(8192, 4096), "moderate": Vector2i(8192, 4096), "maximum": Vector2i(8192, 4096), "vr": true}
	state.picture_upscale_available = false
	menu.refresh()
	check(not option.call("picture_upscale", 2).enabled and "8192×4096" in menu._tips[option.call("picture_upscale", 2).target]
		and "6K" in menu._tips[option.call("picture_upscale", 2).target], "A VR video at full size greys super resolution out and says why")
	check(option.call("picture_denoise", 1).enabled, "Denoise stays on offer for it")
	state.picture_upscale_available = true
	state.picture_quality = false
	menu.refresh()
	check(not option.call("picture_upscale", 2).enabled and not option.call("picture_denoise", 1).enabled, "Both wait for the mode")
	state.picture_quality = true
	state.picture_quality_supported = false
	menu.refresh()
	check(not menu._adjust_rows.has(Menu.PICTURE_SHARPNESS), "Runtimes without the mode show no row for it")
	state.picture_quality_supported = true
	state.picture_quality = false
	state.grade_curves_locked = true
	menu._adjustment = "color_grade"
	menu._grade_page = 0
	menu.refresh()
	var keys: Array = Grade.PAGES[0]
	for index in keys.size():
		var locked: bool = keys[index] in Grade.CURVES
		check(menu._adjust_rows[450 + index].button.enabled != locked, "Colour page lock: " + keys[index])
	check(not menu._leaves_layer("gamma"), "Locked curves carry no eye-buffer warning")
	state.picture_quality_available = false
	state.grade_curves_locked = false
	menu.refresh()
	check(menu._adjust_rows[450 + keys.find("gamma")].button.enabled and menu._leaves_layer("gamma"), "Without the mode gamma works as before, with its warning")
	for failure in failures: printerr("FAIL: " + failure)
	print("picture quality tests: %d failures" % failures.size())
	quit(1 if not failures.is_empty() else 0)

## Each setting that keeps Alpha off the layer has its own explanation on the switch.
func _alpha_blockers() -> void:
	var texts := {}
	for key in ["alpha", "alpha_background", "alpha_flat", "alpha_memory", "alpha_fisheye", "3d", "source"]:
		check(Menu.PICTURE_QUALITY_BLOCKERS.has(key), "The switch explains " + key)
		texts[Menu.PICTURE_QUALITY_BLOCKERS.get(key, "")] = true
	check(texts.size() == 7, "Each reason reads differently")
