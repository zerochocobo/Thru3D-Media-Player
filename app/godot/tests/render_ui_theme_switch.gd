extends SceneTree
## Direct appearance swatches and compositor captures; only fixture state/clock are synthetic.
const Palette := preload("res://scripts/ui_theme.gd")
const Library := preload("res://scripts/library_menu.gd")
const States := preload("res://tests/render_ui_theme_states.gd")
const Composition := preload("res://scripts/menu_composition.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void: _run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func frames(count: int = 5) -> void:
	for index in count: await process_frame; await RenderingServer.frame_post_draw

func pixel_at(image: Image, camera: Camera3D, node: Node3D, point: Vector3) -> Color:
	return image.get_pixelv(Vector2i(camera.unproject_position(node.to_global(point))))

func color_delta(first: Color, second: Color) -> float:
	return maxf(absf(first.r - second.r), maxf(absf(first.g - second.g), absf(first.b - second.b)))

func _run() -> void:
	var output := OS.get_environment("UI_THEME_CAPTURE_DIR")
	DirAccess.make_dir_recursive_absolute(output)
	preload("res://scripts/i18n.gd").use("zh")
	var viewport := SubViewport.new(); viewport.size = Vector2i(2000, 1350); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var origin := Node3D.new(); viewport.add_child(origin)
	var camera := Camera3D.new(); camera.fov = 60; origin.add_child(camera)
	var library := Library.new(); library.settings_provider = func(): return {Palette.KEY: Palette.current}
	library.setting_changed.connect(func(key, value):
		if key == Palette.KEY: Palette.use(value))
	origin.add_child(library); library.toggle(); library.section = Library.Section.SETTINGS; library.tab = Library.DISPLAY_TAB
	library.refresh(); library._set_scroll(0); library.refresh()
	for option in Palette.OPTIONS:
		var theme: String = option.value
		Palette.use(theme); await frames()
		library.clear_pointer_visuals(); library._update_highlights(); await frames()
		check(library.rows[0].key == Palette.KEY and library.rows[1].key == "watch_color" and library.rows[2].setting[0] == "bar_transparency", "Appearance swatches precede bar transparency without scrolling")
		var image: Image = viewport.get_texture().get_image()
		image.save_png(output.path_join("display-" + theme + ".png"))
		for button in library._buttons:
			var item: Dictionary = library.choices.targets.get(button.target, {})
			if item.get("key") not in [Palette.KEY, "watch_color"]: continue
			var disc: MeshInstance3D = button.node.get_node("ColorSwatch")
			var material: ShaderMaterial = disc.material_override
			var outline: Color = material.get_shader_parameter("marker_outline")
			check(outline == Palette.color("muted") and material.get_shader_parameter("marker_outline_width") > 0.0, theme + " outlined swatch: " + str(item.value))
			if item.key == Palette.KEY:
				var left := pixel_at(image, camera, disc, Vector3(-0.009, 0.011, 0))
				var right := pixel_at(image, camera, disc, Vector3(0.009, 0.011, 0))
				check(color_delta(left, right) > 0.12, theme + " rendered panel/accent halves: " + str(item.value))
			# Sample the rim and just inside/outside it on the same side. The thin
			# outline must remain visible for dark samples and the white wrist sample.
			var radius: float = disc.mesh.size.x * 0.5
			var rim := pixel_at(image, camera, disc, Vector3(-radius + 0.0007, 0, 0))
			var inside := pixel_at(image, camera, disc, Vector3(-radius + 0.006, 0, 0))
			var outside := pixel_at(image, camera, disc, Vector3(-radius - 0.0015, 0, 0))
			check(maxf(color_delta(rim, inside), color_delta(rim, outside)) > 0.12, theme + " rendered visible rim: " + item.key + "/" + str(item.value))
		var themes := 0
		for item in library.choices.targets.values():
			if item.get("key") == Palette.KEY and item.kind == "choose": themes += 1
		check(themes == 7 and library.choices.opened.is_empty(), "Seven direct theme swatches have no dropdown")
		for key in [Palette.KEY, "watch_color"]:
			var targets: Array = library._buttons.filter(func(button): return library.choices.targets.get(button.target, {}).get("key") == key)
			check(not targets.is_empty(), "Swatches are visible: " + key)
			if targets.is_empty(): continue
			var button: Dictionary = targets[0]
			library.update_pointer("right_hand", button.node.to_global(Vector3(0, 0, 0.4)), -button.node.global_basis.z, true)
			await frames()
			check(is_instance_valid(library._tooltip) and library._tooltip.visible, "Real pointer shows " + key + " tooltip")
			viewport.get_texture().get_image().save_png(output.path_join("display-" + theme + "-" + key + "-tooltip.png"))
			library.clear_pointer_visuals(); library._update_highlights()
	library.free()

	preload("res://scripts/i18n.gd").use("en")
	var menu := States.Widgets.new(); origin.add_child(menu); menu.toggle()
	var capture := Composition.new(); viewport.add_child(capture)
	capture.configure(origin, camera, null, [menu], false, true)
	var direct: Dictionary = {}
	for option in Palette.OPTIONS:
		Palette.use(option.value)
		await frames()
		capture.update(); await frames()
		var slot: Dictionary = {}
		for candidate in capture.slots:
			if candidate.used and candidate.nodes.has(menu._backdrop): slot = candidate; break
		check(not slot.is_empty(), option.value + " has a native menu capture")
		if slot.is_empty(): continue
		var image: Image = slot.raw.get_texture().get_image()
		image.save_png(output.path_join("native-" + option.value + ".png"))
		direct[option.value] = image.get_data().hex_encode().sha256_text()
		var repaints: int = capture.repaints
		await frames(3); capture.update(); await frames(3)
		check(capture.repaints <= repaints + 1, option.value + " idle theme does not repaint every frame")
	Palette.use("default"); await frames(); capture.update(); await frames()
	for candidate in capture.slots:
		if candidate.used and candidate.nodes.has(menu._backdrop):
			check(candidate.raw.get_texture().get_image().get_data().hex_encode().sha256_text() == direct.get("default"), "Returning to original restores identical compositor pixels")
	check(direct.values().size() == 6 and direct.values().all(func(value): return direct.values().count(value) == 1), "All six native captures have distinct palettes")
	FileAccess.open(output.path_join("switch-verification.json"), FileAccess.WRITE).store_string(JSON.stringify({"checks": checks, "failures": failures, "scope": "Desktop GL native-layer capture emulation; headset runtime not exercised"}, "\t"))
	viewport.free(); await process_frame
	for failure in failures: push_error(failure)
	print("UI theme switch render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
