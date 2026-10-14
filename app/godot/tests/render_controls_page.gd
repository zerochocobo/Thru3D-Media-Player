extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Bindings := preload("res://scripts/controller_bindings.gd")
const I18n := preload("res://scripts/i18n.gd")
var failures: Array[String] = []
var checks := 0
var widget_counts := {}

func _initialize() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/controller-controls/previews")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1600, 1050); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60
	viewport.add_child(camera)
	var menu := Menu.new(); camera.add_child(menu)
	menu.settings_provider = func(): return {"version": "0.6.1"}
	menu.toggle(); menu.section = Menu.Section.SETTINGS
	for language in ["zh", "en", "zh_Hant", "ja"]:
		I18n.use(language)
		menu.tab = Menu.VIDEO_TAB; menu.refresh()
		check(menu.rows.size() == 8 and menu.rows.any(func(row): return row.get("key", "") == "subtitle_distance"), "Video contains subtitle controls: " + language)
		check(not menu._buttons.any(func(button): return button.target == Menu.TAB_BASE + Menu.SUBTITLES_TAB), "Separate subtitle tab is absent: " + language)
		await shot(viewport, menu, output.path_join(language + "-video.png"))
		menu.tab = Menu.CONTROLS_TAB; menu.controls_page.mode = 0; menu.scroll = 0; menu.refresh()
		if language == "zh": widget_counts["controllers"] = count_widgets(menu)
		check(menu.choices.targets.is_empty() and menu.controls_page.selection.is_empty(), "Controller text list has no dormant selectors: " + language)
		check_headers(menu)
		await shot(viewport, menu, output.path_join(language + "-controllers.png"))
		var play: Dictionary = menu._buttons.filter(func(button): return button.get("choice_key", "") == "control_binding/play")[0]
		menu.update_pointer("right_hand", play.node.to_global(Vector3(0.40, 0, 1)), -menu.global_basis.z, true)
		check(play.hover_labels[0].modulate == menu.ACCENT and menu.choices.targets.is_empty(), "Editable text highlights without a selector: " + language)
		await shot(viewport, menu, output.path_join(language + "-controllers-hover.png"))
		menu.update_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)
		menu.scroll = 8; menu._draw()
		await shot(viewport, menu, output.path_join(language + "-controllers-scrolled.png"))
		menu.scroll = menu.rows.find(menu.rows.filter(func(row): return row.get("id") == "move_video")[0]); menu.refresh()
		check(menu._buttons.all(func(button): return button.target != 7052), "No recording button remains")
		check(menu.rows.filter(func(row): return row.get("id", "") in Bindings.FIXED_ACTIONS).all(func(row): return row.has("fixed") and row.fixed == menu.controls_page.bindings.label(row.id)), "Both movement rows display fixed left/right grips")
		check(not menu._buttons.any(func(button): return button.get("choice_key", "") in ["control_binding/move_video", "control_binding/move_photo"]), "Fixed movement has no reassignment dropdown")
		check(not Array(menu.text_snapshot().split("\n")).any(func(text): return text in ["video", "photo"]), "Fixed movement context uses the translated video/photo names")
		await shot(viewport, menu, output.path_join(language + "-move-binding.png"))
		menu.choices.reset(); menu.controls_page.reset(); menu.scroll = menu._max_scroll(); menu.refresh()
		open_dropdown(menu, "control_move_scope")
		await shot(viewport, menu, output.path_join(language + "-move-scope.png"))
		menu.choices.reset(); menu.controls_page.mode = 0; menu.scroll = 0; menu.refresh()
		open_dropdown(menu, "control_binding/play")
		check(menu.choices.popup.choices.all(func(option): return not str(option.value).ends_with("/grip_click")), "Other action dropdowns omit both grips")
		await shot(viewport, menu, output.path_join(language + "-binding-dropdown.png"))
		await pointer_shot(viewport, camera, menu, "right_hand/ax_button", output.path_join(language + "-binding-pointer.png"), language == "zh")
		menu.choices.reset(); menu.controls_page.choose("control_binding/play", "left_hand/ax_button"); menu.refresh()
		check(not menu.controls_page.pending.is_empty() and menu.text_snapshot().contains(I18n.t("Swap these bindings?")), "Duplicate binding visibly requires confirmation")
		await shot(viewport, menu, output.path_join(language + "-binding-conflict.png"))
		menu.controls_page.action(menu.ControlsPage.CANCEL)
		menu.choices.reset(); menu.controls_page.reset(); menu.controls_page.mode = 2; menu.scroll = 0; menu.refresh()
		if language == "zh": widget_counts["combinations"] = count_widgets(menu)
		check(menu.choices.targets.is_empty() and menu.controls_page.selection.is_empty(), "Combination text list has no dormant selectors: " + language)
		check_headers(menu)
		await shot(viewport, menu, output.path_join(language + "-combinations-list.png"))
		open_dropdown(menu, "control_binding/subtitles")
		await shot(viewport, menu, output.path_join(language + "-combination.png"))
		check(str(menu.controls_page.selection.prefix).ends_with("?") and str(menu.controls_page.selection.prefix) == menu.controls_page.combination_hint(), "Dialog identifies the missing third chord input")
		await pointer_shot(viewport, camera, menu, "left_hand/stick_up", output.path_join(language + "-combination-pointer.png"))
		menu.choices.reset(); menu.controls_page.reset(); menu.controls_page.mode = 1; menu.scroll = 0; menu.refresh()
		for index in [0, 2, 4]:
			menu.controls_page.selected_gesture = index; menu._draw()
			menu.controls_page.demo.animate = false; menu.controls_page.demo.show_phase(0.55)
			await shot(viewport, menu, output.path_join(language + "-gesture-%d.png" % index))
			if index == 2:
				var replay: Dictionary = menu._buttons.filter(func(button): return button.target == menu.ControlsPage.REPLAY)[0]
				menu.update_pointer("right_hand", replay.node.to_global(Vector3(0, 0, 1)), -menu.global_basis.z, true)
				await shot(viewport, menu, output.path_join(language + "-gesture-replay-hover.png"))
				menu.update_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)
		if language == "zh":
			menu.controls_page.selected_gesture = 2; menu._draw(); menu.controls_page.demo.animate = false
			DirAccess.make_dir_recursive_absolute(output.path_join("gesture-frames"))
			for frame in 36:
				menu.controls_page.demo.show_phase(float(frame) / 36)
				await shot(viewport, menu, output.path_join("gesture-frames/%03d.png" % frame), false)
	await grip_frames(viewport, camera, menu, output)
	menu.queue_free(); viewport.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify({"checks": checks, "failures": failures, "widget_counts": widget_counts}, "\t"))
	print("Controls render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func grip_frames(viewport: SubViewport, camera: Camera3D, menu: Node3D, output: String) -> void:
	I18n.use("zh")
	menu.choices.reset(); menu.controls_page.reset(); menu.controls_page.mode = 0
	menu.scroll = menu._max_scroll(); menu.refresh()
	menu.reparent(viewport, true)
	var main := preload("res://tests/test_controller_bindings.gd").InputMain.new()
	main.recent_menu = menu
	main.head_pose = camera.global_transform
	var head_start := camera.global_transform
	var up := menu.global_basis.y.normalized()
	var radius := menu.global_position.distance_to(camera.global_position)
	var point: Vector3 = menu._backdrop.to_global(Vector3(-menu._backdrop.mesh.size.x / 2 + 0.025, 0.1, 0))
	var initial := Transform3D(Basis.IDENTITY, point + Vector3(0.04, -0.02, 0.9)).looking_at(point, Vector3.UP)
	main.pose = initial; main.rays.right_hand = [initial.origin, -initial.basis.z]
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.014)
	await shot(viewport, menu, output.path_join("zh-grip-before.png"), false)
	main._on_controller_button("grip_click", "right_hand")
	check(main.interface_move.pending(), "Grip preview captures the empty panel background")
	for index in 3:
		main.pose = initial
		if index > 0:
			main.pose.basis = Basis(Vector3.UP, 0.18 if index == 1 else -0.2) * initial.basis
			if index == 2: main.pose.origin += Vector3(0.12, 0.05, -0.1)
		main.rays.right_hand = [main.pose.origin, -main.pose.basis.z]
		main._update_interface_move(); main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.014)
		check(absf(menu.global_position.distance_to(camera.global_position) - radius) < 0.0001, "Grip preview preserves viewing distance while translating and turning")
		var pointer: Dictionary = menu._pointers.right_hand
		check(pointer.line.visible and pointer.dot.visible and pointer.dot.global_position.distance_to(main.interface_move.capture.anchor) < 0.009, "Grip preview ray terminates at the live captured point")
		var frame := await shot(viewport, menu, output.path_join("zh-grip-%d.png" % index), false)
		check(amber_pixels(frame, camera.unproject_position(pointer.dot.global_position), 6) >= 10, "Live grip reticle pixels remain visible on the panel")
		var line_point: Vector3 = main.pose.origin.lerp(main.interface_move.capture.anchor, 0.85)
		check(amber_pixels(frame, camera.unproject_position(line_point), 4) > 0, "Live grip line pixels track the current hand origin")
	for step in 8: main._process_sticks(Vector2.ZERO, Vector2(0, 1), 0.05)
	check(menu.global_position.distance_to(camera.global_position) > radius + 0.3, "Grip plus stick up visibly pushes the menu away")
	var depth_pointer: Dictionary = menu._pointers.right_hand
	check(depth_pointer.dot.global_position.distance_to(main.interface_move.capture.anchor) < 0.009, "Depth movement keeps the ray endpoint on its grabbed point")
	var pushed := await shot(viewport, menu, output.path_join("zh-grip-pushed.png"), false)
	check(amber_pixels(pushed, camera.unproject_position(depth_pointer.dot.global_position), 6) >= 10, "Depth-adjusted menu retains visible reticle pixels")
	for step in 8: main._process_sticks(Vector2.ZERO, Vector2(0, -1), 0.05)
	check(absf(menu.global_position.distance_to(camera.global_position) - radius) < 0.0001, "Grip plus down visibly returns to the original distance")
	for step in 37:
		var turn := Basis(up, step * PI / 36.0)
		main.pose = Transform3D(turn * initial.basis, head_start.origin + turn * (initial.origin - head_start.origin))
		main.rays.right_hand = [main.pose.origin, -main.pose.basis.z]
		camera.global_transform = Transform3D(turn * head_start.basis, head_start.origin)
		main.head_pose = camera.global_transform
		main._update_interface_move(); main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.014)
		check(menu.global_basis.y.normalized().dot(up) > 0.99999, "Actual menu stays upright when dragged to the side and behind the head")
		if step in [18, 36]:
			var rear_pointer: Dictionary = menu._pointers.right_hand
			var frame := await shot(viewport, menu, output.path_join("zh-grip-side.png" if step == 18 else "zh-grip-behind.png"), false)
			check(amber_pixels(frame, camera.unproject_position(rear_pointer.dot.global_position), 6) >= 10, "The upright side/rear menu retains its visible grab marker")
	main._on_controller_release("grip_click", "right_hand")
	camera.global_transform = head_start
	main.head_pose = Transform3D(head_start.basis * Basis.from_euler(Vector3(0.1, 0, 0.25)), head_start.origin)
	main.interface_move.placements.erase(main._menu_key(menu))
	main._place_menu(menu)
	check(menu.global_basis.y.is_equal_approx(Vector3.UP), "Actual library ignores head tilt when follow is off")
	await shot(viewport, menu, output.path_join("zh-level-head-tilted.png"), false)
	main.view_follow.set_enabled(true); main._place_menu(menu)
	check(menu.global_basis.is_equal_approx(main.head_pose.basis), "Actual library uses the full head tilt only in follow mode")
	await shot(viewport, menu, output.path_join("zh-follow-head-tilted.png"), false)
	main.free()

