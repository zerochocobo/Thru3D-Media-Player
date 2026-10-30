extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Test := preload("res://tests/test_web_browser_panel.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("WEB_VIDEO_PREVIEW")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	preload("res://scripts/i18n.gd").use("zh")
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1600, 1400 if "--keyboard" in OS.get_cmdline_user_args() else 1100); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 95 if "--keyboard" in OS.get_cmdline_user_args() else 72; viewport.add_child(camera)
	var menu := Menu.new(); camera.add_child(menu)
	var platform := Test.Platform.new(); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	var library_preview: bool = "--history" in OS.get_cmdline_user_args() or "--bookmarks" in OS.get_cmdline_user_args()
	if library_preview:
		menu.web_browser.list_mode = "bookmarks" if "--bookmarks" in OS.get_cmdline_user_args() else "history"
		menu.web_browser.saved_poll = Time.get_ticks_msec() + 60000
		var samples := [{"title": "浏览历史中的长视频标题：".repeat(8), "url": "https://www.bilibili.com/video/BV13x41117TL/?" + "long_tracking_parameter=1234567890&".repeat(25)},
			{"title": "YouTube · VR180 收藏", "url": "https://www.youtube.com/watch?v=9r6NI9m_IxM"},
			{"title": "我的全景视频", "url": "https://www.example.com/videos/360"}]
		menu.web_browser.saved = {"history": samples, "bookmarks": samples}
		var panel: RefCounted = menu.web_browser.library
		if "--manage" in OS.get_cmdline_user_args():
			panel.managing = true; panel.selection[str(samples[0].url)] = true
		if "--editor" in OS.get_cmdline_user_args(): panel._edit(samples[0])
		if "--confirm" in OS.get_cmdline_user_args(): panel.action(panel.BASE + panel.Action.CLEAR)
	else: menu.web_browser.open("https://www.bilibili.com/video/BV13x41117TL/")
	platform.browser.title = "中文视频标题"
	platform.browser.network_capture_available = true
	if "--beta" in OS.get_cmdline_user_args():
		platform.browser.bilibili_beta_available = true
		platform.browser.network_capture_available = false
	platform.browser.network_capture_enabled = "--capture" in OS.get_cmdline_user_args()
	if "--tabs" in OS.get_cmdline_user_args():
		platform.browser.tab_id = 2
		platform.browser.tabs = 4
		platform.browser.tab_list = [
			{"id": 1, "window": 1, "title": "哔哩哔哩", "url": "https://www.bilibili.com/"},
			{"id": 2, "window": 1, "title": "中文视频标题", "url": platform.browser.url},
			{"id": 3, "window": 1, "title": "YouTube VR180", "url": "https://www.youtube.com/", "sleeping": true},
			{"id": 4, "window": 1, "title": "全景视频收藏", "url": "https://example.com/360", "sleeping": true}]
	platform.browser.editing = "--keyboard" in OS.get_cmdline_user_args()
	if "--start-page" in OS.get_cmdline_user_args():
		platform.browser.url = "about:blank"; platform.browser.title = ""; platform.browser.native_supported = false
		platform.library.bookmarks = [{"title": "Emby · 家庭影院", "url": "http://192.168.31.185:8096"}, {"title": "我的长标题收藏".repeat(6), "url": "https://example.com"}]
	if "--windows" in OS.get_cmdline_user_args():
		platform.browser.focused_window = 1; platform.browser.tab_id = 1
		platform.browser.windows = []
		platform.browser.tab_list = []
		for id in range(1, 5):
			var title: String = ["Emby · 家庭影院", "哔哩哔哩 · 我的收藏", "中文视频标题：".repeat(6), "网页资料"][id - 1]
			platform.browser.windows.append({"id": id, "tab_id": id, "title": title, "url": "https://example.com/" + str(id)})
			platform.browser.tab_list.append({"id": id, "window": id, "title": title, "url": "https://example.com/" + str(id)})
	if not library_preview:
		menu.web_browser.tick()
		if "--site-menu" in OS.get_cmdline_user_args(): menu.web_browser.tabs_open = true
		if "--merge" in OS.get_cmdline_user_args(): menu.web_browser.action(menu.web_browser.BASE + 16)
		var host: Node3D = menu.web_browser.windows[1]
		if "--wide" in OS.get_cmdline_user_args(): host.page_size = Vector2(2.4, 0.65)
		if "--tall" in OS.get_cmdline_user_args(): host.page_size = Vector2(1.44, 1.8)
		if "--cinema-available" in OS.get_cmdline_user_args():
			menu.web_browser.cinema_provider = func(): return {"position": [0, 3, -12], "width": 10.0, "height": 5.625}
		host.reparent(viewport); host.global_transform = Transform3D(Basis.IDENTITY, Vector3(-0.13, 0.0, -1.65))
		if "--wide" in OS.get_cmdline_user_args() or "--tall" in OS.get_cmdline_user_args():
			host.global_position = Vector3(-host.CENTRE.x, -host.CENTRE.y, -2.1)
	menu.refresh()
	for i in 4: await process_frame; await RenderingServer.frame_post_draw
	var suffix := "-wide" if "--wide" in OS.get_cmdline_user_args() else "-tall" if "--tall" in OS.get_cmdline_user_args() else "-cinema" if "--cinema-available" in OS.get_cmdline_user_args() else ""
	var code := viewport.get_texture().get_image().save_png(output.path_join("web-browser" + suffix + ".png" if not suffix.is_empty() else "web-browser-tabs.png" if "--tabs" in OS.get_cmdline_user_args() else "web-browser-keyboard.png" if platform.browser.editing else ("web-browser-history.png" if "--history" in OS.get_cmdline_user_args() else "web-browser-controls.png")))
	print("Browser control preview saved; Android webpage Surface is absent on desktop: %s" % (code == OK))
	menu.free(); platform.free(); viewport.free()
	quit(0 if code == OK else 1)
