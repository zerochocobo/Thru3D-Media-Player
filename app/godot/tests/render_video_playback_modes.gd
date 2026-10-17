extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var state := {"has_video": true, "geometry": 0, "playing": true, "playback_state": "playing", "playback_mode": "single", "duration_ms": 60000, "position_ms": 1000}
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func click(menu: Node3D, target: int) -> bool:
	var buttons: Array = menu._buttons.filter(func(button): return button.target == target and button.enabled)
	if buttons.is_empty(): return false
	var node: Node3D = buttons[0].node
	var origin: Vector3 = node.to_global(Vector3(0, 0, 0.5))
	menu.press_pointer("right_hand", origin, -node.global_basis.z, true)
	menu.release_pointer("right_hand", origin, -node.global_basis.z, true)
	return true

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/video-modes-ray/visuals")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1280, 1000); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var menu := Menu.new(); menu.state_provider = func(): return state
	menu.setting_requested.connect(func(key, value): state[key] = value)
	camera.add_child(menu); menu.position.y = -0.45; menu.toggle(); menu.section = 1
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language); menu.refresh()
		for mode in ["single", "repeat_one", "sequence", "repeat_all"]:
			menu.choices.opened = "playback_mode"; menu.refresh()
			var targets: Array = menu.choices.targets.keys().filter(func(id): return menu.choices.targets[id].get("kind") == "choose" and menu.choices.targets[id].get("key") == "playback_mode")
			check(targets.size() == 4, "All playback modes are visible together: " + language)
			for id in targets:
				var button: Dictionary = menu._buttons.filter(func(row): return row.target == id)[0]
				var node: Node3D = button.node
				var hit: Dictionary = menu.ray_hit(node.to_global(Vector3(0, 0, 0.5)), -node.global_basis.z)
				check(hit.get("target", -1) == id, "Every mode has an unoccluded ray target: " + language)
			var selected: Array = targets.filter(func(id): return menu.choices.targets[id].value == mode)
			check(selected.size() == 1 and click(menu, selected[0]) and state.playback_mode == mode and menu.visible, "Ray selects the exact mode and keeps settings open: " + language + "/" + mode)
			if mode == "repeat_all":
				await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
				check(viewport.get_texture().get_image().save_png(output.path_join(language + "-selected.png")) == OK, "Selected mode screenshot saved")
		menu.choices.opened = "playback_mode"; menu.refresh()
		await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
		check(viewport.get_texture().get_image().save_png(output.path_join(language + "-choices.png")) == OK, "Four mode choices screenshot saved")
		menu.choices.reset()
	for failure in failures: push_error(failure)
	print("Video playback modes render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
