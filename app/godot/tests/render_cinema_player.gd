extends SceneTree
## Actual desktop OpenGL render of the production player and bundled cinema.
## Uses an original generated texture through video_rvm_pair, not a mock shader.
const Logic := preload("res://tests/test_cinema_player_integration.gd")
const HostTest := preload("res://tests/test_player_menu.gd")
const I18n := preload("res://scripts/i18n.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Catalog := preload("res://scripts/recent_files.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/cinema-gt/player")
var main: Node3D
var viewport: SubViewport
var checks: Array[Dictionary] = []
var failures: Array[String] = []
var views: Array[Dictionary] = []

class RenderMain extends Logic.InputMain:
	func _move_pose(hand: String) -> Variant:
		var ray: Variant = rays.get(hand)
		if ray == null: return null
		var up := Vector3.FORWARD if absf(Vector3(ray[1]).dot(Vector3.UP)) > 0.95 else Vector3.UP
		return Transform3D(Basis.looking_at(ray[1], up), ray[0])

func _initialize() -> void: _run.call_deferred()

func check(ok: bool, label: String, detail: Variant = "") -> void:
	checks.append({"label": label, "passed": ok, "detail": str(detail)})
	if not ok: failures.append(label + ": " + str(detail)); printerr("FAIL: " + failures.back())

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	if DisplayServer.get_name() == "headless" or RenderingServer.get_current_rendering_method() != "gl_compatibility":
		push_error("Real desktop GL Compatibility is required for cinema render verification")
		quit(2); return
	var config := ConfigFile.new()
	config.set_value("appearance", "background", "dark"); config.set_value("ui", "language", "en")
	config.save(output.path_join("settings.cfg"))
	viewport = SubViewport.new(); viewport.size = Vector2i(1440, 960)
	viewport.own_world_3d = true; viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	main = RenderMain.new(); main.settings_path = output.path_join("settings.cfg")
	main.display = Logic.SupportedDisplay.new(); viewport.add_child(main)
	main.set_process(false); main.video.set_process(false); main.photo.set_process(false)
	main._head_placed = true
	main.report_timer.stop()
	main.video.history_enabled = false; main.photo.history_enabled = false
	main.video.mode_memory = Memory.new(output.path_join("modes.cfg"))
	main.video.recent_files = Catalog.new(output.path_join("recent.cfg"))
	main.video.platform = HostTest.Host.new()
	main.video.local_uri = "file:///original-cinema-test.mp4"
	main.video.media.begin(7); main.video.media.state = "playing"
	main.video.media.format.width = 640; main.video.media.format.height = 360
	main.video.requested_play = true; main.video._waiting_first = false
	main.video.control.duration_ms = 600000; main.video.control.observed_position_ms = 125000
	main.video._apply_geometry(); main.video.panel.visible = true
	main.video.material.set_shader_parameter("color_texture", _original_video_texture())
	main.video.material.set_shader_parameter("source_size", Vector2(640, 360))
	main.video.material.set_shader_parameter("alpha_enabled", false)
	_background_page()
	check(_choice("background", "cinema"), "Production background choice selects cinema through controller press/release")
	var deadline := Time.get_ticks_msec() + 20000
	while main.cinema_environment.loading and Time.get_ticks_msec() < deadline: await create_timer(0.01).timeout
	main._update_background(); main._sync_cinema_screen()
	check(main._cinema_scene_active(), "Real bundled GLB and navigation become active", main.cinema_environment.snapshot())
	if not main._cinema_scene_active(): await _finish(); return
	check(main.cinema_environment._manifest.seats.size() == 420 and main.cinema_environment.snapshot().seat == "I15", "GT fixture has 420 seats and default I15")
	check(is_equal_approx(main.xr_camera.fov, 75.0), "Production desktop camera retains its existing 75 degree vertical FOV")
	_close_menus()
	_look_at_screen()
	main.rays.clear(); main._update_controller_feedback(0.01)
	for format in [{"id": "1_43", "size": Vector2i(715, 500)}, {"id": "16x9", "size": Vector2i(640, 360)}, {"id": "2_39", "size": Vector2i(956, 400)}]:
		_set_video_source(format.size)
		_look_at_screen()
		var mesh_size: Vector2 = main.video.panel.mesh.size
		var expected := Vector2(32, 32.0 * format.size.y / format.size.x)
		check(mesh_size.is_equal_approx(expected), "Real production mesh fits GT envelope for " + format.id, mesh_size)
		_record_view("I15-" + format.id)
		await _shot("01-I15-" + format.id)
	_set_video_source(Vector2i(640, 360))
	_look_at_screen()
	var frame := await _shot("01-cinema-video")
	check(is_equal_approx(main.video._flat.size.x, 32.0), "Rendered production screen has 32 metre width", main.video._flat.size)
	var colored := 0
	for y in range(80, 850, 4):
		for x in range(100, 1340, 4):
			var pixel := frame.get_pixel(x, y)
			if pixel.r > 0.4 and pixel.r - pixel.b > 0.15: colored += 1
	check(colored > 2000, "Actual rendered production video shader shows original saturated test image", colored)
	check(_select_scene_seat("N15"), "Actual production ray can select the last row N15")
	_look_at_screen(); _record_view("N15-16x9")
	await _shot("01-N15-16x9")
	main.cinema_environment.home(); main._sync_cinema_screen(); _look_at_screen()
	var rig_before: Transform3D = main.xr_origin.global_transform
	var tracked_before: Transform3D = main.xr_camera.transform
	main.xr_camera.global_position = Vector3(13, 14.0, 25.5)
	main.xr_camera.look_at(Vector3(0, 8, 9), Vector3.UP)
	await _shot("01-GT-auditorium-overview")
	main.xr_camera.global_position = Vector3(0, 7.0, -2.5)
	main.xr_camera.look_at(Vector3(0, 12, 25), Vector3.UP)
	await _shot("01-GT-auditorium-reverse")
	main.xr_origin.global_transform = rig_before; main.xr_camera.transform = tracked_before
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language)
		_close_menus(); main._show_player_menu()
		main.player_menu._adjustment = "screen"; main.player_menu.refresh()
		main._place_menu(main.player_menu, true)
		check(main.player_menu._state.get("screen_scene_locked", false), "Scene-locked screen state reaches player menu " + language)
		var targets: Array = main.player_menu._buttons.map(func(button): return button.target)
		check([main.player_menu.CINEMA_SEAT, main.player_menu.CINEMA_MOVE, main.player_menu.CINEMA_HOME].all(func(target): return target in targets),
			"Scene screen page exposes three actions " + language)
		check(450 not in targets and 451 not in targets, "Scene screen page omits incompatible distance/size sliders " + language)
		_check_label_fit(main.player_menu, language)
		main.rays.clear(); main._update_controller_feedback(0.01)
		await _shot("02-screen-page-" + language)
	for language in ["en", "zh"]:
		I18n.use(language); _background_page()
		main.rays.clear(); main._update_controller_feedback(0.01)
		await _shot("03-background-page-" + language)
	I18n.use("en")
	_background_page()
	check(_choice("cinema_interaction", "seat"), "Background interaction choice activates seat mode through actual controller release")
	check(main.cinema_environment.interaction == "seat" and main._active_menu() == null, "Choosing seat closes UI and gives scene ownership")
	var ray := _seat_ray("H16")
	main.rays.right_hand = ray
	var seat_hit: Dictionary = main.cinema_environment.ray_hit(ray[0], ray[1])
	check(seat_hit.get("id", "") == "H16", "Rendered seat feedback uses an actual other-seat hit", seat_hit)
	if not seat_hit.is_empty(): main.xr_camera.look_at(seat_hit.position + Vector3(0, 0.3, 0), Vector3.UP)
	main._update_controller_feedback(0.016)
	_update_feedback()
	var seat_frame := await _shot("04-seat-ray-feedback")
	var visual: Node3D = main.cinema_environment.get_node_or_null("CinemaPointer_right_hand")
	check(visual != null and visual.is_visible_in_tree() and visual.get_node("SeatLabel").text == "H16", "Production seat feedback node and label are visible")
	check(_green_pixels(seat_frame) > 400, "Seat marker and label produce real visible pixels")
	main._on_controller_button("trigger_click", "right_hand")
	check(main.cinema_environment.snapshot().capture_hand == "right_hand", "Seat ray press captures actual authored chair")
	main._on_controller_release("trigger_click", "right_hand")
	check(main.cinema_environment.snapshot().seat == "H16" and main._active_menu() == null, "Seat ray release commits without toggling video controls")
	_background_page()
	check(_choice("cinema_interaction", "move"), "Background interaction choice activates free movement through actual controller release")
	_look_at_screen()
	var head: Vector3 = main.xr_camera.global_position
	var floor_ray: Array = []
	var floor_hit: Dictionary = {}
	for offset in [Vector3(0.5, 0, 0), Vector3(-0.5, 0, 0), Vector3(0, 0, -0.1)]:
		var candidate_ray := [head + offset, Vector3.DOWN]
		var candidate: Dictionary = main.cinema_environment.ray_hit(candidate_ray[0], candidate_ray[1])
		if candidate.get("valid", false): floor_ray = candidate_ray; floor_hit = candidate; break
	if not floor_ray.is_empty(): main.rays.right_hand = floor_ray
	check(floor_hit.get("kind", "") == "floor" and floor_hit.get("valid", false), "Rendered floor feedback uses a valid reachable target", floor_hit)
	main._update_controller_feedback(0.016)
	_update_feedback()
	# Desktop-only viewing adjustment makes the real floor marker visible in the capture.
	if not floor_hit.is_empty(): main.xr_camera.look_at(floor_hit.position, Vector3.UP)
	var floor_frame := await _shot("05-floor-ray-feedback")
	visual = main.cinema_environment.get_node_or_null("CinemaPointer_right_hand")
	check(visual != null and visual.is_visible_in_tree() and visual.get_node("FloorRing").is_visible_in_tree(), "Production floor feedback ring is visible")
	check(_green_pixels(floor_frame) > 400, "Valid floor ring produces real visible pixels")
	await _finish()

