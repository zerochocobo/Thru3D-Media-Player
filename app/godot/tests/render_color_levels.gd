extends SceneTree
## Flat QIYU playback with the bridge's 2x reductions (color_levels): the standalone plain shaders
## match the pair shaders, a side-by-side eye never takes the other eye's colour, a smooth picture
## stays close to the footprint filter, and a minified detailed picture really uses the levels.
const Surface := preload("res://scripts/media_surface.gd")
const Binding := preload("res://scripts/pair_texture_binding.gd")
var failures: Array[String] = []
var checks := 0
var viewport: SubViewport
var surface: Node3D
var head: Camera3D
var eye_camera: Camera3D

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

func draw(shader: Shader, image: Image, levels: Array[ImageTexture], sbs: bool, eye: int, taps: int = 3) -> Image:
	surface.material.shader = shader
	var texture := ImageTexture.create_from_image(image)
	var params := {"alpha_enabled": false, "plain_fast_path": true, "plain_footprint_taps": taps, "color_texture": texture, "test_eye": eye,
			"source_size": Vector2(image.get_width(), image.get_height()), "color_levels": levels.size(),
			"grade_enabled": true, "grade_contrast": 1.1, "grade_gain": Vector3(1.05, 0.95, 1.0), "grade_offset": Vector3(0.01, 0.0, -0.01)}
	for k in 4: params["color_level_%d" % (k + 1)] = levels[k] if k < levels.size() else null
	for key in params: surface.material.set_shader_parameter(key, params[key])
	surface.sharpness = 0
	surface.stereo_sbs = sbs; surface.top_bottom = false; surface.stereo_half = false
	surface.geometry = 0
	surface.flat_pose = surface.global_transform.affine_inverse() * Transform3D(head.global_basis, head.global_position - head.global_basis.z * 1.2)
	surface._apply_geometry(); surface.reset_view()
	eye_camera.global_transform = head.global_transform * Transform3D(Basis.IDENTITY, Vector3(-0.032 if eye == 0 else 0.032, 0, 0))
	return await capture()

## Largest and mean channel difference over the lit pixels of [a].
func difference(a: Image, b: Image) -> Vector2:
	var worst := 0.0
	var total := 0.0
	var count := 0
	for y in range(0, 200, 2):
		for x in range(0, 200, 2):
			var p := a.get_pixel(x, y); var q := b.get_pixel(x, y)
			if p.r + p.g + p.b <= 0.3: continue
			var d := maxf(absf(p.r - q.r), maxf(absf(p.g - q.g), absf(p.b - q.b)))
			worst = maxf(worst, d); total += d; count += 1
	return Vector2(worst, total / maxi(count, 1))

func lit(image: Image) -> int:
	var count := 0
	for y in range(0, 200, 2):
		for x in range(0, 200, 2):
			var p := image.get_pixel(x, y)
			if p.r + p.g + p.b > 0.3: count += 1
	return count

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _run() -> void:
	viewport = SubViewport.new(); viewport.size = Vector2i(200, 200); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	head = Camera3D.new(); head.position = Vector3(0.3, 1.6, -0.2)
	viewport.add_child(head)
	eye_camera = Camera3D.new(); eye_camera.fov = 90; viewport.add_child(eye_camera); eye_camera.current = true
	surface = Surface.new()
	viewport.add_child(surface); surface.view_camera = head
	surface.initialize_surface(shader_for("res://shaders/video_rvm_pair.gdshader")); surface.panel.visible = true
	var detail := Image.create(2048, 1024, false, Image.FORMAT_RGB8)
	var smooth := Image.create(2048, 1024, false, Image.FORMAT_RGB8)
	var eyes := Image.create(2048, 1024, false, Image.FORMAT_RGB8)
	for y in 1024:
		for x in 2048:
			detail.set_pixel(x, y, Color(float((x * 7) % 256) / 255.0, float((y * 13) % 256) / 255.0, float(((x ^ y) * 5) % 256) / 255.0))
			var u := float(x) / 2048.0
			smooth.set_pixel(x, y, Color(0.2 + 0.6 * u, 0.3 + 0.4 * sin(float(y) / 90.0) * 0.5 + 0.2, 0.5 + 0.3 * cos(u * 6.0)))
			eyes.set_pixel(x, y, Color(0.9, 0.1, 0.1) if x < 1024 else Color(0.1, 0.9, 0.1))
	var detail_levels := reductions(detail)
	var smooth_levels := reductions(smooth)
	var eye_levels := reductions(eyes)
	var none: Array[ImageTexture] = []
	for pipeline in ["", "_oes"]:
		var branch := shader_for("res://shaders/video_rvm_pair%s.gdshader" % pipeline)
		var plain := Shader.new(); plain.code = Binding.plain_code(branch.code)
		for sbs in [false, true]:
			for eye in 2:
				var name := str([pipeline, sbs, eye])
				var a := await draw(branch, detail, detail_levels, sbs, eye)
				var b := await draw(plain, detail, detail_levels, sbs, eye)
				var parity := difference(a, b)
				check(parity.x <= 1.5 / 255.0, "Plain shader differs with levels " + name + " by " + str(parity.x * 255.0))
				check(lit(a) >= 100, "Nothing drawn " + name)
				var without := await draw(branch, detail, none, sbs, eye, 0)
				check(difference(a, without).y >= 4.0 / 255.0, "Levels unused on a minified picture " + name)
				var filtered := await draw(branch, smooth, none, sbs, eye, 3)
				var leveled := await draw(branch, smooth, smooth_levels, sbs, eye)
				var close := difference(leveled, filtered)
				check(close.x <= 10.0 / 255.0 and close.y <= 2.0 / 255.0, "Levels far from the footprint filter " + name + " max/mean " + str(close * 255.0))
				if sbs:
					var own := await draw(branch, eyes, eye_levels, true, eye)
					var bleed := 0.0
					for y in range(0, 200, 2):
						for x in range(0, 200, 2):
							var p := own.get_pixel(x, y)
							# The own eye's channel dominates; the other eye's would raise the weak one.
							if (p.r if eye == 0 else p.g) > 0.5: bleed = maxf(bleed, p.g if eye == 0 else p.r)
					check(bleed < 0.2, "Other eye bleeds into eye %d with levels (%s)" % [eye, pipeline])
	viewport.free()
	for failure in failures: push_error(failure)
	print("Color levels render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
