extends SceneTree
## Main's actual production routes with the bundled environment and synthetic
## tracked rays. This checks desktop logic, not OpenXR or decoder pixel fidelity.
const Bindings := preload("res://scripts/controller_bindings.gd")
const HostTest := preload("res://tests/test_player_menu.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Catalog := preload("res://scripts/recent_files.gd")
var checks: Array[Dictionary] = []
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../build/output/cinema-player-integration")
var main: Node3D
var viewport: SubViewport

class SupportedDisplay extends XrDisplay:
	func supports_passthrough() -> bool: return true

class InputMain extends "res://scripts/main.gd":
	var rays := {}
	var focused := true
	func _ray(hand: String) -> Variant: return rays.get(hand)
	func _input_focused() -> bool: return focused
	func _head_tracked() -> bool: return true

func _initialize() -> void: _run.call_deferred()

func check(ok: bool, label: String, detail: Variant = "") -> void:
	checks.append({"label": label, "passed": ok, "detail": str(detail)})
	if not ok:
		failures.append(label + (": " + str(detail) if not str(detail).is_empty() else ""))
		printerr("FAIL: " + failures.back())

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var config := ConfigFile.new()
	config.set_value("appearance", "background", "dark")
	config.set_value("ui", "language", "en")
	config.save(output.path_join("settings.cfg"))
	viewport = SubViewport.new()
	viewport.size = Vector2i(1280, 800)
	viewport.own_world_3d = true
	root.add_child(viewport)
	main = InputMain.new()
	main.settings_path = output.path_join("settings.cfg")
	main.display = SupportedDisplay.new()
	viewport.add_child(main)
	main.set_process(false)
	main.video.set_process(false); main.photo.set_process(false)
	main.report_timer.stop()
	main.video.history_enabled = false; main.photo.history_enabled = false
	main.video.mode_memory = Memory.new(output.path_join("modes.cfg"))
	main.video.recent_files = Catalog.new(output.path_join("recent.cfg"))
	main.video.platform = HostTest.Host.new()
	main.video.local_uri = "file:///cinema-integration.mp4"
	main.video.media.begin(7); main.video.media.state = "playing"
	main.video.media.format.width = 1920; main.video.media.format.height = 1080
	main.video._apply_geometry()
	main.video._waiting_first = false; main.video.requested_play = true
	main.video.control.duration_ms = 600000
	main.video.control.observed_position_ms = 120000
	main.video.audio_volume = 50
	main.video.panel.visible = true
	_close_menus()
	check(main.has_method("_cinema_scene_active") and main.get("cinema_environment") != null,
		"Production main exposes the cinema host and integration API")
	if not main.has_method("_cinema_scene_active") or main.get("cinema_environment") == null:
		await _finish(); return
	_playback_routes("dark", true)
	var original_rig: Transform3D = main.xr_origin.global_transform
	var original_camera_local: Transform3D = main.xr_camera.transform
	var original_size: Vector2 = main.video._flat.size
	var preferences := _screen_preferences()
	check(main.background.select("cinema"), "Cinema is available through the production background selector")
	main._update_background()
	var deadline := Time.get_ticks_msec() + 20000
	while main.cinema_environment.loading and Time.get_ticks_msec() < deadline:
		await create_timer(0.01).timeout
	main._update_background(); main._sync_cinema_screen()
	check(main.cinema_environment.is_ready and main._cinema_scene_active(), "Bundled imported GLB and navigation activate in main", main.cinema_environment.snapshot())
	if not main._cinema_scene_active():
		await _finish(); return
	check(main.xr_camera.transform.is_equal_approx(original_camera_local), "Entering cinema changes rig without overwriting tracked camera local pose")
	check(main.cinema_environment.snapshot().seat == "I12", "Production cinema starts at default seat I12")
	var world_screen: Transform3D = main.video.global_transform * main.video.flat_pose
	check(is_equal_approx(main.video._flat.size.x, 32.0), "Cinema video uses the 32 metre physical screen envelope",
		{"mesh": main.video._flat.size, "scale": main.video.screen_scale, "base": main.video._screen_base, "saved": main._cinema_screen_saved})
	check(_screen_preferences() == preferences, "Entering cinema does not persist its 32 metre envelope as user preferences")
	main.xr_camera.position += Vector3(0.12, -0.06, 0.04)
	main._update_view_follow(); main._place_screen(); main._sync_cinema_screen()
	check((main.video.global_transform * main.video.flat_pose).is_equal_approx(world_screen), "Room-scale head movement and screen placement keep cinema screen fixed")
	main.xr_camera.transform = original_camera_local
	_playback_routes("cinema-watch", false)
	await _seat_routes()
	_movement_routes()
	_menu_and_capture_routes()
	_context_routes()
	_return_routes()
	var expected: Dictionary = main._cinema_screen_saved.duplicate(true)
	main._reset_picture()
	main._apply_screen_preset("home150")
	main._on_playback_adjustment("screen_scale", 3000)
	main._set_screen_preference("scale", 999)
	main._save_playback_adjustments()
	check(_screen_preferences() == preferences, "All screen write paths reject cinema dimensions, even direct preference writes")
	for choice in ["morning", "dark", "belfast"]:
		main.background.select(choice); main._update_background()
		check(main._cinema_screen_saved.is_empty() and is_equal_approx(main.video.screen_scale, float(expected.screen_scale)), "Background switch restores ordinary scale: " + choice)
		main._on_setting_changed("screen_scale", 999)
		main.background.select("cinema"); main._update_background()
	main._sync_cinema_lights()
	check(not main.cinema_environment.lights_on, "Playing defaults to dark auditorium")
	main._on_setting_changed("cinema_lights", "on")
	check(main.cinema_environment.lights_on, "Manual lighting action overrides playback")
	main._on_setting_changed("cinema_lights", "auto")
	_close_menus(); main._cinema_request_interaction("watch")
	main._recenter()
	check((main.video.global_transform * main.video.flat_pose).is_equal_approx(world_screen), "Explicit recenter preserves world cinema screen")
	check(main.cinema_environment.snapshot().seat == "I12", "Explicit recenter returns to default cinema seat")
	main._on_system_recentered()
	check((main.video.global_transform * main.video.flat_pose).is_equal_approx(world_screen), "System recenter preserves world cinema screen")
	check(_screen_preferences() == preferences, "Seat changes, walking and recenter never overwrite ordinary screen preferences")
	main.xr_camera.basis = Basis.from_euler(Vector3(0.2, 0.65, 0.1))
	main.background.select("dark"); main._update_background()
	check(not main._cinema_scene_active() and not main.cinema_environment.selected, "Leaving cinema deselects and hides bundled scenery")
	check(main.xr_origin.global_transform.is_equal_approx(original_rig), "Leaving cinema restores pre-cinema rig")
	var ordinary_pose: Transform3D = main._view_pose(main.video.screen_distance, 0)
	check((main.video.global_transform * main.video.flat_pose).is_equal_approx(ordinary_pose), "Leaving cinema automatically faces the current heading instead of restoring a stale world pose")
	main._place_screen(); main._update_view_follow()
	check((main.video.global_transform * main.video.flat_pose).is_equal_approx(ordinary_pose), "Normal placement stays stable after leaving cinema")
	main._turn_picture(0.12, 0.05)
	check(not (main.video.global_transform * main.video.flat_pose).is_equal_approx(ordinary_pose), "Ordinary dragging works immediately after leaving cinema")
	check(main.video._flat.size.is_equal_approx(original_size), "Leaving cinema restores pre-cinema video dimensions")
	check(_screen_preferences() == preferences, "Leaving cinema restores without saving scene dimensions")
	await _finish()

func _close_menus() -> void:
	for menu in [main.recent_menu, main.video_menu, main.photo_menu, main.music_menu]:
		if menu: menu.dismiss()
	main.player_menu = main.video_menu

func _screen_preferences() -> Dictionary:
	var result := {}
	for key in ["distance", "scale", "curve", "cinema", "default_view", "default_cinema"]:
		result[key] = main.settings.get_value("screen", key) if main.settings.has_section_key("screen", key) else null
	return result

func _return_routes() -> void:
	_close_menus(); main._cinema_request_interaction("move")
	main.rays.clear() # Right controller only: no left pose/ray participates.
	var eye: Vector3 = main.xr_camera.global_position
	main.rays.right_hand = [eye, Vector3.DOWN]
	main._on_controller_button("ax_button", "right_hand")
	check(main.cinema_environment.snapshot().capture_hand == "right_hand", "Right A owns movement aim")
	main.cinema_environment.update_pointer("right_hand", eye, Vector3.DOWN, true)
	main._on_controller_button("trigger_click", "right_hand")
	main._on_controller_release("trigger_click", "right_hand")
	check(main.cinema_environment.interaction == "move" and main.player_menu.visible, "Right trigger opens menu without changing the movement toggle")
	check(main.cinema_environment.snapshot().capture_hand.is_empty(), "Opening menu cancels held movement aim")
	main._on_controller_release("ax_button", "right_hand")
	check(main.xr_camera.global_position.is_equal_approx(eye), "Releasing A over menu cannot teleport")
	var button: Dictionary = main.player_menu._buttons.filter(func(item): return item.target == main.player_menu.FREE_MOVEMENT)[0]
	var follow: Dictionary = main.player_menu._buttons.filter(func(item): return item.target == main.player_menu.FOLLOW)[0]
	check(button.node.position.x < follow.node.position.x, "Free movement appears to the left of Follow")
	main.rays.right_hand = [eye, (button.node.global_position - eye).normalized()]
	main._update_menu_pointer("right_hand")
	check(main.player_menu._pointers.right_hand.line.visible, "Menu restores the normal straight right-hand ray")
	check(not main.cinema_environment._pointer_visuals.right_hand.root.visible, "Menu hides the movement arc")
	main._on_controller_button("ax_button", "right_hand")
	main._on_controller_release("ax_button", "right_hand")
	check(main.cinema_environment.snapshot().capture_hand.is_empty(), "A is inert for movement while menus are visible")
	main._on_controller_button("trigger_click", "right_hand")
	main._on_controller_release("trigger_click", "right_hand")
	check(main.cinema_environment.interaction == "watch" and main.player_menu.visible, "Right trigger switches off movement from the shared footer")
	check(main.xr_camera.global_position.is_equal_approx(eye), "Switching to playback preserves the viewpoint")
	check(not main._session_controls_state().cinema_moving, "Footer toggle state updates immediately")
	_close_menus(); main._cinema_request_interaction("move")
	main._on_controller_button("by_button", "right_hand")
	main._on_controller_release("by_button", "right_hand")
	check(main.cinema_environment.interaction == "watch" and main.player_menu.visible, "Right B remains a direct playback exit")
	_close_menus(); main.rays.clear()

func _neutral() -> void:
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 1.0 / 72)

