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
	var move_poses := {}
	var focused := true
	func _ray(hand: String) -> Variant: return rays.get(hand)
	func _move_pose(hand: String) -> Variant: return move_poses.get(hand, super._move_pose(hand))
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
	config.set_value("appearance", "cinema_seat", "N11")
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
	check(main.cinema_environment.snapshot().seat == "N11", "Production main restores the globally saved seat on its first cinema load")
	var world_screen: Transform3D = main.video.global_transform * main.video.flat_pose
	check(is_equal_approx(main.video._flat.size.x, 32.0), "Cinema video uses the 32 metre physical screen envelope",
		{"mesh": main.video._flat.size, "scale": main.video.screen_scale, "base": main.video._screen_base, "saved": main._cinema_screen_saved})
	check(_screen_preferences() == preferences, "Entering cinema does not persist its 32 metre envelope as user preferences")
	main.xr_camera.position += Vector3(0.12, -0.06, 0.04)
	main._update_view_follow(); main._place_screen(); main._sync_cinema_screen()
	check((main.video.global_transform * main.video.flat_pose).is_equal_approx(world_screen), "Room-scale head movement and screen placement keep cinema screen fixed")
	main.xr_camera.transform = original_camera_local
	_picture_size_routes(world_screen, preferences)
	_playback_routes("cinema-watch", false)
	await _seat_routes()
	_movement_routes()
	_menu_and_capture_routes()
	_panel_lock_routes()
	_context_routes()
	_immersive_completion_menu_routes()
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
		check(not main.recent_menu.scene_overlay and not main.photo_menu.scene_overlay and not main.music_menu.scene_overlay,
			"Leaving cinema restores ordinary menu depth: " + choice)
		check(main._cinema_screen_saved.is_empty() and is_equal_approx(main.video.screen_scale, float(expected.screen_scale)), "Background switch restores ordinary scale: " + choice)
		main._on_setting_changed("screen_scale", 999)
		main.background.select("cinema"); main._update_background()
	main._sync_cinema_lights()
	check(not main.cinema_environment.lights_on, "Playing defaults to dark auditorium")
	main._on_setting_changed("cinema_lights", "on")
	check(main.cinema_environment.lights_on, "Manual lighting action overrides playback")
	main._on_setting_changed("cinema_lights", "auto")
	_auto_light_routes()
	_viewing_brightness_routes()
	_screen_light_routes()
	await _recenter_and_saved_seat_routes(world_screen)
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
	await _photo_close_routes()
	await _finish()

func _panel_lock_routes() -> void:
	_close_menus(); main._show_player_menu()
	var menu: Node3D = main.video_menu
	main._on_menu_action("space_lock")
	var pose: Transform3D = menu.global_transform
	var camera: Transform3D = main.xr_camera.transform
	main.xr_camera.position += Vector3(.3, .1, .2)
	menu.dismiss(); main._show_player_menu()
	check(menu.space_locked() and menu.global_transform.is_equal_approx(pose), "Production cinema reopen preserves the locked panel")
	main._show_recent_menu()
	check(main._library_is_attached() and main.recent_menu.space_locked(), "Cinema playback library inherits the panel lock")
	main._on_menu_action("space_lock")
	check(not main.recent_menu.space_locked(), "Unlock also releases the attached cinema library")
	var library_local: Transform3D = main.recent_menu.transform
	var screen: Transform3D = main.video.global_transform * main.video.flat_pose
	var scope: String = main.controller_bindings.move_scope
	main.controller_bindings.move_scope = "all"
	main.move_poses.right_hand = main._head_pose()
	main.rays.right_hand = [main._head_pose().origin, menu.global_position - main._head_pose().origin]
	main._begin_interface_move("right_hand", "grip_click")
	check(not main.interface_move.capture.is_empty(), "Grip captures unlocked cinema playback/library controls")
	main.move_poses.right_hand.origin.x += .2
	main._update_interface_move(); main.interface_move.cancel()
	check(not menu.global_transform.is_equal_approx(pose), "Production cinema grip moves the panel")
	check(main.recent_menu.transform.is_equal_approx(library_local), "Attached cinema library follows the dragged panel")
	var library_world: Transform3D = main.recent_menu.global_transform
	menu.refresh()
	check(main.recent_menu.global_transform.is_equal_approx(library_world), "Attached cinema library retains its dragged pose after refresh")
	main._sync_cinema_screen()
	check((main.video.global_transform * main.video.flat_pose).is_equal_approx(screen), "Dragging all cinema controls keeps the actual movie screen fixed")
	main.controller_bindings.move_scope = scope
	main.move_poses.clear(); main.rays.clear()
	main.xr_camera.transform = camera
	_close_menus(); main._reposition_cinema_menus()