func _close_menus() -> void:
	for menu in [main.recent_menu, main.video_menu, main.photo_menu, main.music_menu]:
		if menu: menu.dismiss()
	main.player_menu = main.video_menu

func _look_at_screen() -> void:
	main.xr_camera.look_at((main.video.global_transform * main.video.flat_pose).origin, Vector3.UP)

func _background_page() -> void:
	_close_menus(); main._show_full_library()
	main.recent_menu.section = main.recent_menu.Section.SETTINGS
	main.recent_menu.tab = main.recent_menu.BACKGROUND_TAB
	main.recent_menu.scroll = 0; main.recent_menu.refresh(); main._place_menu(main.recent_menu, true)

func _tap(menu: Node3D, target: int) -> bool:
	for button in menu._buttons:
		if button.target != target: continue
		var centre: Vector2 = button.rect.get_center()
		main.rays.right_hand = [menu.to_global(Vector3(centre.x, centre.y, 1)), -menu.global_basis.z]
		# This fixture starts with an already aiming hand. Cold hidden pointers
		# intentionally need a wake click before a real UI press in production.
		main.controller_feedback.wake("right_hand")
		main._on_controller_button("trigger_click", "right_hand")
		main._on_controller_release("trigger_click", "right_hand")
		return true
	return false

func _choice(key: String, value: Variant) -> bool:
	var menu: Node3D = main.recent_menu
	# Inline choice rows already expose their buttons without a popup.
	for target in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[target]
		if item.get("kind", "") == "choose" and item.get("key", "") == key and item.get("value") == value:
			return _tap(menu, target)
	var open_target := -1
	for target in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[target]
		if item.get("kind", "") == "open" and item.get("key", "") == key: open_target = target; break
	if open_target < 0 or not _tap(menu, open_target): return false
	for target in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[target]
		if item.get("kind", "") == "choose" and item.get("key", "") == key and item.get("value") == value:
			return _tap(menu, target)
	return false