func _playback_routes(label: String, zoom_expected: bool) -> void:
	_close_menus()
	if main._cinema_scene_active(): main._cinema_request_interaction("watch")
	_neutral()
	var before: float = main.video.audio_volume
	main._process_sticks(Vector2(0, 0.99), Vector2.ZERO, 0.05)
	check(main.video.audio_volume > before, label + " left stick controls actual playback volume")
	_neutral()
	main._process_sticks(Vector2.ZERO, Vector2(0.99, 0), 0.05)
	check(main.seek_feedback.phase == "preview" and main.seek_feedback.owner == "right_hand", label + " right stick enters real seek preview")
	main.stick_controls.suspend(); _neutral()
	if zoom_expected:
		var scale: float = main.video.screen_scale
		main._process_sticks(Vector2.ZERO, Vector2(0, 0.99), 0.05)
		check(main.video.screen_scale > scale, label + " right vertical stick retains flat video scaling")
		main._finish_flat_zoom(); _neutral()
	elif main._cinema_scene_active():
		var size: Vector2 = main.video._flat.size
		var pose: Transform3D = main.video.global_transform * main.video.flat_pose
		var preferences := _screen_preferences()
		main._process_sticks(Vector2.ZERO, Vector2(0, 0.99), 0.1)
		main._finish_flat_zoom(); _neutral()
		check(main.video._flat.size.is_equal_approx(size) and (main.video.global_transform * main.video.flat_pose).is_equal_approx(pose),
			"Fixed cinema ignores physical screen scaling instead of distorting auditorium")
		check(_screen_preferences() == preferences, "Ignored cinema scaling does not overwrite ordinary screen defaults")
	main._show_player_menu()
	check(main.player_menu._buttons.any(func(item): return item.target == main.player_menu.FREE_MOVEMENT) == main._cinema_scene_active(), "Movement footer appears only inside cinema: " + label)
	check(main.player_menu.allows_playback_sticks(), label + " ordinary control bar allows playback sticks")
	before = main.video.audio_volume
	main._process_sticks(Vector2(0, -0.99), Vector2.ZERO, 0.05)
	check(main.video.audio_volume < before, label + " visible ordinary control bar still controls playback")
	main.player_menu.dismiss(); main.stick_controls.suspend(); _neutral()

