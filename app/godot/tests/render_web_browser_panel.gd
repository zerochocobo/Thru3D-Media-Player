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
	platform.browser.tab_id = 1
	if "--loading" in OS.get_cmdline_user_args():
		platform.browser.loading = true; platform.browser.progress = 42
	platform.browser.network_capture_available = true
	if "--beta" in OS.get_cmdline_user_args():
		platform.browser.bilibili_beta_available = true
		platform.browser.videos[0].bilibili_ready = "--unready" not in OS.get_cmdline_user_args()
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
		if "--focus-select" in OS.get_cmdline_user_args():
			host.toggle_focus(); host.selection = Rect2(0.18, 0.16, 0.55, 0.60)
		elif "--focused" in OS.get_cmdline_user_args():
			menu.web_browser.focus_regions[host.focus_tab()] = Rect2(0.18, 0.16, 0.30, 0.70)
	menu.refresh()
	if "--portrait-drag" in OS.get_cmdline_user_args() and not library_preview:
		var host: Node3D = menu.web_browser.windows[1]
		var requested_height := 3.2 if "--portrait-tall" in OS.get_cmdline_user_args() else 2.56
		var pose: Transform3D = host.global_transform
		var handle: Dictionary = host._buttons.filter(func(button): return button.target == host.RESIZE_BOTTOM)[0]
		var start := Vector3(handle.rect.get_center().x, handle.rect.get_center().y, 0.3)
		host.press_pointer("left", pose * start, -pose.basis.z, true)
		for step in range(1, 81):
			host.update_pointer("left", pose * (start + Vector3(0, -(requested_height - 0.9) * step / 80.0, 0)), -pose.basis.z, true)
		host.release_pointer("left", pose * start, -pose.basis.z, true)
		var layout: Dictionary = host.full_page_layout()
		if not layout.size.is_equal_approx(Vector2(1.44, requested_height)):
			push_error("Portrait drag did not reach requested dimensions: " + str(layout.size)); quit(1); return
		camera.position = layout.pose.origin + Vector3(0, 0.2, 3.1)
		var evidence := {"input": "80 production pointer updates on bottom edge", "physical_width": layout.size.x, "physical_height": layout.size.y,
			"css": str(host.Surface.logical_for(host.page_size)), "normal_pixels": str(host.Surface.pixels_for(host.page_size, false)), "low_pixels": str(host.Surface.pixels_for(host.page_size, true))}
		FileAccess.open(output.path_join("portrait-drag-%s.json" % requested_height), FileAccess.WRITE).store_string(JSON.stringify(evidence, "\t"))
	if "--minimum" in OS.get_cmdline_user_args() and not library_preview:
		menu.web_browser.windows[1].adjust_size(-100)
	if "--resize-hover" in OS.get_cmdline_user_args() and not library_preview:
		var host: Node3D = menu.web_browser.windows[1]
		var handle: Dictionary = host._buttons.filter(func(button): return button.target == host.RESIZE)[0]
		host.update_pointer("left", handle.node.global_position + host.global_basis.z.normalized() * 0.3, -host.global_basis.z, true)
	if "--depth" in OS.get_cmdline_user_args():
		menu.web_browser.windows[1].depth.enabled = true
		menu.web_browser.windows[1].depth.state = "ready"
		menu.web_browser.windows[1].refresh()
	if "--depth-settings" in OS.get_cmdline_user_args():
		menu.web_browser.windows[1].depth_settings = true
		menu.web_browser.windows[1].refresh()
	if "--matte" in OS.get_cmdline_user_args():
		menu.web_browser.windows[1].depth.matte = true
		menu.web_browser.windows[1].refresh()
	if "--effect-controls" in OS.get_cmdline_user_args():
		var host: Node3D = menu.web_browser.windows[1]
		if "--depth-boost" in OS.get_cmdline_user_args(): host.depth.strength=1.5
		var page: Dictionary = host.page_layout()
		var origin: Vector3 = page.pose * Vector3(0,0,0.4)
		host.effect_controls.observe_ray("right",origin,-page.pose.basis.z,true,1000)
		host.effect_controls.observe_ray("right",origin,-page.pose.basis.z,true,1125)
		host.effect_controls.set_strength_open(true)
		if "--depth-startup" in OS.get_cmdline_user_args():
			host.depth.state="preparing"
			var button: Dictionary = host.effect_controls._buttons.filter(func(b): return b.target==host.effect_controls.DEPTH)[0]
			var ray: Vector3 = button.node.global_position+host.effect_controls.global_basis.z.normalized()*.2
			host.effect_controls.observe_ray("right",ray,-host.effect_controls.global_basis.z.normalized(),true,1150)
		host.set_process(false)
		camera.position = Vector3(0,-0.3,0.3)
	if "--toolbar-preview" in OS.get_cmdline_user_args():
		viewport.size=Vector2i(1600,600);camera.fov=24;camera.position=Vector3(0,.626,0)
	for i in 4: await process_frame; await RenderingServer.frame_post_draw
	var suffix := "-focus-select" if "--focus-select" in OS.get_cmdline_user_args() else "-focused" if "--focused" in OS.get_cmdline_user_args() else "-loading" if "--loading" in OS.get_cmdline_user_args() else "-wide" if "--wide" in OS.get_cmdline_user_args() else "-tall" if "--tall" in OS.get_cmdline_user_args() else "-cinema" if "--cinema-available" in OS.get_cmdline_user_args() else ""
	if "--minimum" in OS.get_cmdline_user_args(): suffix += "-minimum"
	if "--depth-settings" in OS.get_cmdline_user_args(): suffix += "-depth-settings"
	elif "--depth" in OS.get_cmdline_user_args(): suffix += "-depth"
	if "--matte" in OS.get_cmdline_user_args(): suffix += "-matte"
	if "--effect-controls" in OS.get_cmdline_user_args(): suffix += "-effect-controls"
	if "--depth-boost" in OS.get_cmdline_user_args(): suffix += "-boost"
	if "--depth-startup" in OS.get_cmdline_user_args(): suffix += "-startup"
	if "--toolbar-preview" in OS.get_cmdline_user_args(): suffix += "-toolbar"
	if "--resize-hover" in OS.get_cmdline_user_args(): suffix += "-resize-hover"
	if "--portrait-drag" in OS.get_cmdline_user_args(): suffix += "-portrait-tall" if "--portrait-tall" in OS.get_cmdline_user_args() else "-portrait"
	var code := viewport.get_texture().get_image().save_png(output.path_join("web-browser" + suffix + ".png" if not suffix.is_empty() else "web-browser-tabs.png" if "--tabs" in OS.get_cmdline_user_args() else "web-browser-keyboard.png" if platform.browser.editing else ("web-browser-history.png" if "--history" in OS.get_cmdline_user_args() else "web-browser-controls.png")))
	print("Browser control preview saved; Android webpage Surface is absent on desktop: %s" % (code == OK))
	menu.free(); platform.free(); viewport.free()
	quit(0 if code == OK else 1)