func open_dropdown(menu: Node3D, key: String) -> void:
	for button in menu._buttons:
		if button.get("choice_key", "") == key:
			menu.controls_page.action(button.target)
			check(menu.choices.opened == key and menu.choices.popup.choices.size() >= 3, "Text row opens one selection dialog: " + key)
			check(menu.choices.targets.size() == menu.choices.popup.choices.size() and menu.choices.targets.values().all(func(item): return item.kind == "choose"), "All choices are shown without scroll controls: " + key)
			check(not menu._buttons.any(func(item): return item.has("choice_key")), "Dialog retires the underlying list's hit areas: " + key)
			for item in menu._buttons:
				if not menu.choices.targets.has(item.target): continue
				check(item.node.visible and menu.ray_hit(item.node.to_global(Vector3(0, 0, 1)), -menu.global_basis.z).get("target", -1) == item.target, "Every visible choice has a distinct usable ray target")
				check(item.rect.position.y >= -0.55 and item.rect.end.y <= 0.37 and item.rect.position.x >= -0.50 and item.rect.end.x <= 0.74, "Dialog choice remains inside the menu")
			return
	check(false, "Editable text row missing: " + key)

func count_widgets(menu: Node3D) -> Dictionary:
	var counts := {"nodes": 0, "meshes": 0, "labels": 0, "hit_targets": menu._buttons.size(), "choice_targets": menu.choices.targets.size()}
	count_node(menu, counts)
	return counts

