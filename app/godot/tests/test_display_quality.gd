extends SceneTree
const Quality := preload("res://scripts/display_quality.gd")
const Main := preload("res://scripts/main.gd")
const I18n := preload("res://scripts/i18n.gd")
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
	check(Quality.load_sharpness(settings) == 0.2, "Default sharpness is gentle")
	for adapter in ["Adreno (TM) 650", "Adreno (TM) 540"]:
		check(Quality.is_low_end_gpu(adapter), "XR2 Gen1 class is low end: " + adapter)
	for adapter in ["Adreno (TM) 740", "Adreno (TM) 830", "NVIDIA GeForce RTX 3060", ""]:
		check(not Quality.is_low_end_gpu(adapter), "Not low end: " + adapter)
	check(Quality.load_sharpness(settings, true) == 0.0, "Low-end devices default to no sharpening")
	check(Quality.load_output_choice(settings) == Quality.AUTO_OUTPUT, "Output width defaults to auto")
	check(Quality.output_width(Quality.AUTO_OUTPUT, true) == 4096 and Quality.output_width(Quality.AUTO_OUTPUT, false) == 0, "Auto output follows tier")
	check(Quality.output_width(0, true) == 0 and Quality.output_width(5760, true) == 5760, "Explicit output width is respected")
	var explicit := ConfigFile.new()
	explicit.set_value("video", "output_width", 0)
	explicit.set_value("video", "sharpness", 0.4)
	check(Quality.load_output_choice(explicit) == 0 and Quality.load_sharpness(explicit, true) == 0.6, "Saved choices override tier defaults")
	explicit.set_value("video", "sharpness", 0.6)
	check(Quality.load_sharpness(explicit) == 0.6, "The former High level stays at Quality strength")
	explicit.set_value("video", "output_width", 1234)
	check(Quality.load_output_choice(explicit) == Quality.AUTO_OUTPUT, "Unknown output width falls back to auto")
	var path := "user://quality_test_%d.cfg" % Time.get_ticks_usec()
	settings.set_value("appearance", "background", "dark")
	settings.save(path)
	var main := Main.new()
	main.settings_path = path
	root.add_child(main)
	main.recent_menu.section = main.recent_menu.Section.SETTINGS
	main.recent_menu.tab = main.recent_menu.DISPLAY_TAB
	main.recent_menu.refresh()
	var rows: Array = main.recent_menu.rows
	check(rows.size() == 5 and rows[0].choices.size() == 4 and rows[0].choices[0].value == Quality.AUTO
		and rows[1].key == "refresh_cap" and rows[1].value == Quality.DEFAULT_REFRESH_CAP
		and rows[2].key == "supersampling" and rows[2].choices.size() == 3 and rows[2].value == 1
		and rows[3].key == "sharpness" and rows[3].choices.size() == 3 and rows[4].key == "show_fps",
		"Render scale, playback refresh rate, supersampling (off/normal/quality) and sharpness each occupy one field, followed by the FPS display")
	var refresh_values: Array = rows[1].choices.map(func(option): return option.value)
	var expected_caps: Array = Quality.refresh_choices(main.low_end_gpu)
	check(refresh_values == expected_caps and rows[1].choices.all(func(option): return str(option.label).contains("Hz") and not str(option.get("hint", "")).is_empty()),
		"Refresh choices name their rate in Hz and explain the trade-off")
	var explained := 0
	for button in main.recent_menu._buttons:
		var tip := str(main.recent_menu._tips.get(button.target, ""))
		if tip in [I18n.t(Quality.SCALE_INFO), I18n.t(Quality.REFRESH_INFO), I18n.t(Quality.SUPERSAMPLING_INFO), I18n.t(Quality.SHARPNESS_INFO)] and not button.enabled and button.get("hover_disabled", false): explained += 1
	check(explained == 4, "Pointing at the render scale, refresh rate, supersampling and sharpness titles explains them without making the rows clickable")
	check(main.recent_menu.rows[3].choices.all(func(option): return not str(option.get("hint", "")).is_empty())
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
	main.queue_free()
	await process_frame
	main = Main.new()
	main.settings_path = path
	root.add_child(main)
	check(main.display.render_scale == 1.25, "Restart applies saved quality globally")
	check(not main._library_settings().display_quality_pending, "Restart clears pending label")
	check(not main.low_end_gpu and main.video.sharpness == 0.0, "Desktop renderer is not low end and keeps the saved sharpness")
	main.platform_plugin = host
	main.recent_menu._activate(main.recent_menu.QUIT_APP)
	check(host.requests == [true, false], "Close button requests actual application exit")
	main.platform_plugin = null
	main.queue_free()
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
	main.queue_free()
	await process_frame
	DirAccess.remove_absolute(fresh_path)
	for failure in failures: push_error(failure)
	print("Global display quality: ", "passed" if failures.is_empty() else failures)
	quit(0 if failures.is_empty() else 1)
