extends SceneTree
const Main := preload("res://scripts/main.gd")
const Host := preload("res://tests/test_player_menu.gd").Host
var checks := 0
var failures: Array[String] = []
var directory := ProjectSettings.globalize_path("res://../../build/output/library-distance/" + str(Time.get_ticks_usec()))

class DistanceMain extends "res://scripts/main.gd":
	var test_ray: Variant
	var move_pose := Transform3D.IDENTITY
	func _ray(_hand: String) -> Variant: return test_ray
	func _move_pose(_hand: String) -> Variant: return move_pose

func _initialize() -> void: run.call_deferred()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func make_main(path: String) -> DistanceMain:
	var main := DistanceMain.new(); main.settings_path = path
	root.add_child(main); main.set_process(false); main.report_timer.stop()
	main.video.set_process(false); main.photo.set_process(false)
	main.recent_menu.set_process(false); main.video_menu.set_process(false); main.photo_menu.set_process(false)
	main.video.platform = Host.new()
	# Recenter restores distance and size only for an explicitly saved default view (93f77659).
	main.settings.set_value("screen", "default_view", Vector2(main.video.SCREEN_DISTANCE, 1.0))
	main._show_recent_menu()
	return main

func distance(main: Node3D) -> float:
	return main.recent_menu.to_global(main.recent_menu.panel_centre()).distance_to(main._head_pose().origin)

func begin_move(main: DistanceMain, hand: String, menu: Node3D) -> void:
	var head: Transform3D = main._head_pose()
	main.move_pose = head * Transform3D(Basis.IDENTITY, Vector3(0, 0, -0.3))
	main.test_ray = [head.origin, (menu.to_global(menu.panel_centre()) - head.origin).normalized()]
	main._on_controller_button("grip_click", hand)
	check(not main.interface_move.capture.is_empty(), "Grip captures the visible menu: " + hand)
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)

func push_menu(main: DistanceMain, hand: String, menu: Node3D) -> void:
	begin_move(main, hand, menu)
	for i in 8:
		main._process_sticks(Vector2(0, 1) if hand == "left_hand" else Vector2.ZERO, Vector2(0, 1) if hand == "right_hand" else Vector2.ZERO, 0.1)
	main._on_controller_release("grip_click", hand)

func verify_recenter(main: DistanceMain, radius: float) -> void:
	for following in [false, true]:
		if main.view_follow.enabled != following: main._on_session_control("follow")
		for pose in [Transform3D(Basis.from_euler(Vector3(0.6, 0.4, 0.3)), Vector3(1, 1.7, 2)),
			Transform3D(Basis.from_euler(Vector3(-0.5, -0.7, -0.4)), Vector3(-1, 1.3, -2)),
			Transform3D(Basis.from_euler(Vector3(1.54, 0.2, 0.1)), Vector3(0.3, 0.8, 0.4))]:
			main.xr_camera.transform = pose
			for system in [false, true]:
				if system: main._on_system_recentered()
				else: main._recenter()
				var head: Transform3D = main._head_pose()
				var centre: Vector3 = main.recent_menu.to_global(main.recent_menu.panel_centre())
				var expected: Vector3 = head.origin - head.basis.z * radius
				check(centre.is_equal_approx(expected), "App/system recenter puts the panel centre on the gaze sphere at the saved radius")
				check(is_equal_approx(main._library_distance(), radius), "Recenter preserves the saved library distance")
				check(main.recent_menu.global_basis.z.normalized().dot((head.origin - centre).normalized()) > 0.99999, "Recenter keeps the panel tangent to the viewing sphere")
				if not following and absf(head.basis.z.y) < 0.99:
					check(absf(main.recent_menu.global_basis.x.y) < 0.00001, "Standard menus remain upright when the head rolls")
				main._update_view_follow()
				check(main.recent_menu.to_global(main.recent_menu.panel_centre()).is_equal_approx(expected), "The next follow update preserves recentered placement")

