extends SceneTree
const PhotoMenu := preload("res://scripts/photo_menu.gd")
const VideoMenu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")

func _initialize() -> void: run.call_deferred()
func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/photo-mode-default/previews")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1440, 900); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 50; viewport.add_child(camera)
	var state := {"has_image":true,"has_video":true,"geometry":0,"stereo":false,"title":"Travel journal","reuse_last_mode":false}
	var frames := 0
	for kind in ["photo","video"]:
		var menu: Node3D = PhotoMenu.new() if kind == "photo" else VideoMenu.new()
		menu.state_provider = func(): return state
		camera.add_child(menu); menu.set_process(false); menu.visible = true
		menu.position.y = -.49; menu._mode_open = true
		for language in ["zh","zh_Hant","ja","en"]:
			I18n.use(language)
			for projection in [0,2]:
				for enabled in [false,true]:
					state.geometry = projection; state.stereo = projection == 2; state.reuse_last_mode = enabled
					menu.refresh(); menu._hover = {}; menu._update_tooltip()
					await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
					viewport.get_texture().get_image().save_png(output.path_join("%s-%s-%d-%s.png" % [kind,language,projection,"on" if enabled else "off"]))
					frames += 1
		menu.free()
	viewport.queue_free(); await process_frame
	print("Photo/video mode default comparison: %d frames" % frames)
	quit(0)
