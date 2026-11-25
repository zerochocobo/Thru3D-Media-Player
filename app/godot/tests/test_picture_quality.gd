extends SceneTree
## Picture quality mode: gamma and saturation wait for the mode, and the menu shows that.
const Grade := preload("res://scripts/color_grade.gd")
const Main := preload("res://scripts/main.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
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

	const Display := Video
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
	# The layer copy's output cap (Quest 2, memory saver): enlarged up to it, not dropped past it.
	check(Display.upscale_size(Vector2i(1920, 960), 1, 2, 1, Display.Upscale.MAXIMUM, 4096) == Vector2i(4096, 2048), "A 2K VR180 picture stops at the cap")
	check(Display.upscale_size(Vector2i(4096, 2048), 1, 2, 1, Display.Upscale.MAXIMUM, 4096) == Vector2i(4096, 2048), "4K VR180 under a 4096 cap is not enlarged")
	check(Display.upscale_size(Vector2i(3840, 1920), 1, 2, 1, Display.Upscale.MAXIMUM, 4096) == Vector2i(3840, 1920), "Less than the smallest worthwhile step under the cap is no enlargement")
	check(Display.upscale_size(Vector2i(1920, 1080), 0, 1, 1, Display.Upscale.MAXIMUM, 4096) == Vector2i(3840, 2160), "1080p reaches 4K within the cap")
	_picture_memory()
	I18n.use("en")
	var menu := Menu.new()
	var state := {"has_video": true, "geometry": 1, "stereo": true, "layer_available": true, "grade_on_layer": true,
		"picture_quality_supported": true, "picture_quality_available": true, "picture_quality": false, "picture_sharpness": 50.0,
		"grade_curves_locked": true, "grade_values": Grade.DEFAULTS.duplicate(), "color_grade": {"preset": "Custom"},
		"picture_inherit_available": true}
	menu.state_provider = func(): return state
	menu.setting_requested.connect(func(key: String, value: Variant):
		if key == "reuse_last_picture": state.reuse_last_picture = value
		if key == "clear_current_picture": state.picture_clear_available = false)
	root.add_child(menu)
	menu.toggle()
	for capture_shown in [false, true]:
		for disc_shown in [false, true]:
			state.capture = {"available": capture_shown}
			state.disc_menu_available = disc_shown
			menu.refresh_values()
			var open_button: Dictionary = menu._buttons.filter(func(button): return button.target == Menu.PICTURE_OPEN)[0]
			check(is_equal_approx(open_button.rect.get_center().x, 0.42 + 0.14 * (int(capture_shown) + int(disc_shown))),
				"Picture shortcut follows capture and disc")
	state.capture = {"available": false}
	state.disc_menu_available = false
	menu.refresh()
	var shortcut: Dictionary = menu._buttons.filter(func(button): return button.target == Menu.PICTURE_OPEN)[0]
	var origin: Vector3 = shortcut.node.global_position + menu.global_basis.z * 0.2
	menu.press_pointer("right_hand", origin, -menu.global_basis.z, true)
	menu.release_pointer("right_hand", origin, -menu.global_basis.z, true)
	check(menu.editing_picture(), "Picture shortcut opens the current video's editor")
	# The settings tile opens the very same editor: there is no separate global default.
	menu._adjustment = ""; menu.section = 1; menu.refresh()
	menu._activate(Menu.SETTINGS_TILE + Menu.OPERATIONS[1].find("color_grade"))
	check(menu.editing_picture() and "Default picture" not in menu.text_snapshot(), "The settings tile opens the current video's editor")
	state.has_video = false; menu._adjustment = ""; menu.refresh()
	check(not menu._enabled("color_grade"), "Without a video the settings tile has nothing to edit")
	state.has_video = true; menu.section = 0; menu._adjustment = ""; menu.refresh()
	menu.press_pointer("right_hand", origin, -menu.global_basis.z, true)
	menu.release_pointer("right_hand", origin, -menu.global_basis.z, true)
	check(menu._adjust_rows.has(Menu.PICTURE_SHARPNESS), "The quality tab shows the sharpness slider")
	check(not menu._adjust_rows[Menu.PICTURE_SHARPNESS].button.enabled, "Sharpness is locked while the mode is off")
	check("Picture quality mode" in menu.text_snapshot(), "The picture panel names the mode")
	I18n.use("zh"); menu.refresh()
	check("画质调色" in menu.text_snapshot() and "沿用上次画面设置" in menu.text_snapshot(), "Localized panel shows the reuse control")
	var toggle: Dictionary = menu._buttons.filter(func(button):
		return menu.choices.targets.get(button.target, {}).get("key") == "reuse_last_picture")[0]
	var toggle_ray: Vector3 = toggle.node.global_position + menu.global_basis.z * 0.2
	menu.press_pointer("right_hand", toggle_ray, -menu.global_basis.z, true)
	menu.release_pointer("right_hand", toggle_ray, -menu.global_basis.z, true)
	check(state.get("reuse_last_picture", false), "Trigger activates the reuse switch in the footer")
	state.picture_clear_available = true
	state.picture_source = "file"
	menu.refresh_values()
	check("清除本片设置" in menu.text_snapshot(), "The footer exposes Clear without a submenu")
	var clear: Dictionary = menu._buttons.filter(func(button): return button.target == Menu.PICTURE_CLEAR)[0]
	check(not clear.rect.intersects(toggle.rect), "Clear and the reuse switch have distinct hit areas")
	var clear_ray: Vector3 = clear.node.global_position + menu.global_basis.z * 0.2
	menu.press_pointer("right_hand", clear_ray, -menu.global_basis.z, true)
	menu.release_pointer("right_hand", clear_ray, -menu.global_basis.z, true)
	check(not state.picture_clear_available, "One press of Clear reaches the current-video reset action")
	I18n.use("en"); menu.refresh()
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
	menu.refresh()
	menu._activate(Menu.PICTURE_QUALITY_TAB + 1)
	check(menu._adjust_rows.size() == 3 and "Picture quality mode" in menu.text_snapshot(), "Color shows three sliders and the shared quality switch")
	menu._activate(Menu.PICTURE_ADVANCED)
	var keys: Array = Grade.PAGES[0]
	for index in keys.size():
		var locked: bool = keys[index] in Grade.CURVES
		check(menu._adjust_rows[450 + index].button.enabled != locked, "Colour page lock: " + keys[index])
	check(not menu._leaves_layer("gamma"), "Locked curves carry no eye-buffer warning")
	state.picture_quality_available = false
	state.grade_curves_locked = false
	menu.refresh()
	check(menu._adjust_rows[450 + keys.find("gamma")].button.enabled and menu._leaves_layer("gamma"), "Without the mode gamma works as before, with its warning")
	state.source_size = "1920 x 1080"
	state.shown_picture = {"size": [3840, 2160], "upscaled": true, "reduced": false}
	check("Picture: 3840 x 2160 | Super resolution" in menu._info_text(), "The info page shows the enlarged size")
	state.shown_picture = {"size": [4096, 2048], "upscaled": false, "reduced": true}
	check("Picture: 4096 x 2048 | Reduced to the output resolution" in menu._info_text(), "The info page shows a picture the cap made smaller")
	state.shown_picture = {"size": [0, 0], "upscaled": false, "reduced": false}
	check(not ("Picture:" in menu._info_text()), "Nothing shown yet: no picture line")
	# The plugins tab: Anime4K's switch first; its mode and level appear beneath it only while it is on.
	state.picture_quality_available = true
	state.picture_quality = true
	state.picture_anime4k = false
	state.picture_anime4k_mode = Video.Anime4k.A
	state.picture_anime4k_tier = 1
	state.picture_anime4k_blocker = ""
	state.picture_anime4k_tiers = [true, true, false, false]
	var targets_of := func(key: String) -> Array:
		return menu._buttons.filter(func(button): return menu.choices.targets.get(button.target, {}).get("key", "") == key)
	menu._activate(Menu.PICTURE_PLUGIN_TAB)
	check(menu._picture_tab == 2 and "Anime4K" in menu.text_snapshot(), "The third tab shows Anime4K")
	check(targets_of.call("picture_anime4k").size() == 1 and targets_of.call("picture_anime4k").front().enabled, "Off: one switch, ready to turn on")
	check(targets_of.call("picture_anime4k_mode").is_empty() and targets_of.call("picture_anime4k_tier").is_empty(), "Off: no mode or level rows")
	var off_height: float = menu._picture_panel_bounds.size.y
	state.picture_anime4k = true
	menu.refresh()
	check(targets_of.call("picture_anime4k_mode").size() == 3 and targets_of.call("picture_anime4k_tier").size() == 4, "On: the mode and level rows appear")
	check(menu._picture_panel_bounds.size.y > off_height, "On: the panel grows for them")
	check(option.call("picture_anime4k_mode", 3).enabled and option.call("picture_anime4k_tier", 1).enabled, "Its modes and an affordable level are on offer")
	check(not option.call("picture_anime4k_tier", 2).enabled and menu._tips[option.call("picture_anime4k_tier", 3).target] == Menu.PICTURE_ANIME4K_TOO_HEAVY,
		"Levels too heavy for this video are greyed and say why")
	state.picture_anime4k_blocker = "hdr"
	menu.refresh()
	check(not option.call("picture_anime4k_mode", 1).enabled and menu._tips[option.call("picture_anime4k_tier", 0).target] == Menu.PICTURE_ANIME4K_BLOCKERS.hdr,
		"Where it cannot run its rows are greyed with the reason")
	check(targets_of.call("picture_anime4k").front().enabled, "It can still be switched off there")
	state.picture_anime4k_blocker = ""
	menu._adjustment = ""
	menu._open_picture_controls()
	check(menu._picture_tab == 2, "With Anime4K on the panel opens on the plugins tab")
	state.picture_anime4k = false
	menu._adjustment = ""
	menu._open_picture_controls()
	check(menu._picture_tab == 0, "With it off the panel opens on picture quality")
	state.picture_anime4k = true
	menu._activate(Menu.PICTURE_QUALITY_TAB)
	check(not option.call("picture_upscale", 2).enabled and menu._tips[option.call("picture_denoise", 1).target] == Menu.PICTURE_ANIME4K_REPLACES,
		"With Anime4K on, super resolution and denoise give way to it")
	state.picture_interpolation_blocker = "anime4k"
	menu.refresh()
	check(menu._tips[option.call("picture_interpolation", 1).target] == Menu.PICTURE_INTERPOLATION_BLOCKERS.anime4k, "Interpolation says Anime4K keeps it off")
	_anime4k()
	for failure in failures: printerr("FAIL: " + failure)
	print("picture quality tests: %d failures" % failures.size())
	quit(1 if not failures.is_empty() else 0)

func _picture_memory() -> void:
	var video := Video.new()
	var privacy := Video.ModeMemory.Privacy
	var previous_policy: String = privacy.file_settings
	privacy.configure_file_settings(privacy.ALL)
	var path := ProjectSettings.globalize_path("res://../../build/picture-test-%s" % Time.get_ticks_usec())
	video.picture_memory = Video.PictureMemory.new(path)
	var a := "file:///picture-test/A.mp4"
	var b := "smb://picture-test/B.mp4"
	var c := "dlna://picture-test/C.mp4"
	var open_clip := func(uri: String, eligible := true) -> void:
		video.local_uri = uri
		video.media.begin(1)
		video._open_picture(uri, eligible)
	var presented := func() -> void:
		video._picture_pending = false
		video._remember_last_picture()
	video.set_reuse_last_picture(true)
	open_clip.call(a)
	presented.call()
	video.preview_picture("picture_quality", true)
	video.preview_picture("picture_upscale", 2)
	video.preview_picture("picture_sharpness", 100.0)
	video.preview_picture("grade_preset", "Warm")
	check(video.picture_memory.lookup(a).is_empty(), "Live preview does not write the file's configuration")
	video.commit_picture()
	var saved_a := video.picture_memory.lookup(a)
	check(video.picture_source == "file" and saved_a.color_grade.preset == "Warm", "Commit stores the chosen settings for A")
	open_clip.call(b)
	check(video.picture_source == "last" and video.picture_snapshot() == saved_a, "B inherits the full configuration")
	presented.call()
	video.preview_picture("temperature", 4000.0)
	video.commit_picture()
	check(video.picture_memory.lookup(b).is_empty(), "A same-value edit on an inherited preset creates no record")
	open_clip.call(c)
	check(video.picture_upscale == 2 and video.picture_source == "last", "C still inherits upscaling choice from the presented B")
	open_clip.call(b)
	presented.call()
	video.preview_picture("picture_sharpness", 150.0)
	video.commit_picture()
	var saved_b := video.picture_memory.lookup(b)
	check(video.picture_source == "file" and saved_b.picture_sharpness == 1.5, "Editing B creates a separate file setting")
	open_clip.call(c)
	check(video.picture_sharpness == 1.5, "The next file inherits the explicitly edited B")
	open_clip.call(a)
	check(video.picture_source == "file" and video.picture_sharpness == 1.0, "A's saved setting wins over inheritance")
	video.clear_current_picture()
	check(video.picture_source == "default" and video.picture_memory.lookup(a).is_empty() and not video.picture_quality,
		"Clearing A returns it to default without reusing the previous appearance")
	open_clip.call(b, false)
	check(video.picture_source == "default", "Temporary playback starts from defaults")
	presented.call()
	video.preview_picture("picture_sharpness", 175.0)
	video.commit_picture()
	check(video.picture_source == "session" and video.picture_memory.lookup(b) == saved_b,
		"Temporary changes do not create or replace stored choices")
	video.set_reuse_last_picture(false)
	open_clip.call(c)
	check(video.picture_source == "default" and video.picture_sharpness == Video.SHARPNESS_DEFAULT,
		"After turning reuse off, an unconfigured clip opens with defaults")
	privacy.configure_file_settings(privacy.NONE)
	open_clip.call(b)
	presented.call()
	video.preview_picture("picture_sharpness", 135.0)
	video.commit_picture()
	check(video.picture_source == "session" and video.picture_memory.lookup(b).is_empty(), "Privacy prevents reads and writes")
	privacy.configure_file_settings(previous_policy)
	check(video.picture_memory.lookup(b) == saved_b, "Disabling file memory leaves existing data intact")
	var restored := Video.PictureMemory.new(path)
	restored.load_saved()
	check(restored.lookup(a).is_empty() and restored.lookup(b) == saved_b and restored.lookup(c).is_empty(),
		"Valid banks reload only explicitly saved and uncleared settings")
	# The carried look survives a restart, also with per-video memory off.
	var stored := {}
	video.last_picture_changed.connect(func(picture: Dictionary, network: bool) -> void:
		stored.picture = picture; stored.network = network)
	privacy.configure_file_settings(privacy.NONE)
	video.set_reuse_last_picture(true)
	open_clip.call(b)
	presented.call()
	video.preview_picture("picture_sharpness", 120.0)
	video.commit_picture()
	check(stored.get("picture", {}).get("picture_sharpness") == 1.2 and stored.get("network") == true,
		"A temporary edit is handed out for saving across restarts")
	var config := ConfigFile.new()
	config.set_value("video", "reuse_last_picture", true)
	config.set_value("video", "last_picture", stored.duplicate(true))
	var reopened := Video.new()
	reopened.load_picture_preferences(config)
	reopened.local_uri = c
	reopened.media.begin(1)
	reopened._open_picture(c, true)
	check(reopened.picture_source == "last" and reopened.picture_sharpness == 1.2, "After a restart the next clip carries the last look")
	reopened.clear_last_picture(true)
	reopened.local_uri = a
	reopened._open_picture(a, true)
	check(reopened.picture_source == "default", "Clearing network settings drops a look carried from a network file")
	config.set_value("video", "last_picture", {"picture": {"picture_quality": "yes"}, "network": false})
	var damaged := Video.new()
	damaged.load_picture_preferences(config)
	damaged.local_uri = a
	damaged.media.begin(1)
	damaged._open_picture(a, true)
	check(damaged.picture_source == "default", "A damaged stored look is ignored")
	privacy.configure_file_settings(previous_policy)
	reopened.free()
	damaged.free()
	video.free()

## Anime4K: the sizes its doublings make, the levels a video affords, its memory and where it cannot run.
func _anime4k() -> void:
	check(Video.anime4k_doublings(Vector2i(352, 240)) == 2 and Video.anime4k_doublings(Vector2i(720, 480)) == 2, "A DVD is doubled twice")
	check(Video.anime4k_doublings(Vector2i(1920, 1080)) == 1 and Video.anime4k_doublings(Vector2i(1080, 1920)) == 1, "1080p becomes 4K, upright too")
	check(Video.anime4k_doublings(Vector2i(2560, 1440)) == 0, "1440p and above are only restored")
	check(Video.anime4k_doublings(Vector2i(1920, 1080), 2048) == 0 and Video.anime4k_doublings(Vector2i(720, 480), 2048) == 1, "The output cap holds")
	var budget := Video.ANIME4K_BUDGET_MS
	check(Video.anime4k_cost(Vector2i(720, 480), Video.Anime4k.A, 3, 2) <= budget, "A DVD affords VL")
	check(Video.anime4k_cost(Vector2i(1920, 1080), Video.Anime4k.A, 1, 1) <= budget, "1080p affords M")
	check(Video.anime4k_cost(Vector2i(1920, 1080), Video.Anime4k.A, 3, 1) > budget, "1080p does not afford VL")
	check(absf(Video.anime4k_cost(Vector2i(1920, 1080), Video.Anime4k.A, 1, 1) - 16.9) < 1.0, "The estimate follows Quest 3's measured 16.9 ms")
	check(Video.anime4k_cost(Vector2i(3840, 2160), Video.Anime4k.A, 1, 0) > budget and Video.anime4k_cost(Vector2i(3840, 2160), Video.Anime4k.A, 0, 0) <= budget,
		"4K is only restored, at S")
	var memory := Video.PictureMemory.new(ProjectSettings.globalize_path("res://../../build/anime4k-test-%s" % Time.get_ticks_usec()))
	var older := memory.clean({"picture_quality": true, "picture_sharpness": 0.5, "picture_upscale": 0, "picture_denoise": 0,
		"color_grade": Grade.new().snapshot()})
	check(not older.picture_anime4k and older.picture_anime4k_mode == 1 and older.picture_anime4k_tier == 1, "A look saved before the plugins tab reads as Anime4K off, A at M")
	var chosen := memory.edited(memory.edited(older, "picture_anime4k", true), "picture_anime4k_mode", 2)
	check(chosen.picture_anime4k and chosen.picture_anime4k_mode == 2 and memory.edited(chosen, "picture_anime4k_tier", 9).picture_anime4k_tier == 3, "Switch, mode and level are kept and clamped")
	check(memory.clean(chosen) == chosen, "The chosen look round-trips")
	check(memory.edited(chosen, "picture_anime4k", false).picture_anime4k_mode == 2, "Switching it off keeps the mode")
	var first_build := older.duplicate(); first_build.erase("picture_anime4k_mode"); first_build.picture_anime4k = 3
	check(memory.clean(first_build).picture_anime4k and memory.clean(first_build).picture_anime4k_mode == 3, "The first test build's saved mode reads as on in that mode")
	first_build.picture_anime4k = 0
	check(not memory.clean(first_build).picture_anime4k, "Its saved 0 reads as off")
	var video := Video.new()
	video.picture_anime4k = true
	video.stereo_sbs = true
	check(video.picture_anime4k_blocker() == "mode", "A 3D picture keeps it off")
	video.stereo_sbs = false
	check(video.picture_anime4k_blocker() == "", "Nothing shown yet: no reason")
	video.media.format = {"width": 3840, "height": 2160}
	video.picture_anime4k_mode = Video.Anime4k.C
	check(video.picture_anime4k_blocker() == "c_size", "Mode C has nothing to enlarge on 4K")
	video.picture_anime4k_mode = Video.Anime4k.A
	video.picture_anime4k_tier = 3
	check(video.picture_anime4k_blocker() == "tier" and video.anime4k_tiers() == [true, false, false, false], "4K affords only S")
	check(video._picture_values().size() == 23 and video._picture_values()[20] == 0.0, "Where it does not run the copy is told mode 0")
	check(video._picture_values()[22] == Video.ANIME4K_BUDGET_MS, "The copy is told this headset's budget")
	video.media.format = {"width": 1920, "height": 1080}
	check(video.anime4k_tiers() == [true, true, false, false], "Quest 3 at 1080p: A at S and M")
	video.anime4k_low_end = true
	check(video.anime4k_tiers() == [false, false, false, false] and video._picture_values()[22] == Video.ANIME4K_LOW_END_BUDGET_MS,
		"Quest 2 at 1080p: no level of A (A S fell to 53 fps there)")
	video.picture_anime4k_mode = Video.Anime4k.C
	check(video.anime4k_tiers()[0] and not video.anime4k_tiers()[1], "Quest 2 at 1080p: C at S (72 fps there)")
	video.media.format = {"width": 720, "height": 480}
	video.picture_anime4k_mode = Video.Anime4k.A
	check(video.anime4k_tiers()[1] and not video.anime4k_tiers()[3], "Quest 2 on a DVD: A at M, not VL")
	video.free()

## Each setting that keeps Alpha off the layer has its own explanation on the switch.
func _alpha_blockers() -> void:
	var texts := {}
	for key in ["alpha", "alpha_background", "alpha_flat", "alpha_memory", "alpha_fisheye", "3d", "source"]:
		check(Menu.PICTURE_QUALITY_BLOCKERS.has(key), "The switch explains " + key)
		texts[Menu.PICTURE_QUALITY_BLOCKERS.get(key, "")] = true
	check(texts.size() == 7, "Each reason reads differently")
