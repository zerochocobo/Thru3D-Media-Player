extends SceneTree
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
const MODES := ["single", "repeat_one", "sequence", "repeat_all"]
var state := {"has_video": true, "geometry": 0, "playing": true, "playback_state": "playing", "playback_mode": "single", "duration_ms": 60000, "position_ms": 1000}
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var output := ProjectSettings.globalize_path("res://../../build/output/video-modes-ray/visuals")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1280, 1000); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var camera := Camera3D.new(); camera.fov = 60; viewport.add_child(camera)
	var menu := Menu.new(); menu.state_provider = func(): return state
	menu.action_requested.connect(func(operation):
		if operation == "loop": state.playback_mode = MODES[(MODES.find(state.playback_mode) + 1) % MODES.size()])
	camera.add_child(menu); menu.set_process(false); menu.position.y = -0.45; menu.toggle(); menu.section = 1
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language)
		for mode in MODES:
			state.playback_mode = mode; menu.refresh()
			var target: int = Menu.SETTINGS_TILE + Menu.OPERATIONS[1].find("loop")
			var button: Dictionary = menu._buttons.filter(func(b): return b.target == target)[0]
			var position: Vector3 = button.node.global_position
			var origin: Vector3 = button.node.to_global(Vector3(0, 0, 0.5))
			var direction: Vector3 = -button.node.global_basis.z
			check(menu.ray_hit(origin, direction).get("target") == target, "Mode tile has an unobstructed ray target")
			check(button.node.find_children("*", "MeshInstance3D", true, false).any(func(mesh): return mesh.material_override is StandardMaterial3D and mesh.material_override.albedo_texture == menu.Icons.texture(Menu.PLAYBACK_MODE_ICONS[mode])), "Visible icon matches the current mode")
			check(menu._tips[target] == I18n.t(Menu.PLAYBACK_MODE_TIPS[mode]), "Tooltip describes the current mode")
			menu._hover = {"right_hand": target}; menu._update_tooltip()
			await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
			check(viewport.get_texture().get_image().save_png(output.path_join(language + "-" + mode + ".png")) == OK, "Save current mode and tooltip preview")
			menu.press_pointer("right_hand", origin, direction, true); menu.release_pointer("right_hand", origin, direction, true)
			check(state.playback_mode == MODES[(MODES.find(mode) + 1) % MODES.size()] and menu.choices.opened.is_empty(), "Ray click cycles once without a dropdown")
			check(menu._buttons.filter(func(b): return b.target == target)[0].node.global_position.is_equal_approx(position), "Mode tile stays in place after cycling")
	viewport.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Video playback modes render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
