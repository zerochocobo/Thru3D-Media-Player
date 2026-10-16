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
		for pair in [[0.1, 0.6], [100.0, 8.0]]:
			restarted.settings.set_value("ui", "library_distance", pair[0]); restarted._place_menu(restarted.recent_menu)
			check(is_equal_approx(distance(restarted), pair[1]), "Distance settings respect existing menu movement limits")
		restarted.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Library distance: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