func _photo_close_routes() -> void:
	main.video.close_video()
	main._on_setting_changed("background", "cinema")
	main.photo_background.select("morning")
	var deadline := Time.get_ticks_msec() + 15000
	while main.photo_background.loading and Time.get_ticks_msec() < deadline:
		await create_timer(.01).timeout
	check(main.photo_background.ready_sky() != null, "Photo close fixture has a loaded morning sky")
	for route in ["comic", "comic_no_browser", "photo", "delete", "forget", "eject"]:
		_close_menus()
		var comic: bool = route.begins_with("comic")
		var uri := "comic://close-regression/0" if comic else "file:///storage/close-regression/page.png"
		main.photo_active = true; main.player_menu = main.photo_menu
		main.photo.local_uri = uri; main.photo.display_name = "page.png"
		main.photo.geometry = 0; main.photo.archive_mode = comic
		main.photo.queue.assign([{"uri": uri, "title": "page.png", "kind": "image"}])
		main.photo.changed.emit()
		check(not main._cinema_scene_active() and main.display.scenery == main.photo_background.sky,
			"Reading uses the independent morning background: " + route)
		match route:
			"delete": main._prepare_file_delete(uri)
			"forget": main._forget_deleted_file(uri)
			"eject": main._release_storage_readers({"id": "/storage/close-regression", "removable": true})
			_: main._close_current_media(route != "comic_no_browser")
		# Do not repair state from the test: the production close route must restore
		# scenery immediately after close_image's synchronous changed callback.
		check(not main.photo_active and main.photo.local_uri.is_empty() and main.player_menu == main.video_menu,
			"Close exits the photo session: " + route)
		check(main._cinema_scene_active() and main.cinema_environment._model.visible,
			"Close immediately restores the actual cinema model: " + route)
		check(main.display.scenery == main.background.ready_sky() and main.display.scenery != main.photo_background.sky,
			"Close removes the photo sky: " + route)
		check(main.background.choice == "cinema" and main.settings.get_value("appearance", "background") == "cinema"
			and main.photo_background.choice == "morning", "Close preserves both independent background choices: " + route)
		await process_frame
		check(main._cinema_scene_active(), "Cinema stays restored on the next frame: " + route)
	main.background.select("dark")

