extends SceneTree
## The depth variants PairTextureBinding generates (depth_code) draw exactly what the pair shaders' full
## path draws for mono 2D->3D (shader parallax), for every projection and eye, several strengths and
## planes, minified (footprint filter) with a non-identity grade. The parallax must move the picture.
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

func color_source() -> ImageTexture:
	var image := Image.create(512, 512, false, Image.FORMAT_RGB8)
	for y in image.get_height():
		for x in image.get_width():
			image.set_pixel(x, y, Color(float((x * 7) % 256) / 255.0, float((y * 13) % 256) / 255.0, float(((x ^ y) * 5) % 256) / 255.0))
	return ImageTexture.create_from_image(image)

## The model's near map for both eye halves (the shader reads the left one): a near disc on a far ramp.
func near_source() -> ImageTexture:
	var image := Image.create(128, 64, false, Image.FORMAT_R8)
	for y in 64:
		for x in 128:
			var u := float(x % 64) / 63.0; var v := float(y) / 63.0
			var near := 0.95 if Vector2(u - 0.5, v - 0.5).length() < 0.25 else 0.15 + 0.3 * u
			image.set_pixel(x, y, Color(near, 0, 0))
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

## Like the bridge: level k is floor(size / 2^k), each texel the mean of the 2x2 above it.
func reductions(image: Image) -> Array[ImageTexture]:
	var result: Array[ImageTexture] = []
	var above := image
	for k in 4:
		var size := Vector2i(maxi(1, image.get_width() >> (k + 1)), maxi(1, image.get_height() >> (k + 1)))
		var level := Image.create(size.x, size.y, false, Image.FORMAT_RGBAF)
		for y in size.y:
			for x in size.x:
				var sum := Color(0, 0, 0, 0)
				for d in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
					sum += above.get_pixel(mini(x * 2 + d.x, above.get_width() - 1), mini(y * 2 + d.y, above.get_height() - 1))
				level.set_pixel(x, y, sum / 4.0)
		result.append(ImageTexture.create_from_image(level))
		above = level
	return result

## Largest and mean channel difference over the lit pixels of [a].
func spread(a: Image, b: Image) -> Vector2:
	var worst := 0.0; var total := 0.0; var count := 0
	for y in range(0, 200, 2):
		for x in range(0, 200, 2):
			var p := a.get_pixel(x, y); var q := b.get_pixel(x, y)
			if p.r + p.g + p.b <= 0.3: continue
			var d := maxf(absf(p.r - q.r), maxf(absf(p.g - q.g), absf(p.b - q.b)))
			worst = maxf(worst, d); total += d; count += 1
	return Vector2(worst, total / maxi(count, 1))

## A minified 2048-wide mono picture under parallax: with the bridge's reductions the depth variant stays
## close to its footprint filter on a smooth picture, and really reads them on a detailed one.
func _run_levels(surface: Node3D, head: Camera3D, eye_camera: Camera3D, near: ImageTexture) -> void:
	var detail := Image.create(2048, 1024, false, Image.FORMAT_RGB8)
	var smooth := Image.create(2048, 1024, false, Image.FORMAT_RGB8)
	for y in 1024:
		for x in 2048:
			detail.set_pixel(x, y, Color(float((x * 7) % 256) / 255.0, float((y * 13) % 256) / 255.0, float(((x ^ y) * 5) % 256) / 255.0))
			var u := float(x) / 2048.0
			smooth.set_pixel(x, y, Color(0.2 + 0.6 * u, 0.3 + 0.4 * sin(float(y) / 90.0) * 0.5 + 0.2, 0.5 + 0.3 * cos(u * 6.0)))
	var none: Array[ImageTexture] = []
	var pictures := {"detail": [detail, reductions(detail)], "smooth": [smooth, reductions(smooth)]}
	for pipeline in ["", "_oes"]:
		var depth := Shader.new(); depth.code = Binding.depth_code(shader_for("res://shaders/video_rvm_pair%s.gdshader" % pipeline).code)
		for eye in 2:
			var shots := {}
			for kind in pictures:
				for leveled in [false, true]:
					var image: Image = pictures[kind][0]
					var levels: Array[ImageTexture] = pictures[kind][1] if leveled else none
					surface.material.shader = depth
					var params := {"alpha_enabled": false, "color_texture": ImageTexture.create_from_image(image), "alpha_texture": near, "test_eye": eye,
							"source_size": Vector2(image.get_width(), image.get_height()), "model_size": Vector2(64, 64), "model_content_rect": Vector4(0, 0, 1, 1),
							"depth_enabled": true, "depth_shift": 0.035, "depth_convergence": 0.35, "plain_footprint_taps": 3, "color_levels": levels.size(),
							"grade_enabled": true, "grade_contrast": 1.1, "grade_gain": Vector3(1.05, 0.95, 1.0), "grade_offset": Vector3(0.01, 0.0, -0.01)}
					for k in 4: params["color_level_%d" % (k + 1)] = levels[k] if k < levels.size() else null
					for key in params: surface.material.set_shader_parameter(key, params[key])
					surface.sharpness = 0
					surface.stereo_sbs = false; surface.top_bottom = false; surface.stereo_half = false
					surface.geometry = 0
					surface.flat_pose = surface.global_transform.affine_inverse() * Transform3D(head.global_basis, head.global_position - head.global_basis.z * 1.2)
					surface._apply_geometry(); surface.reset_view()
					eye_camera.global_transform = head.global_transform * Transform3D(Basis.IDENTITY, Vector3(-0.032 if eye == 0 else 0.032, 0, 0))
					shots[[kind, leveled]] = await capture()
			var name := str([pipeline, eye])
			checks += 1
			if spread(shots[["detail", true]], shots[["detail", false]]).y < 4.0 / 255.0: failures.append("Depth variant ignores the levels " + name)
			var close := spread(shots[["smooth", true]], shots[["smooth", false]])
			checks += 1
			if close.x > 10.0 / 255.0 or close.y > 2.0 / 255.0: failures.append("Depth levels far from the footprint filter " + name + " max/mean " + str(close * 255.0))
			checks += 1
			if lit(shots[["smooth", true]]) < 100: failures.append("Nothing drawn with levels " + name)