func menu_distance_limits() -> void:
	var path := directory.path_join("menu-limits.cfg")
	var config := ConfigFile.new(); config.set_value("appearance", "background", "dark"); config.save(path)
	var main := make_main(path)
	main.xr_camera.transform = Transform3D(Basis.from_euler(Vector3(0.15, -0.3, 0.1)), Vector3(0.2, 1.6, -0.1))
	for hand in ["left_hand", "right_hand"]:
		for following in [false, true]:
			for menu in [main.recent_menu, main.video_menu, main.photo_menu, main.music_menu]:
				for other in [main.recent_menu, main.video_menu, main.photo_menu, main.music_menu]: other.dismiss()
				main.photo_active = menu == main.photo_menu
				main.player_menu = main.photo_menu if main.photo_active else main.video_menu
				main.view_follow.set_enabled(following)
				main.settings.set_value("ui", "library_distance", Main.LIBRARY_DISTANCE_DEFAULT)
				menu.toggle(); main._place_menu(menu, true)
				begin_move(main, hand, menu)
				for i in 60:
					main._process_sticks(Vector2(0, 1) if hand == "left_hand" else Vector2.ZERO, Vector2(0, 1) if hand == "right_hand" else Vector2.ZERO, 0.1)
				var head: Transform3D = main._head_pose()
				var centre: Vector3 = menu.to_global(menu.panel_centre())
				check(is_equal_approx(centre.distance_to(head.origin), 4.0), "Either grip stops each real menu's panel centre at four metres with follow on/off")
				main._on_controller_release("grip_click", hand)
				check(main.interface_move.capture.is_empty() and menu.ray_max_distance == 5.0, "Release keeps the existing five-metre menu ray")
				var size: Vector2 = menu._backdrop.mesh.size
				for mono in [false, true]:
					if mono: menu.set_meta("menu_mono_pointer", {"eye": main.xr_camera, "distance": menu.ray_max_distance})
					for offset in [Vector2.ZERO, Vector2(-0.42, -0.42), Vector2(0.42, -0.42), Vector2(-0.42, 0.42), Vector2(0.42, 0.42)]:
						var point: Vector3 = centre + menu.global_basis * Vector3(offset.x * size.x, offset.y * size.y, 0)
						for side in [-1, 1]:
							var origin: Vector3 = head * Vector3(side * 0.35, -0.3, 0.25)
							var direction: Vector3 = preload("res://tests/test_mono_menu_pointer.gd").aim(menu, head.origin, origin, point) if mono else (point - origin).normalized()
							check(not menu.grab_hit(origin, direction).is_empty(), "Released menu centre/corners remain grabbable from either hand, including zero-disparity projection")
					for button in menu._buttons:
						if not button.enabled or not button.node.is_visible_in_tree(): continue
						var point: Vector3 = button.node.global_position
						var origin: Vector3 = head * Vector3(0.35, -0.3, -0.3)
						var direction: Vector3 = preload("res://tests/test_mono_menu_pointer.gd").aim(menu, head.origin, origin, point) if mono else (point - origin).normalized()
						check(not menu.ray_hit(origin, direction).is_empty(), "Visible buttons remain reachable at the menu distance limit")
					if mono: menu.remove_meta("menu_mono_pointer")
				begin_move(main, hand, menu)
				for i in 8:
					main._process_sticks(Vector2(0, -1) if hand == "left_hand" else Vector2.ZERO, Vector2(0, -1) if hand == "right_hand" else Vector2.ZERO, 0.1)
				main._on_controller_release("grip_click", hand)
				check(menu.to_global(menu.panel_centre()).distance_to(head.origin) < 3.0, "A second real grip pulls the released menu back from its limit")
	main.queue_free(); await process_frame

func migrate_saved_distance() -> void:
	for value in [0.6, 2.5, 4.0, 4.01, 5.5, 8.0, 100.0]:
		var path := directory.path_join("migration-%s.cfg" % value)
		var config := ConfigFile.new()
		config.set_value("appearance", "background", "dark")
		config.set_value("ui", "library_distance", value)
		config.set_value("screen", "distance", 4.25)
		config.set_value("privacy", "file_settings", false)
		config.save(path)
		var expected: float = value if value <= 4.0 else Main.LIBRARY_DISTANCE_DEFAULT
		var main := make_main(path)
		main._place_menu(main.recent_menu)
		check(is_equal_approx(distance(main), expected), "Startup preserves valid distances and returns old over-four-metre settings to the default")
		var saved := ConfigFile.new(); saved.load(path)
		check(is_equal_approx(float(saved.get_value("ui", "library_distance", 0)), expected), "The recovered distance is saved to disk")
		check(is_equal_approx(float(saved.get_value("screen", "distance", 0)), 4.25) and saved.get_value("privacy", "file_settings", true) == false, "Distance migration preserves independent screen and privacy preferences")
		main.queue_free(); await process_frame
		var restarted := make_main(path); restarted._place_menu(restarted.recent_menu)
		check(is_equal_approx(distance(restarted), expected), "The next startup keeps the recovered or valid distance")
		restarted.queue_free(); await process_frame

