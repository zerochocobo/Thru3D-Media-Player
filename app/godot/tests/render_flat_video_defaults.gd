extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var state := {"has_video": true, "geometry": 0, "playing": true, "screen_distance": 0.8, "screen_scale": 150.0, "screen_default_locked": false}
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/flat-video-defaults/visuals")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1280, 1000); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var menu := Menu.new(); menu.state_provider = func(): return state
	menu.adjustment_requested.connect(func(key, value):
		if key == "screen_set_default": state.screen_default_locked = bool(value))
	camera.add_child(menu); menu.position.y = -0.45; menu.toggle(); menu._activate(Menu.SCREEN_SETTINGS)
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language)
		for spatial in [false, true]:
			state.spatial_video = spatial; state.spatial_metadata = {"horizontal_fov_degrees": 90} if spatial else {}
			state.spatial_fov_available = spatial
			for saved in [false, true]:
				state.screen_default_locked = not saved; menu.refresh()
				var selected_target: int = Menu.SCREEN_SET_DEFAULT if saved else Menu.SCREEN_AUTO_DEFAULT
				var button: Dictionary = menu._buttons.filter(func(row): return row.target == selected_target)[0]
				var node: Node3D = button.node
				var origin: Vector3 = node.to_global(Vector3(0, 0, 0.5)); var direction := -node.global_basis.z
				check(menu.ray_hit(origin, direction).get("target", -1) == selected_target, "Default mode button has a clear ray target: " + language)
				check(button.base_color == Menu.TILE, "Inactive mode starts unselected")
				menu.press_pointer("right_hand", origin, direction, true); menu.release_pointer("right_hand", origin, direction, true)
				check(state.screen_default_locked == saved and menu.visible, "Selecting a default mode preserves settings visibility")
				for mode_target in [Menu.SCREEN_SET_DEFAULT, Menu.SCREEN_AUTO_DEFAULT]:
					var mode_button: Dictionary = menu._buttons.filter(func(row): return row.target == mode_target)[0]
					var active: bool = (mode_target == Menu.SCREEN_SET_DEFAULT) == saved
					check(mode_button.base_color == (Menu.SELECTED if active else Menu.TILE), "Automatic and locked modes have exclusive selected styling")
				for target in [450, 451, 452, Menu.SETTINGS_CLOSE, 108] + ([Menu.SPATIAL_FOV] if spatial else []):
					var row: Dictionary = menu._buttons.filter(func(item): return item.target == target)[0]
					check(menu.ray_hit(row.node.to_global(Vector3(0, 0, 0.5)), -row.node.global_basis.z).get("target", -1) == target, "Existing control remains reachable: " + str(target))
				menu.cancel_pointer("right_hand")
				await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
				var filename := "%s-%s-%s.png" % [language, "spatial" if spatial else "flat", "locked" if saved else "automatic"]
				check(viewport.get_texture().get_image().save_png(output.path_join(filename)) == OK, "Screenshot saved: " + filename)
	for failure in failures: push_error(failure)
	print("Flat video defaults render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