func _recenter_and_saved_seat_routes(world_screen: Transform3D) -> void:
	_close_menus(); main._cinema_request_interaction("move"); _neutral()
	var seat: Dictionary = main.cinema_environment._manifest.seats.filter(func(item): return item.id == "N10")[0]
	var seat_eye := Vector3(float(seat.eye_position[0]), float(seat.eye_position[1]), float(seat.eye_position[2]))
	main.rays.right_hand = [seat_eye + Vector3.UP, Vector3.DOWN]
	_press("right_hand"); _release("right_hand")
	check(main.cinema_environment.snapshot().seat == "N10", "Recenter fixture sits in a real non-default seat through the production stick route", main.cinema_environment.ray_hit(main.rays.right_hand[0], main.rays.right_hand[1]))
	main.xr_camera.position += Vector3(.1, -.07, .03)
	main.cinema_environment._rotate_around_head(.8)
	var eye: Vector3 = main.xr_camera.global_position
	var tracked: Transform3D = main.xr_camera.transform
	main._show_player_menu()
	main._on_menu_action("recenter")
	check(main.xr_camera.global_position.is_equal_approx(eye) and main.cinema_environment.snapshot().seat == "N10",
		"Player recenter preserves the chosen seat and exact tracked eye position including height")
	check(main.xr_camera.transform.is_equal_approx(tracked), "Cinema recenter never overwrites the tracked camera local transform")
	var centre: Array = main.cinema_environment.snapshot().screen.position
	var direction := Vector3(float(centre[0]), eye.y, float(centre[2])) - eye
	var forward: Vector3 = -main.xr_camera.global_basis.z
	forward.y = 0
	check(forward.normalized().dot(direction.normalized()) > .9999, "Recenter turns toward the screen from the chosen seat")
	main._on_system_recentered()
	check(main.xr_camera.global_position.is_equal_approx(eye) and main.cinema_environment.snapshot().seat == "N10",
		"System recenter route also preserves the selected seat instead of returning home")
	check((main.video.global_transform * main.video.flat_pose).is_equal_approx(world_screen), "Recenter leaves the auditorium screen fixed")
	var saved := ConfigFile.new(); saved.load(main.settings_path)
	check(saved.get_value("appearance", "cinema_seat", "") == "N10", "Last seated position is saved globally to disk")
	_close_menus(); main._cinema_request_interaction("move")
	check(main.settings.get_value("appearance", "cinema_seat", "") == "N10", "Roaming never erases the last seated location")
	main.background.select("dark"); main._update_background()
	main.background.select("cinema"); main._update_background()
	check(main.cinema_environment.snapshot().seat == "N10", "Re-entering cinema keeps the saved seat")
	# A fresh environment exercises the same saved-setting input as a new app,
	# including asynchronous model/navigation loading and initial rig placement.
	var restored := preload("res://scripts/environments/cinema_environment.gd").new()
	var rig := Node3D.new(); viewport.add_child(rig)
	var camera := Camera3D.new(); camera.position.y = 1.6; rig.add_child(camera)
	viewport.add_child(restored)
	restored.saved_seat = str(saved.get_value("appearance", "cinema_seat", ""))
	restored.configure(rig, camera); restored.select(true)
	var deadline := Time.get_ticks_msec() + 20000
	while restored.loading and Time.get_ticks_msec() < deadline: await create_timer(.01).timeout
	check(restored.active and restored.snapshot().seat == "N10", "A fresh cinema load restores the global seat instead of the default")
	check(camera.global_position.is_equal_approx(seat_eye), "Fresh load places the real eye at the saved seat's authored position")
	restored.free(); rig.free()
	main._show_full_library(); main.recent_menu.section = main.recent_menu.Section.SETTINGS
	main.recent_menu.tab = main.recent_menu.BACKGROUND_TAB; main.recent_menu.refresh()
	var before_home: Vector3 = main.xr_camera.global_position
	main._on_setting_changed("cinema_home", true)
	check(main.cinema_environment.snapshot().seat == "I12" and main.xr_camera.global_position.distance_to(before_home) > 1,
		"Global Return to start actually moves from the selected seat to default I12")
	var default_seat: Dictionary = main.cinema_environment._manifest.seats.filter(func(item): return item.id == "I12")[0]
	var default_eye := Vector3(float(default_seat.eye_position[0]), float(default_seat.eye_position[1]), float(default_seat.eye_position[2]))
	check(main.xr_camera.global_position.is_equal_approx(default_eye), "Global Return to start restores the default seat's full position and height")
	check(main.settings.get_value("appearance", "cinema_seat", "") == "I12", "Explicit Return to start updates the remembered seat")
	_close_menus(); main._cinema_request_interaction("move"); _neutral()
	eye = main.xr_camera.global_position
	main.rays.right_hand = [eye, Vector3.DOWN]; _press("right_hand")
	main._recenter()
	check(main.xr_camera.global_position.is_equal_approx(eye) and main.cinema_environment.interaction == "move",
		"Standing recenter preserves floor position and free movement mode")
	check(main.cinema_environment.snapshot().capture_hand.is_empty(), "Recenter cancels held teleport aim")
	_release("right_hand")
	check(main.xr_camera.global_position.is_equal_approx(eye), "Releasing a canceled aim after recenter cannot teleport")
	main._on_setting_changed("cinema_home", true)
	main.rays.clear()

