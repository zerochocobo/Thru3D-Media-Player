extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Test := preload("res://tests/test_web_browser_panel.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("WEB_VIDEO_PREVIEW")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1600, 1100); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 72; viewport.add_child(camera)
	var menu := Menu.new(); camera.add_child(menu)
	var platform := Test.Platform.new(); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	for language in ["zh", "en", "zh_Hant", "ja"]:
		preload("res://scripts/i18n.gd").use(language)
		for expanded in [false, true]:
			menu.web_video.home.expanded = expanded; menu.refresh()
			for i in 4: await process_frame; await RenderingServer.frame_post_draw
			var code := viewport.get_texture().get_image().save_png(output.path_join("web-home-%s-%s.png" % [language, "expanded" if expanded else "collapsed"]))
			if code != OK: quit(1); return
		if menu.web_video.home.visible_sites().size() < preload("res://scripts/web_video_sites.gd").FEATURED.size():
			menu.web_video.home.site_page = 1; menu.refresh()
			for i in 4: await process_frame; await RenderingServer.frame_post_draw
			if viewport.get_texture().get_image().save_png(output.path_join("web-home-%s-page2.png" % language)) != OK: quit(1); return
	menu.free(); platform.free(); viewport.free()
	print("Browser home: localized collapsed, expanded and pagination previews saved")
	quit()