func _run() -> void:
	viewport = SubViewport.new(); viewport.size = Vector2i(200, 200); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var head := Camera3D.new(); head.position = Vector3(0.3, 1.6, -0.2)
	viewport.add_child(head)
	var eye_camera := Camera3D.new(); eye_camera.fov = 90; viewport.add_child(eye_camera); eye_camera.current = true
	var surface: Node3D = Surface.new()
	viewport.add_child(surface); surface.view_camera = head
	surface.initialize_surface(shader_for("res://shaders/video_rvm_pair.gdshader")); surface.panel.visible = true
	var color := color_source()
	var near := near_source()
	var worst := 0.0
	for pipeline in ["", "_oes"]:
		var branch := shader_for("res://shaders/video_rvm_pair%s.gdshader" % pipeline)
		var depth := Shader.new(); depth.code = Binding.depth_code(branch.code)
		checks += 1
		if depth.code.is_empty(): failures.append("No depth code for " + pipeline); continue
		for projection in [0, 1, 2, 3]:
			for eye in 2:
				for look in [[0.035, 0.35], [0.14, 0.05], [0.2, 0.65]]:
					var images: Array[Image] = []
					for drawn in [[branch, false], [branch, true], [depth, true]]:
						surface.material.shader = drawn[0]
						var params := {"alpha_enabled": false, "plain_fast_path": true, "color_texture": color, "alpha_texture": near, "test_eye": eye,
								"source_size": Vector2(512, 512), "model_size": Vector2(64, 64), "model_content_rect": Vector4(0, 0, 1, 1),
								"depth_enabled": drawn[1], "depth_shift": look[0], "depth_convergence": look[1],
								"grade_enabled": true, "grade_contrast": 1.2, "grade_gain": Vector3(1.1, 0.95, 1.0), "grade_offset": Vector3(0.02, 0.0, -0.01)}
						for key in params: surface.material.set_shader_parameter(key, params[key])
						surface.sharpness = 0
						surface.stereo_sbs = false; surface.top_bottom = false; surface.stereo_half = false
						surface.geometry = projection
						surface.flat_pose = surface.global_transform.affine_inverse() * Transform3D(head.global_basis, head.global_position - head.global_basis.z * 1.2)
						surface._apply_geometry(); surface.reset_view()
						eye_camera.global_transform = head.global_transform * Transform3D(Basis.IDENTITY, Vector3(-0.032 if eye == 0 else 0.032, 0, 0))
						images.append(await capture())
					var name := str([pipeline, projection, eye, look])
					var diff := difference(images[1], images[2])
					worst = maxf(worst, diff)
					checks += 1
					if diff > 1.5 / 255.0: failures.append("Depth shader differs " + name + " by " + str(diff * 255.0))
					checks += 1
					if lit(images[1]) < 100: failures.append("Nothing drawn " + name)
					if projection == 0:
						checks += 1
						if difference(images[0], images[1]) < 8.0 / 255.0: failures.append("Parallax did not move the picture " + name)
	await _run_levels(surface, head, eye_camera, near)
	viewport.free()
	for failure in failures: push_error(failure)
	print("Depth variant parity: %d checks, %d failures, worst %.2f/255" % [checks, failures.size(), worst * 255.0])
	quit(0 if failures.is_empty() else 1)
