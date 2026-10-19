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
	var origin: Vector3 = node.to_global(Vector3(0, 0, 0.5)); var direction := -node.global_basis.z
	if menu.ray_hit(origin, direction).get("target", -1) != target: return false
	menu.press_pointer("right_hand", origin, direction, true); menu.release_pointer("right_hand", origin, direction, true)
	return true

func world(video: Node3D) -> Transform3D: return video.global_transform * video.flat_pose
func bottom(video: Node3D) -> Vector3: return world(video).origin - Vector3.UP * video._flat.size.y / 2

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var main := InputMain.new()
	main.settings_path = ProjectSettings.globalize_path("res://../../build/output/cinema-placement/settings.cfg")
	DirAccess.make_dir_recursive_absolute(main.settings_path.get_base_dir())
	var video := Video.new(); video.history_enabled = false; root.add_child(video); video.set_process(false); main.video = video
	video.platform = preload("res://tests/test_player_menu.gd").Host.new()
	var camera := Camera3D.new(); root.add_child(camera); camera.transform = main.head_pose; video.view_camera = camera
	main.recent_menu = Node3D.new(); main.recent_menu.visible = false
	var menu := Menu.new(); menu.state_provider = main._menu_state
	menu.adjustment_requested.connect(main._on_playback_adjustment); menu.adjustment_committed.connect(main._save_playback_adjustments)
	menu.action_requested.connect(main._on_menu_action); root.add_child(menu); menu.set_process(false); main.player_menu = menu
	video.open_local("file:///cinema/first.mp4", "First.mp4"); video.media.state = "playing"; video.panel.visible = true
	main._restore_flat_video_settings(); main._place_screen()
	check(not video.cinema.enabled, "Fresh installs remain free")
	video.set_screen_rotation(20)
	main.view_follow.set_enabled(true)
	menu.toggle(); menu._activate(Menu.SCREEN_SETTINGS)
	check(not click(menu, Menu.SCREEN_PRESET) and not click(menu, Menu.SCREEN_EYE_LEVEL), "Free mode hides presets and eye levels")
	check(click(menu, Menu.SCREEN_CINEMA), "Cinema toggle is reachable by ray")
	check(video.cinema.enabled and not main.view_follow.enabled, "Enabling cinema leaves follow mode")
	check(video.screen_rotation == 0 and world(video).basis.y.is_equal_approx(Vector3.UP), "Cinema screen stands upright")
	check(not menu._adjust_rows.has(452), "Cinema omits incompatible content-rotation control")
	check(click(menu, Menu.SCREEN_CINEMA) and video.cinema.enabled, "Selecting On again keeps cinema enabled")
	check(click(menu, Menu.SCREEN_CINEMA_OFF) and not video.cinema.enabled and menu._adjust_rows.has(452), "Off returns to free screen controls")
	check(click(menu, Menu.SCREEN_CINEMA_OFF) and not video.cinema.enabled, "Selecting Off again keeps free mode")
	check(click(menu, Menu.SCREEN_CINEMA) and video.cinema.enabled, "On restores cinema from free mode")
	menu.dismiss()
	check(not is_instance_valid(video.cinema.guide), "Idle cinema allocates no ground grid")
	main.rays.right_hand = [camera.global_position, Vector3.FORWARD]
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	main._process_sticks(Vector2.ZERO, Vector2(0, 1), 0.1)
	check(is_instance_valid(video.cinema.guide) and video.cinema.guide.visible, "Stick resizing shows the grid")
	var guide_pose: Transform3D = video.cinema.guide.global_transform
	var guide_mesh: int = video.cinema.guide.mesh.get_instance_id()
	var tracked_ray: Array = main.rays.right_hand
	main.rays.erase("right_hand"); main._update_cinema_guide()
	check(not video.cinema.guide.visible, "Lost tracking hides the active grid")
	main.rays.right_hand = tracked_ray; main._update_cinema_guide()
	main.display.preview = false; main.display.session_state = "session_visible"; main._update_cinema_guide()
	check(not video.cinema.guide.visible, "Lost input focus hides the active grid")
	main.display.preview = true; main._update_cinema_guide()
	main.photo_active = true; main._update_cinema_guide()
	check(not video.cinema.guide.visible, "Switching to photos hides the grid")
	main.photo_active = false
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	check(not video.cinema.guide.visible, "Stick neutral hides the grid")
	menu.toggle(); menu._activate(Menu.SCREEN_SETTINGS)
	for target in [450, 451]:
		var slider: Node3D = menu._buttons.filter(func(button): return button.target == target)[0].node
		var origin: Vector3 = slider.to_global(Vector3(0, 0, 0.5)); var direction := -slider.global_basis.z
		main.rays.right_hand = [origin, direction]
		menu.press_pointer("right_hand", origin, direction, true); main._update_cinema_guide()
		check(video.cinema.guide.visible, "Size and distance slider capture show the grid")
		menu.release_pointer("right_hand", origin, direction, true); main._update_cinema_guide()
		check(not video.cinema.guide.visible, "Slider release hides the grid")
		menu.press_pointer("right_hand", origin, direction, true); main._update_cinema_guide()
		menu.dismiss(); main._update_cinema_guide()
		check(not video.cinema.guide.visible, "Dismissing a captured slider hides the grid")
		menu.toggle(); menu._activate(Menu.SCREEN_SETTINGS)
	menu.dismiss()
	var first_pose := world(video)
	main.head_pose.origin += Vector3(0.25, 0.2, 0.1); main.head_pose.basis = Basis.from_euler(Vector3(0.2, 0.3, 0.1)); camera.transform = main.head_pose
	main._update_view_follow(); main._place_screen()
	check(world(video).is_equal_approx(first_pose), "Head movement cannot move the screen")
	main._update_cinema_guide()
	check(not video.cinema.guide.visible, "Head movement does not show the grid")
	main.view_follow.set_enabled(true); main._place_screen()
	check(not main.view_follow.enabled and world(video).is_equal_approx(first_pose), "Returning from another media's follow mode keeps cinema world-fixed")
	for curve in [0.0, 0.7]:
		video.set_screen_curve(curve)
		var anchor := bottom(video); var distance: float = main._surface_distance(video)
		main._zoom_video(log(1.5 / video.screen_scale)); main._finish_flat_zoom()
		check(bottom(video).is_equal_approx(anchor) and is_equal_approx(main._surface_distance(video), distance), "Stick scaling fixes bottom midpoint and plane distance")
		main._on_playback_adjustment("screen_scale", 200.0)
		check(bottom(video).is_equal_approx(anchor), "Settings slider shares the same bottom anchor")
		var size: Vector2 = video._flat.size
		main._push_screen(1.0)
		check(is_equal_approx(main._surface_distance(video), distance + 1) and is_equal_approx(bottom(video).y, anchor.y) and video._flat.size == size, "Push changes only normal distance, never height or size")
		main._on_playback_adjustment("screen_distance", 2.5)
		check(is_equal_approx(main._surface_distance(video), 2.5), "Distance slider uses the plane distance despite elevated centre")
		for hand in ["left_hand", "right_hand"]:
			for corner in [0, 1]:
				menu.dismiss(); menu.section = 0; menu._adjustment = ""; menu.toggle()
				video.set_screen_scale(1.0); video.panel.visible = true
				anchor = bottom(video)
				var target: Vector3 = video.panel.to_global(video.screen_corner(corner))
				main.rays[hand] = [camera.global_position, (target - camera.global_position).normalized()]
				check(main._try_corner_resize(hand), "Either upper corner can start a resize with either hand")
				if not main._grab.has("resize"): continue
				main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
				check(video.cinema.guide.visible, "Either corner shows the temporary grid")
				var vector: Vector3 = main._grab.resize.cinema_vector
				main.rays[hand][1] = (anchor + vector * 1.4 - camera.global_position).normalized()
				main._update_grab()
				check(is_equal_approx(video.screen_scale, 1.4) and bottom(video).is_equal_approx(anchor), "Corner dragging grows about the same bottom midpoint")
				main._on_pointer_release("trigger_click", hand)
				main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
				check(not video.cinema.guide.visible, "Corner release hides the grid")
			for corner in [2, 3]:
				var target: Vector3 = video.panel.to_global(video.screen_corner(corner))
				check(video.corner_at(camera.global_position, (target - camera.global_position).normalized()) == -1, "Lower corners cannot resize cinema screens")
			main.pose = Transform3D(Basis.IDENTITY, main.head_pose.origin + Vector3(0, 0, -0.3))
			main.rays[hand] = [camera.global_position, (video.panel.global_position - camera.global_position).normalized()]
			main._begin_interface_move(hand, "grip_click")
			check(not main.interface_move.capture.is_empty(), "Grip captures cinema screen")
			main.pose.origin += Vector3(0.2, 0.15, 0); main.pose.basis = Basis.from_euler(Vector3(0.1, 0.2, 0.2))
			main._update_interface_move()
			check(world(video).basis.y.is_equal_approx(Vector3.UP), "Grip translation cannot pitch or roll the screen")
			anchor = bottom(video); distance = main._surface_distance(video); size = video._flat.size
			main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
			main._process_sticks(Vector2(0, 1) if hand == "left_hand" else Vector2.ZERO, Vector2(0, 1) if hand == "right_hand" else Vector2.ZERO, 0.1)
			check(video.cinema.guide.visible, "Grip plus stick depth shows the grid for either hand")
			check(video.cinema.guide.global_transform.is_equal_approx(guide_pose) and video.cinema.guide.mesh.get_instance_id() == guide_mesh, "Screen movement reuses a stationary grid")
			check(is_equal_approx(bottom(video).y, anchor.y) and main._surface_distance(video) > distance and video._flat.size == size, "Grip plus stick moves only forwards/backwards")
			main._on_controller_release("grip_click", hand)
			main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
			check(not video.cinema.guide.visible, "Grip release hides the grid")
			check(is_equal_approx(video.screen_distance, main._surface_distance(video)), "Grip release persists plane distance, not centre distance")
	var large_anchor := bottom(video)
	main._on_playback_adjustment("screen_scale", 500.0)
	check(video.screen_scale == 5.0 and bottom(video).is_equal_approx(large_anchor), "500 percent settings size preserves the cinema bottom")
	main._zoom_video(log(20)); main._finish_flat_zoom()
	check(video.screen_scale == 30.0, "Stick zoom stops at 3000 percent")
	video.set_screen_scale(5.0)
	main._on_playback_adjustment("screen_distance", 3.0)
	menu.dismiss(); menu.toggle(); menu._activate(Menu.SCREEN_SETTINGS)
	check(click(menu, Menu.SCREEN_SET_DEFAULT) and main._flat_video_is_default(), "Set as default saves cinema placement and selected feedback")
	menu.dismiss()
	var saved := main._cinema_default(); var saved_size := main._flat_video_defaults()
	check(saved_size.y == 5.0, "500 percent can be saved as the default")
	check(saved.enabled and is_equal_approx(saved.height, bottom(video).y - camera.global_position.y), "Default includes relative bottom height")
	main._push_screen(1); video.set_screen_scale(2.3)
	var pose := world(video); pose.origin.y += 0.7; video.set_flat_world_pose(pose)
	main._save_screen()
	check(main._cinema_default() == saved and main._flat_video_defaults() == saved_size, "Temporary adjustments cannot overwrite saved cinema defaults")
	for system in [false, true]:
		main._set_cinema_mode(false)
		main.head_pose = Transform3D(Basis.from_euler(Vector3(0.3, -0.4, 0.2)), Vector3(0.5, 1.2, 0.3)); camera.transform = main.head_pose
		if system: main._on_system_recentered()
		else: main._on_menu_action("recenter")
		check(video.cinema.enabled and world(video).basis.y.is_equal_approx(Vector3.UP), "Both recenter routes restore cinema mode and vertical orientation")
		check(not video.cinema.guide.visible, "Recenter does not show the grid")
		check(is_equal_approx(bottom(video).y - camera.global_position.y, saved.height) and is_equal_approx(main._surface_distance(video), saved_size.x) and is_equal_approx(video.screen_scale, saved_size.y), "Recenter restores height, plane distance and size relative to new viewer")
	var anchor := bottom(video)
	video._apply_geometry(); video._apply_geometry()
	check(not video.cinema.guide.visible and not video.has_node("CinemaReferences"), "Geometry updates do not show a grid or add a frame")
	video.media.format = {"width": 1920, "height": 800}; video._apply_geometry()
	check(bottom(video).is_equal_approx(anchor), "Late aspect-ratio changes preserve the anchor")
	video.cinema.show_guide(video, main.head_pose, true)
	video.close_video()
	check(not video.cinema.guide.visible, "Closing video hides the grid")
	video.open_local("file:///cinema/next.mp4", "Next.mp4"); main._place_screen()
	check(bottom(video).is_equal_approx(anchor), "Changing videos does not reposition the cinema screen")
	video.panel.visible = true; video.cinema.show_guide(video, main.head_pose, true)
	video.set_projection(1)
	main._update_cinema_guide()
	check(not video.cinema.guide.visible, "Immersive projection hides the grid")
	check(not video.cinema.active(video), "Immersive videos do not use cinema placement")
	video.set_screen_rotation(25)
	check(video.screen_rotation == 25, "Immersive content rotation remains available")
	video.set_projection(0); main._place_screen(); video.panel.visible = true
	check(video.cinema.enabled and bottom(video).is_equal_approx(anchor) and video.panel.global_basis.y.is_equal_approx(Vector3.UP), "Returning to flat restores upright cinema after immersive rotation")
	var restart := InputMain.new(); restart.video = Video.new(); restart.video.history_enabled = false
	restart.settings.load(main.settings_path); restart._restore_flat_video_settings()
	root.add_child(restart.video); restart.video.set_process(false); restart.video.view_camera = camera; restart.head_pose = main.head_pose
	restart.video.local_uri = "file:///cinema/restarted.mp4"; restart._place_screen()
	check(restart.video.cinema.enabled and restart.video.screen_scale == 5.0 and is_equal_approx(bottom(restart.video).y - camera.global_position.y, saved.height), "Startup restores saved mode, 500 percent size and height after tracking becomes available")
	restart.video.free(); restart.free()
	main._on_session_control("follow")
	check(main.view_follow.enabled and not video.cinema.enabled, "Explicit follow exits cinema; no hidden conflict")
	check(not video.cinema.guide.visible, "Leaving cinema hides the grid")
	main._on_session_control("follow")
	main._set_cinema_mode(true)
	main._on_playback_adjustment("screen_distance", 1.0); main._save_flat_video_defaults()
	check(is_equal_approx(main._flat_video_defaults().x, 1.0), "Minimum cinema distance can be saved despite floating-point rounding")
	var previous_view := main._flat_video_defaults(); var previous_mode := main._cinema_default()
	var settings_path: String = main.settings_path
	main.settings_path = settings_path.get_base_dir(); main._set_cinema_mode(false); main._save_flat_video_defaults()
	check(main._flat_video_defaults() == previous_view and main._cinema_default() == previous_mode, "Failed save rolls back both dimensions and mode/height")
	main.settings_path = settings_path
	menu.toggle(); menu._activate(Menu.SCREEN_SETTINGS); click(menu, Menu.SCREEN_SET_DEFAULT); menu.dismiss()
	main._set_cinema_mode(true); main._recenter()
	check(not video.cinema.enabled, "Saving free mode then recentering restores free mode")
	var before := world(video); video.set_screen_scale(60)
	check(video.screen_scale == 30.0 and world(video).is_equal_approx(before), "Free mode supports 3000 percent and retains centre scaling")
	var original_default := main._flat_video_defaults()
	video.stereo_sbs = false; video.top_bottom = false; video.stereo_half = false
	menu.toggle(); menu._activate(Menu.SCREEN_SETTINGS)
	check(click(menu, Menu.SCREEN_CINEMA), "Enable cinema before choosing a preset")
	for index in Video.ScreenPresets.ITEMS.size():
		var preset: Dictionary = Video.ScreenPresets.ITEMS[index]
		video.media.format = {"width": 1920, "height": 1080}; video._apply_geometry()
		check(click(menu, Menu.SCREEN_PRESET + index), "Preset is reachable by a real ray: " + preset.id)
		check(video.cinema.enabled and video.screen_preset == preset.id and main._active_screen_preset() == preset.id, "Preset enables upright cinema and selection: " + preset.id)
		check(is_equal_approx(main._surface_distance(video), preset.distance) and is_equal_approx(video._flat.size.x, preset.size.x), "Preset applies physical width and viewing distance: " + preset.id + " actual=" + str(video._flat.size) + " base=" + str(video._screen_base) + " stereo=" + str(video.stereo_sbs) + " distance=" + str(main._surface_distance(video)))
		check(is_equal_approx((world(video).origin.y - camera.global_position.y) / preset.size.y, 0.5 - float(preset.eye_level)), "Preset places the screen at its intended seat height")
		check(main._flat_video_defaults() == original_default, "Trying presets does not overwrite the saved default")
		check(not video.cinema.guide.visible, "Preset application does not flash the adjustment grid")
		var preset_center := world(video).origin
		for dimensions in [Vector2i(2390, 1000), Vector2i(1430, 1000), Vector2i(1080, 1920)]:
			video.media.format = {"width": dimensions.x, "height": dimensions.y}; video._apply_geometry()
			check(is_equal_approx(video._flat.size.x / video._flat.size.y, float(dimensions.x) / dimensions.y), "Preset preserves late-arriving source aspect")
			check(world(video).origin.is_equal_approx(preset_center), "Aspect changes preserve nominal screen center and seat height")
			check(video._flat.size.x <= preset.size.x + 0.001 and video._flat.size.y <= preset.size.y + 0.001, "Portrait and wide videos fit the preset envelope")
	var before_height_size: Vector2 = video._flat.size
	var before_height_distance: float = main._surface_distance(video)
	check(click(menu, Menu.SCREEN_EYE_LEVEL + 1), "Centered eye level is reachable")
	check(is_equal_approx(world(video).origin.y, camera.global_position.y), "Centered eye level puts nominal screen center at eye height")
	check(click(menu, Menu.SCREEN_EYE_LEVEL), "Cinema eye level is reachable")
	check(is_equal_approx(video.cinema.eye_level(video, camera.global_position), 1.0 / 3.0), "Cinema eye level uses GSCA one-third reference")
	check(video._flat.size == before_height_size and is_equal_approx(main._surface_distance(video), before_height_distance), "Eye level changes neither dimensions nor distance")
	check(main._flat_video_defaults() == original_default, "Eye level changes do not overwrite defaults")
	var content_anchor := bottom(video)
	video.set_screen_scale(video.screen_scale * 1.1)
	check(bottom(video).is_equal_approx(content_anchor), "Leaving a letterboxed preset for manual scaling retains the visible bottom")
	video.media.format = {"width": 1430, "height": 1000}; video._apply_geometry()
	main._apply_screen_preset("giant32"); main._save_flat_video_defaults()
	var giant_bottom := bottom(video).y - camera.global_position.y
	check(giant_bottom < -4 and is_equal_approx(main._cinema_default().height, giant_bottom), "Giant-screen saved height is not truncated to the old four metre limit")
	main._apply_screen_preset("tv100"); main._on_system_recentered()
	check(video.screen_preset == "giant32" and is_equal_approx(video._flat.size.x, 32) and is_equal_approx(main._surface_distance(video), 24) and is_equal_approx(bottom(video).y - camera.global_position.y, giant_bottom), "System recenter restores the saved giant screen")
	main._apply_screen_preset("home150"); main._on_menu_action("recenter")
	check(video.screen_preset == "giant32" and main._flat_video_is_default(), "Player recenter restores the saved preset")
	video.media.format = {"width": 2390, "height": 1000}; video._apply_geometry()
	var wide_center := world(video).origin
	main._on_menu_action("recenter"); main._on_system_recentered()
	check(world(video).origin.is_equal_approx(wide_center) and main._flat_video_is_default(), "Repeated recenter of a letterboxed preset cannot accumulate height offsets")
	var restarted := InputMain.new(); restarted.video = Video.new(); restarted.video.history_enabled = false
	restarted.settings.load(main.settings_path); restarted._restore_flat_video_settings()
	root.add_child(restarted.video); restarted.video.set_process(false); restarted.video.view_camera = camera; restarted.head_pose = main.head_pose
	restarted.video.local_uri = "file:///cinema/preset-restart.mp4"; restarted.video.media.format = {"width": 1430, "height": 1000}
	restarted.video._apply_geometry(); restarted._place_screen()
	check(restarted.video.screen_preset == "giant32" and is_equal_approx(restarted.video._flat.size.x, 32) and is_equal_approx(restarted.video.cinema.bottom.origin.y - camera.global_position.y, giant_bottom), "Restart restores physical preset dimensions after metadata arrives")
	restarted.video.media.format = {"width": 2390, "height": 1000}; restarted.video._apply_geometry()
	check(world(restarted.video).origin.is_equal_approx(wide_center), "Late widescreen metadata keeps saved nominal screen position")
	restarted.video.free(); restarted.free()
	video.set_screen_scale(7)
	check(video.screen_preset.is_empty() and main._active_screen_preset().is_empty(), "Manual scaling leaves the preset and preserves custom size")
	video._apply_geometry(); check(video.screen_scale == 7, "Metadata updates do not overwrite custom scaling")
	for span in [Vector3(1, 50, 0.1), Vector3(100, 3000, 5)]:
		for fraction in [0.0, 0.25, 0.5, 0.75, 1.0]:
			var value := Video.ScreenPresets.slider_value(fraction, span)
			check(value >= span.x and value <= span.y and absf(Video.ScreenPresets.slider_fraction(value, span) - fraction) < 0.02, "Wide-range slider mapping stays bounded and reversible")
	check_free_exit(main, video, camera, menu)
	menu.free(); main.recent_menu.free(); video.free(); camera.free(); main.free()
	for failure in failures: push_error(failure)
	print("Cinema placement: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func check_free_exit(main: Node3D, video: Node3D, camera: Camera3D, menu: Node3D) -> void:
	var locked: Vector2 = main._flat_video_defaults()
	var locked_cinema: Dictionary = main._cinema_default()
	for id in ["tv100", "home150", "giant22", "giant32"]:
		main.head_pose = Transform3D(Basis.from_euler(Vector3(0.22, 0.6, 0.1)), Vector3(0.3, 1.7, -0.2))
		camera.transform = main.head_pose
		main._apply_screen_preset(id)
		main._turn_picture(0.15, 0.12)
		var size: Vector2 = video._flat.size
		var distance: float = main._surface_distance(video)
		main.interface_move.placements[&"video"] = Transform3D(Basis.IDENTITY, Vector3(8, 4, -2))
		menu.dismiss(); menu.toggle(); menu._activate(Menu.SCREEN_SETTINGS)
		check(click(menu, Menu.SCREEN_CINEMA_OFF), "Exit cinema through the actual Off button: " + id)
		var pose := world(video)
		check(pose.is_equal_approx(main._view_pose(distance, 0)), "Cinema Off automatically uses ordinary placement at the current heading: " + id)
		check(is_equal_approx(video.screen_distance, distance) and video._flat.size.is_equal_approx(size), "Cinema Off retains plane distance and size: " + id)
		check(pose.basis.z.normalized().is_equal_approx((camera.global_position - pose.origin).normalized()), "Free screen faces the eyes without a recenter press: " + id)
		check(not main.interface_move.placements.has(&"video") and main._grab.is_empty(), "Exit discards stale drag placement: " + id)
		main._place_screen(); main._update_view_follow()
		check(world(video).is_equal_approx(pose), "Later placement cannot resurrect the cinema pose: " + id)
		menu.dismiss()
		var direction := (pose.origin - camera.global_position).normalized()
		main.rays.right_hand = [camera.global_position, direction]
		main._begin_grab("right_hand")
		main.rays.right_hand = [camera.global_position, Basis(Vector3.UP, 0.15) * direction]
		main._update_grab()
		check(not world(video).is_equal_approx(pose), "The first free-mode pointer drag works immediately: " + id)
		main._grab.clear()
		check(main._flat_video_defaults() == locked and main._cinema_default() == locked_cinema, "Automatic free placement never overwrites locked defaults: " + id)
