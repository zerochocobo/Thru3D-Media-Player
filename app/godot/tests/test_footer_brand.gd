extends SceneTree
const Palette := preload("res://scripts/ui_theme.gd")
const States := preload("res://tests/render_ui_theme_states.gd")
const Composition := preload("res://scripts/menu_composition.gd")
var checks := 0
var failures: Array[String] = []
func _initialize() -> void: _run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func frames() -> void:
	for index in 3: await process_frame
func _run() -> void:
	Palette.use("default"); Palette.set_custom({})
	var menu := States.Widgets.new(); root.add_child(menu); menu.toggle()
	var status: Node3D = menu.device_status
	var original_pose: Transform3D = status._brand_icon.transform
	var original_size: Vector2 = status._brand_icon.mesh.size
	for overlay in [false, true, false]:
		menu.set_scene_overlay(overlay)
		for theme in ["default", "pearl", "sand", "jade", "ocean", "dusk", "pearl", "default"]:
			Palette.use(theme); await frames()
			var material: Material = status._brand_icon.material_override
			if Palette.light():
				check(material is ShaderMaterial, theme + " uses a tonal graphite material")
				check(material.get_shader_parameter("gray_icon") == status.GRAY_ICON, "Light logo reuses original gradient/alpha artwork")
				var high: Color = material.get_shader_parameter("highlight_ink")
				var low: Color = material.get_shader_parameter("shadow_ink")
				check(high.r - low.r >= 0.20 and high.r == high.g and high.g == high.b, theme + " has neutral gray highlight/shadow separation")
				check(Palette.Custom.contrast(high, Palette.color("panel")) >= 3.0, theme + " brightest graphite face is visible")
				check(("depth_test_disabled" in material.shader.code) == overlay, "Graphite honors cinema depth policy")
			else:
				check(material is StandardMaterial3D and material.albedo_texture == status.GRAY_ICON, theme + " retains classic textured material")
				check(material.albedo_color == Palette.color("label") and material.no_depth_test == overlay, theme + " retains old tint and depth policy")
			check(Composition._is_detail(status._brand_icon), "Brand stays in high-density detail capture")
			check(status._brand_icon.transform == original_pose and status._brand_icon.mesh.size == original_size, "Theme changes preserve footer layout")
	Palette.set_custom({"background": Color("808080"), "accent": Color("1c6085"), "text": "auto"}); Palette.use(Palette.CUSTOM); await frames()
	check(status._brand_icon.material_override is ShaderMaterial, "Custom light background also gets graphite")
	var high: Color = status._brand_icon.material_override.get_shader_parameter("highlight_ink")
	check(Palette.Custom.contrast(high, Palette.color("panel")) >= 3.0, "Graphite adapts to custom medium-light gray")
	menu.free(); Palette.use("default"); Palette.set_custom({}); await frames()
	for failure in failures: push_error(failure)
	print("Footer brand: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