func _seat_ray(id: String) -> Array:
	for seat in main.cinema_environment._manifest.seats:
		if str(seat.id) == id:
			var eye := Vector3(seat.eye_position[0], seat.eye_position[1], seat.eye_position[2])
			return [eye + Vector3(0, -0.1, 0.9), Vector3.FORWARD]
	return []

func _select_scene_seat(id: String) -> bool:
	if not main._cinema_request_interaction("seat"): return false
	var ray := _seat_ray(id)
	if ray.is_empty(): return false
	main.rays.right_hand = ray
	main.controller_feedback.wake("right_hand")
	main._on_controller_button("trigger_click", "right_hand")
	main._on_controller_release("trigger_click", "right_hand")
	main.rays.clear(); main._update_controller_feedback(0.016)
	return main.cinema_environment.snapshot().seat == id

func _set_video_source(size: Vector2i) -> void:
	main.video.media.format.width = size.x; main.video.media.format.height = size.y
	main.video._apply_geometry(); main._sync_cinema_screen()
	main.video.material.set_shader_parameter("color_texture", _original_video_texture(size))
	main.video.material.set_shader_parameter("source_size", Vector2(size))
	main.video.material.set_shader_parameter("alpha_enabled", false)

func _record_view(label: String) -> void:
	var camera: Camera3D = main.xr_camera
	var panel: MeshInstance3D = main.video.panel
	var pose := panel.global_transform
	var size: Vector2 = panel.mesh.size
	var eye := camera.global_position
	var left := pose * Vector3(-size.x / 2, 0, 0) - eye
	var right := pose * Vector3(size.x / 2, 0, 0) - eye
	var top := pose * Vector3(0, size.y / 2, 0) - eye
	var bottom := pose * Vector3(0, -size.y / 2, 0) - eye
	views.append({"id": label, "seat": main.cinema_environment.snapshot().seat,
		"eye_world_metres": [eye.x, eye.y, eye.z], "image_world_metres": [size.x, size.y],
		"screen_envelope_metres": [32.0, 32.0 / 1.43],
		"plane_distance_metres": (eye - pose.origin).dot(pose.basis.z.normalized()),
		"horizontal_ray_angle_degrees": rad_to_deg(left.angle_to(right)),
		"vertical_ray_angle_degrees": rad_to_deg(top.angle_to(bottom)),
		"horizontal_azimuth_span_degrees": absf(rad_to_deg(wrapf(atan2(right.x, -right.z) - atan2(left.x, -left.z), -PI, PI))),
		"camera_vertical_fov_degrees": camera.fov,
		"camera_horizontal_fov_degrees": rad_to_deg(2 * atan(tan(deg_to_rad(camera.fov) / 2) * float(viewport.size.x) / viewport.size.y)),
		"viewport_pixels": [viewport.size.x, viewport.size.y]})

