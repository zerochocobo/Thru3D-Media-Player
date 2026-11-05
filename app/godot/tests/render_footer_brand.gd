extends SceneTree
const Palette := preload("res://scripts/ui_theme.gd")
const Status := preload("res://scripts/device_status.gd")
const Menu := preload("res://scripts/ray_menu.gd")
var checks := 0
var failures: Array[String] = []
func _initialize() -> void: _run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func frames() -> void:
	for index in 5: await process_frame; await RenderingServer.frame_post_draw
func sample(image: Image, camera: Camera3D, node: MeshInstance3D, uv: Vector2) -> Color:
	var size: Vector2 = node.mesh.size
	return image.get_pixelv(Vector2i(camera.unproject_position(node.to_global(Vector3((uv.x - 0.5) * size.x, (0.5 - uv.y) * size.y, 0)))))
func _run() -> void:
	var output := OS.get_environment("UI_THEME_CAPTURE_DIR"); DirAccess.make_dir_recursive_absolute(output)
	preload("res://scripts/i18n.gd").use("zh")
	var view := SubViewport.new(); view.size = Vector2i(1800, 600); view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(view)
	var camera := Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.size = 0.26; view.add_child(camera)
	var old := Status.new(); old.position = Vector3(-0.18, -0.015, -0.6)
	var current := Status.new(); current.position = Vector3(0.18, -0.015, -0.6)
	for status in [old, current]:
		status.status_provider = func(): return {"level": 73, "clock24": true}
		status.clock_provider = func(): return {"hour": 10, "minute": 8}
		view.add_child(status)
	for item in [{"title": "Before", "x": -0.18}, {"title": "After", "x": 0.18}]:
		var label := Label3D.new(); label.text = "原先" if item.title == "Before" else "修复后"
		label.font = Menu.ui_font(); Menu.set_label_size(label, 18); label.outline_size = 0
		label.position = Vector3(item.x, 0.065, -0.6); view.add_child(label)
	# Sample opaque authored dark and bright faces, away from antialiased edges.
	var texture: Image = Status.GRAY_ICON.get_image()
	var dark := Vector2.ZERO; var bright := Vector2.ZERO
	for y in range(10, texture.get_height() - 10, 4):
		for x in range(10, texture.get_width() - 10, 4):
			var color := texture.get_pixel(x, y)
			if color.a < 0.99: continue
			if color.r > 0.80 and color.r < 0.84: bright = Vector2(float(x) / texture.get_width(), float(y) / texture.get_height())
			if color.r > 0.23 and color.r < 0.27: dark = Vector2(float(x) / texture.get_width(), float(y) / texture.get_height())
	for theme in ["default", "pearl", "sand", "jade", "custom"]:
		if theme == "custom": Palette.set_custom({"background": Color("808080"), "accent": Color("12367a"), "text": "auto"})
		Palette.use(theme); await frames()
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED; material.render_priority = 12
		material.albedo_texture = Status.GRAY_ICON; material.albedo_color = Palette.color("label")
		old._brand_icon.material_override = material
		await frames()
		var image := view.get_texture().get_image(); image.save_png(output.path_join("footer-" + theme + ".png"))
		var high := sample(image, camera, current._brand_icon, bright)
		var low := sample(image, camera, current._brand_icon, dark)
		if theme != "default":
			check(high.r - low.r > 0.08, theme + " rendered logo retains multiple gray levels")
			check(absf(high.r - high.g) < 0.02 and absf(high.g - high.b) < 0.02, theme + " rendered logo remains neutral graphite")
		var hole := sample(image, camera, current._brand_icon, Vector2(0.5, 0.5))
		var paper := image.get_pixelv(Vector2i(camera.unproject_position(current.to_global(Vector3(0, -0.039, 0)))))
		check(absf(hole.r - paper.r) < 0.03 and absf(hole.g - paper.g) < 0.03, theme + " preserves transparent logo center")
	FileAccess.open(output.path_join("footer-verification.json"), FileAccess.WRITE).store_string(JSON.stringify({"checks": checks, "failures": failures}, "\t"))
	view.free(); await process_frame; Palette.use("default"); Palette.set_custom({})
	for failure in failures: push_error(failure)
	print("Footer brand render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
