extends SceneTree
const Palette := preload("res://scripts/ui_theme.gd")
const Library := preload("res://scripts/library_menu.gd")
const Editor := preload("res://scripts/theme_editor.gd")
const Composition := preload("res://scripts/menu_composition.gd")
var checks := 0
var failures: Array[String] = []
var library: Node3D
var viewport: SubViewport
var output := ""
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: _run.call_deferred()
func frames(count: int = 5) -> void:
	for index in count: await process_frame; await RenderingServer.frame_post_draw
func button(target: int) -> Dictionary:
	for item in library._buttons:
		if item.target == target: return item
	return {}
func choice(key: String, value: Variant) -> int:
	for target in library.choices.targets:
		var item: Dictionary = library.choices.targets[target]
		if item.get("key") == key and item.get("value") == value: return target
	return -1
func tap(target: int, local: Vector2 = Vector2.ZERO) -> void:
	check(not button(target).is_empty(), "Visible ray target: %d" % target)
	if button(target).is_empty(): return
	var node: Node3D = button(target).node
	var start: Vector3 = node.to_global(Vector3(local.x, local.y, 0.4))
	var direction := -node.global_basis.z
	library.press_pointer("right_hand", start, direction, true)
	library.release_pointer("right_hand", start, direction, true)
	await frames()
func capture(name: String) -> Image:
	library.clear_pointer_visuals(); library._update_highlights(); await frames()
	var image := viewport.get_texture().get_image()
	image.save_png(output.path_join(name + ".png"))
	return image
func _run() -> void:
	output = OS.get_environment("UI_THEME_CAPTURE_DIR"); DirAccess.make_dir_recursive_absolute(output)
	preload("res://scripts/i18n.gd").use("zh")
	Palette.use("default"); Palette.set_custom({})
	viewport = SubViewport.new(); viewport.size = Vector2i(2000, 1350); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var origin := Node3D.new(); viewport.add_child(origin)
	var camera := Camera3D.new(); camera.fov = 60; origin.add_child(camera)
	var settings := ConfigFile.new()
	library = Library.new(); library.settings_provider = func(): return {Palette.KEY: Palette.current}
	library.setting_changed.connect(func(key, value):
		if key == Palette.KEY: Palette.save_choice(settings, value)
		if key == Palette.CUSTOM_KEY: Palette.save_custom(settings, value))
	origin.add_child(library); library.toggle(); library.section = Library.Section.SETTINGS; library.tab = Library.DISPLAY_TAB; library.refresh()
	await capture("display-custom-entry")
	await tap(choice(Palette.KEY, Palette.CUSTOM))
	check(Palette.original() and not library.theme_editor.opened, "Quick custom button initially preserves classic palette")
	await capture("display-custom-default")
	await tap(choice(Palette.EDIT_CUSTOM, true))
	check(library.theme_editor.opened, "Separate edit button opens picker")
	await capture("editor-default")
	# Real pointer taps set blue, a dark background, and a complementary accent.
	await tap(Editor.HUE, Vector2((0.61 - 0.5) * Editor.HUE_SIZE.x, 0))
	await tap(Editor.FIELD, Vector2((0.55 - 0.5) * Editor.FIELD_SIZE.x, (0.20 - 0.5) * Editor.FIELD_SIZE.y))
	check(Palette.custom_data.is_empty(), "Rendered draft has not changed saved palette")
	var background_image := await capture("editor-background")
	var accent_node: MeshInstance3D
	for item in library.theme_editor.preview:
		if item.key == "accent" and item.node.mesh.size.y > 0.05: accent_node = item.node; break
	var pixel := background_image.get_pixelv(Vector2i(camera.unproject_position(accent_node.to_global(Vector3(0.08, 0, 0)))))
	var panel: Color = Palette.custom_palette(library.theme_editor.draft).panel
	check(maxf(absf(pixel.r - panel.r), maxf(absf(pixel.g - panel.g), absf(pixel.b - panel.b))) > 0.12, "Preview accent button renders visibly above its backing panel")
	await tap(Editor.TABS + 1); await tap(Editor.ACCENTS + 3)
	await capture("editor-accent")
	await tap(Editor.TABS + 2); await tap(Editor.TEXTS + 1)
	await capture("editor-text")
	await tap(Editor.APPLY)
	check(Palette.current == Palette.CUSTOM and not Palette.light(), "Apply renders a saved dark custom theme")
	await capture("display-custom-dark")
	await tap(choice(Palette.EDIT_CUSTOM, true))
	await tap(Editor.HUE, Vector2((0.48 - 0.5) * Editor.HUE_SIZE.x, 0))
	await tap(Editor.FIELD, Vector2((0.12 - 0.5) * Editor.FIELD_SIZE.x, (0.95 - 0.5) * Editor.FIELD_SIZE.y))
	await capture("editor-light")
	await tap(Editor.APPLY)
	check(Palette.current == Palette.CUSTOM and Palette.light(), "Apply renders a saved light custom theme")
	await capture("display-custom-light")
	await tap(choice(Palette.EDIT_CUSTOM, true))
	var layers := Composition.new(); viewport.add_child(layers); layers.configure(origin, camera, null, [library], false, true)
	# The production node updates itself once per process frame. Extra manual
	# ticks would park UPDATE_ONCE before the renderer gets its first draw.
	await frames(8)
	var before: int = layers.repaints
	for index in 16:
		library._update_highlights(); await frames(1)
	check(layers.repaints <= before + 1, "Idle picker keeps compositor cache rather than repainting every frame")
	var captured := false
	for slot in layers.slots:
		if slot.used and slot.nodes.has(library._backdrop):
			var image: Image = slot.raw.get_texture().get_image()
			image.save_png(output.path_join("editor-native-capture.png"))
			check(image.get_used_rect().has_area(), "Native menu capture contains visible editor pixels")
			var first := image.get_pixelv(Vector2i(slot.camera.unproject_position(library.theme_editor.field.to_global(Vector3(-0.10, 0.10, 0)))))
			var second := image.get_pixelv(Vector2i(slot.camera.unproject_position(library.theme_editor.field.to_global(Vector3(0.10, -0.10, 0)))))
			check(first.a > 0.9 and second.a > 0.9 and maxf(absf(first.r - second.r), maxf(absf(first.g - second.g), absf(first.b - second.b))) > 0.15, "Picker gradient survives native-layer capture")
			captured = true
	check(captured, "Editor receives a production native-layer capture slot")
	FileAccess.open(output.path_join("custom-verification.json"), FileAccess.WRITE).store_string(JSON.stringify({"checks": checks, "failures": failures, "scope": "Production menus and real ray actions rendered by desktop Godot GL; no headset runtime"}, "\t"))
	viewport.free(); await process_frame; Palette.use("default"); Palette.set_custom({})
	for failure in failures: push_error(failure)
	print("Custom theme render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