func count_node(node: Node, counts: Dictionary) -> void:
	if node.has_meta("menu_pointer"): return
	counts.nodes += 1
	if node is MeshInstance3D: counts.meshes += 1
	if node is Label3D: counts.labels += 1
	for child in node.get_children(): count_node(child, counts)

func check_headers(menu: Node3D) -> void:
	var expected: Array[String] = [I18n.t("Context"), I18n.t("Action"), I18n.t("Binding") + (" · " + menu.controls_page.combination_hint() if menu.controls_page.mode == 2 else "")]
	var headers: Array = menu._labels.filter(func(caption): return caption.text in expected)
	check(headers.size() == 3 and headers.all(func(caption): return caption.font_size == 22 * menu.TEXT_RASTER_SCALE and caption.modulate == menu.ControlsPage.INK and caption.font == menu.ui_bold_font()), "Both tables use white bold headers distinct from body text")
	if menu.controls_page.mode == 2: check(expected[2].ends_with("?"), "Combination table includes the missing third input")

func amber_pixels(image: Image, point: Vector2, radius: int) -> int:
	var result := 0
	for y in range(maxi(0, floori(point.y) - radius), mini(image.get_height(), ceili(point.y) + radius + 1)):
		for x in range(maxi(0, floori(point.x) - radius), mini(image.get_width(), ceili(point.x) + radius + 1)):
			var pixel := image.get_pixel(x, y)
			if pixel.r > 0.8 and pixel.g > 0.35 and pixel.b < 0.5 and pixel.r - pixel.g > 0.07: result += 1
	return result

