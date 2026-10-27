extends SceneTree
const Quality := preload("res://scripts/display_quality.gd")
const Main := preload("res://scripts/main.gd")
const I18n := preload("res://scripts/i18n.gd")
const Palette := preload("res://scripts/watch_palette.gd")
class HostProbe extends RefCounted:
	var requests: Array[bool] = []
	func finish_app(restart: bool) -> void: requests.append(restart)
var failures: Array[String] = []
func check(value: bool, message: String) -> void:
	if not value: failures.append(message)
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var settings := ConfigFile.new()
	check(Quality.load_quality(settings) == Quality.AUTO, "Default quality is auto")
	check(Quality.render_scale(Quality.AUTO, false) == 1.1 and Quality.render_scale(Quality.AUTO, true) == 1.0, "Auto quality: Enhanced, or Standard on low end")
	check(Quality.render_scale(2, true) == 1.25, "Explicit quality is respected on low end")
	check(Quality.load_sharpness(settings) == 0.2, "Photos default to gentle sharpening")
	check(Quality.load_video_sharpness(settings) == 0.0, "Video defaults to no sharpening")
	for adapter in ["Adreno (TM) 650", "Adreno (TM) 540"]:
		check(Quality.is_low_end_gpu(adapter), "XR2 Gen1 class is low end: " + adapter)
	for adapter in ["Adreno (TM) 740", "Adreno (TM) 830", "NVIDIA GeForce RTX 3060", ""]:
		check(not Quality.is_low_end_gpu(adapter), "Not low end: " + adapter)
	check(Quality.load_sharpness(settings, true) == 0.0, "Low-end devices default to no sharpening")
	check(Quality.load_output_choice(settings) == Quality.AUTO_OUTPUT, "Output width defaults to auto")
	check(Quality.output_width(Quality.AUTO_OUTPUT, true) == 4096 and Quality.output_width(Quality.AUTO_OUTPUT, false) == 0, "Auto output follows tier")
	check(Quality.output_width(0, true) == 0 and Quality.output_width(5760, true) == 5760, "Explicit output width is respected")
	check(Quality.load_memory_choice(settings) == Quality.MEMORY_AUTO, "Memory mode defaults to auto")
	check(not Quality.memory_saver(Quality.MEMORY_AUTO, false, 7757) and not Quality.memory_saver(Quality.MEMORY_AUTO, false, 0),
		"Auto keeps standard memory on Quest 3 class RAM or when RAM is unknown")
	check(Quality.memory_saver(Quality.MEMORY_AUTO, false, 5650) and Quality.memory_saver(Quality.MEMORY_AUTO, true, 7757),
		"Auto saves memory on 6 GB headsets and XR2 Gen1 class GPUs")
	check(Quality.memory_saver(Quality.MEMORY_SAVER, false, 12000) and not Quality.memory_saver(Quality.MEMORY_STANDARD, true, 5650),
		"An explicit memory mode overrides the device")
	check(Quality.load_alpha_precision(settings) == Quality.ALPHA_PRECISION_AUTO and not Quality.alpha_fp32(Quality.ALPHA_PRECISION_AUTO)
		and not Quality.alpha_fp32(Quality.ALPHA_PRECISION_FAST) and Quality.alpha_fp32(Quality.ALPHA_PRECISION_PRECISE) == Quality.ALPHA_PRECISION_SHOWN,
		"AI precision defaults to auto (FP16); Precise runs FP32 only while the setting is shown")
	var memory_choice := ConfigFile.new()
	memory_choice.set_value("video", "memory_mode", 7)
	check(Quality.load_memory_choice(memory_choice) == Quality.MEMORY_AUTO, "Unknown memory mode falls back to auto")
	var explicit := ConfigFile.new()
	explicit.set_value("video", "output_width", 0)
	explicit.set_value("video", "sharpness", 0.4)
	check(Quality.load_output_choice(explicit) == 0 and Quality.load_sharpness(explicit, true) == 0.6, "Saved choices override tier defaults")
	explicit.set_value("video", "sharpness", 0.6)
	check(Quality.load_sharpness(explicit) == 0.6, "The former High level stays at Quality strength")
	check(Quality.load_video_sharpness(explicit) == 0.6, "A saved sharpness applies to video too")
	explicit.set_value("video", "output_width", 1234)
	check(Quality.load_output_choice(explicit) == Quality.AUTO_OUTPUT, "Unknown output width falls back to auto")
	var path := "user://quality_test_%d.cfg" % Time.get_ticks_usec()
	settings.set_value("appearance", "background", "dark")
	check(Palette.load_choice(settings) == "mint", "Old settings use the unified mint watch")
	settings.set_value("watch", "color", "blue")
	settings.save(path)
	var main := Main.new()
	main.settings_path = path
	root.add_child(main)
	check(main.wrist_watch.color_choice == "blue", "Watch restores its saved color on startup")
	main.recent_menu.section = main.recent_menu.Section.SETTINGS
	main.recent_menu.tab = main.recent_menu.DISPLAY_TAB
	main.recent_menu.refresh()
	# The transparency editor is an action row; these assertions describe choice fields.
	var watch_rows: Array = main.recent_menu.rows.filter(func(row): return row.get("key") == "watch_color")
	check(watch_rows.size() == 1 and watch_rows[0].get("swatches", false) and watch_rows[0].choices.size() == 5,
		"Display offers five inline watch color swatches")
	var watch_index: int = main.recent_menu.rows.find(watch_rows[0])
	check(main.recent_menu.rows[watch_index - 1].key == "show_fps", "Watch color sits directly below Show FPS")
	main.recent_menu._set_scroll(main.recent_menu._max_scroll())
	for option in Palette.OPTIONS:
		var target := -1
		for id in main.recent_menu.choices.targets:
			var item: Dictionary = main.recent_menu.choices.targets[id]
			if item.get("key") == "watch_color" and item.get("value") == option.value: target = id
		check(target >= 0, "Visible watch color target: " + option.value)
		if target < 0: continue
		main.recent_menu.choices.action(target)
		settings.load(path)
		check(Palette.load_choice(settings) == option.value and main.wrist_watch.color_choice == option.value,
			"Swatch updates the live watch and persists: " + option.value)
		for material in main.wrist_watch._materials:
			check(material.get_shader_parameter("accent") == option.swatch and material.get_shader_parameter("secondary") == option.swatch,
				"All dial, control and projection materials share " + option.value)
	main.recent_menu._set_scroll(0)
	var rows: Array = main.recent_menu.rows.filter(func(row): return row.has("key") and row.key != "watch_color")
	check(rows.size() == 7 and rows[0].choices.size() == 4 and rows[0].choices[0].value == Quality.AUTO
		and rows[1].key == "refresh_cap" and rows[1].value == Quality.DEFAULT_REFRESH_CAP
		and rows[2].key == "supersampling" and rows[2].choices.size() == 3 and rows[2].value == 1
		and rows[3].key == "sharpness" and rows[3].choices.size() == 3 and rows[4].key == "show_fps",
		"Render scale, playback refresh rate, supersampling (off/normal/quality) and sharpness each occupy one field, followed by the FPS display")
	check(rows[-2].key == "playback_menu_depth" and rows[-2].choices.size() == 3 and rows[-2].value == "default",
		"Experimental VR playback control depth keeps its unchanged default above progress visibility")
	check(rows.back().key == "stick_seek_overlay" and rows.back().value and not rows.back().get("switch", false) and rows.back().choices.size() == 2,
		"Thumbstick progress visibility is the final Display row and defaults on")
	var refresh_values: Array = rows[1].choices.map(func(option): return option.value)
	var expected_caps: Array = Quality.refresh_choices(main.low_end_gpu)
	check(refresh_values == expected_caps and rows[1].choices.all(func(option): return str(option.label).contains("Hz") and not str(option.get("hint", "")).is_empty()),
		"Refresh choices name their rate in Hz and explain the trade-off")
	var explained := 0
	for button in main.recent_menu._buttons:
		var tip := str(main.recent_menu._tips.get(button.target, ""))
		if tip in [I18n.t(Quality.SCALE_INFO), I18n.t(Quality.REFRESH_INFO), I18n.t(Quality.SUPERSAMPLING_INFO), I18n.t(Quality.SHARPNESS_INFO)] and not button.enabled and button.get("hover_disabled", false): explained += 1
	check(explained == 4, "Pointing at the render scale, refresh rate, supersampling and sharpness titles explains them without making the rows clickable")
	check(rows[3].choices.all(func(option): return not str(option.get("hint", "")).is_empty())
		and main.recent_menu._tips.values().has(I18n.t(Quality.SHARPNESS_HINTS[2])), "Each sharpness choice has a technical hint")
	main._on_setting_changed("display_quality",2)
	main._on_setting_changed("sharpness",0.6)
	main._on_setting_changed("supersampling", 0)
	main._on_setting_changed("refresh_cap", 72)
	main._on_setting_changed("refresh_cap", 75)
	settings.load(path)
	check(Quality.load_supersampling(settings) == 0, "Supersampling off persists")
	check(Quality.load_refresh_cap(settings, false) == 72, "Power-saving refresh persists and unknown rates are ignored")
	var layer := preload("res://scripts/video_layer.gd").new(null)
	layer._settings = true
	for mode in 3:
		layer.supersampling = mode
		var filters := int(layer.layer_values(main.video, main.video.view_camera.get_parent())[18])
		check(filters & 3 == [0, 1, 2][mode] and filters & 8 != 0, "Layer supersampling %d is independent of sharpening" % mode)
	check(not bool(ProjectSettings.get_setting("xr/openxr/extensions/meta/dynamic_resolution", true)), "Runtime cannot silently lower chosen video/menu render quality")
	check(main.display.capabilities().meta_dynamic_resolution_enabled == false and main.display.capabilities().render_target_size_scope == "allocated_eye_buffer", "Diagnostics distinguish allocated buffers from dynamic render regions")
	check(main.display.render_scale == 1.1, "Quality keeps current XR targets until restart")
	check(main._library_settings().display_quality_pending, "Pending quality is visible")
	check(main.video.sharpness == 0.6 and main.photo.sharpness == 0.6, "Sharpness applies to both media types")
	check(main.photo._detail_material.get_shader_parameter("sharpness") == 0.6, "Photo magnifier matches")
	settings.load(path)
	check(Quality.load_quality(settings) == 2 and Quality.load_sharpness(settings) == 0.6, "Settings persist")
	main._on_setting_changed("sharpness",0.0)
	check(main.video.material.get_shader_parameter("sharpness") == 0.0, "Off restores neutral shader")
	var host := HostProbe.new()
	main.platform_plugin = host
	main.recent_menu._activate(main.recent_menu.RESTART_APP)
	main.recent_menu._activate(main.recent_menu.RESTART_APP)
	check(host.requests == [true], "Restart button calls Android once and saves settings")
	main.platform_plugin = null
	main.recent_menu.dismiss(); main.queue_free()
	await process_frame
	main = Main.new()
	main.settings_path = path
	root.add_child(main)
	check(main.display.render_scale == 1.25, "Restart applies saved quality globally")
	check(main.wrist_watch.color_choice == "white", "Restart restores the last watch color selected")
	main._on_setting_changed("watch_color", "unknown")
	check(main.wrist_watch.color_choice == "mint" and main._library_settings().watch_color == "mint", "Unknown color falls back consistently")
	check(not main._library_settings().display_quality_pending, "Restart clears pending label")
	check(not main.low_end_gpu and main.video.sharpness == 0.0, "Desktop renderer is not low end and keeps the saved sharpness")
	main.platform_plugin = host
	main.recent_menu._activate(main.recent_menu.QUIT_APP)
	check(host.requests == [true, false], "Close button requests actual application exit")
	main.platform_plugin = null
	main.recent_menu.dismiss(); main.queue_free()
	await process_frame
	DirAccess.remove_absolute(path)
	var fresh_path := "user://quality_low_end_%d.cfg" % Time.get_ticks_usec()
	var fresh := ConfigFile.new()
	fresh.set_value("appearance", "background", "dark")
	fresh.save(fresh_path)
	main = Main.new()
	main.settings_path = fresh_path
	main.gpu_adapter = "Adreno (TM) 650"
	root.add_child(main)
	check(main.display.render_scale == 1.0 and main._library_settings().display_quality == Quality.AUTO and not main._library_settings().display_quality_pending, "Low-end tier starts at Standard through auto quality")
	check(main.low_end_gpu and main.video.sharpness == 0.0 and main.photo.sharpness == 0.0, "Low-end tier starts without sharpening")
	check(main._library_settings().output_width == Quality.AUTO_OUTPUT and main._library_settings().sharpness == 0.0, "Menu shows auto output and sharpness off")
	main.recent_menu.section = main.recent_menu.Section.SETTINGS
	main.recent_menu.tab = main.recent_menu.VIDEO_TAB
	main.recent_menu.refresh()
	var resolution: Array = main.recent_menu.rows.filter(func(row): return row.get("key", "") == "output_width")
	check(resolution.size() == 1 and resolution[0].value == Quality.AUTO_OUTPUT and resolution[0].choices[0].value == Quality.AUTO_OUTPUT, "Resolution offers auto first")
	var memory_rows: Array = main.recent_menu.rows.filter(func(row): return row.get("key", "") == "memory_mode")
	check(memory_rows.size() == 1 and main.recent_menu.rows.find(memory_rows[0]) == main.recent_menu.rows.find(resolution[0]) + 1
		and memory_rows[0].value == Quality.MEMORY_AUTO and memory_rows[0].choices.size() == 3
		and memory_rows[0].choices.all(func(option): return not str(option.get("hint", "")).is_empty()),
		"Memory follows output resolution with auto, standard and saver")
	check(main.memory_saver, "XR2 Gen1 class GPU uses the memory saver automatically")
	main._on_setting_changed("memory_mode", Quality.MEMORY_STANDARD)
	check(not main.memory_saver and Quality.load_memory_choice(main.settings) == Quality.MEMORY_STANDARD, "Standard memory overrides the device and persists")
	main.recent_menu.dismiss(); main.queue_free()
	await process_frame
	DirAccess.remove_absolute(fresh_path)
	for failure in failures: push_error(failure)
	print("Global display quality: ", "passed" if failures.is_empty() else failures)
	quit(0 if failures.is_empty() else 1)