func _viewing_brightness_routes() -> void:
	check(main._library_settings().cinema_viewing_brightness == "low", "Viewing brightness defaults to the original darkest lighting")
	_close_menus(); main._show_full_library()
	main.recent_menu.section = main.recent_menu.Section.SETTINGS
	main.recent_menu.tab = main.recent_menu.BACKGROUND_TAB; main.recent_menu.refresh()
	main._on_setting_changed("cinema_lights", "on")
	for level in ["soft", "dim", "low"]:
		main._on_setting_changed("cinema_viewing_brightness", level)
		var expected: float = main.cinema_environment.VIEWING_LIGHT_LEVELS[level]
		check(main.cinema_environment._light_mix == expected, "Viewing click immediately changes the real room without closing the menu: " + level)
		main._sync_cinema_lights()
		check(main.cinema_environment._light_mix == expected and main._cinema_viewing_preview,
			"Frame sync preserves live viewing preview: " + level)
	main._on_setting_changed("cinema_viewing_brightness", "soft")
	var saved := ConfigFile.new(); saved.load(main.settings_path)
	check(saved.get_value("appearance", "cinema_viewing_brightness") == "soft", "Selected viewing brightness persists to disk")
	main.recent_menu.tab = main.recent_menu.GENERAL_TAB
	main._sync_cinema_lights(); main.cinema_environment._process(1.0)
	check(not main._cinema_viewing_preview and main.cinema_environment._light_mix == 1,
		"Leaving background settings ends preview and restores manual on")
	main._on_setting_changed("cinema_lights", "auto"); main.cinema_environment._process(1.0)
	check(main.cinema_environment._light_mix == .2, "Normal automatic playback retains the saved soft viewing level")
	main.recent_menu.tab = main.recent_menu.BACKGROUND_TAB
	main.video.media.state = "paused"
	main._cinema_lights_idle_since = Time.get_ticks_msec() - main.CINEMA_LIGHTS_UP_DELAY_MS - 1
	main._on_setting_changed("cinema_viewing_brightness", "dim")
	check(main.cinema_environment._light_mix == .08, "Paused playback also previews the chosen brightness immediately")
	var uri: String = main.video.local_uri
	main.video.local_uri = ""; main.video.media.state = "idle"
	main._on_setting_changed("cinema_viewing_brightness", "soft")
	check(main.cinema_environment._light_mix == .2, "An empty cinema previews brightness immediately without starting playback")
	main.video.local_uri = uri
	main._on_setting_changed("cinema_viewing_brightness", "low")
	main._on_setting_changed("cinema_viewing_brightness", "invalid")
	check(main.settings.get_value("appearance", "cinema_viewing_brightness") == "low", "Unknown brightness cannot overwrite the saved level")
	main.video.media.state = "playing"
	_close_menus(); main._sync_cinema_lights(); main.cinema_environment._process(1.0)
	check(main.cinema_environment._light_mix == 0 and not main._cinema_viewing_preview,
		"Closing settings returns to the exact original darkest playback state")

func _screen_light_routes() -> void:
	check(main._library_settings().cinema_screen_light, "Screen ambient light defaults on in production settings")
	main._update_cinema_film_light(.016)
	var colors: Array[Color] = [Color.RED, Color.GREEN, Color.BLUE]
	main.cinema_film_light.colors = colors
	main.cinema_environment.set_film_light(main.cinema_film_light.colors)
	main._on_setting_changed("cinema_screen_light", false)
	check(main.cinema_environment.film_light.all(func(color): return color == Color.BLACK), "Turning screen light off clears all film lighting immediately")
	check(not main.cinema_film_light.enabled and not main._library_settings().cinema_screen_light,
		"Disabled screen light stops sampling and updates the production menu state")
	var saved := ConfigFile.new()
	saved.load(main.settings_path)
	check(saved.get_value("appearance", "cinema_screen_light", true) == false, "Screen light preference is saved to disk")
	main._on_setting_changed("cinema_lights", "on")
	check(main.cinema_environment.lights_on and main.cinema_environment.film_light[0] == Color.BLACK,
		"House lights remain independent from disabled film lighting")
	main._on_setting_changed("cinema_screen_light", true)
	main._update_cinema_film_light(.1)
	# With no film the blank screen throws no light, so re-enabling only resumes sampling.
	check(main.cinema_film_light.enabled and main.cinema_environment.film_light[0].r < .01,
		"Re-enabling screen light resumes sampling without lighting a blank screen")
	main._on_setting_changed("cinema_lights", "auto")