func _seat_ray(id: String) -> Array:
	for seat in main.cinema_environment._manifest.seats:
		if str(seat.id) == id:
			var position := Vector3(seat.eye_position[0], seat.eye_position[1], seat.eye_position[2])
			# Behind the target backrest, still in front of the next row's chair volume.
			return [position + Vector3(0, -0.1, 0.6), Vector3.FORWARD]
	return []

func _press(hand: String, optical: bool = false) -> void:
	if optical: main._on_pointer_button("trigger_click", hand)
	else: main._on_controller_button("ax_button", hand)

func _release(hand: String, optical: bool = false) -> void:
	if optical: main._on_pointer_release("trigger_click", hand)
	else: main._on_controller_release("ax_button", hand)

func _seat_routes() -> void:
	check(not main._cinema_request_interaction("seat"), "Stale seat mode is rejected")
	for optical in [false]:
		_close_menus()
		check(main._cinema_request_interaction("move"), "Explicit teleport mode accepted")
		_neutral()
		var before: Vector3 = main.xr_camera.global_position
		main.rays.right_hand = [before + Vector3(.5, 0, 0), Vector3.DOWN]
		main.rays.left_hand = main.rays.right_hand
		_press("right_hand", optical)
		check(main.cinema_environment.snapshot().capture_hand == "right_hand", "Controller/optical trigger owns teleport aim")
		_release("left_hand", optical)
		check(main.cinema_environment.snapshot().capture_hand == "right_hand", "Wrong hand release cannot commit teleport")
		_release("right_hand", optical)
		check(main.xr_camera.global_position.distance_to(before) > .3, "Owning controller/optical release teleports")
		check(main._active_menu() == null, "Teleport does not reveal playback controls")

