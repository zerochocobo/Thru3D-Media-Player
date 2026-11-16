extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Fixture := preload("res://tests/test_web_browser_panel.gd")
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/web-bookmark-preview")
	DirAccess.make_dir_recursive_absolute(output)
	var picture := Image.create(384, 216, false, Image.FORMAT_RGB8)
	picture.fill(Color("24465b"))
	picture.fill_rect(Rect2i(0, 130, 384, 86), Color("32676b"))
	picture.fill_rect(Rect2i(55, 42, 70, 70), Color("f3bd71"))
	var path := output.path_join("fixture.jpg"); picture.save_jpg(path)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1600, 1200); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 72; viewport.add_child(camera)
	var platform := Fixture.Platform.new(); var menu := Menu.new(); camera.add_child(menu); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	menu.set_process(false); menu.web_browser.saved_poll = Time.get_ticks_msec() + 60000; menu.web_browser.list_mode = "bookmarks"
	var entries: Array = []
	for i in 20:
		entries.append({"title": ["故宫 8K · 第二集", "稍后再看", "收藏夹里的视频", "没有截图的旧书签"][i % 4], "url": "https://example.com/video/%d" % i, "preview_path": path if i % 4 != 3 else ""})
	menu.web_browser.saved = {"bookmarks": entries}
	preload("res://scripts/i18n.gd").use("zh")
	for mode in ["grid", "manage", "list"]:
		menu.web_browser.library.preview_mode = mode != "list"
		menu.web_browser.library.managing = mode == "manage"
		menu.web_browser.library.selection = {"https://example.com/video/0": true}
		menu.refresh()
		await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png(output.path_join(mode + ".png"))
	platform.browser.merge({"url": "about:blank", "tab_id": 1, "start_page": true}, true)
	platform.library = {"bookmarks": entries}
	menu.web_browser.library.preview_mode = true; menu.web_browser.library.managing = false
	menu.web_browser.open(); menu.web_browser.tick()
	var host: Node3D = menu.web_browser.windows[1]
	host.reparent(viewport); host.set_process(false)
	host.global_transform = Transform3D(Basis.IDENTITY, Vector3(-0.13, -0.12, -1.65))
	menu.position.x = 100; host.refresh()
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png(output.path_join("start-page.png"))
	menu.free(); platform.free(); viewport.queue_free(); await process_frame
	print("Bookmark preview render complete")
	quit()
