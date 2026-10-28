extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")
const I18n := preload("res://scripts/i18n.gd")
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/bookmark-remote/previews")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 1200); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 72; viewport.add_child(camera)
	var platform := Fixture.Platform.new(); var menu := Menu.new(); camera.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	menu.set_process(false); menu.web_browser.saved_poll = Time.get_ticks_msec() + 60000; menu.web_browser.list_mode = "bookmarks"
	var failures := 0
	for language in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(language)
		for mode in ["list", "start", "direct", "code", "confirm"]:
			menu.web_browser.library.modal = "" if mode == "list" else "wifi_confirm" if mode == "confirm" else "wifi"
			menu.web_browser.saved = {"bookmarks": [{"title": "YouTube VR", "url": "https://youtube.com"}], "share": {"active": mode in ["direct", "code"], "url": "http://192.168.100.188:8791", "seconds": 1200, "requires_code": mode == "code", "code": "AKPW" if mode == "code" else ""}}
			menu.refresh()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			if viewport.get_texture().get_image().save_png(output.path_join(language + "-" + mode + ".png")) != OK: failures += 1
	menu.free(); platform.free(); viewport.queue_free(); await process_frame
	print("Bookmark share render: 20 layouts, %d failures" % failures)
	quit(0 if failures == 0 else 1)