func _movement_routes() -> void:
	check(main._cinema_request_interaction("move"), "Move mode leaves seat at authored safe aisle exit")
	_neutral()
	var before: Vector3 = main.xr_camera.global_position
	var volume: float = main.video.audio_volume
	var sequence: int = main.video.control.sequence
	for frame in 20: main._process_sticks(Vector2(0.99, 0), Vector2.ZERO, 1.0 / 60)
	check(main.xr_camera.global_position.is_equal_approx(before), "Teleport mode disables continuous stick translation")
	check(main.video.audio_volume == volume and main.video.control.sequence == sequence and main.seek_feedback.phase.is_empty(), "Move input cannot seek or change playback volume")
	var camera_local: Transform3D = main.xr_camera.transform
	main._process_sticks(Vector2.ZERO, Vector2(0.99, 0), 1.0 / 60)
	check(main.xr_camera.transform.is_equal_approx(camera_local), "Snap turning preserves tracked local camera transform")
	# Actual ray target/trigger path, independent of the locomotion pure-unit tests.
	var position: Vector3 = main.xr_camera.global_position
	var floor_hit: Dictionary = {}
	for offset in [Vector3(0.5, 0, 0), Vector3(-0.5, 0, 0), Vector3(0, 0, 0.2)]:
		var candidate: Dictionary = main.cinema_environment.ray_hit(position + offset, Vector3.DOWN)
		if candidate.get("valid", false):
			floor_hit = candidate; main.rays.right_hand = [position + offset, Vector3.DOWN]; break
	check(floor_hit.get("kind", "") == "floor" and floor_hit.get("valid", false), "Move ray resolves connected collision-safe floor", floor_hit)
	if not floor_hit.is_empty():
		_press("right_hand")
		check(main.cinema_environment.snapshot().capture_hand == "right_hand", "Main trigger captures actual floor teleport target")
		_release("right_hand")
		var target: Vector3 = floor_hit.position + Vector3.UP * 1.65
		check(main.xr_camera.global_position.is_equal_approx(target), "Main owning trigger release commits actual floor teleport", main.xr_camera.global_position)
	check(main._active_menu() == null and main._video_control_tap.is_empty(), "Floor teleport trigger never toggles playback controls")
	var screen: Transform3D = main.video.global_transform * main.video.flat_pose
	main._sync_cinema_screen()
	check((main.video.global_transform * main.video.flat_pose).is_equal_approx(screen), "Walking and teleporting preserve fixed world screen")

