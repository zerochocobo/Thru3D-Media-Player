extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Test := preload("res://tests/test_web_video_panel.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("WEB_VIDEO_PREVIEW")
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	preload("res://scripts/i18n.gd").use("zh")
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1600, 1100); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 72; viewport.add_child(camera)
	var menu := Menu.new(); camera.add_child(menu)
	var platform := Test.Platform.new(); menu.attach_platform(platform); menu.toggle()
	menu._activate(Menu.NAV_BASE + Menu.Section.WEB)
	menu.web_video.address = "https://www.bilibili.com/video/BV13x41117TL/"
	menu.web_video.result = {"state": "ready", "title": "中文演示视频", "height": 1080, "uri": menu.web_video.address}
	menu.refresh()
	for i in 4: await process_frame; await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	var code := image.save_png(output.path_join("web-video-panel.png"))
	print("Web video preview saved: %s" % (code == OK))
	menu.free(); platform.free(); viewport.free()
	quit(0 if code == OK else 1)
