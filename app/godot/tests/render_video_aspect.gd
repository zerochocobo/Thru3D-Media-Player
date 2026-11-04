extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
var state := {"has_video":true,"source_uri":"file:///aspect-preview.mp4","geometry":0,"stereo":false,
	"screen_cinema":false,"screen_scene_locked":false,"screen_distance":2.0,"screen_scale":100.0,
	"screen_dimensions":Vector2(1.7778,1),"video_aspect_preset":"16:9","video_aspect_factor":1.0}
var failures: Array[String] = []
var frames := 0
var output := ProjectSettings.globalize_path("res://../../build/output/video-aspect-20261103/previews")

func _initialize() -> void: run.call_deferred()

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1400,1100); viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 65; viewport.add_child(camera)
	var menu := Menu.new(); menu.state_provider = func(): return state
	camera.add_child(menu); menu.set_process(false); menu.visible = true
	menu.position = Vector3(0,-0.5,-1.5)
	menu.section = 1; menu._adjustment = "screen"
	for language in ["zh","zh_Hant","en","ja"]:
		Menu.I18n.use(language)
		for cinema in [false,true]:
			state.screen_scene_locked = cinema; state.stereo = cinema
			menu.refresh()
			await snapshot(viewport, camera, menu, "%s-%s" % [language,"cinema" if cinema else "flat"])
	Menu.I18n.use("zh"); state.screen_scene_locked = false; state.screen_cinema = true; state.stereo = true
	menu.refresh(); await snapshot(viewport, camera, menu, "zh-upright")
	menu.choices.opened = "video_aspect_preset"; menu.refresh()
	await snapshot(viewport, camera, menu, "zh-presets-top")
	menu.choices.offset = 2; menu.refresh()
	await snapshot(viewport, camera, menu, "zh-presets-bottom")
	menu.queue_free(); viewport.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Video aspect render: %d frames, %d failures" % [frames,failures.size()])
	quit(0 if failures.is_empty() else 1)

func snapshot(viewport: SubViewport, camera: Camera3D, menu: Node3D, name: String) -> void:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	for button in menu._buttons:
		if not button.node.is_visible_in_tree(): continue
		var mesh_size: Vector2 = button.node.mesh.size
		for x in [-0.5,0.5]:
			for y in [-0.5,0.5]:
				var point: Vector2 = camera.unproject_position(button.node.to_global(Vector3(mesh_size.x*x,mesh_size.y*y,0)))
				if not Rect2(Vector2.ZERO,viewport.size).has_point(point): failures.append(name + " button outside preview: " + str(button.target))
	var row: Dictionary = menu._adjust_rows[Menu.VIDEO_ASPECT_FACTOR]
	if not is_equal_approx(row.knob.position.x, row.left + row.width*0.5): failures.append(name + " ratio center marker mismatch")
	viewport.get_texture().get_image().save_png(output.path_join(name + ".png")); frames += 1
