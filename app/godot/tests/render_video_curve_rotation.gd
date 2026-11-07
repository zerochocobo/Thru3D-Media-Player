extends SceneTree

const Video := preload("res://scripts/mpv_video_display.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/video-curve-rotation/preview")

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1200, 1000)
	viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 65; viewport.add_child(camera)
	var video := Video.new(); viewport.add_child(video); video.set_process(false)
	video.view_camera = camera
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
	video.set_screen_scale(2)
	video.set_screen_curve(120)
	video.panel.visible = true
	var count := 0
	for shape in ["landscape", "portrait"]:
		video.media.format = {"width": 1920 if shape == "landscape" else 1080, "height": 1080 if shape == "landscape" else 1920}
		for angle in [0, 90, 45]:
			video.set_screen_rotation(angle)
			for view in ["front", "side"]:
				camera.position = Vector3.ZERO if view == "front" else Vector3(2.2, 1.0, 0.2)
				camera.look_at(Vector3(0, 0, -3))
				await process_frame
				await RenderingServer.frame_post_draw
				await RenderingServer.frame_post_draw
				assert(viewport.get_texture().get_image().save_png(output.path_join("%s-%d-%s.png" % [shape, angle, view])) == OK)
				count += 1
	viewport.free()
	print("Video curve rotation render: %d images, 0 failures" % count)
	quit()
