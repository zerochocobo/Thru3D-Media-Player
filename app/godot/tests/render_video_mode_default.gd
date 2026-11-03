extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")

func _initialize() -> void: _run.call_deferred()
func _run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/video-mode-default/right-aligned")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1600, 1100); viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var state := {"has_video": true, "geometry": 0, "stereo": false, "title": "Travel journal", "reuse_last_mode": false}
	var menu := Menu.new(); menu.state_provider = func(): return state
	camera.add_child(menu); menu.set_process(false); menu.visible = true; menu.position.y = -0.45; menu._mode_open = true
	for language in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(language)
		for projection in [0, 2]:
			viewport.size = Vector2i(1600, 1100); camera.keep_aspect = Camera3D.KEEP_HEIGHT; camera.fov = 60; menu.position.y = -0.45
			state.geometry = projection; state.stereo = projection == 2; state.reuse_last_mode = projection == 2
			menu.refresh()
			# Keep the setting and surrounding controls unobscured in layout review screenshots.
			menu._hover = {}; menu._update_tooltip()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join("%s-%d.png" % [language, projection]))
			viewport.size = Vector2i(1440, 560); camera.keep_aspect = Camera3D.KEEP_WIDTH; camera.fov = 50
			menu.position.y = -0.485 if projection == 2 else -0.43
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join("%s-%d-detail.png" % [language, projection]))
	viewport.queue_free(); await process_frame
	print("Video mode default renders: 16 frames")
	quit(0)
