extends SceneTree
const Prototype := preload("res://scripts/environments/cinema_prototype.gd")
const Loader := preload("res://scripts/environments/cinema_loader.gd")
var checks := 0
var failures: Array[String] = []
var output := ProjectSettings.globalize_path("res://../../build/output/cinema-gt/prototype")
var views: Array[Dictionary] = []

func _initialize() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message); printerr("FAIL: " + message)

func shot(viewport: SubViewport, filename: String) -> Image:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	check(image.save_png(output.path_join(filename + ".png")) == OK, "Save " + filename)
	return image

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	var viewport := SubViewport.new(); viewport.size = Vector2i(1440, 960); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	var cinema := Prototype.new(); viewport.add_child(cinema)
	await cinema.environment_loaded
	# Keep comparison projection identical to the real player's desktop camera.
	# The production prototype's camera/FOV and OpenXR projection stay unchanged.
	cinema.camera.fov = 75.0
	check(not cinema.manifest.is_empty(), "Runtime GLB loads from file")
	if cinema.manifest.is_empty(): quit(1); return
	check(cinema.stats.runtime_glb and cinema.stats.seats == 420, "All 420 GT seats and runtime asset identity")
	check(cinema.stats.triangles == 628118, "Committed baked GT asset triangle count")
	var seats: MeshInstance3D = cinema.environment_root.find_child("Seats_01A_near", true, false)
	check(seats != null and seats.get_active_material(0).vertex_color_use_as_albedo, "Runtime seat chunks retain baked vertex lighting")
	check(cinema.motion.selected_seat == "I15", "Default central GT seat from manifest")
	check(cinema.movie != null, "Real Theora motion clip is attached")
	await create_timer(0.6).timeout
	check(cinema._video_size.x > 0, "Video decoder supplies texture dimensions")
	var decoded: Image = cinema.movie.get_video_texture().get_image()
	var gold := decoded.get_pixel(24, 20)
	check(Vector3(gold.r, gold.g, gold.b).distance_to(Vector3(224.0 / 255, 184.0 / 255, 90.0 / 255)) < 0.08,
		"Known gold video patch decodes without corrupted interframes")
	check(is_equal_approx(cinema.video_surface.panel.mesh.size.x / cinema.video_surface.panel.mesh.size.y, 16.0 / 9.0), "Film aspect fits tall screen")
	check(cinema.video_surface.panel.mesh.size.is_equal_approx(Vector2(32, 18)), "Real decoded 16:9 video spans 32 by 18 metres")
	var pose: Transform3D = cinema.video_surface.panel.global_transform
	_record_view(cinema, "I15-16x9")
	var first := await shot(viewport, "01-center-view")
	await create_timer(0.7).timeout
	var second := await shot(viewport, "02-video-motion")
	var difference := 0.0
	for y in range(240, 600, 24):
		for x in range(460, 960, 24):
			var a := first.get_pixel(x, y)
			var b := second.get_pixel(x, y)
			difference += Vector3(a.r, a.g, a.b).distance_to(Vector3(b.r, b.g, b.b))
	check(difference > 1.0, "Rendered screen changes while the actual video plays")
	cinema._toggle_seats()
	await shot(viewport, "03-seat-map")
	check(cinema.seat_buttons.size() == 420 and cinema.seat_picker.visible, "Seat picker exposes all 420 seats")
	_check_seat_map_bounds(cinema, viewport, "1440x960")
	viewport.size = Vector2i(1280, 720)
	await shot(viewport, "03-seat-map-1280x720")
	_check_seat_map_bounds(cinema, viewport, "1280x720")
	viewport.size = Vector2i(1440, 960)
	await process_frame
	cinema.seat_buttons["C03"].pressed.emit()
	await process_frame
	check(cinema.motion.selected_seat == "C03" and not cinema.seat_picker.visible, "Seat button selects and closes")
	await shot(viewport, "04-front-side-seat")
	check(cinema.video_surface.panel.global_transform.is_equal_approx(pose), "Seat switch keeps world screen fixed")
	# The click carries its own coordinates; a stale hover must not select an old target.
	cinema.choose_seat("I15")
	var target: Dictionary = cinema.manifest.seats.filter(func(seat): return seat.id == "H15")[0]
	var target_eye: Vector3 = Prototype._vector(target.eye_position)
	var target_pixel := cinema.camera.unproject_position(target_eye + Vector3(0, -0.45, 0.1))
	cinema._hover_seat = "N30"
	var click := InputEventMouseButton.new(); click.button_index = MOUSE_BUTTON_LEFT; click.pressed = true; click.position = target_pixel
	cinema._unhandled_input(click)
	check(cinema.motion.selected_seat == "H15", "Mouse click recomputes visible seat ray instead of stale hover")
	check(cinema.choose_seat("N15"), "Last row seat N15 is selectable")
	_record_view(cinema, "N15-16x9")
	await shot(viewport, "05-rear-side-seat")
	check(cinema.set_moving(true), "Leave seat into collision-safe aisle")
	check(cinema.motion.selected_seat.is_empty(), "Free movement leaves seated state")
	var before: Vector3 = cinema.motion.eye_position
	cinema.set_process(false)
	cinema.motion.step(Vector2.ZERO, 0, 0.016)
	for frame in 90: cinema.motion.step(Vector2.LEFT, 0, 1.0 / 60)
	cinema._sync_camera()
	check(cinema.motion.eye_position.distance_to(before) > 1.5, "Continuous movement traverses aisle")
	check(cinema.video_surface.panel.global_transform.is_equal_approx(pose), "Walking keeps world screen fixed")
	await shot(viewport, "06-free-walking")
	var safe_eye: Vector3 = cinema.motion.eye_position
	check(not cinema.motion.teleport_floor(Vector3(30, 0, 20)), "Out-of-room teleport rejected")
	check(cinema.motion.eye_position == safe_eye, "Rejected teleport retains position")
	cinema.motion.suspend()
	cinema.motion.step(Vector2.LEFT, 0, 0.2)
	check(cinema.motion.eye_position == safe_eye, "Capture neutral gate stops movement")
	check(not cinema.load_cinema("res://missing.glb", Prototype.DESCRIPTION), "Missing import fails explicitly")
	check(is_instance_valid(cinema.environment_root), "Failed replacement retains old environment")
	check(cinema.choose_seat("I15"), "Return to GT centre seat")
	cinema.motion.eye_position = Vector3(13, 14.0, 25.5)
	cinema._aim_screen()
	cinema._sync_camera()
	await shot(viewport, "07-auditorium-overview")
	cinema.camera.global_position = Vector3(0, 7, -2.5)
	cinema.camera.look_at(Vector3(0, 12, 25), Vector3.UP)
	await shot(viewport, "07-auditorium-reverse")
	cinema.toggle_playback()
	check(cinema.movie.paused, "Pause reaches the decoder")
	check(cinema.load_cinema(), "Reload valid environment")
	check(cinema._paused and cinema.movie.paused, "Reload preserves paused playback")
	var loader := Loader.new()
	check(not loader._validate_document({"materials": [{"alphaMode": "BLEND"}]}).is_empty(), "Unsupported transparent scenes rejected before loading")
	check(not loader._validate_document({"buffers": [{"uri": "https://example.invalid/model.bin"}]}).is_empty(), "External resource URI rejected")
	check(not loader._validate_document({"extensionsRequired": ["KHR_draco_mesh_compression"]}).is_empty(), "Unsupported required extension rejected")
	var summary := {"checks": checks, "failures": failures, "model": cinema.stats,
		"views": views, "angle_definition": "3D angle between actual eye rays to opposite edge midpoints; horizontal world azimuth span reported separately. Camera vertical FOV stays 75 degrees for comparison.",
		"rendering": "desktop GL Compatibility", "real_video": cinema.movie != null,
		"openxr_verified": false, "android_verified": false}
	var file := FileAccess.open(output.path_join("summary.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(summary, "\t")); file.close()
	viewport.queue_free(); await process_frame
	print("Cinema prototype render: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _record_view(cinema: Node3D, label: String) -> void:
	var panel: MeshInstance3D = cinema.video_surface.panel
	var pose := panel.global_transform
	var size: Vector2 = panel.mesh.size
	var eye: Vector3 = cinema.camera.global_position
	var left := pose * Vector3(-size.x / 2, 0, 0) - eye
	var right := pose * Vector3(size.x / 2, 0, 0) - eye
	var top := pose * Vector3(0, size.y / 2, 0) - eye
	var bottom := pose * Vector3(0, -size.y / 2, 0) - eye
	views.append({"id": label, "seat": cinema.motion.selected_seat, "eye_world_metres": [eye.x, eye.y, eye.z],
		"image_world_metres": [size.x, size.y], "screen_envelope_metres": [32.0, 32.0 / 1.43],
		"horizontal_ray_angle_degrees": rad_to_deg(left.angle_to(right)), "vertical_ray_angle_degrees": rad_to_deg(top.angle_to(bottom)),
		"horizontal_azimuth_span_degrees": absf(rad_to_deg(wrapf(atan2(right.x, -right.z) - atan2(left.x, -left.z), -PI, PI))),
		"camera_vertical_fov_degrees": cinema.camera.fov, "viewport_pixels": [1440, 960]})

func _check_seat_map_bounds(cinema: Node3D, viewport: SubViewport, label: String) -> void:
	var bounds := Rect2(Vector2.ZERO, Vector2(viewport.size)).grow(0.5)
	check(bounds.encloses(cinema.seat_picker.get_global_rect()), "Whole 420-seat picker fits " + label + ": " + str(cinema.seat_picker.get_global_rect()))
	var all_inside := true
	for button: Button in cinema.seat_buttons.values():
		if not bounds.encloses(button.get_global_rect()): all_inside = false; break
	check(all_inside, "All 420 clickable seats fit " + label)