func _auto_light_routes() -> void:
	var requested: bool = main.video.requested_play
	var state: String = main.video.media.state
	var uri: String = main.video.local_uri
	# A stale play request with nothing open must not keep the house dark.
	main.video.local_uri = ""; main.video.requested_play = true; main.video.media.state = "idle"
	main._cinema_lights_idle_since = 0
	main._sync_cinema_lights()
	check(main.cinema_environment.lights_on, "Auto keeps the lights up when no film is open")
	main.video.local_uri = uri if not uri.is_empty() else "file:///film.mp4"
	main.video.requested_play = true
	main.video.media.state = "idle"
	main._sync_cinema_lights()
	check(not main.cinema_environment.lights_on, "Auto keeps the house dark while a requested film is still opening")
	main.video.media.state = "paused"
	main._sync_cinema_lights()
	check(not main.cinema_environment.lights_on, "A brief stop does not flash the house lights")
	main._cinema_lights_idle_since = Time.get_ticks_msec() - main.CINEMA_LIGHTS_UP_DELAY_MS - 1
	main._sync_cinema_lights()
	check(main.cinema_environment.lights_on, "Auto raises the house lights once playback has really stopped")
	# Closing a film keeps its uri and play request, but the closed session is not loading.
	main.video.media.state = "playing"; main._sync_cinema_lights()
	check(not main.cinema_environment.lights_on, "Auto darkens the house again for the next film")
	main.video.media.state = "closed"; main._sync_cinema_lights()
	main._cinema_lights_idle_since = Time.get_ticks_msec() - main.CINEMA_LIGHTS_UP_DELAY_MS - 1
	main._sync_cinema_lights()
	check(main.cinema_environment.lights_on, "Auto raises the house lights after the film is closed")
	main._on_setting_changed("cinema_lights", "off")
	check(not main.cinema_environment.lights_on, "Manual off keeps the house dark while stopped")
	main._on_setting_changed("cinema_lights", "auto")
	main.video.requested_play = requested
	main.video.media.state = state
	main.video.local_uri = uri
	main._cinema_lights_idle_since = 0
	main._sync_cinema_lights()

func _picture_size_routes(full_screen: Transform3D, preferences: Dictionary) -> void:
	var full_scale: float = main.video.screen_scale
	var full_height: float = main.video._flat.size.y
	main._on_playback_adjustment("cinema_picture_size", 60.0)
	var smaller: Transform3D = main.video.global_transform * main.video.flat_pose
	check(is_equal_approx(main.video.screen_scale, full_scale * 0.6) and is_equal_approx(main.video._flat.size.y, full_height * 0.6),
		"Picture size scales only the picture inside the fixed cinema screen")
	check(is_equal_approx(smaller.origin.x, full_screen.origin.x) and is_equal_approx(smaller.origin.z, full_screen.origin.z)
		and is_equal_approx(full_screen.origin.y - smaller.origin.y, full_height * 0.4 * main.CINEMA_PICTURE_DROP),
		"A smaller picture stays centred across and settles slightly below the screen centre")
	check(is_equal_approx(float(main.settings.get_value("appearance", "cinema_picture_size")), 0.6) and _screen_preferences() == preferences,
		"Picture size is its own cinema preference and never writes ordinary screen settings")
	check(is_equal_approx(float(main._menu_state().get("cinema_picture_size", 0)), 60.0),
		"Menu state reports the cinema picture size")
	main._on_playback_adjustment("cinema_picture_size", 10.0)
	check(is_equal_approx(main._cinema_picture_size(), main.CINEMA_PICTURE_MIN), "Picture size never shrinks below its minimum")
	main._on_playback_adjustment("cinema_picture_size", 100.0)
	check((main.video.global_transform * main.video.flat_pose).is_equal_approx(full_screen) and is_equal_approx(main.video.screen_scale, full_scale),
		"Full size restores the original fixed cinema picture")

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
	_neutral(); _press("right_hand")
	check(main.cinema_environment.snapshot().capture_hand == "right_hand", "Right stick forward owns movement aim")
	main.cinema_environment.update_pointer("right_hand", eye, Vector3.DOWN, true)
	main._on_controller_button("trigger_click", "right_hand")
	main._on_controller_release("trigger_click", "right_hand")
	check(main.cinema_environment.interaction == "move" and main.player_menu.visible, "Right trigger opens menu without changing the movement toggle")
	check(main.cinema_environment.snapshot().capture_hand.is_empty(), "Opening menu cancels held movement aim")
	_release("right_hand")
	check(main.xr_camera.global_position.is_equal_approx(eye), "Releasing stick over menu cannot teleport")
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
	elif hand == "right_hand": main._process_sticks(Vector2.ZERO, Vector2(0, .99), 1.0 / 72)

