extends SceneTree
const Video := preload("res://scripts/mpv_video_display.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void: call_deferred("_run")

func centroid(pixels: Image) -> Vector2:
	var mass := 0.0
	var total := Vector2.ZERO
	for y in pixels.get_height():
		for x in pixels.get_width():
			var c := pixels.get_pixel(x, y)
			var weight := maxf(0, minf(c.r, minf(c.g, c.b)) - 0.5)
			mass += weight; total += Vector2(x, y) * weight
	if mass < 2: failures.append("Missing subtitle pixels")
	return total / maxf(mass, 0.001)

func _run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/subtitle-center/projection")
	DirAccess.make_dir_recursive_absolute(output)
	preload("res://scripts/i18n.gd").use("zh")
	var viewport := SubViewport.new(); viewport.size = Vector2i(1000, 800); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var head := Camera3D.new(); viewport.add_child(head); head.position.y = 1.6
	var eye := Camera3D.new(); viewport.add_child(eye); eye.position.y = 1.6; eye.fov = 90; eye.make_current()
	var video := Video.new(); viewport.add_child(video); video.set_process(false); video.view_camera = head
	video.caption.text = "田"; video.caption.visible = true
	var shader := Shader.new()
	var source: String = load("res://shaders/video_rvm_pair.gdshader").code
	shader.code = source.replace("void vertex() {", "uniform int probe_eye = 0;\nvoid vertex() {").replace("eye_index = int(VIEW_INDEX);", "eye_index = probe_eye;")
	video.material.shader = shader
	var color := Image.create(2, 2, false, Image.FORMAT_RGB8); color.fill(Color(0.1, 0.2, 0.35))
	video.material.set_shader_parameter("color_texture", ImageTexture.create_from_image(color))
	video.material.set_shader_parameter("source_size", Vector2(2, 2)); video.material.set_shader_parameter("model_size", Vector2(2, 2))
	video.material.set_shader_parameter("sharpness", 0)
	for geometry in [1, 2, 3]:
		video.geometry = geometry; video._apply_geometry(); video.panel.visible = true
		for direction in [0, 1]:
			video.subtitle_direction = direction
			for center in [Vector2.ZERO, Vector2(-20, -15), Vector2(25, 18)]:
				video.subtitle_horizontal_position = center.x; video.subtitle_vertical_position = center.y
				video.subtitle_distance = 5.0; video._place_caption()
				for index in 2:
					eye.position.x = (index - 0.5) * 0.064; video.material.set_shader_parameter("probe_eye", index)
					await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
					var pixels := viewport.get_texture().get_image()
					var actual := centroid(pixels)
					var expected := eye.unproject_position(video.projected_subtitles.plane_pose.origin)
					checks += 1
					if actual.distance_to(expected) > 3.0: failures.append("Centre mismatch geometry=%d direction=%d center=%s eye=%d actual=%s expected=%s" % [geometry, direction, center, index, actual, expected])
					if pixels.save_png(output.path_join("geometry%d-direction%d-x%d-y%d-eye%d.png" % [geometry, direction, center.x, center.y, index])) != OK: failures.append("Save failed")
	video.free(); viewport.free()
	for failure in failures: push_error(failure)
	print("Subtitle centre render checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
