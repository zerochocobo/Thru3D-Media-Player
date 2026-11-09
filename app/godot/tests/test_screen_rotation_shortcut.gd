extends SceneTree
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Rotation := preload("res://scripts/screen_rotation_control.gd")
var checks := 0
var failures: Array[String] = []

class InputMain extends "res://scripts/main.gd":
	var rays := {}
	var commits: Array[float] = []
	func _ray(hand: String) -> Variant: return super(hand) if hand == "mouse" else rays.get(hand)
	func _save_playback_adjustments() -> void: commits.append(video.screen_rotation)

func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func aim(main: Node3D, hand: String) -> void:
	var origin := Vector3(0, 1.6, 0)
	var corner := Rotation.lower_left_corner(main.video)
	main.rays[hand] = [origin, (main.video.panel.to_global(main.video.screen_corner(corner)) - origin).normalized()]
	main._update_screen_rotation_control()

func turn(main: Node3D, hand: String, degrees: float) -> void:
	var capture: Dictionary = main._grab.rotate
	var angle: float = float(capture.last) - deg_to_rad(degrees)
	var pose: Transform3D = main.video.global_transform * main.video.flat_pose
	var point := pose * Vector3(cos(angle), sin(angle), 0)
	var origin := Vector3(0, 1.6, 0)
	main.rays[hand] = [origin, (point - origin).normalized()]
	main._update_grab()

