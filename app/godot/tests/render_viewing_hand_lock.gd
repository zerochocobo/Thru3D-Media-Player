extends SceneTree
## Desktop renderer only: shared artwork, placement and progress feedback in all three entries.
const Menu := preload("res://scripts/player_menu.gd")
const Watch := preload("res://scripts/wrist_watch.gd")
const Indicator := preload("res://scripts/hand_lock_indicator.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/hand-lock/render")
var view: SubViewport
var camera: Camera3D
var failures: Array[String] = []

func _initialize() -> void: run.call_deferred()

func shot(label: String) -> void:
	for i in 4:
		await process_frame
		await RenderingServer.frame_post_draw
	if view.get_texture().get_image().save_png(output.path_join(label + ".png")) != OK: failures.append(label)

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	view = SubViewport.new(); view.size = Vector2i(1280, 800); view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(view)
	var environment := Environment.new(); environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.12, 0.16, 0.19)
	var world := WorldEnvironment.new(); world.environment = environment; view.add_child(world)
	camera = Camera3D.new(); camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.near = 0.01
	camera.size = 1.5; view.add_child(camera)
	var state := {"has_video": true, "title": "观影手势锁", "duration_ms": 7200000, "position_ms": 1320000,
		"watch_available": true, "watch_enabled": true, "hand_lock_available": true, "hand_locked": false}
	var menu := Menu.new(); menu.state_provider = func(): return state
	view.add_child(menu); menu.set_process(false); menu.toggle(); menu.position = Vector3(0, 0, -1)
	preload("res://scripts/i18n.gd").use("zh")
	for locked in [false, true]:
		state.hand_locked = locked; menu.refresh()
		await shot("panel-locked" if locked else "panel-unlocked")
	menu.set_hand_lock_progress(0.65); await shot("panel-hold")
	menu.free()
	var watch := Watch.new(); view.add_child(watch)
	watch.clock_provider = func(): return {"hour": 21, "minute": 47}
	watch.status_provider = func(): return {"level": 76, "clock24": true}
	watch.visible = true; watch.expand = 1; watch.face_reveal = 1
	watch.logic.phase = watch.Logic.Phase.EXPANDED
	watch.logic.holo = Transform3D(Basis.IDENTITY, Vector3(0, 0, -0.5))
	watch.logic.media = {"has_video": true, "playing": true, "duration_ms": 7200000, "position_ms": 1320000,
		"hand_lock_available": true, "hand_locked": false}
	camera.size = 0.3
	for locked in [false, true]:
		watch.logic.media.hand_locked = locked
		watch.logic.hand_lock_progress = 0.65 if locked else 0.0
		for i in 40: watch._present(Transform3D.IDENTITY, 0.02)
		await shot("watch-locked-hold" if locked else "watch-unlocked")
	watch.free()
	var indicator := Indicator.new(); view.add_child(indicator)
	var gesture := preload("res://scripts/hand_lock_gesture.gd").new()
	gesture.shown = true; gesture.hit = true; gesture.progress = 0.65
	gesture.target = Transform3D(Basis.IDENTITY, Vector3(0, 0, -0.5))
	gesture.cursor = Vector3(0.025, 0.01, -0.498)
	indicator.sync(gesture, [Vector3(0.1, -0.05, -0.2), Vector3(-0.2, 0.1, -1).normalized()], 1.0)
	await shot("independent-hold")
	# Exercise the same companion capture used when native video layers are active.
	var origin := Node3D.new(); view.add_child(origin)
	var display := preload("res://scripts/xr_display.gd").new()
	display.configure(view, environment, null, true)
	var compositor := preload("res://scripts/menu_composition.gd").new(); view.add_child(compositor)
	compositor.configure(origin, camera, display, [], false, true)
	compositor.register_companion(indicator); compositor.update()
	for i in 8:
		await process_frame
		await RenderingServer.frame_post_draw
	var captured := false
	for slot in compositor.slots:
		if slot.used and slot.nodes.has(indicator.icon) and slot.nodes.has(indicator.ring):
			captured = true
			if slot.raw.get_texture().get_image().save_png(output.path_join("independent-compositor.png")) != OK: failures.append("compositor image")
	if not captured: failures.append("Recovery icon and progress ring must share a companion capture")
	compositor.shutdown("test_finished"); compositor.free()
	view.free()
	for failure in failures: push_error(failure)
	print("Hand lock render: 7 images, %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)