func _menu_and_capture_routes() -> void:
	main._show_player_menu()
	_neutral()
	check(main._cinema_interaction_owns() and main._cinema_input_blocked(), "Menu preserves the movement toggle while suspending locomotion")
	var position: Vector3 = main.xr_camera.global_position
	var before: float = main.video.audio_volume
	main._process_sticks(Vector2(0, -0.99), Vector2.ZERO, 0.05)
	check(main.video.audio_volume < before and main.xr_camera.global_position.is_equal_approx(position), "Transport sticks operate playback while rig remains still")
	main.player_menu.dismiss()
	main._show_full_library()
	main.recent_menu.section = main.recent_menu.Section.SETTINGS
	main.recent_menu.tab = main.recent_menu.CONTROLS_TAB
	main.recent_menu.controls_page.mode = 0; main.recent_menu.scroll = 0; main.recent_menu.refresh()
	var scroll: float = main.recent_menu.scroll
	before = main.video.audio_volume
	main._process_sticks(Vector2(0, -0.99), Vector2.ZERO, 0.3)
	check(main.recent_menu.scroll > scroll, "Settings list scrolls through main production stick route")
	check(main.video.audio_volume == before and main.xr_camera.global_position.is_equal_approx(position), "Settings list input cannot move rig or alter playback")
	check(main._cinema_request_interaction("move"), "Move request can be activated from background/settings UI")
	check(main._active_menu() == null, "Move request closes settings before enabling scene input")
	position = main.xr_camera.global_position
	main._process_sticks(Vector2(0.99, 0), Vector2.ZERO, 0.1)
	check(main.xr_camera.global_position.is_equal_approx(position), "Mode switch with held stick waits for neutral")
	_close_menus()
	main._process_sticks(Vector2(0.99, 0), Vector2.ZERO, 0.1)
	var held: Vector3 = main.xr_camera.global_position
	main._process_sticks(Vector2(0.99, 0), Vector2.ZERO, 0.1)
	check(main.xr_camera.global_position.is_equal_approx(held), "Held input after closing settings waits for neutral")
	_neutral()
	# Main has real pointer-capture gates even without a visible timeline.
	main._grab = {"resize": true, "hand": "right_hand"}
	main._process_sticks(Vector2(0.99, 0), Vector2.ZERO, 0.1)
	check(main.xr_camera.global_position.is_equal_approx(held), "Resize capture blocks scene locomotion")
	main._grab = {}
	main._process_sticks(Vector2(0.99, 0), Vector2.ZERO, 0.1)
	check(main.xr_camera.global_position.is_equal_approx(held), "Release from resize capture still requires neutral")
	_neutral()
	main.focused = false; main._on_input_session_changed()
	main._process_sticks(Vector2(0.99, 0), Vector2.ZERO, 0.1)
	check(main.xr_camera.global_position.is_equal_approx(held), "Focus loss blocks scene movement")
	main.focused = true
	main._process_sticks(Vector2(0.99, 0), Vector2.ZERO, 0.1)
	check(main.xr_camera.global_position.is_equal_approx(held), "Focus resume with held stick waits for neutral")
	_neutral()
	main._cinema_request_interaction("watch")
	main._process_sticks(Vector2(0.99, 0), Vector2.ZERO, 0.1)
	check(main.seek_feedback.phase.is_empty(), "Leaving MOVE with held stick cannot create deferred seek")
	main.stick_controls.suspend(); _neutral()