func pointer_shot(viewport: SubViewport, camera: Camera3D, menu: Node3D, value: String, path: String, reproduce_old: bool = false) -> void:
	var target: int = menu.choices.targets.keys().filter(func(key): return menu.choices.targets[key].get("value", "") == value)[0]
	var button: Dictionary = menu._buttons.filter(func(item): return item.target == target)[0]
	var aim: Vector3 = button.node.to_global(Vector3(0.18, 0, 0))
	var origin: Vector3 = aim + menu.global_basis * Vector3(0.25, 0.13, 0.6)
	menu.update_pointer("right_hand", origin, aim - origin, true)
	check(menu._hover.right_hand == target, "Angled dialog ray hits the chosen input")
	var pointer: Dictionary = menu._pointers.right_hand
	var dot_world: Vector3 = pointer.dot.global_position
	check(menu.to_local(dot_world).is_equal_approx(menu.to_local(aim) + Vector3(0, 0, 0.008)), "Reticle follows the dialog's own hit plane")
	var dot_pixel := camera.unproject_position(dot_world)
	var endpoint: Vector3 = aim + menu.global_basis * Vector3(0, 0, 0.006)
	# Sample the ray inside the popup silhouette, rather than its visible section outside it.
	var line_pixel := camera.unproject_position(origin.lerp(endpoint, 0.9))
	if reproduce_old:
		pointer.line.material_override.render_priority = 14; pointer.dot.material_override.render_priority = 15
		var old := await shot(viewport, menu, path.get_base_dir().path_join("zh-binding-pointer-before.png"))
		check(amber_pixels(old, dot_pixel, 5) == 0 and amber_pixels(old, line_pixel, 3) == 0, "Pixel fixture reproduces old dialog hiding line and reticle")
		pointer.line.material_override.render_priority = menu.POINTER_LINE_PRIORITY
		pointer.dot.material_override.render_priority = menu.POINTER_DOT_PRIORITY
	var rendered := await shot(viewport, menu, path)
	check(amber_pixels(rendered, dot_pixel, 5) >= 15, "Reticle pixels remain visible over the dialog")
	check(amber_pixels(rendered, line_pixel, 3) > 0, "Ray pixels remain visible over the dialog")
	menu.update_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)

func shot(viewport: SubViewport, menu: Node3D, path: String, bounds: bool = true) -> Image:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	if bounds:
		for button in menu._buttons:
			if not button.node.visible: continue
			for child in button.node.get_children():
				if child is Label3D:
					var width: float = child.font.get_string_size(child.text, HORIZONTAL_ALIGNMENT_LEFT, -1, child.font_size).x * child.pixel_size
					check(width <= button.rect.size.x + 0.004, "Button text exceeds hit area: " + child.text + " @ " + path.get_file())
	var image := viewport.get_texture().get_image()
	image.save_png(path)
	return image