func _release(hand: String, optical: bool = false) -> void:
	if optical: main._on_pointer_release("trigger_click", hand)
	elif hand == "right_hand": _neutral()
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
		check(main.cinema_environment.snapshot().capture_hand == "right_hand", "Right stick forward owns teleport aim")
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
	_neutral()
	var yaw: float = main.cinema_environment._head_yaw()
	main._process_sticks(Vector2.ZERO, Vector2(0, -.99), 1.0 / 60)
	check(absf(absf(wrapf(main.cinema_environment._head_yaw() - yaw, -PI, PI)) - PI) < .001,
		"Right stick back turns exactly 180 degrees")
	yaw = main.cinema_environment._head_yaw()
	for frame in 20: main._process_sticks(Vector2.ZERO, Vector2(0, -.99), 1.0 / 60)
	main._process_sticks(Vector2.ZERO, Vector2(.99, 0), .016)
	check(is_equal_approx(yaw, main.cinema_environment._head_yaw()), "Holding or rolling back gesture cannot repeat a turn before neutral")
	check(main.xr_camera.global_position.is_equal_approx(before), "180 degree turn pivots around the tracked eye")
	_neutral()
	main._on_controller_button("ax_button", "right_hand"); main._on_controller_release("ax_button", "right_hand")
	check(main.cinema_environment.snapshot().capture_hand.is_empty() and main.video.control.sequence == sequence,
		"A no longer aims or changes playback in free movement")
	# Actual ray target/trigger path, independent of the locomotion pure-unit tests.
	var position: Vector3 = main.xr_camera.global_position
	var floor_hit: Dictionary = {}
	for offset in [Vector3(0.5, 0, 0), Vector3(-0.5, 0, 0), Vector3(0, 0, 0.2)]:
		var candidate: Dictionary = main.cinema_environment.ray_hit(position + offset, Vector3.DOWN)
		if candidate.get("valid", false):
			floor_hit = candidate; main.rays.right_hand = [position + offset, Vector3.DOWN]; break
	check(floor_hit.get("kind", "") == "floor" and floor_hit.get("valid", false), "Move ray resolves connected collision-safe floor", floor_hit)
	if not floor_hit.is_empty():
		_neutral()
		_press("right_hand")
		check(main.cinema_environment.snapshot().capture_hand == "right_hand", "Main stick gesture captures actual floor teleport target")
		_release("right_hand")
		var target: Vector3 = floor_hit.position + Vector3.UP * 1.65
		check(main.xr_camera.global_position.is_equal_approx(target), "Main stick release commits actual floor teleport", main.xr_camera.global_position)
	check(main._active_menu() == null and main._video_control_tap.is_empty(), "Floor teleport never toggles playback controls")
	_neutral()
	var held_eye: Vector3 = main.xr_camera.global_position
	_press("right_hand")
	main.focused = false
	main._process_sticks(Vector2.ZERO, Vector2(0, .99), .016)
	main.focused = true
	main._process_sticks(Vector2.ZERO, Vector2(0, .99), .016)
	check(main.cinema_environment.snapshot().capture_hand.is_empty(), "Focus loss cancels the arc; a held forward stick cannot rearm it")
	_neutral()
	check(main.xr_camera.global_position.is_equal_approx(held_eye), "Releasing the canceled aim cannot teleport after focus resumes")
	_press("right_hand")
	main._process_sticks(Vector2.ZERO, Vector2(NAN, 0), .016)
	_neutral()
	check(main.cinema_environment.snapshot().capture_hand.is_empty() and main.xr_camera.global_position.is_equal_approx(held_eye),
		"Invalid tracking axes cancel held aim without committing a landing")
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
	check(main.video.audio_volume == before and main.xr_camera.global_position.is_equal_approx(position), "Move mode blocks playback sticks even with transport visible")
	var sequence: int = main.video.control.sequence
	for right in [Vector2(1, 0), Vector2(0, 1), Vector2(0, -1)]:
		_neutral(); main._process_sticks(Vector2.ZERO, right, .05)
	check(main.video.control.sequence == sequence and main.seek_feedback.phase.is_empty() and main.cinema_environment.snapshot().capture_hand.is_empty(),
		"Transport cannot seek, turn or aim in movement mode")
	main.player_menu.dismiss()
	main._show_full_library()
	check(main.recent_menu.scene_overlay and main.photo_menu.scene_overlay and main.music_menu.scene_overlay,
		"All cinema menus opt into chair occlusion protection")
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

