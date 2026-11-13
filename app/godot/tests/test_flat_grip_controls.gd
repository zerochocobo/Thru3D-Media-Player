extends SceneTree
## Real grip routing with synthetic tracking; no decoder or headset session.
const InputMain := preload("res://tests/test_controller_bindings.gd").InputMain
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func push(main: Node, hand: String, stick: Vector2, delta: float = 0.1) -> void:
	main._process_sticks(stick if hand == "left_hand" else Vector2.ZERO, stick if hand == "right_hand" else Vector2.ZERO, delta)
	main._update_interface_move()

func grab(main: Node, video: Node, hand: String) -> void:
	var point: Vector3 = video.panel.to_global(Vector3(0.13, -0.08, 0))
	var origin: Vector3 = main.head_pose.origin + Vector3(0.22, -0.3, -0.4)
	main.pose = main.InterfaceMove.ray_pose(origin, point - origin)
	main.rays = {hand: [origin, (point - origin).normalized()]}
	main._on_controller_button("grip_click", hand)
	check(not main.interface_move.capture.is_empty(), "Either grip captures the flat video")

func run() -> void:
	var main := InputMain.new(); main.settings_path = "user://flat-grip-controls.cfg"
	var video := Video.new(); video.history_enabled = false
	root.add_child(video); video.set_process(false); main.video = video
	video.local_uri = "file:///flat-grip.mp4"; video.media.begin(1)
	video.media.format = {"width": 1920, "height": 1080}
	var host := preload("res://tests/test_player_menu.gd").Host.new(); video.platform = host
	var camera := Camera3D.new(); root.add_child(camera); camera.global_transform = main.head_pose; video.view_camera = camera
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false); main.player_menu = menu
	menu.state_provider = main._menu_state; menu.visible = false
	main.screen_rotation_control = main.ScreenRotationControl.new(); root.add_child(main.screen_rotation_control)
	main.screen_edit_lock.control = main.ScreenEditLock.CornerControl.new(); root.add_child(main.screen_edit_lock.control)
	for alpha in [false, true]:
		for stereo in [false, true]:
			for hand in ["left_hand", "right_hand"]:
				video.alpha_requested = alpha; video.stereo_sbs = stereo
				main.portrait_screen.active = alpha
				main.portrait_screen.pending = false
				main.portrait_screen.last_scale = 1.0; main.portrait_screen.last_distance = 3.0
				video.screen_distance = 3.0; video.screen_scale = 1.0
				video.set_flat_world_pose(Transform3D(Basis.IDENTITY, main.head_pose.origin + Vector3(0, 0, -3)))
				video._apply_geometry(); video.panel.visible = true
				grab(main, video, hand)
				var pose: Transform3D = video.flat_pose
				var label := "alpha=%s stereo=%s hand=%s" % [alpha, stereo, hand]
				push(main, hand, Vector2.RIGHT)
				check(video.screen_scale == 1.0, "Pre-held stick waits for neutral: " + label)
				push(main, hand, Vector2.ZERO)
				push(main, "right_hand" if hand == "left_hand" else "left_hand", Vector2.RIGHT)
				check(video.screen_scale == 1.0, "Other hand cannot resize the grip: " + label)
				for step in 10: push(main, hand, Vector2.RIGHT)
				check(video.screen_scale > 1.5 and video.flat_pose.is_equal_approx(pose) and is_equal_approx(video.screen_distance, 3), "Right enlarges at the same pose/distance: " + label)
				for step in 10: push(main, hand, Vector2.LEFT)
				check(is_equal_approx(video.screen_scale, 1.0) and video.flat_pose.is_equal_approx(pose), "Left shrinks symmetrically without moving: " + label)
				push(main, hand, Vector2(0, 1))
				check(is_equal_approx(video.screen_distance, 3.15) and is_equal_approx(video.screen_scale, 1), "Forward still pushes away without scaling: " + label)
				push(main, hand, Vector2(0, -1))
				check(is_equal_approx(video.screen_distance, 3) and video.flat_pose.is_equal_approx(pose), "Back still pulls closer without scaling: " + label)
				for sample in [Vector2(0.1, 0), Vector2(0.8, 0.8), Vector2(NAN, 0), Vector2(INF, 0)]: push(main, hand, sample)
				push(main, hand, Vector2.RIGHT, NAN)
				check(is_equal_approx(video.screen_scale, 1) and video.flat_pose.is_equal_approx(pose), "Deadzone, equal diagonals and invalid input do nothing: " + label)
				main.settings.set_value("screen", "edit_locked", true)
				push(main, hand, Vector2.RIGHT)
				check(is_equal_approx(video.screen_scale, 1), "Screen lock blocks grip resizing: " + label)
				main.settings.set_value("screen", "edit_locked", false)
				push(main, hand, Vector2.RIGHT)
				var saved_scale: float = video.screen_scale
				main._on_controller_release("grip_click", hand)
				check(main.interface_move.capture.is_empty(), "Release ends capture: " + label)
				var saved := ConfigFile.new(); saved.load(main.settings_path)
				check(is_equal_approx(saved.get_value("portrait_screen" if alpha else "screen", "scale", 0.0), saved_scale), "Release saves the right independent size preference: " + label)
				var calls := host.calls.size(); push(main, hand, Vector2.RIGHT)
				check(host.calls.size() == calls and is_equal_approx(video.screen_scale, saved_scale), "Held stick after release cannot leak seek: " + label)
				push(main, hand, Vector2.ZERO)
	# Menu-only grabs keep their old distance-only behavior.
	video.alpha_requested = false; main.portrait_screen.active = false
	menu.toggle() if not menu.visible else menu.refresh()
	main.rays = {"right_hand": [menu.global_position + menu.global_basis.z, -menu.global_basis.z]}
	main._begin_interface_move("right_hand", "grip_click")
	check(main.interface_move.capture.targets.all(func(target): return target.kind == "menu"), "Menu-only capture excludes the video")
	var size: float = video.screen_scale; push(main, "right_hand", Vector2.ZERO); push(main, "right_hand", Vector2.RIGHT)
	check(video.screen_scale == size, "Grip on a menu cannot resize video")
	main._finish_interface_move(); menu.dismiss()
	# A pending grip + trigger chord retains ownership; no scale shortcut intercepts it.
	grab(main, video, "right_hand"); push(main, "right_hand", Vector2.ZERO)
	main.controller_bindings.press("right_hand", "trigger_click")
	push(main, "right_hand", Vector2.RIGHT)
	check(video.screen_scale == size, "Grip + trigger combinations do not resize")
	main.controller_bindings.release("right_hand", "trigger_click"); main._on_controller_release("grip_click", "right_hand")
	# Fixed bindings ignore optional remaps; clamp at both existing size limits.
	main.controller_bindings.assign("flat_zoom_in", main.ControllerBindings.bind("left_hand", "ax_button"), true)
	grab(main, video, "right_hand"); push(main, "right_hand", Vector2.ZERO)
	video.set_screen_scale(video.SCALE_LIMITS.y)
	push(main, "right_hand", Vector2.RIGHT)
	check(video.screen_scale == video.SCALE_LIMITS.y, "Grip scaling clamps at the existing maximum")
	video.set_screen_scale(video.SCALE_LIMITS.x)
	push(main, "right_hand", Vector2.LEFT)
	check(video.screen_scale == video.SCALE_LIMITS.x, "Grip scaling clamps at the existing minimum")
	push(main, "right_hand", Vector2.RIGHT)
	check(video.screen_scale > video.SCALE_LIMITS.x, "Ordinary zoom remapping cannot change fixed grip scaling")
	main.pose_available = false; size = video.screen_scale
	push(main, "right_hand", Vector2.RIGHT)
	check(main.interface_move.capture.is_empty() and video.screen_scale == size, "Tracking loss cancels capture before resizing")
	main.pose_available = true; main._on_controller_release("grip_click", "right_hand")
	# Upright placement keeps its bottom at rest through the next grip update.
	video.set_screen_scale(1.0); video.cinema.configure(video, true, main.head_pose)
	grab(main, video, "left_hand"); push(main, "left_hand", Vector2.ZERO)
	var bottom: Transform3D = video.cinema.content_bottom(video)
	var distance: float = main._surface_distance(video)
	for step in 4: push(main, "left_hand", Vector2.RIGHT)
	check(video.screen_scale > 1.0 and video.cinema.content_bottom(video).is_equal_approx(bottom) and is_equal_approx(main._surface_distance(video), distance), "Upright resizing preserves its bottom and distance across grip updates")
	main._on_controller_release("grip_click", "left_hand"); video.cinema.configure(video, false, main.head_pose)
	# No invisible corner targets remain while a flat cutout is active.
	for stereo in [false, true]:
		video.stereo_sbs = stereo; video.alpha_requested = false; video._apply_geometry()
		video.set_corner_hover(1)
		check(video._handles[1].visible, "Ordinary flat video retains its corner bracket")
		video.alpha_requested = true; video._sync_portrait()
		check(video._handles.all(func(handle): return not handle.visible), "Enabling passthrough clears an already visible bracket")
		for corner in 4:
			var point: Vector3 = video.panel.to_global(video.screen_corner(corner))
			main.rays = {"right_hand": [main.head_pose.origin, (point - main.head_pose.origin).normalized()]}
			video.set_corner_hover(corner); video._apply_geometry()
			main._update_corner_hover(); main._update_screen_rotation_control(); main.screen_edit_lock.update()
			check(video.corner_at(main.rays.right_hand[0], main.rays.right_hand[1]) == -1 and video._handles.all(func(handle): return not handle.visible), "Passthrough corners neither draw nor hit")
			check(not main.screen_rotation_control.visible and not main.screen_edit_lock.control.visible, "Passthrough hides rotation/lock corner companions too")
		video.alpha_requested = false; video.set_corner_hover(1)
		check(video._handles[1].visible, "Leaving passthrough restores normal corners")
	video.packed_file = true; video.packed_alpha = true; video._sync_portrait()
	video.set_corner_hover(1)
	check(video._handles.all(func(handle): return not handle.visible), "Authored Alpha passthrough also hides corners")
	main.screen_rotation_control.free(); main.screen_edit_lock.control.free()
	menu.free(); camera.free(); video.free(); main.free()
	for failure in failures: push_error(failure)
	print("Flat grip controls: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