func _context_routes() -> void:
	_close_menus()
	for geometry in [1, 2, 3]:
		main.video.geometry = geometry; main._update_background()
		check(not main._cinema_scene_active() and not main.cinema_environment.active, "Immersive geometry hides cinema: " + str(geometry))
		var yaw: float = main.video.view_yaw
		var zoom: float = main.video.view_zoom
		main._turn_picture(.1, 0); main._zoom_video(.1)
		check(not is_equal_approx(yaw, main.video.view_yaw) and not is_equal_approx(zoom, main.video.view_zoom), "Hidden cinema does not block immersive view controls: " + str(geometry))
		main._reset_picture()
	main.video.geometry = 0; main._update_background()
	check(main._cinema_scene_active(), "Returning to flat video restores cinema")
	main.video.alpha_requested = true; main._update_background()
	check(not main._cinema_scene_active() and main.display.applied_passthrough, "Alpha hides cinema and applies passthrough")
	main.video.alpha_requested = false; main._update_background()
	check(main._cinema_scene_active(), "Leaving Alpha restores cinema")
	main.temporary_passthrough = true; main._update_background()
	check(not main._cinema_scene_active(), "Temporary passthrough hides cinema")
	main.temporary_passthrough = false; main._update_background()
	main.photo_active = true; main.player_menu = main.photo_menu; main._update_background()
	check(not main._cinema_scene_active(), "Photo mode temporarily hides cinema")
	main.photo_active = false; main.player_menu = main.video_menu; main._update_background()
	check(main._cinema_scene_active(), "Returning from photo restores cinema")
	main.puzzle_game.active = true; main._update_background()
	check(not main._cinema_scene_active(), "Puzzle context temporarily hides cinema")
	main.puzzle_game.active = false; main._update_background()
	check(main._cinema_scene_active(), "Returning from puzzle restores cinema")
	check(main.background.choice == "cinema", "Temporary contexts preserve saved cinema background choice")

func _finish() -> void:
	var file := FileAccess.open(output.path_join("summary.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": checks, "failures": failures, "passed": failures.is_empty(),
		"scope": "Desktop production Main routes and bundled GLB environment with synthetic tracked rays. Not OpenXR or decoder pixel fidelity."}, "\t")); file.close()
	if is_instance_valid(viewport): viewport.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	print("Cinema player integration: %d checks, %d failures" % [checks.size(), failures.size()])
	quit(0 if failures.is_empty() else 1)
