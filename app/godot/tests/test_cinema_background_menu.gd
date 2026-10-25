extends SceneTree

const Library := preload("res://scripts/library_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
const PANORAMA_HINT := "Photo mode saves its background separately. Change it from the photo toolbar."
var checks := 0
var failures: Array[String] = []
var events: Array = []

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition: failures.append(message)

func choice_target(menu: Node3D, key: String, value: Variant = null, kind: String = "choose") -> int:
	for id in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[id]
		if item.get("kind") == kind and item.get("key") == key and (kind == "open" or item.get("value") == value): return id
	return -1

func button(menu: Node3D, target: int) -> Dictionary:
	for control in menu._buttons:
		if int(control.target) == target: return control
	return {}

func origin(menu: Node3D, target: int) -> Vector3:
	var control := button(menu, target)
	return control.node.to_global(Vector3(0, 0, 1)) if not control.is_empty() else Vector3.ZERO

func tap(menu: Node3D, target: int) -> void:
	check(target >= 0, "Ray target exists")
	if target < 0: return
	var point := origin(menu, target)
	menu.press_pointer("left_hand", point, -menu.global_basis.z, true)
	menu.release_pointer("left_hand", point, -menu.global_basis.z, true)

func row(menu: Node3D, key: String) -> Dictionary:
	for item in menu.rows:
		if item.get("key", "") == key: return item
	return {}

func has_label(menu: Node3D, text: String) -> bool:
	return menu.find_children("*", "Label3D", true, false).any(func(label): return label.text == text)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	I18n.use("en")
	var state := {"background": "belfast", "background_yaw": 0, "background_brightness": 1.0,
		"cinema_ready": true, "cinema_loading": false, "cinema_error": "", "cinema_interaction": "watch", "cinema_seat": "H11"}
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1600, 1000)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.fov = 46
	viewport.add_child(camera)
	var menu := Library.new()
	menu.section = Library.Section.SETTINGS
	menu.tab = Library.BACKGROUND_TAB
	menu.settings_provider = func(): return state
	menu.setting_changed.connect(func(key, value): events.append([key, value]); state[key] = value)
	camera.add_child(menu)
	menu.position = Vector3(0, 0, -2.3)
	menu.toggle()
	menu.set_process(false)
	check(row(menu, "background").choices.any(func(option): return option.value == "cinema" and option.label == "Grand cinema"), "Background choices include the giant-screen auditorium")
	check(not row(menu, "background_yaw").is_empty() and not row(menu, "background_brightness").is_empty(), "Panorama controls remain available")
	check(has_label(menu, I18n.t(PANORAMA_HINT)), "Photo independence hint is visible on global panorama backgrounds")
	tap(menu, choice_target(menu, "background", null, "open"))
	tap(menu, choice_target(menu, "background", "cinema"))
	check(events.back() == ["background", "cinema"], "Same-hand ray release chooses the cinema background")
	check(row(menu, "background_yaw").is_empty() and row(menu, "background_brightness").is_empty(), "Cinema hides unsupported panorama direction and brightness")
	check(not has_label(menu, I18n.t(PANORAMA_HINT)), "Cinema keeps its full controls; background independence remains in the info tooltip")
	check(row(menu, "cinema_viewing_brightness").value == "low", "Viewing brightness defaults to the original darkest tier")
	for level in ["soft", "dim", "low"]:
		tap(menu, choice_target(menu, "cinema_viewing_brightness", level))
		check(events.back() == ["cinema_viewing_brightness", level], "Viewing brightness uses the real setting dispatch: " + level)
	check(row(menu, "cinema_screen_light").value == true, "Screen ambient light defaults on")
	tap(menu, choice_target(menu, "cinema_screen_light", false))
	check(events.back() == ["cinema_screen_light", false], "Ray toggles screen light independently")
	check(row(menu, "cinema_interaction").choices.map(func(option): return option.value) == ["watch", "move"], "Cinema exposes watch and teleport without seat selection")
	var before := events.size()
	menu.stick_scroll(-1.0, 0.4)
	check(events.size() == before and state.cinema_interaction == "watch", "Thumbstick never chooses an interaction mode")
	var seat_target := choice_target(menu, "cinema_interaction", "move")
	var point := origin(menu, seat_target)
	menu.press_pointer("left_hand", point, -menu.global_basis.z, true)
	check(events.size() == before, "Interaction does not commit on trigger press")
	menu.release_pointer("right_hand", point, -menu.global_basis.z, true)
	check(events.size() == before, "The other hand cannot commit a captured interaction")
	menu.release_pointer("left_hand", point, -menu.global_basis.z, true)
	check(events.back() == ["cinema_interaction", "move"], "Owning trigger release enables seat selection")
	tap(menu, choice_target(menu, "cinema_interaction", "move"))
	check(events.back() == ["cinema_interaction", "move"], "Movement reports the public setting key")
	tap(menu, Library.ROW_BASE + 2)
	check(events.back() == ["cinema_home", true], "Reset seat reports the home action")
	check(not menu.rows[2].has("detail"), "No seat number shown in teleport UI")
	state.cinema_ready = false
	state.cinema_loading = true
	menu.refresh()
	check(menu.status == "Loading cinema…", "Cinema loading has a concise status")
	for value in ["watch", "move"]:
		check(not bool(button(menu, choice_target(menu, "cinema_interaction", value)).get("enabled", true)), "Unavailable interaction is disabled: " + value)
	check(not bool(button(menu, Library.ROW_BASE + 2).get("enabled", true)), "Unavailable reset is disabled")
	before = events.size()
	tap(menu, choice_target(menu, "cinema_interaction", "watch"))
	tap(menu, Library.ROW_BASE + 2)
	check(events.size() == before, "Loading controls cannot dispatch actions")
	state.cinema_loading = false
	state.cinema_error = "Cinema unavailable"
	menu.refresh()
	check(menu.status == "Cinema unavailable", "Cinema errors replace the loading status")
	state.cinema_ready = true
	state.cinema_error = ""
	for hand in ["left_hand", "right_hand"]:
		menu.cancel_pointer(hand)
		menu.update_pointer(hand, Vector3.ZERO, Vector3.ZERO, false)
	var output := ProjectSettings.globalize_path("res://../../build/output/cinema-background-menu")
	if DisplayServer.get_name() != "headless": DirAccess.make_dir_recursive_absolute(output)
	for language in ["zh", "zh_Hant", "ja", "en"]:
		I18n.use(language)
		menu.refresh()
		check(row(menu, "cinema_interaction").title == I18n.t("Cinema interaction"), "Interaction title follows " + language)
		for text in ["Grand cinema", "Cinema interaction", "Screen ambient light", "Viewing brightness", "Soft light", "Dim", "Low light", "Watch", "Free movement", "Return to start", "Auto lights", "Lights on", "Lights off", "Loading cinema…", "Cinema unavailable"]:
			check(language == "en" or I18n.t(text) != text, "Translation exists: " + language + " " + text)
		for value in ["watch", "move"]:
			var control := button(menu, choice_target(menu, "cinema_interaction", value))
			var label: Label3D = control.node.get_child(0)
			check(menu.text_width(label.text, int(label.font_size / menu.TEXT_RASTER_SCALE)) <= control.rect.size.x,
				"Interaction button text fits: " + language + " " + value)
			var hit: Dictionary = menu.ray_hit(origin(menu, int(control.target)), -menu.global_basis.z)
			check(int(hit.get("target", -1)) == int(control.target), "Interaction remains ray-selectable: " + language + " " + value)
		if DisplayServer.get_name() != "headless":
			await process_frame
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			check(viewport.get_texture().get_image().save_png(output.path_join(language + "-cinema.png")) == OK, "Save cinema settings preview: " + language)
	menu.free()
	viewport.free()
	I18n.use("en")
	for failure in failures: push_error(failure)
	print("CINEMA_BACKGROUND_MENU checks=%d failures=%d" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
