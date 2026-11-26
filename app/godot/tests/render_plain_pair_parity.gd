extends SceneTree
## The plain variants PairTextureBinding generates (plain_code) draw exactly what the pair shaders' fast
## path draws, for every projection, stereo layout and eye, with a non-identity grade. Flat views also
## run every plain_footprint_taps cap, and the minified picture must change without the filter.
const Surface := preload("res://scripts/media_surface.gd")
const Binding := preload("res://scripts/pair_texture_binding.gd")
var failures: Array[String] = []
var checks := 0
var viewport: SubViewport

func _initialize() -> void: _run.call_deferred()

func capture() -> Image:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func shader_for(path: String) -> Shader:
	var shader := Shader.new()
	shader.code = FileAccess.get_file_as_string(path).replace("samplerExternalOES", "sampler2D").replace("eye_index = int(VIEW_INDEX);", "eye_index = test_eye;")
	shader.code = shader.code.replace('#include "res://shaders/video_coordinates.gdshaderinc"', FileAccess.get_file_as_string("res://shaders/video_coordinates.gdshaderinc").replace("varying flat int eye_index;", "uniform int test_eye = 0;\nvarying flat int eye_index;"))
	return shader

func source(layout: int) -> ImageTexture:
	var sbs := layout in [1, 3]
	var tb := layout in [2, 4]
	var image := Image.create(512 * (2 if sbs else 1), 512 * (2 if tb else 1), false, Image.FORMAT_RGB8)
	for y in image.get_height():
		for x in image.get_width():
			image.set_pixel(x, y, Color(float((x * 7) % 256) / 255.0, float((y * 13) % 256) / 255.0, float(((x ^ y) * 5) % 256) / 255.0))
	return ImageTexture.create_from_image(image)

func difference(a: Image, b: Image) -> float:
	var diff := 0.0
	for y in range(0, 200, 3):
		for x in range(0, 200, 3):
			var p := a.get_pixel(x, y); var q := b.get_pixel(x, y)
			diff = maxf(diff, maxf(absf(p.r - q.r), maxf(absf(p.g - q.g), absf(p.b - q.b))))
	return diff

func lit(image: Image) -> int:
	var count := 0
	for y in range(0, 200, 3):
		for x in range(0, 200, 3):
			var p := image.get_pixel(x, y)
			if p.r + p.g + p.b > 0.05: count += 1
	return count

func _run() -> void:
	viewport = SubViewport.new(); viewport.size = Vector2i(200, 200); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var head := Camera3D.new(); head.position = Vector3(0.3, 1.6, -0.2)
	viewport.add_child(head)
	var eye_camera := Camera3D.new(); eye_camera.fov = 90; viewport.add_child(eye_camera); eye_camera.current = true
	var surface: Node3D = Surface.new()
	viewport.add_child(surface); surface.view_camera = head
	surface.initialize_surface(shader_for("res://shaders/video_rvm_pair.gdshader")); surface.panel.visible = true
	var worst := 0.0
	for pipeline in ["", "_oes"]:
		var branch := shader_for("res://shaders/video_rvm_pair%s.gdshader" % pipeline)
		var plain := Shader.new(); plain.code = Binding.plain_code(branch.code)
		for projection in [0, 1, 2, 3]:
			for layout in 5:
				var texture := source(layout)
				for eye in 2:
					var unfiltered: Image = null
					for taps in ([0, 1, 2, 3] if projection == 0 else [3]):
						var images: Array[Image] = []
						for shader in [branch, plain]:
							surface.material.shader = shader
							var params := {"alpha_enabled": false, "plain_fast_path": true, "plain_footprint_taps": taps, "color_texture": texture, "test_eye": eye,
									"source_size": Vector2(texture.get_width(), texture.get_height()),
									"grade_enabled": true, "grade_contrast": 1.2, "grade_gain": Vector3(1.1, 0.95, 1.0), "grade_offset": Vector3(0.02, 0.0, -0.01)}
							for key in params: surface.material.set_shader_parameter(key, params[key])
							surface.sharpness = 0
							surface.stereo_sbs = layout != 0; surface.top_bottom = layout in [2, 4]; surface.stereo_half = layout in [3, 4]
							surface.geometry = projection
							surface.flat_pose = surface.global_transform.affine_inverse() * Transform3D(head.global_basis, head.global_position - head.global_basis.z * 1.2)
							surface._apply_geometry(); surface.reset_view()
							eye_camera.global_transform = head.global_transform * Transform3D(Basis.IDENTITY, Vector3(-0.032 if eye == 0 else 0.032, 0, 0))
							images.append(await capture())
						var name := str([pipeline, projection, layout, eye, taps])
						var diff := difference(images[0], images[1])
						worst = maxf(worst, diff)
						checks += 1
						if diff > 1.5 / 255.0: failures.append("Plain shader differs " + name + " by " + str(diff * 255.0))
						checks += 1
						if lit(images[0]) < 100: failures.append("Nothing drawn " + name)
						if taps == 0: unfiltered = images[0]
						elif taps == 3 and unfiltered:
							checks += 1
							if difference(unfiltered, images[0]) < 4.0 / 255.0: failures.append("Footprint cap has no effect " + name)
	viewport.free()
	for failure in failures: push_error(failure)
	print("Plain pair parity: %d checks, %d failures, worst %.2f/255" % [checks, failures.size(), worst * 255.0])
	quit(0 if failures.is_empty() else 1)