func _immersive_completion_menu_routes() -> void:
	for geometry in [1, 2, 3]:
		_close_menus()
		main.video.media.begin(70 + geometry)
		main.video.media.state = "playing"
		main.video.media.format.width = 1920; main.video.media.format.height = 1080
		main.video.geometry = geometry; main.video._apply_geometry()
		main.video.loop_enabled = false; main.video._waiting_first = false
		main.video.requested_play = true; main.video.panel.visible = true
		main.video.changed.emit()
		check(not main._cinema_scene_active(), "Playing immersive video hides cinema before EOF: " + str(geometry))
		main._show_recent_menu()
		check(main._library_is_attached() and main.recent_menu.visible, "Playback library is attached before immersive EOF: " + str(geometry))
		# EOF retains the source geometry; it restores the hall through changed.
		main.video.media.state = "ended"; main.video.changed.emit()
		var head: Transform3D = main._head_pose()
		var pose: Transform3D = main.video_menu.global_transform
		check(main._cinema_scene_active() and main.video.geometry == geometry, "EOF restores cinema without changing VR geometry: " + str(geometry))
		check(main.video_menu.cinema_world_anchor and main.video_menu.scene_overlay
			and pose.basis.get_scale().is_equal_approx(Vector3.ONE) and pose.origin.distance_to(head.origin) < 2.0,
			"EOF automatically restores normal-size near-viewer controls: " + str(geometry), pose)
		var library_centre: Vector3 = main.recent_menu.to_global(main.recent_menu.panel_centre())
		check(main.recent_menu.visible and library_centre.distance_to(head.origin) < 3.0
			and main.recent_menu.global_basis.get_scale().is_equal_approx(Vector3.ONE),
			"Attached library returns near viewer at normal scale without A/B: " + str(geometry), library_centre)
		main._sync_cinema_screen(); main._update_background()
		check(main.video_menu.global_transform.is_equal_approx(pose), "Frame sync preserves EOF menu placement: " + str(geometry))
		main.video.media.state = "playing"; main.video.changed.emit()
		check(not main._cinema_scene_active() and not main.video_menu.cinema_world_anchor,
			"Replaying immersive video restores ordinary controls: " + str(geometry))
		main._close_current_media()
		head = main._head_pose()
		check(main._cinema_scene_active() and main.video_menu.cinema_world_anchor,
			"Closing immersive video restores cinema controls despite retained geometry: " + str(geometry))
		check(main.recent_menu.visible and not main._library_is_attached()
			and main.recent_menu.to_global(main.recent_menu.panel_centre()).distance_to(head.origin) < 3.0,
			"Closing immersive video opens full library near viewer: " + str(geometry))
	# Restore the active flat film expected by the remaining integration routes.
	_close_menus()
	main.video.media.begin(80); main.video.media.state = "playing"
	main.video.media.format.width = 1920; main.video.media.format.height = 1080
	main.video.geometry = 0; main.video._apply_geometry()
	main.video.panel.visible = true; main.video.requested_play = true
	main.video.changed.emit()

func _finish() -> void:
	var file := FileAccess.open(output.path_join("summary.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": checks, "failures": failures, "passed": failures.is_empty(),
		"scope": "Desktop production Main routes and bundled GLB environment with synthetic tracked rays. Not OpenXR or decoder pixel fidelity."}, "\t")); file.close()
	if is_instance_valid(viewport): viewport.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	print("Cinema player integration: %d checks, %d failures" % [checks.size(), failures.size()])
	quit(0 if failures.is_empty() else 1)
