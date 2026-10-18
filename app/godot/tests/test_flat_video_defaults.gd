extends SceneTree

const InputMain := preload("res://tests/test_controller_bindings.gd").InputMain
const Video := preload("res://scripts/mpv_video_display.gd")
const Menu := preload("res://scripts/player_menu.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func click(menu: Node3D, target: int) -> bool:
	var buttons: Array = menu._buttons.filter(func(button): return button.target == target and button.enabled)
	if buttons.is_empty(): return false
	var node: Node3D = buttons[0].node
	var origin: Vector3 = node.to_global(Vector3(0, 0, 0.5))
	var direction := -node.global_basis.z
	if menu.ray_hit(origin, direction).get("target", -1) != target: return false
	menu.press_pointer("right_hand", origin, direction, true)
	menu.release_pointer("right_hand", origin, direction, true)
	return true

func pair(video: Node3D) -> Vector2:
	return Vector2(video.screen_distance, video.screen_scale)

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var main := InputMain.new()
	main.settings_path = ProjectSettings.globalize_path("res://../../build/output/flat-video-defaults/settings.cfg")
	DirAccess.make_dir_recursive_absolute(main.settings_path.get_base_dir())
	var video := Video.new(); video.history_enabled = false
	root.add_child(video); video.set_process(false); main.video = video
	var camera := Camera3D.new(); root.add_child(camera); video.view_camera = camera
	camera.transform = main.head_pose
	video.platform = preload("res://tests/test_player_menu.gd").Host.new()
	video.open_local("file:///defaults/first.mp4", "First.mp4")
	video.media.state = "playing"
	main._restore_flat_video_settings()
	check(pair(video) == Vector2(2, 1), "Fresh install starts at 2m / 100%")
	main.settings.set_value("screen", "distance", 1.2); main.settings.set_value("screen", "scale", 1.8)
	main._restore_flat_video_settings()
	check(pair(video).is_equal_approx(Vector2(1.2, 1.8)), "Legacy current state is preserved on upgrade")
	check(not main.settings.has_section_key("screen", "default_view"), "Legacy state does not silently become a locked default")
	for following in [false, true]:
		main.view_follow.set_enabled(following)
		for system in [false, true]:
			var latest := pair(video)
			if system: main._on_system_recentered()
			else: main._on_menu_action("recenter")
			check(pair(video).is_equal_approx(latest), "Both recenter routes retain latest unlocked values, with follow on or off")
			check(not main.settings.has_section_key("screen", "default_view"), "Recenter does not lock the current values")
			main._push_screen(0.3); main._zoom_video(log(1.2)); main._finish_flat_zoom(); main._save_screen()
	main.view_follow.set_enabled(false)
	var unlocked_restart := InputMain.new(); unlocked_restart.video = Video.new()
	check(unlocked_restart.settings.load(main.settings_path) == OK, "Unlocked latest values are persisted")
	unlocked_restart._restore_flat_video_settings()
	check(pair(unlocked_restart.video).is_equal_approx(pair(video)), "Restart keeps the latest unlocked adjustments")
	unlocked_restart.video.free(); unlocked_restart.free()
	main._apply_screen_preset("giant32")
	var unlocked_preset := pair(video)
	for system in [false, true]:
		if system: main._on_system_recentered()
		else: main._on_menu_action("recenter")
		check(pair(video).is_equal_approx(unlocked_preset) and video.cinema.enabled and video.screen_preset == "giant32", "Unlocked recenter retains the latest cinema preset instead of reverting to factory mode")
	main._set_cinema_mode(false)
	var menu := Menu.new(); menu.state_provider = main._menu_state
	menu.adjustment_requested.connect(main._on_playback_adjustment)
	menu.adjustment_committed.connect(main._save_playback_adjustments)
	menu.action_requested.connect(main._on_menu_action)
	root.add_child(menu); menu.set_process(false); main.player_menu = menu
	main._on_playback_adjustment("screen_distance", 1.0)
	main._on_playback_adjustment("screen_scale", 150.0)
	main._save_playback_adjustments()
	menu.toggle(); menu._activate(Menu.SCREEN_SETTINGS)
	check(click(menu, Menu.SCREEN_SET_DEFAULT), "Ray and trigger can save the visible default button")
	check(main._flat_video_defaults().is_equal_approx(Vector2(1.0, 1.5)), "Explicit save stores distance and size together")
	check(main._menu_state().screen_is_default, "Saved combination is visibly selected")
	menu.dismiss()
	var saved := ConfigFile.new()
	check(saved.load(main.settings_path) == OK and saved.get_value("screen", "default_view").is_equal_approx(Vector2(1.0, 1.5)), "Default pair is persisted")
	for following in [false, true]:
		main.view_follow.set_enabled(following)
		for system in [false, true]:
			main._push_screen(1.2); main._save_screen()
			main._zoom_video(log(2.5 / video.screen_scale)); main._finish_flat_zoom()
			check(is_equal_approx(video.screen_scale, 2.5) and not main._menu_state().screen_is_default, "Stick zoom changes current state and clears selected feedback")
			check(main._flat_video_defaults().is_equal_approx(Vector2(1.0, 1.5)), "Temporary push/zoom and their commits cannot overwrite the saved pair")
			video.set_screen_curve(0.7); video.set_screen_rotation(25)
			main.interface_move.placements[&"video"] = Transform3D(Basis.IDENTITY, Vector3(1, 0.3, -3))
			main.view_follow.capture(&"video", main.head_pose, Transform3D(Basis.IDENTITY, Vector3(1, 2, -3)))
			main.head_pose = Transform3D(Basis.from_euler(Vector3(0.1, 0.4, 0)), Vector3(0.3, 1.7, 0.2))
			camera.transform = main.head_pose
			if system: main._on_system_recentered()
			else:
				menu.toggle()
				check(click(menu, 108), "Playback bar recenter is ray selectable")
				menu.dismiss()
			check(pair(video).is_equal_approx(Vector2(1.0, 1.5)), "App/system recenter restores the saved pair with following on or off")
			var expected: Transform3D = main._follow_screen_pose(video, main.head_pose, true) if following else main._view_pose(1.0, 0)
			check((video.global_transform * video.flat_pose).is_equal_approx(expected), "Recenter faces the current gaze at the preferred distance")
			check(video.screen_curve == 0.7 and video.screen_rotation == 25, "Curve and content rotation are unaffected")
			check(not main.interface_move.placements.has(&"video"), "Recenter discards temporary grip placement")
			main._update_view_follow()
			check((video.global_transform * video.flat_pose).is_equal_approx(expected), "Following cannot resurrect the old placement")
			video.close_video(); video.open_local("file:///defaults/next.mp4", "Next.mp4"); main._place_screen()
			check(pair(video).is_equal_approx(Vector2(1.0, 1.5)), "Changing video retains the restored pair")
	main._on_playback_adjustment("screen_scale", 210.0); main._save_playback_adjustments()
	check(main._flat_video_defaults().is_equal_approx(Vector2(1.0, 1.5)), "Editing settings also requires explicit save to replace defaults")
	var restarted := InputMain.new(); restarted.video = Video.new()
	check(restarted.settings.load(main.settings_path) == OK, "New app instance reads persisted settings")
	restarted._restore_flat_video_settings()
	check(pair(restarted.video).is_equal_approx(Vector2(1.0, 1.5)), "Restart prefers saved defaults over temporary current values")
	restarted.video.free(); restarted.free()
	main._recenter(false)
	check(is_equal_approx(video.screen_scale, 2.1), "Internal placement without reset preserves current scale")
	video.geometry = 1; video.set_screen_distance(3); video.set_screen_scale(2)
	menu.toggle(); menu._activate(Menu.SCREEN_SETTINGS)
	check(not menu._buttons.any(func(button): return button.target == Menu.SCREEN_SET_DEFAULT), "Immersive settings omit the flat-only button")
	menu.dismiss(); main._on_playback_adjustment("screen_set_default", true)
	main._on_system_recentered()
	check(pair(video) == Vector2(3, 2) and main._flat_video_defaults().is_equal_approx(Vector2(1.0, 1.5)), "Immersive recenter and save cannot change the flat pair or defaults")
	video.geometry = 0
	main.photo = preload("res://scripts/photo_display.gd").new(); root.add_child(main.photo); main.photo.set_process(false)
	main.photo_active = true; main.photo.set_screen_distance(1.7); main.photo.set_screen_scale(1.8)
	var photo_before := pair(main.photo)
	main._on_playback_adjustment("screen_set_default", true); main._on_system_recentered()
	check(pair(main.photo).is_equal_approx(photo_before) and pair(video) == Vector2(3, 2), "Photo recenter does not restore flat-video dimensions or alter photo dimensions")
	check(main._flat_video_defaults().is_equal_approx(Vector2(1.0, 1.5)), "Photo operations cannot replace video defaults")
	main.photo_active = false
	video._apply_geometry(); main._place_screen(true)
	menu.toggle(); menu._activate(Menu.SCREEN_SETTINGS)
	check(click(menu, Menu.SLIDER_RESET_BASE + 450) and click(menu, Menu.SLIDER_RESET_BASE + 451), "Existing per-slider resets restore factory dimensions")
	check(pair(video).is_equal_approx(Vector2(2, 1)) and click(menu, Menu.SCREEN_SET_DEFAULT), "Factory values can be saved as the default pair: " + str(pair(video)))
	check(main._flat_video_defaults().is_equal_approx(Vector2(2, 1)), "Factory defaults persist through explicit save")
	main._apply_screen_preset("giant22")
	var latest_cinema := pair(video)
	check(main._menu_state().screen_default_locked, "Temporary preset changes keep the explicit lock active")
	check(click(menu, Menu.SCREEN_AUTO_DEFAULT), "Automatic mode is selectable by ray")
	check(not main._menu_state().screen_default_locked and not main.settings.has_section_key("screen", "default_cinema"), "Automatic selection clears both locked records")
	main._on_system_recentered()
	check(pair(video).is_equal_approx(latest_cinema) and video.screen_preset == "giant22", "Unlocking uses the current cinema setup instead of the old fixed default")
	var auto_restart := InputMain.new(); auto_restart.video = Video.new()
	check(auto_restart.settings.load(main.settings_path) == OK, "Automatic selection persists")
	auto_restart._restore_flat_video_settings()
	check(pair(auto_restart.video).is_equal_approx(latest_cinema) and auto_restart.video.cinema.enabled and auto_restart.video.screen_preset == "giant22", "Restart preserves automatic mode and current cinema setup")
	check(not auto_restart.settings.has_section_key("screen", "default_view"), "Restart does not resurrect the removed lock")
	auto_restart.video.free(); auto_restart.free()
	main._on_playback_adjustment("screen_scale", 230.0); main._save_playback_adjustments()
	main._on_menu_action("recenter")
	check(is_equal_approx(video.screen_scale, 2.3), "Further adjustments after unlocking become the next recenter values")
	check(click(menu, Menu.SCREEN_SET_DEFAULT), "Automatic mode can be locked again")
	main._on_playback_adjustment("screen_scale", 270.0)
	check(click(menu, Menu.SCREEN_SET_DEFAULT), "Clicking fixed settings again replaces the locked values")
	main._on_playback_adjustment("screen_scale", 310.0); main._save_playback_adjustments(); main._on_menu_action("recenter")
	check(is_equal_approx(video.screen_scale, 2.7) and main._menu_state().screen_default_locked, "Replaced lock restores its new value despite later edits")
	menu.dismiss()
	for invalid in ["invalid", Vector2(NAN, 1), Vector2(1, INF)]:
		main.settings.set_value("screen", "default_view", invalid)
		check(main._flat_video_defaults() == Vector2(2, 1), "Malformed saved defaults safely fall back")
	main.settings.set_value("screen", "default_view", Vector2(0.8, 0.4))
	main._restore_flat_video_settings()
	check(pair(video) == Vector2.ONE, "Older defaults below the new minimum restore at 1m and 100 percent")
	main.settings.set_value("screen", "default_view", Vector2(-1, 100))
	check(main._flat_video_defaults().is_equal_approx(Vector2(1.0, 30)), "Out-of-range stored values are clamped")
	main.settings.set_value("screen", "default_view", Vector2(1.0, 1.5))
	main.settings_path = main.settings_path.get_base_dir() # A directory cannot be written as a config file.
	main._save_flat_video_defaults()
	check(main._flat_video_defaults().is_equal_approx(Vector2(1.0, 1.5)), "Failed disk save does not falsely replace the active defaults")
	var before_unlock := main.settings.encode_to_text()
	main._save_flat_video_defaults(false)
	check(main.settings.encode_to_text() == before_unlock and main._menu_state().screen_default_locked, "Failed unlock rolls back current and locked settings together")
	main.photo.free(); menu.free(); video.free(); camera.free(); main.free()
	for failure in failures: push_error(failure)
	print("Flat video defaults: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
