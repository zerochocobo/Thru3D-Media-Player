extends SceneTree
const Pip := preload("res://scripts/video_pip.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Binding := preload("res://scripts/pair_texture_binding.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
var checks := 0
var failures: Array[String] = []

class Host extends "res://tests/test_player_menu.gd".Host:
	var fail := false
	func open_mpv_video(uri: String, start: int, stereo: bool, profile: String, alpha: bool, vulkan: bool, depth: bool = false, tb: bool = false, exact: bool = false) -> int:
		return 0 if fail else super.open_mpv_video(uri, start, stereo, profile, alpha, vulkan, depth, tb, exact)

class Surface extends "res://scripts/media_surface.gd":
	func portrait_requested() -> bool: return false
	var _binding := preload("res://scripts/pair_texture_binding.gd").new()
	var pip := preload("res://scripts/video_pip.gd").new(self)
	func _ready() -> void:
		initialize_surface(preload("res://shaders/video_rvm_pair.gdshader"))
		_binding.material = material
		_flat.size = Vector2(1.6, 0.9); panel.visible = true

class RoutingMain extends "res://scripts/main.gd":
	var test_ray: Variant
	var test_menu: Node3D
	func _ready() -> void: pass
	func _process(_delta: float) -> void: pass
	func _input_focused() -> bool: return true
	func _active_menu() -> Node3D: return test_menu
	func _ray(_hand: String) -> Variant: return test_ray
	func _head_pose() -> Variant: return Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0))
	func _move_pose(_hand: String) -> Variant: return Transform3D(Basis.IDENTITY, Vector3(0, 1.2, 0))

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func ray_to(window: Node3D, point: Vector2) -> Array:
	return [window.to_global(Vector3(point.x, point.y, 0.8)), -window.global_basis.z]

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var video := Surface.new(); root.add_child(video)
	var pip: RefCounted = video.pip
	var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0))
	var config := ConfigFile.new()
	config.set_value("privacy", "history", false); config.set_value("privacy", "file_settings", false)
	config.set_value("pip", "zoom_2", 3.0); config.set_value("pip", "zoom_3", NAN)
	pip.load_settings(config)
	check(pip.preferences == {1: 1.0, 2: 3.0, 3: 1.0}, "Per-slot defaults, corrupt value and independent privacy switches")
	pip.zoom_changed.connect(func(slot, zoom): config.set_value("pip", "zoom_%d" % slot, zoom))
	video.geometry = 3; video._apply_geometry()
	pip.set_count(1, head)
	var first: Node3D = pip.windows[1]
	var first_pose: Transform3D = first.global_transform
	check(first.global_position.y > head.origin.y and is_zero_approx(first.global_position.x), "Panorama slot 1 is above centre")
	var elevation := atan2(first.global_position.y-head.origin.y, head.origin.z-first.global_position.z)
	check(elevation > deg_to_rad(4) and elevation < deg_to_rad(10), "Panorama slot 1 is only slightly above centre, within comfortable forward view")
	pip.set_count(3, Transform3D(Basis(Vector3.UP, PI / 2), head.origin + Vector3(2, 0, 0)))
	check(pip.windows[2].global_position.x < 0 and pip.windows[3].global_position.x > 0, "Later slots use the original group heading and head position")
	check(first.global_transform.is_equal_approx(first_pose), "Adding windows never moves existing windows")
	var poses := [pip.windows[2].global_transform, pip.windows[3].global_transform]
	pip.windows[2].global_transform = first_pose; pip.windows[3].global_transform = first_pose
	var overlap_ray := ray_to(first, Vector2.ZERO)
	check(pip.hit(overlap_ray[0], overlap_ray[1]).get("slot") == 3 and pip.windows[3].picture.render_priority > first.picture.render_priority, "Overlapping windows have matching stable visual and input order")
	pip.windows[2].global_transform = poses[0]; pip.windows[3].global_transform = poses[1]
	check(is_equal_approx(pip.windows[2].zoom, 3), "Slot 2 restores its own global magnification")
	var second: Node3D = pip.windows[2]
	pip.close(1)
	check(pip.windows.keys() == [2, 3] and pip.windows[2] == second, "Closing first does not renumber remaining slots")
	pip.set_count(2, head)
	check(not pip.windows.has(1), "Selecting current total leaves holes intact")
	pip.set_count(3, head)
	check(pip.windows.has(1) and pip.windows[1].global_transform.is_equal_approx(first_pose), "Increasing fills lowest free slot at its fixed location")
	pip._action(1, "zoom", 4.0)
	pip.set_count(1, head)
	check(pip.windows.keys() == [1], "Reducing total removes highest numbered slots")
	pip.clear(); pip.load_settings(config); pip.set_count(1, head)
	check(is_equal_approx(pip.windows[1].zoom, 4) and pip.selecting == 0, "New media preserves global zoom but clears selection")
	var window: Node3D = pip.windows[1]
	window.hover(true, 100); check(not window.controls, "Hover delay prevents flashing controls")
	window.hover(true, 250); check(window.controls, "Toolbar appears after 150 ms")
	window.hover(false, 849); check(window.controls, "Toolbar remains through the gap")
	window.hover(false, 850); check(not window.controls, "Toolbar hides after 600 ms")
	window.controls = true; window.refresh()
	var ray := ray_to(window, Vector2(0, -window.size.y / 2 - 0.012))
	check(not pip.hit(ray[0], ray[1]).is_empty(), "Invisible corridor bridges frame and toolbar")
	var corner: Vector2 = window.corner_point(3)
	var opposite: Vector3 = window.to_global(Vector3(-corner.x, -corner.y, 0))
	ray = ray_to(window, corner)
	check(pip.press("right_hand", "trigger_click", ray, null, head) and pip.blocked(), "Trigger at corner captures resize")
	var zoom: float = window.zoom
	var original_size: Vector2 = window.size
	var moved := ray_to(window, corner * 1.7)
	pip.update_input({"right_hand": moved}, {}, head, 1000)
	check(window.size.x > original_size.x and is_equal_approx(window.size.x / window.size.y, original_size.x / original_size.y), "Resize preserves aspect ratio")
	var fixed: Vector2 = window.corner_point(0)
	check(window.to_global(Vector3(fixed.x, fixed.y, 0)).distance_to(opposite) < 0.0001 and is_equal_approx(window.zoom, zoom), "Opposite corner stays fixed and physical resize does not change zoom")
	check(not pip.release("left_hand", "trigger_click") and pip.blocked(), "Other hand cannot release capture")
	check(pip.release("right_hand", "trigger_click") and not pip.blocked(), "Owner release ends resize")
	ray = ray_to(window, Vector2.ZERO)
	var pose := Transform3D(Basis.looking_at(ray[1]), ray[0])
	check(pip.press("right_hand", "grip_click", ray, pose, head), "Grip captures only the aimed window")
	var before: Transform3D = window.global_transform
	pose.origin.x += 0.12
	pip.update_input({"right_hand": ray}, {"right_hand": pose}, head, 1100)
	check(not window.global_transform.is_equal_approx(before), "Existing interface movement moves the window")
	pip.cancel_pointer("right_hand"); check(not pip.blocked(), "Tracking loss cancels grip")
	before = window.global_transform
	pip.update_input({}, {}, Transform3D(Basis(Vector3.UP, 1), head.origin), 1200)
	check(window.global_transform.is_equal_approx(before), "Released window stays world fixed after head rotation")
	pip._action(1, "select", 0)
	check(pip.selecting == 1 and pip.blocked(), "Selection blocks playback shortcuts")
	check(not pip.source_hit(head.origin, Vector3.RIGHT).is_empty(), "360 selection reaches sideways")
	var saved: Basis = window.crop_basis
	pip.update_input({"right_hand": [head.origin, Vector3.RIGHT]}, {}, head, 1300)
	check(window.crop_basis == saved and not pip.candidate.is_empty(), "Hover preview never commits selection")
	pip.press("right_hand", "by_button", null, null, head)
	check(pip.selecting == 0 and window.crop_basis == saved, "Back cancels preview")
	pip._action(1, "select", 0)
	pip.press("right_hand", "trigger_click", [head.origin, Vector3.RIGHT], null, head)
	check(pip.selecting == 0 and (-window.crop_basis.z).dot(Vector3.RIGHT) > 0.99, "Trigger commits selected source direction")
	video.geometry = 1; video._apply_geometry()
	check(pip.source_hit(head.origin, Vector3.BACK).is_empty(), "180 rejects rear hemisphere")
	video.geometry = 2; video.fisheye_fov = 180; video._apply_geometry()
	check(pip.source_hit(head.origin, Vector3.BACK).is_empty(), "Fisheye rejects directions outside the lens")
	video.geometry = 0; video._apply_geometry()
	var center: Vector3 = video.panel.global_position
	var flat_hit: Dictionary = pip.source_hit(head.origin, (center - head.origin).normalized())
	check(flat_hit.get("center", Vector2.ZERO).distance_to(Vector2(0.5, 0.5)) < 0.001, "Flat selection follows displayed screen UV")
	video.screen_curve = 0.5; video._apply_geometry()
	flat_hit = pip.source_hit(head.origin, (video.panel.global_position - head.origin).normalized())
	check(flat_hit.get("center", Vector2.ZERO).distance_to(Vector2(0.5, 0.5)) < 0.001, "Curved screen selection uses the actual cylinder")
	pip.sync()
	check(is_equal_approx(window.size.x / window.size.y, video._flat.size.x / video._flat.size.y), "Changing projection updates physical per-eye aspect")
	video._flat.size *= 2; window.crop_center = Vector2(0.3, 0.7); pip.sync()
	check(window.crop_center == Vector2(0.3, 0.7), "Resizing the main screen never resets the frozen crop")
	video.stereo_sbs = true; video._apply_geometry(); pip.sync()
	check(is_equal_approx(window.size.x / window.size.y, video._flat.size.x / video._flat.size.y), "Changing stereo layout does not stretch a stale window aspect")
	pip.clear()
	check(pip.windows.is_empty() and pip.anchor == null and config.get_value("pip", "zoom_1") == 4.0, "Close all clears content and anchor without losing preferences")
	await process_frame
	var state := {"has_video": true, "pip_count": 0, "pip_slots": []}
	var menu := Menu.new(); menu.state_provider = func(): return state
	root.add_child(menu); menu.toggle()
	var operations: Array = []
	menu.action_requested.connect(func(operation):
		operations.append(operation)
		if operation.begins_with("pip_slot_"):
			var slot: int = operation.trim_prefix("pip_slot_").to_int()
			if state.pip_slots.has(slot): state.pip_slots.erase(slot)
			else: state.pip_slots.append(slot)
			state.pip_count = state.pip_slots.size())
	menu._activate(Menu.PIP)
	check(menu._pip_open and not menu.allows_playback_sticks(), "Camera popup suspends playback sticks")
	for count in 3:
		menu._pip_open = true; menu.refresh()
		var buttons: Array = menu._buttons.filter(func(button): return button.target == Menu.PIP_ADD)
		check(buttons.size() == 1, "Add choice exists until three windows are open: %d" % count)
		var button: Node3D = buttons[0].node
		var origin := button.to_global(Vector3(0, 0, 0.5))
		var direction := -button.global_basis.z
		check(menu.ray_hit(origin, direction).get("target", -1) == Menu.PIP_ADD, "Add choice is not occluded: %d" % count)
		menu.press_pointer("right_hand", origin, direction, true)
		menu.release_pointer("right_hand", origin, direction, true)
		check(operations.back() == "pip_slot_%d" % (count + 1) and menu._pip_open, "Add creates the next identity without dismissing the popup: %d" % count)
	check(menu._buttons.all(func(button): return button.target != Menu.PIP_ADD), "No add choice remains at three windows")
	var main := RoutingMain.new(); root.add_child(main); main.video = video
	main.player_menu = menu; main.test_menu = menu
	pip.set_count(1, head); window = pip.windows[1]
	main.test_ray = ray_to(window, window.corner_point(3))
	menu._pip_open = true
	check(main._pip_pointer_press("trigger_click", "right_hand") and not pip.resize.is_empty(), "A newly added frame accepts rays outside the open picker")
	main._update_pip_input()
	check(not pip.resize.is_empty(), "The next input update retains capture while the picker remains open")
	main._on_controller_release("trigger_click", "right_hand")
	var slot_button: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.PIP_COUNT + 1)[0]
	main.test_ray = [slot_button.node.to_global(Vector3(0,0,0.5)), -slot_button.node.global_basis.z]
	check(not main._pip_pointer_press("trigger_click", "right_hand"), "The picker button keeps priority when actually hit")
	main.test_ray = ray_to(window, window.corner_point(3))
	menu._pip_open = false
	main.test_menu = null
	check(main._pip_pointer_press("trigger_click", "right_hand") and not pip.resize.is_empty(), "Main dispatch routes corner to PiP")
	main._on_controller_release("trigger_click", "right_hand")
	check(pip.resize.is_empty(), "Controller release routes to captured PiP")
	pip._action(1, "select", 0)
	check(not main._shortcut_allowed("play"), "Selection blocks button shortcuts")
	main.video = null; main.queue_free()
	pip.clear()
	video.geometry = 0; video._apply_geometry()
	pip.set_count(2, head)
	var flat_second: Node3D = pip.windows[2]
	flat_second.global_position += Vector3(0.2,0.1,0.1)
	var preserved_flat_pose: Transform3D = flat_second.global_transform
	pip.close(1)
	var turned_head := Transform3D(Basis(Vector3.UP, PI/2), head.origin+Vector3(2,0.2,1))
	pip.toggle_slot(1, turned_head)
	var opened_relative: Vector3 = pip.level_head(turned_head).affine_inverse()*pip.windows[1].global_position
	var expected_relative := Vector3(0.75,0.47,-1.21).normalized()*1.5
	check(opened_relative.is_equal_approx(expected_relative), "Reopening a flat slot uses the current viewer rather than the first group's old anchor")
	check(flat_second.global_transform.is_equal_approx(preserved_flat_pose), "Opening a flat slot preserves other dragged windows")
	check(pip.windows[1].global_basis.z.normalized().dot((turned_head.origin-pip.windows[1].global_position).normalized())>0.999, "New flat window faces the current viewer")
	pip.clear(); pip.toggle_slot(1, turned_head)
	check((pip.level_head(turned_head).affine_inverse()*pip.windows[1].global_position).is_equal_approx(expected_relative), "Closing all flat slots does not persist their old positions")
	pip.clear(); menu.queue_free(); video.queue_free()
	await process_frame
	var player := Video.new(); root.add_child(player); player.set_process(false)
	var host := Host.new(); player.platform = host; player.history_enabled = false
	check(player.open_local("file:///pip-test.mp4", "PiP test", 4200, false), "Playback opens through existing host")
	player.set_pip_count(1, head)
	check(not player.pip.active(), "Cannot create a window before the source format arrives")
	player.media.frame_counter = 1
	player.requested_play = false
	player.set_pip_count(3, head)
	player.pip._action(2, "zoom", 6)
	var kept: Node3D = player.pip.windows[2]
	var kept_pose: Transform3D = kept.global_transform
	kept.crop_center = Vector2(0.3, 0.7)
	player._reopen_on_eye_buffer(4200)
	player.pip.sync()
	check(player.pip.windows.size() == 3 and player.pip.windows[2] == kept, "Same-file renderer reopen preserves window identities")
	check(kept.global_transform == kept_pose and kept.crop_center == Vector2(0.3, 0.7) and kept.zoom == 6, "Reopen preserves placement, crop and zoom")
	check(not player.requested_play and player._layer_return_uri == player.local_uri, "Reopen preserves paused intent and compositor return URI")
	check(not player._layer_presentation() and not player.layer_capable(), "Active PiP prevents reopen loops and uses existing eye-buffer refresh cap")
	player.media.frame_counter = 1
	player._layer_session = true; player.captures.recording = {"id": 1}
	check(not player.pip_available(), "Native recording prevents decoder replacement")
	player._layer_session = false
	check(player.pip_available(), "Recording can keep already shared GPU output")
	player.captures.recording.clear()
	player.open_local("file:///different.mp4", "Next", 0, false)
	check(not player.pip.active() and player.pip.preferences[2] == 6, "Real file change clears windows and keeps global preference")
	player.media.frame_counter = 1; player.set_pip_count(1, head); host.fail = true
	player._reopen_on_eye_buffer(100)
	check(not player.pip.active() and not player.pip.reopening, "Failed renderer reopen drops stale windows and reset guard")
	player.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Video PiP: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
