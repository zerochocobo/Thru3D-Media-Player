extends SceneTree

const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []
var checks := 0
var viewport: SubViewport
var material: ShaderMaterial
var output := ""

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	output = ProjectSettings.globalize_path("res://../../build/output/stereo-view/render")
	DirAccess.make_dir_recursive_absolute(output)
	await _menus()
	viewport = SubViewport.new()
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
	for variant in ["video_rvm_pair", "video_rvm_pair_oes"]:
		var code := FileAccess.get_file_as_string("res://shaders/" + variant + ".gdshader") \
			.replace('#include "res://shaders/video_coordinates.gdshaderinc"', FileAccess.get_file_as_string("res://shaders/video_coordinates.gdshaderinc")) \
			.replace("varying flat int eye_index;", "uniform int test_eye = 0;\nuniform vec2 test_uv = vec2(0.5);\nuniform vec3 test_direction = vec3(0.0, 0.0, -1.0);\nvarying flat int eye_index;") \
			.replace("eye_index = int(VIEW_INDEX);", "eye_index = test_eye;") \
			.replace("media_direction = VERTEX;", "media_direction = test_direction;") \
			.replace("eye_uv(UV, media_direction)", "eye_uv(test_uv, media_direction)")
		# Desktop has no Android decoder EGLImage. Exercise the exact OES sampling math
		# with an ordinary texture; actual external binding remains a device check.
		code = code.replace("uniform samplerExternalOES color_texture;", "uniform sampler2D color_texture : filter_linear, repeat_disable;")
		var shader := Shader.new(); shader.code = code
		material = ShaderMaterial.new(); material.shader = shader
		quad.material_override = material
		material.set_shader_parameter("stereo_sbs", true)
		material.set_shader_parameter("alpha_enabled", false)
		material.set_shader_parameter("separate_subtitles", true)
		for tb in [false, true]:
			for rotation in [0, 90, 180, 270]:
				_textures(tb, rotation)
				material.set_shader_parameter("rotation_degrees", rotation)
				material.set_shader_parameter("stereo_offset", Vector2.ZERO)
				var before_left := await _pixel(0)
				var before_right := await _pixel(1)
				check(absf(before_left.r - before_right.r) + absf(before_left.g - before_right.g) > 0.03, variant + " fixture really has misalignment")
				material.set_shader_parameter("stereo_offset", Vector2(0.03125, 0.015625))
				var left := await _pixel(0)
				var right := await _pixel(1)
				check(absf(left.r - right.r) < 0.006 and absf(left.g - right.g) < 0.006, variant + " SBS/TB rotated color alignment: " + str([tb, rotation, left, right]))
				material.set_shader_parameter("alpha_enabled", true)
				left = await _pixel(0); right = await _pixel(1)
				check(absf(left.a - right.a) < 0.008, variant + " matte follows the same corrected coordinates")
				for swap in [false, true]:
					material.set_shader_parameter("swap_eyes", swap)
					for selected in [1, 2]:
						material.set_shader_parameter("viewing_eye", selected)
						left = await _pixel(0); right = await _pixel(1)
						check(left.is_equal_approx(right), variant + " mono duplicates color and alpha independent of alignment")
						var source: int = (2 - selected) if swap else (selected - 1)
						# A transparent viewport stores premultiplied color.
						var blue := left.b / maxf(left.a, 0.001)
						check(blue > 0.7 if source == 1 else blue < 0.2, variant + " mono selects the requested logical eye after swap")
				material.set_shader_parameter("viewing_eye", 0)
				material.set_shader_parameter("swap_eyes", false)
				material.set_shader_parameter("alpha_enabled", false)
		_textures(false, 0)
		material.set_shader_parameter("rotation_degrees", 0)
		material.set_shader_parameter("stereo_offset", Vector2(0.04, 0.02))
		material.set_shader_parameter("test_uv", Vector2(0.99, 0.5))
		var edge := await _pixel(1)
		check(edge.r < 0.01 and edge.g < 0.01 and edge.b < 0.01 and edge.a > 0.99, variant + " corrected edge is black, not stretched or cross-eye")
		material.set_shader_parameter("alpha_enabled", true)
		check((await _pixel(1)).a < 0.01, variant + " corrected Alpha border remains transparent")
		material.set_shader_parameter("alpha_enabled", false)
		material.set_shader_parameter("test_uv", Vector2(0.5, 0.5))
		material.set_shader_parameter("stereo_offset", Vector2(0.03125, 0.015625))
		for geometry in [1, 2, 3]:
			material.set_shader_parameter("video_geometry", geometry)
			var left := await _pixel(0); var right := await _pixel(1)
			check(absf(left.r - right.r) < 0.006 and absf(left.g - right.g) < 0.006, variant + " immersive projection applies alignment " + str(geometry))
		material.set_shader_parameter("test_direction", Vector3(0.001, 0, 1))
		var seam := await _pixel(1)
		check(seam.b > 0.7 and seam.r < 0.02 and seam.a > 0.99, variant + " 360 wraps longitude inside the selected eye")
	# Compile and sample the actual compositor mask/border shaders as well. A corrected
	# packed eye's exposed edge is black; mono viewing and 360 wrapping have no border.
	for variant in ["video_layer_hole", "video_layer_border"]:
		var code := FileAccess.get_file_as_string("res://shaders/" + variant + ".gdshader") \
			.replace('#include "res://shaders/video_coordinates.gdshaderinc"', FileAccess.get_file_as_string("res://shaders/video_coordinates.gdshaderinc")) \
			.replace("varying flat int eye_index;", "uniform int test_eye = 0;\nuniform vec2 test_uv = vec2(0.5);\nuniform vec3 test_direction = vec3(0.0, 0.0, -1.0);\nvarying flat int eye_index;") \
			.replace("eye_index = int(VIEW_INDEX);", "eye_index = test_eye;") \
			.replace("media_direction = VERTEX;", "media_direction = test_direction;") \
			.replace("eye_uv(UV, media_direction)", "eye_uv(test_uv, media_direction)")
		var shader := Shader.new(); shader.code = code
		material = ShaderMaterial.new(); material.shader = shader; quad.material_override = material
		material.set_shader_parameter("stereo_sbs", true)
		material.set_shader_parameter("stereo_offset", Vector2(0.04, 0.04))
		for edge_uv in [Vector2(0.99, 0.5), Vector2(0.5, 0.99)]:
			material.set_shader_parameter("test_uv", edge_uv)
			var edge := await _pixel(1)
			check(edge.a > 0.99 if variant == "video_layer_border" else edge.a < 0.01, variant + " handles corrected horizontal and vertical edges")
		material.set_shader_parameter("viewing_eye", 1)
		check((await _pixel(1)).a < 0.01, variant + " mono suspends correction border")
		material.set_shader_parameter("viewing_eye", 0)
		material.set_shader_parameter("video_geometry", 3)
		material.set_shader_parameter("test_direction", Vector3(0.001, 0, 1))
		check((await _pixel(1)).a < 0.01, variant + " 360 seam wraps without border")
	viewport.queue_free()
	await process_frame
	print("Stereo viewing render checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)

func _pixel(eye: int) -> Color:
	material.set_shader_parameter("test_eye", eye)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image().get_pixel(32, 32)

func _textures(tb: bool, rotation: int) -> void:
	var size := Vector2i(128, 256) if tb else Vector2i(256, 128)
	var color := Image.create(size.x, size.y, false, Image.FORMAT_RGB8)
	var alpha := Image.create(256, 128, false, Image.FORMAT_R8)
	var delta := Vector2(0.03125, 0.015625)
	if rotation == 90: delta = Vector2(delta.y, -delta.x)
	elif rotation == 180: delta = -delta
	elif rotation == 270: delta = Vector2(-delta.y, delta.x)
	for eye in 2:
		for y in 128:
			for x in 128:
				var uv := (Vector2(x, y) + Vector2(0.5, 0.5)) / 128.0 - delta * eye
				color.set_pixel(x + (0 if tb else 128 * eye), y + (128 * eye if tb else 0), Color(clampf(uv.x, 0, 1), clampf(uv.y, 0, 1), 0.8 if eye == 1 else 0.1))
				alpha.set_pixel(x + 128 * eye, y, Color(clampf(uv.x * 0.5 + uv.y * 0.5, 0, 1), 0, 0))
	material.set_shader_parameter("color_texture", ImageTexture.create_from_image(color))
	material.set_shader_parameter("alpha_texture", ImageTexture.create_from_image(alpha))
	material.set_shader_parameter("source_size", Vector2(size))
	material.set_shader_parameter("model_size", Vector2(128, 128))
	material.set_shader_parameter("top_bottom", tb)

func _menus() -> void:
	var view := SubViewport.new()
	view.size = Vector2i(1500, 1100)
	view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var camera := Camera3D.new(); camera.fov = 60
	view.add_child(camera)
	var state := {"has_video": true, "stereo": true, "viewing_eye": 0, "stereo_horizontal": 3.0, "stereo_vertical": 2.0}
	var menu := Menu.new()
	menu.state_provider = func(): return state
	camera.add_child(menu)
	menu.position = Vector3(0, 0, -1.2)
	menu.toggle(); menu.section = 1; menu._adjustment = "stereo_view"
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language)
		for selected in [0, 1, 2]:
			state.viewing_eye = selected
			menu.refresh()
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			check(view.get_texture().get_image().save_png(output.path_join("menu_%s_%d.png" % [language, selected])) == OK, "Save " + language + " stereo menu")
			for button in menu._buttons:
				if button.target < Menu.VIEWING_EYE or button.target > Menu.ALIGNMENT_RESET: continue
				var label: Label3D = button.node.get_child(0)
				var width := menu.ui_font().get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size).x * label.pixel_size
				check(width < button.rect.size.x - 0.025, "Translated stereo button fits " + language + ": " + label.text)
	view.queue_free()
	await process_frame
