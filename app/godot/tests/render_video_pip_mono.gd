extends SceneTree
## Render both production display-eye paths. Mono PiP must remain pixel-identical
## for every source layout, projection, magnification and explicit source eye.
const PipWindow := preload("res://scripts/video_pip_window.gd")
var checks := 0
var failures: Array[String] = []
var views: Array[SubViewport] = []
var windows: Array[Node3D] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	for eye in 2:
		var viewport := SubViewport.new(); viewport.size = Vector2i(256, 144)
		viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(viewport); views.append(viewport)
		var camera := Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.size = 0.27
		viewport.add_child(camera)
		var window := PipWindow.new(); viewport.add_child(window); windows.append(window)
		window.position.z = -2; window.frame.visible = true
		var shader := Shader.new()
		shader.code = window.picture.shader.code.replace("int(VIEW_INDEX)", str(eye))
		window.picture.shader = shader
	var source := Image.create(512, 256, false, Image.FORMAT_RGBA8)
	var texture := ImageTexture.create_from_image(source)
	for tb in [false, true]:
		for y in source.get_height():
			for x in source.get_width():
				var second: bool = y >= 128 if tb else x >= 256
				var detail := 0.55 if (x / 8 + y / 8) % 2 == 0 else 1.0
				source.set_pixel(x, y, Color(0, 0.15, detail) if second else Color(detail, 0.15, 0))
		texture.update(source)
		for geometry in [0, 1, 2, 3]:
			for swap in [false, true]:
				for selected in [0, 1, 2]:
					for zoom in [1.0, 4.0, 8.0]:
						for window in windows:
							var material: ShaderMaterial = window.picture
							material.set_shader_parameter("color_texture", texture)
							material.set_shader_parameter("source_size", Vector2(512, 256))
							material.set_shader_parameter("stereo_sbs", true)
							material.set_shader_parameter("top_bottom", tb)
							material.set_shader_parameter("swap_eyes", swap)
							material.set_shader_parameter("viewing_eye", selected)
							material.set_shader_parameter("video_geometry", geometry)
							material.set_shader_parameter("stereo_offset", Vector2(0.06, 0.02))
							material.set_shader_parameter("alpha_enabled", false)
							window.zoom = zoom; window.crop_parameters()
						await process_frame
						await RenderingServer.frame_post_draw
						await RenderingServer.frame_post_draw
						var left: Image = views[0].get_texture().get_image()
						var right: Image = views[1].get_texture().get_image()
						check(left.get_data() == right.get_data(), "Both eyes match: projection %d TB %s swap %s source %d zoom %s" % [geometry, tb, swap, selected, zoom])
						var pixel := left.get_pixel(128, 72)
						var blue: bool = (selected == 2) != swap
						check(pixel.b > 0.5 and pixel.r < 0.05 if blue else pixel.r > 0.5 and pixel.b < 0.05, "Selected source eye contains visible video detail")
	# A mono source with live depth inference stays unwarped in PiP.
	for window in windows:
		window.picture.set_shader_parameter("stereo_sbs", false)
		window.picture.set_shader_parameter("depth_enabled", true)
		window.picture.set_shader_parameter("alpha_texture", texture)
		window.picture.set_shader_parameter("depth_shift", 0.2)
		window.picture.set_shader_parameter("video_geometry", 0)
		window.picture.set_shader_parameter("rotation_degrees", 90)
		window.zoom = 4; window.crop_parameters()
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	check(views[0].get_texture().get_image().get_data() == views[1].get_texture().get_image().get_data(), "Depth conversion cannot reintroduce binocular disparity into mono PiP")
	for view in views: view.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	print("Video PiP mono render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
