extends SceneTree
const Video := preload("res://scripts/mpv_video_display.gd")
var failures: Array[String] = []

func _initialize() -> void: call_deferred("_run")

func capture(viewport: SubViewport) -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func patch_rect(camera: Camera3D, pose: Transform3D, size: Vector2i) -> Rect2i:
	var rect := Rect2(camera.unproject_position(pose * Vector3(-0.35, -0.35, 0)), Vector2.ZERO)
	for corner in [Vector3(-0.35, 0.35, 0), Vector3(0.35, -0.35, 0), Vector3(0.35, 0.35, 0)]:
		rect = rect.expand(camera.unproject_position(pose * corner))
	return Rect2i(rect.grow(3)).intersection(Rect2i(Vector2i.ZERO, size))

func compare(actual: Image, reference: Image, rect: Rect2i) -> Dictionary:
	var union_pixels := 0
	var different := 0
	var max_error := 0.0
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var a := actual.get_pixel(x, y)
			var b := reference.get_pixel(x, y)
			var white_a := minf(a.r, minf(a.g, a.b)) > 0.85
			var white_b := minf(b.r, minf(b.g, b.b)) > 0.85
			if white_a or white_b: union_pixels += 1
			if white_a != white_b: different += 1
			max_error = maxf(max_error, maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b))))
	return {"white_union": union_pixels, "different_white_pixels": different,
		"mismatch_fraction": float(different) / maxi(1, union_pixels), "max_rgb_error": max_error}

func _run() -> void:
	var output := OS.get_environment("SUBTITLE_PROJECTION_OUTPUT")
	var legacy_probe := OS.get_environment("SUBTITLE_PROJECTION_LEGACY_PROBE") == "1"
	if output.is_empty(): quit(1); return
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var head := Camera3D.new()
	head.position = Vector3(0, 1.6, 0)
	viewport.add_child(head)
	var eye := Camera3D.new()
	viewport.add_child(eye)
	eye.make_current()
	var video := Video.new()
	viewport.add_child(video)
	video.set_process(false)
	video.view_camera = head
	video.caption.text = "今天的风景很美。\nBeautiful scenery today."
	video.caption.visible = true
	var color := Image.create(2, 2, false, Image.FORMAT_RGB8)
	color.fill(Color.BLACK)
	var alpha := Image.create(2, 2, false, Image.FORMAT_R8)
	alpha.fill(Color.BLACK)
	var color_texture := ImageTexture.create_from_image(color)
	var alpha_texture := ImageTexture.create_from_image(alpha)
	var reference := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.7, 0.7)
	reference.mesh = quad
	var reference_material := ShaderMaterial.new()
	var reference_shader := Shader.new()
	reference_shader.code = "shader_type spatial; render_mode unshaded, cull_disabled, depth_test_disabled, blend_premul_alpha; uniform sampler2D caption : source_color, filter_linear, repeat_disable; void fragment() { vec4 c = texture(caption, UV); ALBEDO = c.rgb; ALPHA = c.a; }"
	reference_material.shader = reference_shader
	reference.material_override = reference_material
	viewport.add_child(reference)
	reference.visible = false
	var samples: Array[Dictionary] = []
	for path in ["video", "oes", "surface"]:
		var source_path := "res://shaders/video_rvm_pair_oes.gdshader" if path == "oes" else "res://shaders/video_rvm_pair.gdshader"
		var shader := Shader.new()
		shader.code = load(source_path).code.replace("samplerExternalOES", "sampler2D")
		if legacy_probe:
			shader = preload("res://tests/benchmark_subtitle_projection.gd").legacy_shader(shader.code, false)
			video._subtitle_material.shader = preload("res://tests/benchmark_subtitle_projection.gd").legacy_shader(load("res://shaders/subtitle_surface.gdshader").code, true)
		video.material.shader = shader
		video.material.set_shader_parameter("color_texture", color_texture)
		video.material.set_shader_parameter("alpha_texture", alpha_texture)
		video.material.set_shader_parameter("source_size", Vector2(2, 2))
		video.material.set_shader_parameter("model_size", Vector2(2, 2))
		video.material.set_shader_parameter("alpha_enabled", true)
		video.material.set_shader_parameter("sharpness", 0)
		for geometry in [1, 2]:
			video.geometry = geometry
			video._apply_geometry()
			for direction in [0, 1]:
				video.subtitle_direction = direction
				for position in [0.0, 30.0]:
					video.subtitle_position = position
					for distance in [0.1, 5.0]:
						video.subtitle_distance = distance
						video.set_screen_rotation(90 if path == "surface" else 0)
						video.panel.visible = true
						video._place_caption()
						video._sync_subtitle_surface()
						if legacy_probe:
							for material in [video.material, video._subtitle_material]:
								material.set_shader_parameter("subtitle_anchor_inverse", video.SubtitleDepth.anchor(position, direction == 1).transposed())
								material.set_shader_parameter("subtitle_parallax", 2 * atan((0.055 if position == 0 else 0.075) / (2 * distance)))
						# Independent rasterization of the same physical plane checks complete glyphs,
						# including edges/line shape, rather than only their shared centroid.
						reference.global_transform = video.projected_subtitles.plane_pose
						reference_material.set_shader_parameter("caption", video.projected_subtitles.viewport.get_texture())
						for index in 2:
							var side := float(index) - 0.5
							eye.position = head.position + Vector3(side * (0.055 if position == 0 else 0.075), 0, 0)
							eye.rotation.y = side * 0.02
							eye.set_frustum(0.02, Vector2(side * 0.0004, -0.0001), 0.01, 100.0)
							var actual := await capture(viewport)
							video.panel.visible = false
							video._subtitle_surface.visible = false
							reference.visible = true
							var expected := await capture(viewport)
							var result := compare(actual, expected, patch_rect(eye, reference.global_transform, viewport.size))
							result.merge({"path": path, "geometry": geometry, "direction": direction, "position_degrees": position, "distance_m": distance, "eye": index})
							if result.white_union < 50 or result.mismatch_fraction > 0.03 or result.max_rgb_error > 0.06:
								failures.append("Per-eye projected glyphs differ from an actual plane: " + JSON.stringify(result))
							if distance == 0.1 and position == 30:
								var name := "%s_geometry%d_direction%d_eye%d" % [path, geometry, direction, index]
								actual.save_png(output.path_join(name + ".png"))
								expected.save_png(output.path_join(name + "_reference.png"))
							samples.append(result)
							reference.visible = false
							video.panel.visible = true
							video._sync_subtitle_surface()
	var report := {"state": "passed" if failures.is_empty() else "failed", "legacy_probe": legacy_probe, "samples": samples, "failures": failures,
		"scope": "Full bilingual glyph pixels vs independent physical QuadMesh rasterization; fisheye/VR180, texture/OES sampler surrogate/separate surface, horizontal/vertical, 0.1m/5m, off-axis/canted desktop views and 55/75mm eye separation. Reference cameras use a 0.01m near clip to include the nearest plane. Physical XR and decoder OES ownership remain separate."}
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	for failure in failures: push_error(failure)
	print("Per-eye subtitle glyph comparisons=%d failures=%d" % [samples.size(), failures.size()])
	viewport.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
