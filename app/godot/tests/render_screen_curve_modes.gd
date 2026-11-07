extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/screen-curve-modes/previews")

func _initialize() -> void: _run.call_deferred()

func snapshot(viewport: SubViewport, filename: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	assert(viewport.get_texture().get_image().save_png(output.path_join(filename + ".png")) == OK)

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1200, 1200)
	viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 65; viewport.add_child(camera)
	var video := Video.new(); viewport.add_child(video); video.set_process(false)
	video.view_camera = camera; video.set_curve_modes_available(true)
	var picture := Image.create(480, 270, false, Image.FORMAT_RGB8)
	for y in 270:
		for x in 480:
			var color := Color(0.04, 0.2, 0.3).lerp(Color(0.1, 0.6, 0.65), y / 270.0)
			if x % 60 < 3 or y % 45 < 3: color = Color(0.85, 0.95, 0.95)
			if y < 12: color = Color(1, 0.5, 0.12)
			if x < 12: color = Color(0.2, 0.85, 0.4)
			picture.set_pixel(x, y, color)
	video.material.set_shader_parameter("color_texture", ImageTexture.create_from_image(picture))
	video.material.set_shader_parameter("source_size", Vector2(480, 270))
	video.material.set_shader_parameter("alpha_enabled", false)
	video.set_flat_world_pose(Transform3D(Basis.IDENTITY, Vector3(0, 0, -3)))
	video.set_screen_scale(2); video.set_screen_curve(150); video.panel.visible = true
	var count := 0
	for mode in ["horizontal", "vertical", "spherical"]:
		video.set_screen_curve_mode(mode)
		for rotation in [0, 90]:
			video.set_screen_rotation(rotation)
			for view in ["front", "side"]:
				camera.position = Vector3.ZERO if view == "front" else Vector3(2.2, 1.0, 0.2)
				camera.look_at(Vector3(0, 0, -3))
				await snapshot(viewport, "%s-%d-%s" % [mode, rotation, view]); count += 1
	video.free()
	camera.position = Vector3(0, 0.35, 0); camera.rotation = Vector3.ZERO
	for language in ["zh", "en", "ja"]:
		I18n.use(language)
		for mode in ["horizontal", "vertical", "spherical"]:
			var state := {"has_video": true, "geometry": 0, "screen_curve": 150.0, "screen_curve_mode": mode,
				"screen_curve_modes_available": true, "screen_cinema": false, "screen_scale": 100, "screen_distance": 2,
				"screen_dimensions": Vector2(3.2, 1.35), "source_uri": "file:///curve-modes.mp4", "title": "Cinema", "playing": true}
			var menu := Menu.new(); menu.state_provider = func(): return state
			camera.add_child(menu); menu.position = Vector3(0, -0.15, -2)
			menu.set_process(false); menu.toggle(); menu._adjustment = "screen"; menu.refresh()
			assert(menu.choices.targets.values().any(func(item): return item.get("key") == "screen_curve_mode"))
			assert(menu.choices.targets.values().filter(func(item): return item.get("key") == "screen_curve_mode" and item.get("kind") == "choose").size() == 3)
			assert(not menu.choices.targets.values().any(func(item): return item.get("key") == "screen_curve_mode" and item.get("kind") == "open"))
			assert(menu._adjust_rows[Menu.SCREEN_CURVE_SLIDER].span.y == 180)
			await snapshot(viewport, "menu-%s-%s" % [language, mode]); count += 1
			menu.free()
	viewport.free()
	print("Screen curve modes render: %d images, 0 failures" % count)
	quit()
