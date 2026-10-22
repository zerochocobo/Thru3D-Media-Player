extends SceneTree
const PipTest := preload("res://tests/test_video_pip.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Icons := preload("res://scripts/menu_icons.gd")
var checks := 0
var failures: Array[String] = []
class DistanceMain extends PipTest.RoutingMain:
	func _stick_seek_sample() -> Dictionary: return {}
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func ray_to(window: Node3D, point: Vector2) -> Array:
	return [window.to_global(Vector3(point.x,point.y,0.8)), -window.global_basis.z]
func run() -> void:
	var video := PipTest.Surface.new(); root.add_child(video)
	video.geometry = 3; video.stereo_sbs = true; video._apply_geometry()
	var pip: RefCounted = video.pip
	var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0))
	pip.toggle_slot(3, head)
	check(pip.windows.keys() == [3] and pip.windows[3].global_position.x > 0, "Camera 3 opens alone at the fixed right position")
	var third: Node3D = pip.windows[3]; var pose: Transform3D = third.global_transform
	pip.toggle_slot(1, head); pip.toggle_slot(3, head)
	check(pip.windows.keys() == [1], "Toggling camera 3 leaves camera 1 open without renumbering")
	pip.toggle_slot(3, head)
	check(pip.windows[3].global_transform.is_equal_approx(pose), "Reopening a camera restores its preset, independently of total count")
	pip.sync()
	var window: Node3D = pip.windows[1]
	var main_eye: Variant = video.material.get_shader_parameter("viewing_eye")
	var third_zoom: float = pip.windows[3].zoom
	for zoom in [1, 4, 8]:
		pip._action(1, "zoom", zoom)
		check(window.picture.get_shader_parameter("pip_viewing_eye") == 1, "Every magnification displays the same source eye to both eyes")
	check(video.material.get_shader_parameter("viewing_eye") == main_eye and pip.windows[3].zoom == third_zoom, "PiP changes neither the main stereo policy nor another camera's zoom")
	video.material.set_shader_parameter("viewing_eye", 2); pip.sync()
	check(window.picture.get_shader_parameter("pip_viewing_eye") == 2, "An explicit main source-eye selection is preserved in the mono crop")
	check(window._buttons.all(func(button): return button.target != 5), "PiP has no 3D toggle")
	video.material.set_shader_parameter("viewing_eye", 0); pip.sync()
	video.geometry = 0; video._apply_geometry(); pip.sync()
	window.set_aspect(3)
	var span: Vector2 = window.crop_span()
	check(is_equal_approx(window.size.x / window.size.y, 1.0) and is_equal_approx(window.source_aspect * span.x / span.y, 1.0), "Square windows crop rather than stretching the original aspect")
	window.set_aspect(4); span = window.crop_span()
	check(is_equal_approx(window.source_aspect * span.x / span.y, 9.0 / 16.0), "Portrait windows retain the source's correct geometry")
	var custom: Vector2 = window.size
	video.geometry = 3; video._apply_geometry(); pip.sync()
	check(window.size == custom, "Changing source projection preserves a chosen window shape")
	check(is_equal_approx(window.tangent().x / window.tangent().y, 9.0 / 16.0), "Panorama selection and sampling use the window's actual aspect")
	window.set_aspect(0); window.controls = true; window.refresh()
	var point: Vector2 = window.edge_point(3)
	var opposite: Vector3 = window.to_global(Vector3(-point.x, 0, 0))
	var ray: Array = ray_to(window, point)
	var before: Vector2 = window.size; var zoom: float = window.zoom
	check(pip.press("right_hand", "trigger_click", ray, null, head) and pip.resize.get("edge") == 3, "A side handle captures independent width resizing")
	ray = ray_to(window, point + Vector2(0.12, 0))
	pip.update_input({"right_hand": ray}, {}, head, 1000)
	check(window.size.x > before.x and is_equal_approx(window.size.y, before.y) and is_equal_approx(window.zoom, zoom), "Changing width preserves height and per-camera magnification")
	check(window.to_global(Vector3(-window.size.x / 2, 0, 0)).distance_to(opposite) < 0.0001, "The opposite side stays fixed while changing width")
	pip.release("right_hand", "trigger_click")
	for button in window._buttons:
		check(window.controls_root.is_ancestor_of(button.node), "Toolbar controls belong to the HD capture root")
	check(not window.controls_root.is_ancestor_of(window.frame), "Video never enters the menu capture")
	var pick: Dictionary = window._buttons.filter(func(button): return button.target == 2)[0]
	window.update_pointer("right_hand", pick.node.to_global(Vector3(0, 0, 0.5)), -window.global_basis.z, true)
	check(is_instance_valid(window._tooltip) and window.controls_root.is_ancestor_of(window._tooltip), "Hover captions work without a library backdrop and remain in the HD root")
	check(Icons.PATHS.get("pick_region", "") != Icons.PATHS.get("recenter", ""), "Source selection has a distinct cursor-in-frame icon")
	# Exercise the production main-input route, including stick ownership and rearming.
	var main := DistanceMain.new(); root.add_child(main)
	main.video = video
	ray = ray_to(window, Vector2.ZERO)
	var grip_pose: Transform3D = main._move_pose("right_hand")
	check(pip.press("right_hand", "grip_click", ray, grip_pose, head), "Grip captures a camera for joystick distance")
	var initial: Transform3D = window.global_transform
	var physical_size: Vector2 = window.size
	var third_pose: Transform3D = pip.windows[3].global_transform
	main._process_stick_input(Vector2.ZERO, Vector2(0, 1), 0.1)
	check(window.global_transform.is_equal_approx(initial), "A preheld stick waits for centre before moving the camera")
	main._process_stick_input(Vector2.ZERO, Vector2.ZERO, 0.1)
	main._process_stick_input(Vector2(0, 1), Vector2.ZERO, 0.1)
	check(window.global_transform.is_equal_approx(initial), "The other hand's joystick cannot change distance")
	main._process_stick_input(Vector2.ZERO, Vector2(0, 1), 0.1)
	check(window.global_position.distance_to(head.origin) > initial.origin.distance_to(head.origin) + 0.1, "Grip plus the same hand's forward stick pushes the camera farther")
	for i in 100: main._process_stick_input(Vector2.ZERO, Vector2(0, 1), 0.1)
	check(is_equal_approx(window.global_position.distance_to(head.origin), 8), "Far distance uses the existing eight-metre bound")
	for i in 100: main._process_stick_input(Vector2.ZERO, Vector2(0, -1), 0.1)
	check(is_equal_approx(window.global_position.distance_to(head.origin), 0.6), "Pulling the stick brings the camera closer within the existing bound")
	check(window.size == physical_size and window.zoom == zoom and pip.windows[3].global_transform.is_equal_approx(third_pose), "Distance preserves size, zoom and other cameras")
	pip.release("right_hand", "grip_click"); initial = window.global_transform
	check(not pip.adjust_distance("right_hand", Vector2(0, 1), 0.1, grip_pose, head) and window.global_transform == initial, "Releasing grip stops distance changes")
	main.video = null; main.queue_free()
	var menu := Menu.new()
	menu.state_provider = func(): return {"has_video": true, "pip_slots": [1, 3], "pip_count": 2, "bookmarks": [{"id":"a","position_ms":1000}], "duration_ms":10000}
	root.add_child(menu); menu.toggle(); menu._activate(Menu.PIP)
	var entry: Dictionary = menu._buttons.filter(func(button): return button.target == Menu.PIP)[0]
	var bookmark: Dictionary = menu._buttons.filter(func(button): return button.target == menu.bookmarks.LIST)[0]
	check(not entry.rect.intersects(bookmark.rect) and bookmark.rect.get_center().x < entry.rect.get_center().x, "Bookmark entry moves left without overlapping PiP")
	check(menu._buttons.all(func(button): return button.target != Menu.PIP_COUNT + 2), "Unopened cameras have no numbered placeholder")
	check(menu.PipControls.next_slot(menu._state) == 2, "Add fills the lowest unused identity without renumbering")
	for slot in [1, 3]:
		var button: Dictionary = menu._buttons.filter(func(value): return value.target == Menu.PIP_COUNT + slot)[0]
		menu.update_pointer("right_hand", button.node.to_global(Vector3(0,0,0.5)), -button.node.global_basis.z, true)
		pip.identify(menu.pip_controls.hovered_slots())
		check(pip.windows[slot].identified and not pip.windows[4 - slot].identified, "Hover identifies the corresponding world window")
		var face: Dictionary = menu.pip_controls._faces.filter(func(value): return value.slot == slot)[0]
		check(face.icon.visible and not face.number.visible and menu.ray_hit(button.node.to_global(Vector3(0,0,0.5)), -button.node.global_basis.z).get("target", -1) == button.target, "Hover replaces the number without changing its hit target")
	pip.clear(); menu.queue_free(); video.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Video PiP refinements: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
