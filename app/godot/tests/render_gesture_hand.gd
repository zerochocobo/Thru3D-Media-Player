extends SceneTree
const Menu := preload("res://scripts/library_menu.gd")
const Bindings := preload("res://scripts/controller_bindings.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
var saved: Array[Dictionary] = []

func _initialize() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/gesture-hand/previews")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1600, 1050); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var menu := Menu.new(); camera.add_child(menu)
	menu.settings_provider = func(): return {}
	menu.setting_changed.connect(func(key, value):
		if key == "controller_bindings": saved.append(value))
	menu.toggle(); menu.section = Menu.Section.SETTINGS; menu.tab = Menu.CONTROLS_TAB
	menu.controls_page.mode = 1; menu.controls_page.selected_gesture = 5; menu.refresh()
	check(menu.controls_page.bindings.pinch_hand == "right_hand", "Fresh gesture page defaults to right hand")
	for language in ["zh", "en", "zh_Hant", "ja"]:
		I18n.use(language); menu.refresh()
		for index in 3:
			var target: int = menu.ControlsPage.PINCH_HAND + index
			var button: Dictionary = menu._buttons.filter(func(item): return item.target == target)[0]
			var origin: Vector3 = button.node.to_global(Vector3(0, 0, 1))
			check(menu.ray_hit(origin, -menu.global_basis.z).get("target") == target, "Button has an unobstructed ray target")
			var before := saved.size()
			menu.press_pointer("right_hand", origin, -menu.global_basis.z, true)
			menu.release_pointer("right_hand", origin, -menu.global_basis.z, true)
			var hand: String = menu.ControlsPage.PINCH_HANDS[index]
			check(menu.controls_page.bindings.pinch_hand == hand and saved.size() == before + 1, "Ray click changes and saves gesture hand: " + language + "/" + hand)
			check(menu.choices.opened.is_empty() and menu.choices.targets.is_empty(), "Hand switching never opens a select popup")
			var config := ConfigFile.new(); config.set_value("input", "controller_bindings", saved.back())
			var path := output.path_join("settings-test.cfg")
			check(config.save(path) == OK, "Save global gesture preference")
			var loaded := ConfigFile.new(); check(loaded.load(path) == OK, "Read global gesture preference")
			var restored := Bindings.new(); restored.restore(loaded.get_value("input", "controller_bindings"))
			check(restored.pinch_hand == hand, "Reload retains selected hand")
			menu.update_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)
			menu._draw(); menu.controls_page.demo.animate = false; menu.controls_page.demo.show_phase(0.55)
			var buttons := menu._buttons.filter(func(item): return item.target in range(menu.ControlsPage.PINCH_HAND, menu.ControlsPage.PINCH_HAND + 3))
			check(buttons.size() == 3, "Exactly three hand buttons")
			for item in buttons:
				check(item.base_color == (menu.ACCENT if item.target == target else menu.TILE), "Only selected hand is highlighted")
				check(item.rect.position.y > 0.225, "Buttons stay above gesture demo")
				for child in item.node.get_children():
					if child is Label3D:
						var width: float = child.font.get_string_size(child.text, HORIZONTAL_ALIGNMENT_LEFT, -1, child.font_size).x * child.pixel_size
						check(width <= item.rect.size.x, "Localized button label fits: " + child.text)
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			viewport.get_texture().get_image().save_png(output.path_join(language + "-gesture-hand-%d.png" % index))
	menu.queue_free(); viewport.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	FileAccess.open(output.path_join("gesture-verification.json"), FileAccess.WRITE).store_string(JSON.stringify({"checks":checks, "failures":failures}, "\t"))
	print("Gesture hand render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
