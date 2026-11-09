extends SceneTree
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Corner := preload("res://scripts/screen_lock_control.gd")
const Rotation := preload("res://scripts/screen_rotation_control.gd")
const LockMenu := preload("res://scripts/screen_lock_menu.gd")
var checks := 0
var failures: Array[String] = []

class InputMain extends "res://scripts/main.gd":
	var rays := {}
	var pulses := []
	var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	func _ray(hand: String) -> Variant: return rays.get(hand)
	func _head_pose() -> Variant: return head
	func _move_pose(_hand: String) -> Variant: return head
	func _scene_target_pulse(hand: String) -> void: pulses.append(hand)

func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); print("FAIL: ", message)

func aim(main: Node, hand: String, corner: int = -1) -> void:
	var point: Vector3 = main.video.panel.global_position if corner < 0 else main.video.panel.to_global(main.video.screen_corner(corner))
	main.rays[hand] = [main.head.origin, (point - main.head.origin).normalized()]
	main.screen_edit_lock.update()

func picture(video: Node) -> Array:
	return [video.flat_pose, video.screen_scale, video.screen_distance, video.screen_rotation, video.screen_curve,
		video.screen_curve_mode, video.cinema.enabled, video.video_aspect_preset, video.video_aspect_factor]

func run() -> void:
	var main := InputMain.new()
	main.settings_path = ProjectSettings.globalize_path("res://../../build/output/screen-lock/settings.cfg")
	DirAccess.make_dir_recursive_absolute(main.settings_path.get_base_dir())
	var video := Video.new(); root.add_child(video); video.set_process(false); main.video = video
	video.local_uri = "file:///lock-test.mp4"; video.media.begin(11); video.media.format = {"width": 1920, "height": 1080}
	video.flat_pose = Transform3D(Basis.IDENTITY, Vector3(0, 1.6, -2)); video._apply_geometry(); video.panel.visible = true
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false); main.player_menu = menu; main.video_menu = menu
	main.recent_menu = preload("res://scripts/library_menu.gd").new(); root.add_child(main.recent_menu); main.recent_menu.set_process(false); main.recent_menu.visible = false
	menu.state_provider = main._menu_state
	menu.setting_requested.connect(main._on_player_setting)
	menu.adjustment_requested.connect(main._on_playback_adjustment)
	menu.screen_lock_blocked.connect(func(hand: String): main.screen_edit_lock.deny(hand, "menu"))
	var control := Corner.new(); root.add_child(control); main.screen_edit_lock.control = control
	var rotation := Rotation.new(); root.add_child(rotation); main.screen_rotation_control = rotation
	var guard = main.screen_edit_lock
	check(not guard.locked(), "First use is unlocked")
	main._save_flat_video_defaults(true)
	check(not guard.locked(), "Existing saved recenter settings never migrate into an edit lock")
	guard.update(); check(not control.visible, "No permanent corner button")
	for angle in [0.0, 90.0, -90.0, 180.0]:
		video.set_screen_rotation(angle)
		for hand in ["left_hand", "right_hand"]:
			aim(main, hand, Corner.upper_left_corner(video))
			check(control.visible and control.global_position.x < video.panel.global_position.x and control.global_position.y > video.panel.global_position.y, "Lock follows visible upper-left at " + str(angle))
			var before := picture(video)
			main._on_controller_button("trigger_click", hand)
			check(not guard.locked() and not guard.capture.is_empty(), "Press captures without toggling")
			main._on_controller_release("trigger_click", hand)
			check(guard.locked() and picture(video) == before, "Release toggles lock without modifying picture")
			check(main._menu_state().screen_edit_locked, "Menu state follows corner")
			main._on_controller_button("trigger_click", hand); main._on_controller_release("trigger_click", hand)
			check(not guard.locked() and picture(video) == before, "Second click unlocks without a jump")
		main.rays.clear()
	video.set_screen_rotation(0)
	aim(main, "right_hand", Corner.upper_left_corner(video)); guard.press("right_hand")
	aim(main, "right_hand"); aim(main, "right_hand", Corner.upper_left_corner(video)); guard.release("right_hand")
	check(not guard.locked(), "Moving outside cancels even when the ray returns before release")
	guard.press("right_hand"); guard.release("left_hand")
	check(not guard.capture.is_empty(), "Other hand cannot release the lock button")
	video.media.begin(12); guard.release("right_hand")
	check(not guard.locked(), "Media replacement invalidates a pending lock click")
	guard.press("right_hand"); main._cancel_pointer("right_hand"); guard.release("right_hand")
	check(not guard.locked(), "Cancelled capture cannot toggle later")
	var menu_pose: Transform3D = menu.global_transform
	menu.visible = true; menu.section = 0; menu.refresh()
	var foreground: Dictionary = menu._buttons.filter(func(b): return b.target == 102)[0]
	var corner_point: Vector3 = video.panel.to_global(video.screen_corner(Corner.upper_left_corner(video)))
	menu.global_position += main.head.origin.lerp(corner_point, .65) - foreground.node.global_position
	aim(main, "right_hand", Corner.upper_left_corner(video))
	check(not guard.hit(main.rays.right_hand) and not guard.press("right_hand"), "Foreground playback control keeps its ray; hidden lock cannot steal the click")
	menu.dismiss(); menu.global_transform = menu_pose


	menu.visible = true; menu.section = 1; menu._adjustment = "screen"; menu.refresh()
	menu._adjust_hand = "left_hand"; menu._adjust_target = 451
	var before_slider_lock := picture(video)
	menu._activate(LockMenu.TOGGLE)
	check(menu._adjust_hand.is_empty() and picture(video) == before_slider_lock, "Lock terminates an active settings slider at its displayed value")
	check(guard.locked() and control._locked, "Menu switch updates hovered corner immediately")
	var baseline := picture(video)
	var edits := {"screen_distance": 9.0, "screen_scale": 200.0, "screen_rotation": 90.0, "screen_curve": 60.0,
		"screen_curve_mode": "vertical", "screen_cinema": true, "screen_preset": "giant22", "screen_eye_level": 0.33,
		"screen_set_default": false, "cinema_picture_size": 50.0, "video_aspect_preset": "16:9", "video_aspect_factor": 1.3,
		"spatial_match_fov": true, "portrait_scale": 250.0, "portrait_distance": 9.0}
	for key in edits:
		main._on_playback_adjustment(key, edits[key]); main._on_player_setting(key, edits[key])
		check(picture(video) == baseline and main.settings.has_section_key("screen", "default_view"), "Locked callback cannot change " + key)
	for row in menu._adjust_rows.values():
		if row.key not in main.ScreenEditLock.KEYS: continue
		check(not row.button.enabled and row.button.hover_disabled and menu._tips[row.button.target] == menu.I18n.t("Unlock to adjust"), "Disabled slider remains hit-testable with tooltip: " + row.key)
		menu._adjust_target = row.button.target; menu._adjust_hand = "left_hand"; menu._set_adjustment_at(row.left + row.width)
		check(picture(video) == baseline, "Stale slider capture cannot bypass lock: " + row.key)
	menu._finish_adjustment()
	for button in menu._buttons:
		if menu.screen_lock_ui.protected_target(button.target):
			check(not button.enabled, "All geometry controls disabled: " + str(button.target))
	for target in [menu.SCREEN_CINEMA, menu.SCREEN_SET_DEFAULT, menu.SCREEN_AUTO_DEFAULT, LockMenu.SAVE, menu.ROTATION_RESET]: menu._activate(target)
	check(picture(video) == baseline, "Presets/reset/baseline buttons cannot bypass lock")
	check(menu._buttons.any(func(b): return b.target == LockMenu.TOGGLE and b.enabled), "Unlock remains reachable")
	guard._last_notice = -2000; guard.attempts.clear(); main.pulses.clear()
	var notices: int = guard.notice_count
	for i in 180: main._zoom_video(0.02, "left_hand")
	check(guard.notice_count == notices + 1 and main.pulses == ["left_hand"] and picture(video) == baseline, "Continuous zoom gives one toast and one owning-hand pulse, with no change")
	main.settings.set_value("ui", "show_status_info", false)
	check(main._playback_status_sample().get("caption", "") == menu.I18n.t("Screen locked"), "Action feedback survives passive-status preference and an open menu")
	# Keep attempting past toast expiry: a held gesture must never re-trigger it.
	for i in 35:
		main._zoom_video(0.02, "left_hand")
		await create_timer(.05).timeout
	check(guard.notice_count == notices + 1, "Held zoom stays silent after the toast duration")
	guard.release_guard("left_hand"); guard._last_notice = -2000; guard._explained = false
	main._zoom_video(0.02, "left_hand")
	check(guard.caption() == "Screen locked\nUnlock at the top-left or in Screen settings", "First blocked operation explains both unlock locations")
	guard.notice_until = 0
	check(main._playback_status_sample().is_empty(), "Toast expires without changing passive-status preference")
	main._push_screen(2); main._turn_picture(.1, .1); main._reset_picture()
	for id in ["flat_zoom_in", "flat_zoom_out", "zoom_in", "zoom_out", "reset_video"]: main._execute_shortcut(id)
	check(picture(video) == baseline, "Distance, desktop drag, reset and remapped zoom are blocked")
	menu.dismiss()
	for hand in ["left_hand", "right_hand"]:
		aim(main, hand)
		main._begin_interface_move(hand, "grip_click")
		check(main.interface_move.capture.is_empty() and picture(video) == baseline, "Grip cannot move locked video: " + hand)
		aim(main, hand, Rotation.lower_left_corner(video)); main._try_screen_rotation(hand)
		check(main._grab.is_empty(), "Rotation capture blocked: " + hand)
		main._update_screen_rotation_control(); main._update_corner_hover()
		check(not rotation.visible and video.hovered_corner == -1, "Locked screen hides editable corner affordances")
	# Disabled controls still own the real ray hit and provide feedback before ChoiceFields captures.
	menu.visible = true; menu.section = 1; menu._adjustment = "screen"; menu.refresh()
	for button in menu._buttons:
		if not menu.screen_lock_ui.protected_target(button.target) or not button.node.visible: continue
		var origin: Vector3 = button.node.to_global(Vector3(0, 0, 0.4))
		var direction: Vector3 = -button.node.global_basis.z
		if menu.ray_hit(origin, direction).get("target", -1) != button.target: continue
		guard.attempts.clear(); guard._last_notice = -2000; notices = guard.notice_count
		check(menu.press_pointer("right_hand", origin, direction, true), "Disabled control consumes pointer " + str(button.target))
		menu.release_pointer("right_hand", origin, direction, true)
		check(guard.notice_count == notices + 1 and not menu.has_pointer_capture() and picture(video) == baseline, "Disabled pointer has feedback and cannot change value " + str(button.target))
	# Menus continue to move, even with a configured linked/all movement scope.
	menu.section = 0; menu._adjustment = ""; menu.refresh()
	var play: Dictionary = menu._buttons.filter(func(b): return b.target == 102)[0]
	main.rays.left_hand = [main.head.origin, (play.node.global_position - main.head.origin).normalized()]
	for scope in ["panel", "media", "all"]:
		main.controller_bindings.move_scope = scope
		main._begin_interface_move("left_hand", "grip_click")
		check(not main.interface_move.capture.is_empty() and not main.interface_move.capture.targets.any(func(t): return t.node == video), "Locked media excluded from linked grip scope: " + scope)
		main.interface_move.cancel()
	main.controller_bindings.move_scope = "panel"
	video.pip.selecting = 1
	check(guard.locked(), "PiP selection cannot temporarily unlock the main video")
	main._on_playback_adjustment("screen_scale", 180.0)
	check(picture(video) == baseline, "Main geometry remains protected while PiP owns interaction")
	video.pip.selecting = 0
	menu.dismiss()
	# A simple click still opens playback controls, without a false blocked notification.
	aim(main, "right_hand"); notices = guard.notice_count
	main._on_controller_button("trigger_click", "right_hand"); main._on_controller_release("trigger_click", "right_hand")
	check(menu.visible and guard.notice_count == notices, "Normal trigger click still summons controls silently")
	menu.dismiss()
	# Recenter is intentional recovery, retaining current dimensions rather than old saved dimensions.
	video.set_screen_scale(1.7); video.set_screen_distance(3.0); video.set_screen_curve(30); video.set_screen_rotation(90)
	main.head.origin.x = 1.0
	main._recenter()
	check(guard.locked() and is_equal_approx(video.screen_scale, 1.7) and is_equal_approx(video.screen_distance, 3.0) and video.screen_curve == 30 and video.screen_rotation == 90, "Recenter retains current dimensions/shape/rotation and lock")
	var persisted := ConfigFile.new(); check(persisted.load(main.settings_path) == OK and persisted.get_value("screen", "edit_locked", false), "Lock persists on disk")
	main.settings = persisted
	video.local_uri = "file:///next.mp4"; video.media.begin(13)
	check(guard.locked(), "New video and reloaded preferences retain global lock")
	video.depth_requested = true; check(guard.locked(), "2D-to-3D still uses protected flat screen")
	video.depth_requested = false; video.geometry = 1
	check(not guard.locked() and not guard.guard("screen_rotation"), "Immersive video retains its own controls")
	video.geometry = 0; main.photo_active = true
	check(not guard.locked(), "Photos do not inherit video lock")
	main.photo_active = false
	# Locking during active edits must not snap rotation or replay the held input.
	guard.set_locked(false); video.set_screen_rotation(37)
	main._grab = {"hand": "left_hand", "moved": true, "rotate": {"start": 0.0}}
	main.controller_bindings.press("left_hand", "trigger_click")
	main.view_follow.enabled = true
	guard.set_locked(true)
	check(video.screen_rotation == 37 and main._grab.is_empty() and main.view_follow.enabled, "Lock ends active rotation at displayed angle and preserves follow mode")
	guard.set_locked(false)
	check(main.stick_controls.poll(Vector2(1,0), Vector2.ZERO).is_empty(), "Unlock cannot replay held stick")
	check(main.controller_bindings.blocked.left_hand.has("trigger_click"), "Held physical button requires release")
	main._on_controller_release("trigger_click", "left_hand")
	main.stick_controls.poll(Vector2.ZERO, Vector2.ZERO)
	check(not main.stick_controls.poll(Vector2(1,0), Vector2.ZERO).is_empty(), "Sticks resume after neutral")
	main._on_playback_adjustment("screen_scale", 125.0)
	check(is_equal_approx(video.screen_scale, 1.25), "Unlocked slider retains original percentage conversion")
	menu.visible = true; menu.section = 1; menu._adjustment = "screen"; menu.refresh()
	menu._activate(LockMenu.SAVE)
	var saved: Variant = main.settings.get_value("screen", "default_view")
	main._on_playback_adjustment("screen_scale", 140.0); menu._activate(menu.SCREEN_SET_DEFAULT)
	check(main.settings.get_value("screen", "default_view") == saved, "Selecting saved settings does not overwrite them")
	menu._activate(LockMenu.SAVE)
	check(not main.settings.get_value("screen", "default_view").is_equal_approx(saved), "Explicit save replaces stored setup")
	menu._activate(menu.SCREEN_AUTO_DEFAULT)
	check(not main.settings.has_section_key("screen", "default_view"), "Latest settings retains existing baseline-clearing behavior")
	var path: String = main.settings_path
	main.settings_path = path.path_join("missing/settings.cfg")
	guard.set_locked(true)
	check(not guard.locked() and guard.notice == "Could not save. Try again.", "Failed persistence rolls lock state back and reports failure")
	main.settings_path = path
	guard.control = null; rotation.free(); control.free(); menu.free(); main.recent_menu.free(); main.free(); video.free()
	for failure in failures: push_error(failure)
	print("Screen edit lock: %s (%d checks, %d failures)" % ["passed" if failures.is_empty() else "failed", checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
