extends SceneTree
const PipTest := preload("res://tests/test_video_pip.gd")
const Menu := preload("res://scripts/player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var video := PipTest.Surface.new(); root.add_child(video); video.geometry = 3; video._apply_geometry()
	var head := Transform3D(Basis(Vector3.FORWARD, 0.3), Vector3(0, 1.5, 0))
	video.pip.set_count(1, head)
	var pip: RefCounted = video.pip
	var window: Node3D = pip.windows[1]
	window.global_basis *= Basis(Vector3.FORWARD, 0.4)
	var direction: Vector3 = (window.global_position - head.origin).normalized()
	var pose := Transform3D(Basis.looking_at(direction), head.origin)
	check(pip.press("right_hand", "grip_click", [head.origin, direction], pose, head), "Grip captures a previously banked window")
	var physical_size: Vector2 = window.size; var zoom: float = window.zoom
	for cycle in 3:
		for angles in [Vector2(0.7, 0.5), Vector2(-0.8, 0.3), Vector2(0.4, -0.6), Vector2(-0.2, 0.8), Vector2.ZERO]:
			pose.basis = Basis(Vector3.UP, angles.x) * Basis(Vector3.RIGHT, angles.y)
			pip.update_input({"right_hand": [pose.origin, -pose.basis.z]}, {"right_hand": pose}, head, 1000 + cycle * 200)
			check(absf(window.global_basis.x.y) < 0.00001 and window.global_basis.y.y > 0, "Repeated diagonal drags retain gravity-aligned horizontal edges")
			check(window.global_basis.z.dot((head.origin - window.global_position).normalized()) > 0.9999, "The upright window still faces the viewer")
	check(window.size == physical_size and window.zoom == zoom, "Upright dragging preserves size and zoom")
	pip.release("right_hand", "grip_click")
	var fixed: Transform3D = window.global_transform
	pip.update_input({}, {}, Transform3D(Basis(Vector3.UP, 1), head.origin + Vector3(0.1, 0, 0)), 2000)
	check(window.global_transform.is_equal_approx(fixed), "Released windows remain world-fixed")
	var language := I18n.choice; I18n.use("zh")
	window.controls = true; window.shape_open = true; window.set_aspect(0); window.refresh()
	check(I18n.t("Source aspect") == "原片比例", "Source aspect has a context-specific translation")
	var source: Dictionary = window._buttons.filter(func(b): return b.target == 20)[0]
	check(source.selected and source.foreground.r > 0.9, "The selected aspect retains bright readable text")
	check(source.node.get_child_count() >= 6, "Selection has a visible border and check mark, beyond its fill colour")
	window.custom_shape = true; window.set_size(Vector2(0.51, 0.27))
	check(window.aspect_index() == -1 and window._buttons.filter(func(b): return b.target >= 20).all(func(b): return not b.selected), "A manually chosen non-preset ratio clears every preset selection")
	window.set_aspect(3); window.set_size(window.size * 1.1)
	check(window.aspect_index() == 3, "Uniform physical enlargement retains the chosen aspect")
	I18n.use(language)
	var state := {"has_video": true, "pip_slots": [1, 3], "pip_count": 2}
	var menu := Menu.new()
	menu.state_provider = func(): return state
	root.add_child(menu)
	menu.toggle(); menu._activate(Menu.PIP)
	var actions: Array = []; menu.action_requested.connect(func(action): actions.append(action))
	var number: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.PIP_COUNT + 1)[0]
	var origin: Vector3 = number.node.to_global(Vector3(0, 0, 0.5)); var ray: Vector3 = -number.node.global_basis.z
	menu.press_pointer("right_hand", origin, ray, true); menu.release_pointer("right_hand", origin, ray, true)
	check(actions.back() == "pip_slot_1" and state.pip_slots == [1, 3], "The whole numbered square closes its window")
	menu.update_pointer("right_hand", origin, ray, true)
	var face: Dictionary = menu.pip_controls._faces[0]
	check(face.icon.visible and not face.number.visible, "Hover replaces the number with a large X")
	check(number.rect.size == Vector2.ONE * 0.072 and face.icon.mesh.size.x >= 0.048, "Slot hit area is square and X is large")
	menu.cancel_pointer("right_hand")
	check(menu.pip_controls.hovered_slots().is_empty(), "Losing the pointer clears identification")
	menu._pip_open = false
	for has_bookmarks in [false,true]:
		for has_music in [false,true]:
			state.bookmarks = [{"id":"a","position_ms":1000}] if has_bookmarks else []
			state.audio_play_during_video = has_music
			menu.refresh()
			var targets: Array = [Menu.PIP,107,100,108]
			if has_bookmarks: targets.push_front(menu.bookmarks.LIST)
			if has_music: targets.push_front(Menu.MUSIC_OPEN)
			var previous := Vector2.ZERO
			for i in targets.size():
				var button: Dictionary = menu._buttons.filter(func(b):return b.target==targets[i])[0]
				var centre: Vector2 = button.rect.get_center()
				if i > 0: check(is_equal_approx(centre.x-previous.x,0.14) and is_equal_approx(centre.y,previous.y), "Optional music/bookmark entries pack into the same row spacing without gaps")
				previous = centre
			check(menu._buttons.any(func(b):return b.target==menu.bookmarks.LIST)==has_bookmarks and menu._buttons.any(func(b):return b.target==Menu.MUSIC_OPEN)==has_music, "Optional entries retain their visibility conditions")
	pip.clear(); menu.queue_free(); video.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Video PiP feedback: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
