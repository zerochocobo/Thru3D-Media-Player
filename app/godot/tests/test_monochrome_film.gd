extends SceneTree
## Monochrome film (the plugins tab): saved per video, carried after the grade to the plugin, shown on
## the plugins tab, and rendered black and white by the eye buffers' shader.
const Grade := preload("res://scripts/color_grade.gd")
const PictureMemory := preload("res://scripts/file_picture_memory.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
var failures: Array[String] = []
func check(value: bool, message: String) -> void:
	if not value: failures.append(message)
func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	_memory()
	_values()
	_menu()
	await _render()
	if failures.is_empty():
		print("MONOCHROME FILM PASS")
		quit(0)
	else:
		for failure in failures: push_error(failure)
		quit(1)

func _memory() -> void:
	var memory := PictureMemory.new()
	var old := {"picture_quality": true, "picture_sharpness": 0.5, "picture_upscale": 0, "picture_denoise": 0,
		"color_grade": {"preset": "Original", "custom": {}}}
	var clean := memory.clean(old)
	check(clean.get("picture_mono") == false and clean.get("picture_mono_style") == 0 and clean.get("picture_mono_grain") == 1,
		"A look saved before monochrome film reads as off, standard, low grain")
	var edited := memory.edited(clean, "picture_mono", true)
	edited = memory.edited(edited, "picture_mono_style", 1)
	edited = memory.edited(edited, "picture_mono_grain", 3)
	check(edited.picture_mono and edited.picture_mono_style == 1 and edited.picture_mono_grain == 3, "The switch, style and grain are edited")
	check(memory.clean(edited) == edited, "The edited look survives a save")
	check(memory.clean(memory.edited(edited, "picture_mono_style", 9)).picture_mono_style == 2, "A style out of range is clamped")
	var bad := old.duplicate(true); bad["picture_mono"] = "yes"
	check(memory.clean(bad).is_empty(), "A malformed switch reads as no look")
	check(PictureMemory.is_adjustment("picture_mono") and PictureMemory.is_adjustment("picture_mono_grain"), "Film settings are picture adjustments")

func _values() -> void:
	var grade := Grade.new()
	grade.mono = PackedFloat32Array([1.0, 0.25, 0.35, 0.4, 0.12, 1.2, 0.72, 0.0, 1.0, 0.045, 1.0])
	check(grade.linear_terms().is_empty(), "Monochrome film cannot be a per-channel scale")
	var look := PackedFloat32Array()
	look.resize(Video.MONO_AT + Video.MONO_FLOATS)
	look[1] = 1.0
	look[12] = 0.7 # saturation
	for index in Video.MONO_FLOATS: look[Video.MONO_AT + index] = 10.0 + index
	var carried := Video._look_grade(look)
	check(carried.size() == 22 and is_equal_approx(carried[10], 0.7) and is_equal_approx(carried[11], 10.0) and is_equal_approx(carried[21], 20.0),
		"A draw takes the grade's 11 values, then the film's 11")
	look[1] = 0.0
	check(Video._look_grade(look).is_empty(), "No grade, no film")
	check(Video.MONO_STYLES.size() == Menu.PICTURE_MONO_STYLES.size() and Video.MONO_GRAIN.size() == Menu.PICTURE_MONO_GRAINS.size(),
		"The menu offers every style and grain level")
	for style in Video.MONO_STYLES:
		check(style.size() == 8 and absf(style[0] + style[1] + style[2] - 1.0) < 0.011, "Each style's weights keep white white")

func _menu() -> void:
	var menu = Menu.new()
	menu._state = {"picture_mono": true, "picture_quality": true, "picture_quality_available": true}
	check(menu._mono_on(), "On with the mode on")
	menu._state.picture_quality = false
	check(not menu._mono_on(), "Off with the mode off")
	menu.free()

## The eye buffers' shader: film turns a colour grey, keeps reds and greens of one luminance apart, and
## the Original preset still grades with it on.
func _render() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(64, 64)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.position.z = 2
	viewport.add_child(camera)
	var quad := MeshInstance3D.new()
	quad.mesh = QuadMesh.new()
	quad.mesh.size = Vector2(4, 4)
	viewport.add_child(quad)
	var material := ShaderMaterial.new()
	material.shader = load("res://shaders/video_rvm_pair.gdshader")
	quad.material_override = material
	material.set_shader_parameter("model_size", Vector2(2, 2))
	material.set_shader_parameter("source_size", Vector2(2, 2))
	material.set_shader_parameter("alpha_enabled", false)
	var grade := Grade.new()
	grade.mono = PackedFloat32Array([1.0, 0.25, 0.35, 0.4, 0.12, 1.2, 0.72, 0.0, 1.0, 0.0, 1.0])
	grade.apply(material)
	# Red and green of one Rec. 709 luminance.
	var red := await _sample(viewport, material, Color(0.8, 0.2, 0.2))
	var green := await _sample(viewport, material, Color(0.2, 0.42, 0.2))
	check(absf(red.r - red.g) < 0.01 and absf(red.g - red.b) < 0.01, "Film is grey")
	check(absf(red.r - green.r) > 0.03, "Reds and greens of one luminance stay apart (%.3f, %.3f)" % [red.r, green.r])
	grade.mono = PackedFloat32Array()
	grade.apply(material)
	var colour := await _sample(viewport, material, Color(0.8, 0.2, 0.2))
	check(colour.r > colour.g + 0.2, "Off, the colour comes back")
	viewport.queue_free()

func _sample(viewport: SubViewport, material: ShaderMaterial, colour: Color) -> Color:
	var image := Image.create(2, 2, false, Image.FORMAT_RGB8)
	image.fill(colour)
	material.set_shader_parameter("color_texture", ImageTexture.create_from_image(image))
	var mask := Image.create(4, 2, false, Image.FORMAT_R8)
	mask.fill(Color(1, 0, 0))
	material.set_shader_parameter("alpha_texture", ImageTexture.create_from_image(mask))
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image().get_pixel(32, 32)
