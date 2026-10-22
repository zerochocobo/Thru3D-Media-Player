extends SceneTree
## The control bar offers the wrist watch toggle beside the lock only while hands are tracked.
const Menu := preload("res://scripts/player_menu.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	preload("res://scripts/i18n.gd").use("zh")
	var output := OS.get_environment("THRU3D_TEST_OUTPUT")
	if output.is_empty(): output = ProjectSettings.globalize_path("res://../../build/output/watch-toggle")
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 520)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.fov = 40
	viewport.add_child(camera)
	var state := {"has_video": true, "title": "一段很长很长的旅行记录标题 · VR180 · 2026 夏天 · 山海之间的第三天清晨", "duration_ms": 7200000,
		"position_ms": 1320000, "watch_available": true, "watch_enabled": true}
	var menu := Menu.new()
	menu.state_provider = func(): return state
	var actions: Array[String] = []
	menu.action_requested.connect(func(operation): actions.append(operation))
	camera.add_child(menu); menu.toggle()
	menu.position = Vector3(0, 0, -1.25)
	for mode in ["on", "off", "controllers"]:
		state.watch_enabled = mode != "off"
		state.watch_available = mode != "controllers"
		menu.refresh()
		await process_frame
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		viewport.get_texture().get_image().save_png(output.path_join("bar-" + mode + ".png"))
		var offered: bool = menu._buttons.any(func(button): return button.target == Menu.WATCH)
		check(offered == (mode != "controllers"), "Watch toggle offered only with hands: " + mode)
	state.watch_available = true
	menu.refresh()
	menu._activate(Menu.WATCH)
	check(actions == ["wrist_watch_toggle"], "Touching the watch glyph asks to toggle it")
	menu.free(); viewport.free()
	for failure in failures: push_error(failure)
	print("Watch toggle render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
