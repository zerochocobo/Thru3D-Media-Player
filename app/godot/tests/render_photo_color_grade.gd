extends SceneTree
## Image settings with the colour grading entry, and the per-image grade page, in four languages.
const Menu := preload("res://scripts/photo_menu.gd")
const Grade := preload("res://scripts/color_grade.gd")
const I18n := preload("res://scripts/i18n.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/photo-color-grade-preview")
var failures: Array[String] = []
var viewport: SubViewport
var camera: Camera3D
var menu: Node3D
var grade := Grade.new()
var state := {"has_image":true, "geometry":0, "title":"旅行相册 · Travel journal", "index":2, "count":12, "can_previous":true, "can_next":true,
	"screen_distance":3.0, "screen_scale":1.0, "inspect_magnification":2.0, "source_uri":"file:///a.jpg", "layer_available":true, "grade_on_layer":true}

func _initialize() -> void: call_deferred("_run")

func snapshot(name: String) -> void:
	state.color_grade = grade.snapshot(); state.grade_values = grade.values()
	menu.refresh()
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	if image.save_png(output.path_join(name + ".png")) != OK: failures.append("Failed to save " + name)
	for button in menu._buttons:
		var label: Variant = button.node.get_child(0) if button.node.get_child_count() > 0 else null
		if not label is Label3D or label.text.is_empty() or button.rect.size.x < 0.2: continue
		var width: float = menu.ui_font().get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size).x * label.pixel_size
		if width >= button.rect.size.x - 0.01: failures.append("%s: \"%s\" overflows its button" % [name, label.text])

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	viewport = SubViewport.new()
	viewport.size = Vector2i(1280, 900)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	camera = Camera3D.new()
	camera.fov = 56
	camera.position.y = -0.2
	viewport.add_child(camera)
	menu = Menu.new()
	menu.state_provider = func(): return state.duplicate()
	viewport.add_child(menu)
	menu.toggle(); menu._activate(11)
	for language in ["zh", "en"]:
		I18n.use(language)
		await snapshot("settings-" + language)
	state.depth_available = true
	await snapshot("settings-position-en")
	if not menu._buttons.any(func(b): return b.target == Menu.PHOTO_COLOR and b.enabled): failures.append("Colour entry missing from image settings")
	state.erase("depth_available")
	menu._activate(Menu.PHOTO_COLOR)
	grade.select("Warm")
	for language in ["zh", "zh_Hant", "en", "ja"]:
		I18n.use(language)
		for page in 3:
			menu._grade_page = page
			await snapshot("grade-%s-%d" % [language, page])
	grade.adjust("exposure", 1.0); grade.adjust("saturation", 1.6)
	I18n.use("zh"); menu._grade_page = 0
	await snapshot("grade-custom-zh")
	menu.visible = false
	for shader in ["photo", "photo_spatial", "panorama_tile"]: await _shader_grades(shader)
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify({
		"state":"passed" if failures.is_empty() else "failed", "failures":failures,
		"scope":"Production Godot photo menu on desktop OpenGL; image settings and grade pages in four languages; photo, spatial and panorama tile shaders apply the grade",
		"physical_headset_verified":false}, "	"))
	menu.free(); viewport.free()
	for failure in failures: push_error(failure)
	print("Photo colour grade render: %s; %s" % ["passed" if failures.is_empty() else "failed", output])
	quit(0 if failures.is_empty() else 1)

## The image shaders compile with the grade and brighten a grey picture by one stop of exposure.
func _shader_grades(name: String) -> void:
	var quad := MeshInstance3D.new()
	quad.mesh = QuadMesh.new(); quad.mesh.size = Vector2(4, 4)
	quad.position = Vector3(0, -0.2, -1.0)
	var material := ShaderMaterial.new(); material.shader = load("res://shaders/%s.gdshader" % name)
	var grey := Image.create(4, 4, false, Image.FORMAT_RGBA8); grey.fill(Color(0.3, 0.3, 0.3))
	var texture := ImageTexture.create_from_image(grey)
	for key in ["photo_texture", "image_texture", "tile_texture"]: material.set_shader_parameter(key, texture)
	material.set_shader_parameter("portal_size", Vector2(4, 4))
	quad.material_override = material
	viewport.add_child(quad)
	var probe := Grade.new()
	probe.apply(material)
	var before := await _centre()
	probe.adjust("exposure", 1.0); probe.apply(material)
	var after := await _centre()
	if after.r < before.r * 1.6 or before.r < 0.05: failures.append("%s shader does not apply the grade (%.3f -> %.3f)" % [name, before.r, after.r])
	quad.free()

func _centre() -> Color:
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	return image.get_pixel(image.get_width() / 2, image.get_height() / 2)