func run() -> void:
	var main := InputMain.new()
	main.settings_path = ProjectSettings.globalize_path("res://../../build/output/screen-rotation/settings.cfg")
	DirAccess.make_dir_recursive_absolute(main.settings_path.get_base_dir())
	var video := Video.new(); root.add_child(video); video.set_process(false); main.video = video
	video.local_uri = "file:///dance.mp4"; video.media.begin(7)
	video.media.format = {"width": 1920, "height": 1080}
	video.flat_pose = Transform3D(Basis.IDENTITY, Vector3(0, 1.6, -2)); video._apply_geometry(); video.panel.visible = true
	var control := Rotation.new(); root.add_child(control); main.screen_rotation_control = control
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false)
	main.player_menu = menu; main.video_menu = menu
	main.recent_menu = preload("res://scripts/library_menu.gd").new(); main.recent_menu.visible = false
	menu.state_provider = main._menu_state
	menu.setting_requested.connect(main._on_player_setting)
	main._update_screen_rotation_control()
	check(not control.visible, "No permanent button or mark while the pointer is away")
	menu.visible = true; menu.section = 1; menu._adjustment = "screen"; menu.refresh()
	check(not menu.text_snapshot().contains("Rotation button") and not menu._buttons.any(func(button): return button.target == 617), "Rotation switch is removed entirely")
	check(menu._adjust_rows[452].span == Vector3(-180, 180, 1), "Flat rotation slider still includes upside-down")
	check(menu._tips.get(452, "") == Menu.I18n.t("Point at the screen's lower-left corner to show the curved arrows; hold either end to keep turning, or drag to rotate, then release to snap to the nearest 90°."), "Screen rotation slider explains the lower-left corner hold and drag gestures")
	menu.dismiss()
	for old_preference in [false, true]:
		main.settings.set_value("ui", "screen_rotation_shortcut", old_preference)
		aim(main, "right_hand")
		check(control.visible, "Hover at the corner works by default regardless of the obsolete switch")
		main._update_corner_hover()
		check(video.hovered_corner == -1, "Arc replaces the lower-left resize bracket")
		var corner := Rotation.lower_left_corner(video)
		check(control.global_position.distance_to(video.panel.to_global(video.screen_corner(corner))) < 0.02, "Rotation mark shares the original corner hit position")
		main.rays.right_hand = [Vector3(0, 1.6, 0), Vector3.FORWARD]
		main._update_screen_rotation_control()
		check(not control.visible, "Leaving the corner removes the mark immediately")
	for angle in [0.0, 90.0, 180.0, -90.0]:
		video.set_screen_rotation(angle); aim(main, "right_hand")
		check(control.visible and control.global_position.x < video.panel.global_position.x and control.global_position.y < video.panel.global_position.y, "Arc stays at the visible lower-left for every orientation")
		main._on_controller_button("trigger_click", "right_hand")
		check(main._grab.has("rotate") and not menu.visible, "Physical trigger captures the hovered corner")
		var count := main.commits.size()
		main._on_controller_release("trigger_click", "right_hand")
		check(video.screen_rotation == angle and main.commits.size() == count and main._grab.is_empty(), "A click without dragging does not rotate or commit")
	check(video.subtitle_transform().basis.is_equal_approx(Basis.IDENTITY), "Rotation leaves subtitles upright")
	video.set_screen_rotation(0)
	menu.visible = true; menu.section = 0; menu._adjustment = ""; menu.refresh()
	for corner in [1, 3]:
		var origin := Vector3(0, 1.6, 0)
		main.rays.right_hand = [origin, (video.panel.to_global(video.screen_corner(corner)) - origin).normalized()]
		main._update_screen_rotation_control(); main._update_corner_hover()
		check(not control.visible and video.hovered_corner == corner and video._handles[corner].visible, "Other two corners retain their right-angle resize marks")
		check(main._try_corner_resize("right_hand") and main._grab.has("resize"), "Other corner still begins resize instead of rotation")
		main._on_pointer_release("trigger_click", "right_hand")
	menu.dismiss()
	for curve in [0.0, 60.0]:
		for direction in [1, -1]:
			video.set_screen_curve(curve); video.set_screen_rotation(0); aim(main, "right_hand")
			var origin := Vector3(0, 1.6, 0)
			var end: Vector3 = control.to_global(Vector3(-0.11, 0.035, 0) if direction == 1 else Vector3(0.035, -0.11, 0))
			main.rays.right_hand = [origin, (end - origin).normalized()]
			main._on_controller_button("trigger_click", "right_hand")
			check(main._grab.has("rotate") and main._grab.rotate.hold_direction == direction, "Either arrow end selects its own continuous turning direction")
			var next: int = main._grab.rotate.next_hold
			Rotation.hold_tick(video, main._grab, next - 1)
			check(video.screen_rotation == 0, "A brief press waits for the hold delay")
			for step in 6:
				Rotation.hold_tick(video, main._grab, int(main._grab.rotate.next_hold))
				main._update_grab()
				var expected := float((step + 1) * 90 * direction)
				if absf(expected) > 180: expected = wrapf(expected, -180, 180)
				check(is_zero_approx(wrapf(video.screen_rotation - expected, -180, 180)) and main._grab.has("rotate"), "Holding the same stationary ray keeps turning without reacquiring the moved corner")
				var before_repeat: float = video.screen_rotation
				Rotation.hold_tick(video, main._grab, int(main._grab.rotate.next_hold) - 1)
				check(video.screen_rotation == before_repeat, "Repeated turns respect their interval")
			var before_release: float = video.screen_rotation
			main._on_controller_release("trigger_click", "right_hand")
			Rotation.hold_tick(video, main._grab, next + 20000)
			check(main._grab.is_empty() and video.screen_rotation == before_release, "Release ends continuous turning without an extra step")
	video.set_screen_curve(0); video.set_screen_rotation(0); aim(main, "right_hand"); main._try_screen_rotation("right_hand")
	Rotation.hold_tick(video, main._grab, int(main._grab.rotate.next_hold))
	turn(main, "right_hand", 12)
	check(is_equal_approx(video.screen_rotation, 102), "Dragging after a held quarter turn continues from its displayed angle")
	Rotation.hold_tick(video, main._grab, int(main._grab.rotate.next_hold) + 20000)
	check(is_equal_approx(video.screen_rotation, 102), "Intentional dragging takes over from hold repeat")
	main._on_pointer_release("trigger_click", "right_hand")
	for hand in ["left_hand", "right_hand"]:
		for curve in [0.0, 60.0]:
			video.set_screen_rotation(0); video.set_screen_curve(curve); aim(main, hand)
			main._on_pointer_button("trigger_click", hand)
			check(main._grab.has("rotate"), "Either pointer can capture rotation, including curved flat video")
			var pose: Transform3D = video.flat_pose; var scale_before: float = video.screen_scale
			turn(main, hand, 132)
			check(is_equal_approx(video.screen_rotation, 132), "Drag previews its continuous angle")
			main._update_flat_grab_stick(Vector2(0, 1), Vector2(0, 1), 1)
			main._process_sticks(Vector2(1, 0), Vector2(1, 0), 0.1)
			check(video.flat_pose == pose and video.screen_scale == scale_before, "Rotation capture blocks movement, resize and playback sticks")
			main._on_pointer_release("trigger_click", "left_hand" if hand == "right_hand" else "right_hand")
			check(not main._grab.is_empty(), "The other hand cannot release the drag")
			main._on_pointer_release("trigger_click", hand)
			check(video.screen_rotation == 90, "Release snaps 132 degrees to 90")
			check(main.stick_controls.poll(Vector2(1, 0), Vector2.ZERO, true).is_empty(), "Held stick stays suspended after release")
			main.stick_controls.poll(Vector2.ZERO, Vector2.ZERO, true)
			check(not main.stick_controls.poll(Vector2(1, 0), Vector2.ZERO, true).is_empty(), "Stick shortcuts resume after returning to centre")
	video.set_screen_curve(0); video.set_screen_rotation(0); aim(main, "right_hand"); main._try_screen_rotation("right_hand")
	turn(main, "right_hand", -178); turn(main, "right_hand", -24)
	check(is_equal_approx(video.screen_rotation, 158), "Counterclockwise drag crosses the angle seam smoothly")
	var before: float = video.screen_rotation
	main.rays.right_hand = [Vector3(0, 1.6, 0), Vector3.FORWARD]; main._update_grab()
	check(video.screen_rotation == before, "Crossing the centre does not create an undefined turn")
	main.rays.right_hand = [Vector3(0, 1.6, 0), Vector3(1, 0, -2).normalized()]; main._update_grab()
	check(video.screen_rotation == before, "Leaving the centre rebases the ray without a half-turn jump")
	main._on_pointer_release("trigger_click", "right_hand")
	check(absf(video.screen_rotation) == 180, "Release reaches the upside-down orientation")
	video.set_screen_rotation(0); aim(main, "right_hand"); main._try_screen_rotation("right_hand"); turn(main, "right_hand", 51)
	main.rays.right_hand = null; main._update_grab()
	check(video.screen_rotation == 90 and main._grab.is_empty(), "Tracking loss snaps a moved drag without becoming a click")
	aim(main, "right_hand"); main._try_screen_rotation("right_hand"); main._cancel_pointer("right_hand")
	check(video.screen_rotation == 90, "Cancelling an unmoved press never rotates")
	aim(main, "right_hand"); main._try_screen_rotation("right_hand"); turn(main, "right_hand", 10)
	var commit_count := main.commits.size()
	video.media.begin(8); video.local_uri = "file:///next.mp4"; video.set_screen_rotation(0); main._update_grab()
	check(video.screen_rotation == 0 and main._grab.is_empty() and main.commits.size() == commit_count, "Changing video invalidates the old drag and cannot commit into the next file")
	aim(main, "right_hand"); menu.global_transform = control.global_transform; menu.position.z += 0.05; menu.visible = true
	check(not main._try_screen_rotation("right_hand"), "A menu in front owns its ray instead of the hidden rotation button")
	menu.dismiss()
	video.cinema.enabled = true; main._update_screen_rotation_control()
	check(not control.visible, "Upright cinema screen retains its placement constraint")
	video.cinema.enabled = false; video.geometry = 1; main._update_screen_rotation_control()
	check(not control.visible, "Immersive video has no flat shortcut")
	video.set_screen_rotation(270)
	check(video.screen_rotation == 90, "Immersive rotation retains the existing slider limits")
	video.geometry = 0; main.photo_active = true; main._update_screen_rotation_control()
	check(not control.visible, "Photo viewing does not inherit the video shortcut")
	main.photo_active = false; video.set_screen_rotation(0); video._apply_geometry(); video.panel.visible = true
	main.rays.clear()
	var camera := Camera3D.new(); root.add_child(camera); camera.position = Vector3(0, 1.6, 0); video.view_camera = camera
	var corner := Rotation.lower_left_corner(video)
	var point: Vector3 = video.panel.to_global(video.screen_corner(corner))
	var motion := InputEventMouseMotion.new(); motion.position = camera.unproject_position(point)
	main._unhandled_input(motion)
	check(control.visible and control._hover.get("mouse", -1) == Rotation.ROTATE, "Actual mouse motion reveals the corner arc")
	var press := InputEventMouseButton.new(); press.button_index = MOUSE_BUTTON_LEFT; press.pressed = true; press.position = motion.position
	main._unhandled_input(press)
	check(main._grab.has("rotate") and main._grab.hand == "mouse", "Mouse press captures the original lower-left corner")
	var start_angle: float = main._grab.rotate.last
	point = video.global_transform * video.flat_pose * Vector3(cos(start_angle - deg_to_rad(104)), sin(start_angle - deg_to_rad(104)), 0)
	motion.position = camera.unproject_position(point); motion.button_mask = MOUSE_BUTTON_MASK_LEFT; main._unhandled_input(motion)
	check(is_equal_approx(video.screen_rotation, 104), "Mouse drag rotates the image rather than moving the screen")
	press.pressed = false; press.position = motion.position; main._unhandled_input(press)
	check(video.screen_rotation == 90 and main._grab.is_empty(), "Mouse release snaps to the nearest quarter turn")
	motion.position = camera.unproject_position(video.panel.global_position); motion.button_mask = 0; main._unhandled_input(motion)
	check(not control.visible, "Mouse leave has no lingering rotation button")
	video.view_camera = null; camera.free()
	menu.free(); control.free(); main.recent_menu.free(); main.free(); video.free()
	for failure in failures: push_error(failure)
	print("Screen rotation shortcut: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
