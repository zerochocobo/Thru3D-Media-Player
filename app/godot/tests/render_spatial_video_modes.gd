extends SceneTree

const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []
var checks := 0

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/spatial-mode-ui/render")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1600, 1000)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.fov = 60
	viewport.add_child(camera)
	var state := {"has_video": true, "geometry": 0, "playing": true, "playback_state": "playing",
		"spatial_video": true, "stereo": true, "title": "iPhone spatial video", "source_uri": "test.mov",
		"position_ms": 2000, "duration_ms": 5000, "mode_lock": {"geometry": 1, "layout": 1, "depth": false}}
	var menu := Menu.new()
	menu.state_provider = func(): return state
	camera.add_child(menu)
	menu.position = Vector3(0, -0.12, -1.4)
	menu.toggle()
	menu._mode_open = true
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language)
		menu.refresh()
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		check(image.save_png(output.path_join(language + ".png")) == OK, "Save " + language)
		check(not menu._buttons.any(func(b): return b.target == 112), language + " has no Auto 3D action")
		check(menu._buttons.filter(func(b): return b.get("fixed_current", false)).size() == 2, language + " has two selected read-only tiles")
		for label in menu._labels:
			if label.text.contains("MV-HEVC") or label.text == I18n.t("Mode fixed"):
				var width := menu.ui_font().get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size).x * label.pixel_size
				check(width < (0.65 if label.text.contains("MV-HEVC") else 0.21), language + " header fits its column")
	menu.queue_free()
	viewport.queue_free()
	await process_frame
	await _check_stereo_alpha(output)
	print("Spatial mode render and stereo Alpha checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)

func _check_stereo_alpha(output: String) -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(65, 65)
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2
	camera.position.z = 2
	viewport.add_child(camera)
	var quad := MeshInstance3D.new()
	quad.mesh = QuadMesh.new()
	quad.mesh.size = Vector2(2, 2)
	viewport.add_child(quad)
	var code := FileAccess.get_file_as_string("res://shaders/video_rvm_pair.gdshader") \
		.replace('#include "res://shaders/video_coordinates.gdshaderinc"', FileAccess.get_file_as_string("res://shaders/video_coordinates.gdshaderinc")) \
		.replace("varying flat int eye_index;", "uniform int test_eye = 0;\nuniform vec2 test_uv = vec2(0.5);\nvarying flat int eye_index;") \
		.replace("eye_index = int(VIEW_INDEX);", "eye_index = test_eye;") \
		.replace("vec2 shown_uv = eye_uv(pip_uv(UV), sample_direction);", "vec2 shown_uv = test_uv;")
	var shader := Shader.new()
	shader.code = code
	var material := ShaderMaterial.new()
	material.shader = shader
	quad.material_override = material
	var color := Image.create(64, 32, false, Image.FORMAT_RGB8)
	color.fill_rect(Rect2i(0, 0, 32, 32), Color(0.8, 0, 0))
	color.fill_rect(Rect2i(32, 0, 32, 32), Color(0, 0.8, 0))
	var matte := Image.create(64, 32, false, Image.FORMAT_R8)
	matte.fill(Color(0, 0, 0))
	matte.fill_rect(Rect2i(0, 16, 32, 16), Color(1, 1, 1))
	matte.fill_rect(Rect2i(32, 0, 32, 16), Color(1, 1, 1))
	matte.fill_rect(Rect2i(32, 16, 32, 16), Color(0.25, 0.25, 0.25))
	material.set_shader_parameter("color_texture", ImageTexture.create_from_image(color))
	material.set_shader_parameter("alpha_texture", ImageTexture.create_from_image(matte))
	material.set_shader_parameter("source_size", Vector2(64, 32))
	material.set_shader_parameter("model_size", Vector2(32, 32))
	material.set_shader_parameter("model_content_rect", Vector4(0, 0, 1, 1))
	material.set_shader_parameter("stereo_sbs", true)
	material.set_shader_parameter("video_geometry", 0)
	material.set_shader_parameter("alpha_enabled", true)
	for eye in [0, 1]:
		material.set_shader_parameter("test_eye", eye)
		for sample in [[0.25, 0.0 if eye == 0 else 1.0], [0.75, 1.0 if eye == 0 else 0.25], [0.5, 0.5 if eye == 0 else 0.625]]:
			material.set_shader_parameter("test_uv", Vector2(0.5, sample[0]))
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			var image := viewport.get_texture().get_image()
			var pixel := image.get_pixel(32, 32)
			check(absf(pixel.a - sample[1]) < 0.035, "Flat stereo Alpha picks the correct eye and edge: %d/%.2f" % [eye, sample[0]])
			if sample[1] == 1:
				check(pixel.r > pixel.g + 0.4 if eye == 0 else pixel.g > pixel.r + 0.4, "Opaque Alpha retains native color eye %d" % eye)
			image.save_png(output.path_join("alpha_eye%d_y%.2f.png" % [eye, sample[0]]))
	material.set_shader_parameter("swap_eyes", true)
	material.set_shader_parameter("test_eye", 0)
	material.set_shader_parameter("test_uv", Vector2(0.5, 0.25))
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var swapped := viewport.get_texture().get_image().get_pixel(32, 32)
	check(swapped.a > 0.99 and swapped.g > swapped.r + 0.4, "Eye swap moves the matching color and Alpha together")
	material.set_shader_parameter("alpha_enabled", false)
	material.set_shader_parameter("test_uv", Vector2(0.5, 0.75))
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	check(viewport.get_texture().get_image().get_pixel(32, 32).a > 0.99, "Alpha off restores opaque spatial video")
	viewport.queue_free()
	await process_frame
