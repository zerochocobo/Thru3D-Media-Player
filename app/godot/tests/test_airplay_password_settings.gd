extends SceneTree
const Main := preload("res://scripts/main.gd")
const Menu := preload("res://scripts/library_menu.gd")
const KEY := "airplay_require_password"
var checks := 0
var failures: Array[String] = []

class Platform extends Node:
	var values: Array[bool] = []
	func airplay_receiver_require_password(value: bool) -> void: values.append(value)

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func click(menu: Node3D, value: bool) -> void:
	var target := -1
	for id in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[id]
		if item.get("key") == KEY and item.get("value") == value: target = int(id)
	check(target >= 0, "Both security choices are directly visible ray buttons")
	if target < 0: return
	var button: Dictionary = menu._buttons.filter(func(b): return b.target == target)[0]
	var pose: Transform3D = button.node.global_transform
	var origin := pose.origin + pose.basis.z * 0.3
	var direction := -pose.basis.z
	check(int(menu.ray_hit(origin, direction).get("target", -1)) == target, "Security choice receives the actual ray hit")
	menu.press_pointer("right_hand", origin, direction, true)
	menu.release_pointer("right_hand", origin, direction, true)

func _initialize() -> void: call_deferred("run")
func run() -> void:
	var path := "user://airplay-password-%d.cfg" % Time.get_ticks_usec()
	var main := Main.new(); main.settings_path = path
	var platform := Platform.new(); main.platform_plugin = platform
	main._sync_airplay_password()
	check(platform.values == [false], "First startup applies the default open mode")
	var viewport := SubViewport.new(); viewport.size = Vector2i(1400, 1000); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 65; viewport.add_child(camera)
	var menu := Menu.new(); camera.add_child(menu); menu.set_process(false)
	menu.section = Menu.Section.SETTINGS; menu.tab = Menu.GENERAL_TAB; menu.visible = true
	menu.settings_provider = func(): return {KEY: bool(main.settings.get_value("casting", KEY, false))}
	menu.setting_changed.connect(main._on_setting_changed)
	menu.refresh()
	var index := -1
	for i in menu.rows.size():
		if menu.rows[i].get("key") == KEY: index = i
	check(index >= 0 and not menu.rows[index].value, "General settings defaults to Off")
	check(menu.rows[index - 1].title == menu.I18n.t("Privacy settings") and menu.rows[index + 1].get("diagnostic_group", false), "The setting is below Privacy and above Diagnostics")
	menu._set_scroll(maxi(0, index - 3))
	click(menu, true)
	check(main.settings.get_value("casting", KEY) == true and platform.values.back(), "On persists the global option and applies it to native receiving")
	var restarted := Main.new(); restarted.settings_path = path; restarted.settings.load(path); restarted.platform_plugin = platform
	restarted._sync_airplay_password()
	check(restarted.settings.get_value("casting", KEY) == true and platform.values.back(), "A fresh application restores and applies On")
	menu.refresh(); click(menu, false)
	check(main.settings.get_value("casting", KEY) == false and not platform.values.back(), "Off persists globally and restores direct connection")
	restarted.settings.load(path); restarted._sync_airplay_password()
	check(not restarted.settings.get_value("casting", KEY) and not platform.values.back(), "A fresh application also restores Off")
	var applied := platform.values.size()
	main._on_setting_changed(KEY, "true")
	check(platform.values.size() == applied and not main.settings.get_value("casting", KEY), "A non-boolean event cannot enable access control")
	var output := OS.get_environment("VRPP_AIRPLAY_SETTINGS_PREVIEW")
	if not output.is_empty(): DirAccess.make_dir_recursive_absolute(output)
	for language in ["zh", "zh_Hant", "ja", "en"]:
		menu.I18n.use(language)
		for value in [true, false]:
			main._on_setting_changed(KEY, value); menu.refresh(); menu._set_scroll(maxi(0, index - 3))
			check(menu.rows[index].title == menu.I18n.t("Require AirPlay password"), "Security title is localized")
			var options: Array = menu.choices.targets.values().filter(func(item): return item.get("key") == KEY)
			check(options.size() == 2, "Only On and Off are offered without a dropdown")
			if not output.is_empty():
				menu.cancel_pointer("right_hand"); menu.cancel_pointer("left_hand")
				await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
				check(viewport.get_texture().get_image().save_png(output.path_join("%s-%s.png" % [language, "on" if value else "off"])) == OK, "Localized preview saved")
	menu.visible = false
	# Choice signals and deferred menu redraws may still hold these nodes this frame.
	menu.queue_free(); viewport.queue_free(); restarted.queue_free(); main.queue_free(); platform.queue_free()
	await process_frame; await process_frame
	DirAccess.remove_absolute(path)
	for failure in failures: push_error(failure)
	print("AirPlay password settings: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
