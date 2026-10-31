extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Platform := preload("res://tests/account_platform_fixture.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("ACCOUNT_LOGIN_PREVIEW")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1200, 1400); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.size = 3.4; viewport.add_child(camera)
	var menu := Menu.new(); viewport.add_child(menu); menu.position = Vector3(0, -0.04, -2)
	var platform := Platform.new(); menu.attach_platform(platform); menu.visible = true; menu.section = Menu.Section.CLOUD
	var panel: RefCounted = menu.account_panel; panel.start("cloud", "quark_open")
	var state: Dictionary = platform.account_sessions[panel.session]
	state.state = "web"
	state.web = {"renderer": "gecko", "width": 440, "height": 600, "desktop": false, "status": "", "navigation": 1}
	state.revision += 1
	# Synthetic login/drag fixture only; this does not claim to render a real Quark page on desktop.
	var image := Image.new()
	image.load_svg_from_string('<svg xmlns="http://www.w3.org/2000/svg" width="480" height="600"><rect width="480" height="600" fill="#f1f4f8"/><rect x="36" y="80" width="408" height="440" rx="20" fill="white"/><circle cx="240" cy="135" r="24" fill="#3778ec"/><rect x="72" y="200" width="336" height="50" rx="9" fill="#e9edf3"/><rect x="72" y="270" width="336" height="50" rx="9" fill="#e9edf3"/><rect x="72" y="340" width="336" height="90" rx="9" fill="#c4d9da"/><path d="M90 410L166 359L230 395L300 360L390 412" fill="none" stroke="#86b8b2" stroke-width="8"/><rect x="72" y="448" width="336" height="40" rx="8" fill="#e9edf3"/><rect x="72" y="448" width="52" height="40" rx="8" fill="#3778ec"/><path d="M89 468H108M102 460L110 468L102 476" fill="none" stroke="white" stroke-width="3"/></svg>')
	var texture := ImageTexture.create_from_image(image)
	for mode in ["mobile", "focused", "selection", "desktop", "baidu", "error"]:
		panel.provider = "baidu" if mode == "baidu" else "quark_open"
		menu.I18n.use("ja" if mode == "error" else "en" if mode == "desktop" else "zh")
		state.web.desktop = mode in ["desktop", "baidu"]; state.web.desktop_only = mode == "baidu"
		state.web.width = 1200 if state.web.desktop else 440
		state.web.height = 720 if state.web.desktop else 600
		state.web.failed = mode == "error"; state.web.status = "Page unavailable. Try reloading." if mode == "error" else ""
		state.web.loading = mode == "mobile"; state.web.progress = 65
		panel.poll(); panel.web_focus = Rect2(0.1, 0.5, 0.8, 0.35) if mode == "focused" else panel.Focus.FULL
		panel.web_selecting = mode == "selection"; panel.web_hand = "right_hand" if mode == "selection" else ""
		panel.web_selection = Rect2(0.1, 0.5, 0.8, 0.35)
		menu.refresh()
		var rect: Rect2 = panel.web_rect()
		var crop := ImageTexture.create_from_image(image.get_region(Rect2i(panel.web_focus.position * Vector2(480, 600), panel.web_focus.size * Vector2(480, 600))))
		var page: MeshInstance3D = panel.texture_node(crop, rect.get_center(), rect.size)
		page.set_meta("menu_eye_buffer", true)
		for i in 4: await process_frame; await RenderingServer.frame_post_draw
		var result := viewport.get_texture().get_image().save_png(output.path_join(mode + ".png"))
		if result != OK: quit(1); return
	menu._activate(menu.CLOSE); menu.toggle()
	for i in 4: await process_frame; await RenderingServer.frame_post_draw
	if viewport.get_texture().get_image().save_png(output.path_join("returned-library.png")) != OK: quit(1); return
	menu.free(); platform.free(); viewport.free()
	print("Account login layout previews saved; page content is a synthetic fixture.")
	quit(0)