func run() -> void:
	DirAccess.make_dir_recursive_absolute(directory)
	for hand in ["left_hand", "right_hand"]:
		var path := directory.path_join(hand + ".cfg")
		var config := ConfigFile.new()
		config.set_value("appearance", "background", "dark"); config.set_value("ui", "language", "en")
		config.set_value("library", "history", false); config.set_value("screen", "distance", 4.25)
		config.save(path)
		var main := make_main(path)
		main.xr_camera.transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0)); main._place_menu(main.recent_menu)
		check(is_equal_approx(distance(main), Main.LIBRARY_DISTANCE_DEFAULT), "New settings use the existing default distance")
		push_menu(main, hand, main.recent_menu)
		var radius := distance(main)
		check(radius > 2.3 and is_equal_approx(main._library_distance(), radius), "Grip plus the same-hand stick remembers the actual main-panel distance")
		check(is_equal_approx(main.video.screen_distance, 4.25), "Library movement does not change video distance")
		var saved := ConfigFile.new(); saved.load(path)
		check(is_equal_approx(float(saved.get_value("ui", "library_distance", 0)), radius), "The distance preference survives on disk")
		check(not saved.has_section("interface") and not saved.has_section("placements"), "Only distance, never a world-space pose, is persisted")
		begin_move(main, hand, main.recent_menu)
		main.move_pose.origin += Vector3(0.15, 0.18, 0); main._update_interface_move()
		main._on_controller_release("grip_click", hand)
		check(is_equal_approx(main._library_distance(), radius), "Directional dragging does not replace the distance preference")
		main._on_library_chosen("file:///distance/first_2D.mp4", "First 2D.mp4"); main.video.media.state = "playing"
		main._show_recent_menu(); main._toggle_library_layout()
		push_menu(main, hand, main.video_menu)
		check(is_equal_approx(main._library_distance(), radius), "Moving the playback bar with its attached browser cannot overwrite main-menu distance")
		main._close_current_media()
		check(main.recent_menu.get_parent() == main and is_equal_approx(distance(main), radius), "Returning from playback restores the main-menu distance")
		main._show_player_menu(); main.xr_camera.position += Vector3(1, 0.2, -0.3); main._show_full_library()
		check(is_equal_approx(distance(main), radius), "Reopening at another head position preserves distance")
		verify_recenter(main, radius)
		main._on_library_chosen("file:///distance/second_2D.mp4", "Second 2D.mp4"); main.video.media.state = "playing"
		main.video.set_screen_distance(0.8); main._recenter(); main._close_current_media()
		check(is_equal_approx(main.video.screen_distance, 2) and is_equal_approx(distance(main), radius), "Video recenter resets its own distance while retaining the independent library preference")
		main.queue_free(); await process_frame
		var restarted := make_main(path)
		restarted.xr_camera.transform = Transform3D(Basis.from_euler(Vector3(0.2, 0.5, -0.3)), Vector3(2, 1.8, -1))
		restarted._place_menu(restarted.recent_menu)
		check(not restarted.view_follow.enabled and restarted.interface_move.placements.is_empty(), "Restart restores no old follow mode or spatial offsets")
		check(is_equal_approx(distance(restarted), radius), "A real application startup restores the user's preferred distance")
		for value in [NAN, INF, -1.0, "invalid", Vector3.ONE]:
			restarted.settings.set_value("ui", "library_distance", value); restarted._place_menu(restarted.recent_menu)
			check(is_equal_approx(distance(restarted), Main.LIBRARY_DISTANCE_DEFAULT) and restarted.recent_menu.global_transform.is_finite(), "Invalid distance settings safely use the default")
		for pair in [[0.1, 0.6], [4.0, 4.0], [100.0, Main.LIBRARY_DISTANCE_DEFAULT]]:
			restarted.settings.set_value("ui", "library_distance", pair[0]); restarted._place_menu(restarted.recent_menu)
			check(is_equal_approx(distance(restarted), pair[1]), "Distance settings respect existing menu movement limits")
		restarted.queue_free(); await process_frame
	await menu_distance_limits()
	await migrate_saved_distance()
	for failure in failures: push_error(failure)
	print("Library distance: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