func _update_feedback() -> void:
	# Production main is manually clocked in this fixture. Its normal frame
	# route updates actual environment feedback for the injected tracked rays.
	main._process(0.016)

func _green_pixels(image: Image) -> int:
	var count := 0
	for y in range(0, image.get_height(), 2):
		for x in range(0, image.get_width(), 2):
			var pixel := image.get_pixel(x, y)
			if pixel.g > 0.75 and pixel.g - pixel.r > 0.15 and pixel.g - pixel.b > 0.12: count += 1
	return count

func _shot(label: String) -> Image:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	check(image.save_png(output.path_join(label + ".png")) == OK, "Save actual OpenGL frame " + label)
	return image

func _check_label_fit(menu: Node3D, language: String) -> void:
	for button in menu._buttons:
		if button.target not in [menu.CINEMA_SEAT, menu.CINEMA_MOVE, menu.CINEMA_HOME]: continue
		for label in button.node.find_children("*", "Label3D", true, false):
			var width: float = menu.ui_font().get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.font_size).x * label.pixel_size
			check(width < button.rect.size.x - 0.02, "Translated scene action fits " + language + ": " + label.text, width)

func _original_video_texture(size: Vector2i = Vector2i(640, 360)) -> ImageTexture:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGB8)
	for y in size.y:
		for x in size.x:
			var u := float(x) / (size.x - 1); var v := float(y) / (size.y - 1)
			var color := Color(0.08 + u * 0.1, 0.22 + (1 - v) * 0.25, 0.38 + (1 - v) * 0.25)
			if v > 230.0 / 360 - 0.125 * sin(u * TAU): color = Color(0.12, 0.28, 0.26)
			if Vector2(x - size.x * 450.0 / 640, y - size.y * 130.0 / 360).length() < minf(size.x, size.y) * 62.0 / 360: color = Color(1.0, 0.48 + v * 0.3, 0.15)
			if x % maxi(1, size.x / 8) < 2 or y % maxi(1, size.y / 6) < 2: color = color.lightened(0.14)
			if v > 290.0 / 360 and u > 50.0 / 640 and u < 590.0 / 640: color = Color(0.92, 0.38 + u * 0.4, 0.12)
			image.set_pixel(x, y, color)
	return ImageTexture.create_from_image(image)

func _finish() -> void:
	var file := FileAccess.open(output.path_join("summary.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": checks, "failures": failures, "passed": failures.is_empty(),
		"views": views, "angle_definition": "Ray angle is the 3D angle between rays from the actual eye to opposite edge midpoints; azimuth span is reported separately. All comparisons preserve the production desktop vertical FOV of 75 degrees.",
		"before_image": "../before-16x9.png", "before_envelope_metres": [26.0, 26.0 / 1.43],
		"engine": Engine.get_version_info().string, "renderer": RenderingServer.get_current_rendering_method(),
		"scope": "Actual desktop GL Compatibility render of production Main, imported GLB and video_rvm_pair using an original ImageTexture. Synthetic tracked rays; no OpenXR or Android installation."}, "\t")); file.close()
	if is_instance_valid(viewport): viewport.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	print("Cinema player render: %d checks, %d failures" % [checks.size(), failures.size()])
	quit(0 if failures.is_empty() else 1)
