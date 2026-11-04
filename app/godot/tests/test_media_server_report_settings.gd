extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Main := preload("res://scripts/main.gd")
const Browser := preload("res://scripts/media_server_browser.gd")
const Reports := preload("res://scripts/media_server_playback.gd")
const Fixture := preload("res://tests/test_media_servers.gd")
var checks := 0
var failures: Array[String] = []

class Platform extends Fixture.Platform:
	var intervals: Array[int] = []
	func set_media_server_report_interval(value: int) -> void: intervals.append(value)

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func button(menu: Node, target: int) -> Dictionary:
	var matches: Array = menu._buttons.filter(func(item): return item.target == target)
	return {} if matches.is_empty() else matches.back()

func click(menu: Node, target: int) -> void:
	var item := button(menu, target)
	check(not item.is_empty(), "Ray control exists: %d" % target)
	if item.is_empty(): return
	var pose: Transform3D = item.node.global_transform
	var origin: Vector3 = pose.origin + pose.basis.z * 0.3
	var direction: Vector3 = -pose.basis.z
	check(int(menu.ray_hit(origin, direction).get("target", -1)) == target, "Ray reaches the visible control: %d" % target)
	menu.press_pointer("right_hand", origin, direction, true)
	menu.release_pointer("right_hand", origin, direction, true)

func _initialize() -> void: call_deferred("run")
func run() -> void:
	var path := "user://server-report-settings-%d.cfg" % Time.get_ticks_usec()
	var main := Main.new(); main.settings_path = path
	var platform := Platform.new(); main.platform_plugin = platform
	main._sync_server_report_interval()
	check(platform.intervals == [10000], "Fresh startup sends the ten-second default to native playback")
	for invalid in [null, "0.5", true, [], INF, NAN]:
		main.settings.set_value("media_server", "report_interval_ms", invalid)
		check(Reports.load_interval(main.settings) == 10000, "Invalid persisted interval uses the default")
	main.settings.erase_section("media_server")
	var viewport := SubViewport.new(); viewport.size = Vector2i(1400, 1000); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 65; viewport.add_child(camera)
	var menu := Menu.new(); camera.add_child(menu); menu.attach_platform(platform)
	menu.visible = true; menu.section = Menu.Section.MEDIA_SERVER; menu.status = ""
	menu.settings_provider = func(): return {Reports.INTERVAL_KEY: Reports.load_interval(main.settings)}
	menu.setting_changed.connect(main._on_setting_changed)
	var b: RefCounted = menu.server_browser; b.view = "servers"; menu.refresh()
	check(b.report_interval_ms() == 10000, "The global server menu initially shows ten seconds")
	click(menu, Browser.ACTION + 180)
	check(b.settings_open and b.modal_open(), "Gear opens the ray-driven settings menu")
	var scroll: float = menu.scroll; menu.stick_scroll(-1, 0.5); menu.stick_scroll_horizontal(1, 0.5)
	check(menu.scroll == scroll and not menu._in_list(Vector3.ZERO), "Settings prevents stick and drag input from reaching the underlying library")
	click(menu, Browser.ACTION + 185)
	check(b.report_interval_ms() == 9500 and platform.intervals.back() == 9500, "Minus immediately applies a half-second step to the native bridge")
	click(menu, Browser.ACTION + 187)
	check(b.report_interval_ms() == 10000 and not button(menu, Browser.ACTION + 187).enabled, "Reset restores ten seconds and becomes disabled")
	main._on_setting_changed(Reports.INTERVAL_KEY, 500); menu.refresh()
	check(not button(menu, Browser.ACTION + 185).enabled, "Minimum disables decrement")
	for step in range(2, 41):
		menu._activate(Browser.ACTION + 186)
		check(b.report_interval_ms() == step * 500, "All forty intervals are selectable without skipping steps")
	check(not button(menu, Browser.ACTION + 186).enabled, "Maximum disables increment")
	click(menu, Browser.ACTION + 185)
	check(b.report_interval_ms() == 19500, "Maximum can step back by half a second")
	click(menu, Browser.ACTION + 181)
	check(not b.settings_open and b.view == "servers", "Closing preserves the server browser page")
	for provider in ["emby", "jellyfin", "plex"]:
		b.server = {"id": provider, "provider": provider, "name": provider.capitalize()}
		b.view = "home"; b.capabilities = {"artwork": true, "home_layout": "libraries"}; menu.refresh()
		click(menu, Browser.ACTION + 180)
		check(b.report_interval_ms() == 19500, "Switching server or account retains the one global setting")
		b.back()
	var restored := Main.new(); restored.settings_path = path; restored.settings.load(path)
	restored.platform_plugin = platform; restored._sync_server_report_interval()
	check(Reports.load_interval(restored.settings) == 19500 and platform.intervals.back() == 19500, "A fresh application settings instance restores and applies the saved interval")
	var output := OS.get_environment("VRPP_SERVER_SETTINGS_PREVIEW")
	if not output.is_empty():
		DirAccess.make_dir_recursive_absolute(output)
		menu.cancel_pointer("right_hand"); menu.cancel_pointer("left_hand")
		for language in ["zh", "zh_Hant", "ja", "en"]:
			menu.I18n.use(language)
			for value in [500, 10000, 20000]:
				main._on_setting_changed(Reports.INTERVAL_KEY, value)
				b.view = "servers"; b.server = {}; b.settings_open = true; menu.refresh()
				await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
				check(viewport.get_texture().get_image().save_png(output.path_join("%s-%d.png" % [language, value])) == OK, "Localized settings preview saved")
	menu.visible = false; menu.free(); viewport.free(); restored.free(); main.free(); platform.free()
	DirAccess.remove_absolute(path)
	for failure in failures: push_error(failure)
	print("Media server report settings: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
