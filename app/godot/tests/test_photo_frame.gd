extends SceneTree
const Main := preload("res://scripts/main.gd")
var checks := 0
var failures: Array[String] = []
var folder := "user://photo-frame-%d" % Time.get_ticks_usec()
var entries: Array[Dictionary] = []

class PhotoMain extends Main:
	var rays := {}
	var pose := Transform3D.IDENTITY
	func _ray(hand: String) -> Variant: return rays.get(hand)
	func _move_pose(_hand: String) -> Variant: return pose

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func world(photo: Node3D) -> Transform3D:
	return photo.global_transform * photo.flat_pose

func settle(main: Node3D) -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while main.photo.loading and Time.get_ticks_msec() < deadline: await create_timer(0.01).timeout
	check(not main.photo.loading and main.photo.error.is_empty(), "Photo fixture decodes through the real image path")
	main._process(0.016)

func capture(name: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var output := ProjectSettings.globalize_path("res://../previews")
	DirAccess.make_dir_recursive_absolute(output)
	root.get_texture().get_image().save_png(output.path_join(name + ".png"))

func _initialize() -> void: call_deferred("run")

func run() -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	for index in 3:
		var size: Vector2i = [Vector2i(320, 160), Vector2i(180, 270), Vector2i(240, 240)][index]
		var image := Image.create(size.x, size.y, false, Image.FORMAT_RGB8)
		image.fill(Color.from_hsv(index / 3.0, 0.7, 0.9))
		image.fill_rect(Rect2i(size / 2 - Vector2i(8, 8), Vector2i(16, 16)), Color.WHITE)
		var path := ProjectSettings.globalize_path(folder.path_join("%d.png" % index)); image.save_png(path)
		entries.append({"uri": "file://" + path, "title": "%d.png" % index, "kind": "image"})
	var config := ConfigFile.new(); config.set_value("effects", "auto_3d", false); config.set_value("library", "history", false)
	config.save(folder.path_join("settings.cfg"))
	var main := PhotoMain.new(); main.settings_path = folder.path_join("settings.cfg"); root.add_child(main)
	main.set_process(false); main.video.set_process(false); main.report_timer.stop()
	main._head_placed = true; main.recent_menu.dismiss(); main.video_menu.dismiss(); main.photo_menu.dismiss()
	main.photo_active = true; main.player_menu = main.photo_menu
	var photo: Node3D = main.photo
	for layout in [0, 1]:
		photo.close_image(); main._process(0.016)
		main.xr_camera.transform = Transform3D(Basis.from_euler(Vector3(0.15, -0.2, 0.1)), Vector3(0.3, 1.6, 0.2))
		photo.set_layout_mode(layout)
		photo.open_image(str(entries[0].uri), "0.png", entries); await settle(main); photo.finish_transition()
		check(not photo.placement_pending, "Initial image is placed once in either reading layout")
		main._on_photo_action("recenter")
		photo.set_screen_rotation(17); photo.set_screen_curve(0.35); photo.set_screen_scale(1.2)
		var radius := world(photo).origin.distance_to(main._eye())
		main._turn_picture(0.2, 0.08)
		check(is_equal_approx(world(photo).origin.distance_to(main._eye()), radius), "Trigger dragging orbits the actual headset centre without changing distance")
		var basis := world(photo).basis; var size: Vector2 = photo._flat.size
		main._push_screen(0.45)
		check(is_equal_approx(world(photo).origin.distance_to(main._eye()), radius + 0.45) and world(photo).basis.is_equal_approx(basis) and photo._flat.size.is_equal_approx(size), "Pushing changes depth without changing pose orientation, content rotation or size")
		main.pose = Transform3D(Basis.IDENTITY, main._eye() + Vector3(0.1, -0.15, -0.5)).looking_at(world(photo).origin)
		main.rays.right_hand = [main.pose.origin, -main.pose.basis.z]
		radius = world(photo).origin.distance_to(main._eye())
		main._on_controller_button("grip_click", "right_hand")
		check(main.interface_move.pending(), "Grip captures the central photo in both layouts")
		main.pose.origin += Vector3(0.1, 0.03, 0); main.pose.basis = Basis(Vector3.UP, 0.08) * main.pose.basis
		main._update_interface_move()
		check(is_equal_approx(world(photo).origin.distance_to(main._eye()), radius), "Grip dragging keeps the central photo on its headset-centred sphere")
		main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.05)
		for step in 4: main._process_sticks(Vector2.ZERO, Vector2(0, 1), 0.05)
		main._on_controller_release("grip_click", "right_hand")
		check(is_equal_approx(world(photo).origin.distance_to(main._eye()), radius + 0.3) and not main.view_follow.enabled, "Grip plus stick changes distance and leaves follow off")
		var fixed := world(photo)
		photo.gallery.synchronize()
		var rail: Transform3D = photo.gallery.anchor
		await capture("%d-positioned" % layout)
		for step in 5:
			main.xr_camera.position += Vector3(0.006, 0.003, -0.004); main.xr_camera.rotate_y(0.015)
			main._on_photo_action("photo_next"); await settle(main)
			check(world(photo).is_equal_approx(fixed), "Changing image aspect and decoding the next photo never reapplies the head-relative offset")
			photo.finish_transition(); main._process(0.016); photo.gallery.synchronize()
			check(world(photo).is_equal_approx(fixed) and photo.panel.global_transform.origin.is_equal_approx(fixed.origin), "Each completed transition returns to the same absolute photo centre")
			if layout == 1: check(photo.gallery.anchor.is_equal_approx(rail), "Side previews stay anchored to the same world-fixed central frame")
			if step == 0: await capture("%d-after-next" % layout)
		main.xr_camera.position += Vector3(0.04, -0.02, 0.03)
		photo.open_image(str(entries[1].uri), "1.png", entries)
		check(not photo.placement_pending, "Selecting another image through the library retains the active reading frame")
		await settle(main); photo.finish_transition()
		check(world(photo).is_equal_approx(fixed), "Library reselection also keeps the absolute frame despite head movement")
		main._on_photo_action("photo_next"); await settle(main)
		photo._transition_active = true; photo._transition_time = 0.08; photo._transition_width = 2.0; photo._update_transition()
		radius = world(photo).origin.distance_to(main._eye())
		check(photo.panel.global_position.distance_to(world(photo).origin) > 0.1, "Fixture exposes an actual slide animation offset")
		main._turn_picture(-0.08, 0.05)
		check(is_equal_approx(world(photo).origin.distance_to(main._eye()), radius), "Dragging during a slide uses the stable frame centre, not the temporary animated mesh")
		basis = world(photo).basis
		main._push_screen(0.25)
		check(is_equal_approx(world(photo).origin.distance_to(main._eye()), radius + 0.25) and world(photo).basis.is_equal_approx(basis), "Stick depth during a slide does not add lateral drift or content rotation")
		main._on_photo_adjustment("screen_distance", 2.7)
		check(is_equal_approx(world(photo).origin.distance_to(main._eye()), 2.7), "Distance slider also targets the stable photo centre during transitions")
		photo.finish_transition()
		main.xr_camera.transform = Transform3D(Basis.from_euler(Vector3(0.5, 0.6, -0.3)), Vector3(0.6, 1.4, 0.4))
		main._on_photo_action("recenter"); photo.finish_transition()
		var centered: Transform3D = main._head_pose() * Transform3D(Basis.IDENTITY, Vector3(0, 0, -photo.screen_distance))
		check(world(photo).is_equal_approx(centered), "Explicit recenter puts either reading layout at the current gaze centre including pitch and roll")
		check(photo.screen_rotation == 17 and is_equal_approx(photo.screen_curve, 0.35) and is_equal_approx(photo.screen_scale, 1.2), "Recenter preserves picture size, content rotation, curvature and distance")
		await capture("%d-centered" % layout)
		main.xr_camera.position += Vector3(0.02, -0.01, 0.03)
		main._on_photo_action("photo_next"); await settle(main); photo.finish_transition()
		check(world(photo).is_equal_approx(centered), "After recenter, subsequent photos keep that new absolute centre")
		if layout == 0:
			main._on_session_control("follow")
			var relative: Transform3D = main._head_pose().affine_inverse() * world(photo)
			main.xr_camera.position += Vector3(0.05, 0.03, 0); main.xr_camera.rotate_x(0.1)
			main._on_photo_action("photo_next"); await settle(main); photo.finish_transition()
			check((main._head_pose().affine_inverse() * world(photo)).is_equal_approx(relative), "The existing follow switch still takes precedence when enabled")
			main._on_session_control("follow")
		var reopen_uri: String = photo.local_uri
		var before_close := world(photo)
		photo.close_image()
		main.xr_camera.position += Vector3(0.2, 0.1, 0); main.xr_camera.rotate_y(0.3)
		photo.open_image(reopen_uri, "reopened.png", entries)
		check(photo.placement_pending, "Closing the viewer and reopening requests one initial placement even for the same URI")
		await settle(main); photo.finish_transition()
		check(not photo.placement_pending and not world(photo).is_equal_approx(before_close), "Fresh reopening places once despite an unchanged previous URI")
	photo.close_image(); main.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Photo reading frame: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
