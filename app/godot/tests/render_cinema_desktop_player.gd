extends SceneTree
const Desktop := preload("res://scripts/environments/cinema_desktop_player.gd")
const Files := preload("res://scripts/environments/cinema_desktop_files.gd")
var output := ProjectSettings.globalize_path("res://../../build/output/cinema-desktop-validation")
var samples := ProjectSettings.globalize_path("res://../../build/output/cinema-desktop-video/samples")
var checks: Array[Dictionary] = []
var failures: Array[String] = []
var viewport: SubViewport
var main: Node3D

class TestMain extends Desktop:
	func _boot() -> void: pass

func _initialize() -> void: _run.call_deferred()
func check(ok: bool, label: String, detail: Variant = "") -> void:
	checks.append({"passed": ok, "label": label, "detail": str(detail)})
	if not ok: failures.append(label); printerr("FAIL: " + label + " " + str(detail))

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	if DisplayServer.get_name() == "headless": push_error("GPU render is required"); quit(2); return
	var original := samples.path_join("synthetic-audio.mp4")
	var escaped := samples.path_join("测试 %20 影片.mp4")
	check(FileAccess.file_exists(original), "Original synthetic H264 fixture is available")
	if not FileAccess.file_exists(original): quit(2); return
	check(DirAccess.copy_absolute(original, escaped) == OK, "Prepare Unicode and literal-percent filename fixture")
	viewport = SubViewport.new(); viewport.size = Vector2i(1440, 960); viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS; root.add_child(viewport)
	main = TestMain.new(); main.run_directory = output.path_join("state"); viewport.add_child(main)
	var deadline := Time.get_ticks_msec() + 30000
	while main.cinema_environment.loading and Time.get_ticks_msec() < deadline: await process_frame
	check(main._cinema_scene_active(), "Production cinema becomes ready in the desktop entry")
	if not main._cinema_scene_active(): await _finish(); return
	main.recent_menu.dismiss(); main._look_at_cinema(); main._show_player_menu()
	check(main.video.get_script() == preload("res://scripts/environments/cinema_desktop_video.gd"), "Main uses the real desktop decoder adapter")
	var transport: Node3D = main.player_menu
	check(transport.get_script() == preload("res://scripts/player_menu.gd"), "The original production PlayerMenu is reused")
	check(_tap(transport, 100), "Mouse operates the original file-folder control")
	check(main._active_menu() == main.recent_menu, "File-folder action opens the production library")
	var library: Node3D = main.recent_menu
	check(library.section == library.Section.LOCAL and library.platform == main.desktop_files, "Production library uses real local browsing")
	library._local_stack = [{"id": samples, "title": "Samples"}]
	library._load_section()
	deadline = Time.get_ticks_msec() + 5000
	while (not library._pending.is_empty()) and Time.get_ticks_msec() < deadline: await process_frame
	library.refresh()
	check(library.rows.size() >= 5, "Local browser enumerates more than the first two entries", library.rows.size())
	var row_index := -1
	for index in library.rows.size():
		if str(library.rows[index].get("uri", "")) == Files.video_uri(escaped): row_index = index
	check(row_index >= 0, "Encoded local URI retains Chinese, spaces and literal percent sequences")
	if row_index < 0: await _finish(); return
	check(_tap(library, library.ROW_BASE + row_index), "Mouse selects a real local movie through original library rows")
	deadline = Time.get_ticks_msec() + 10000
	while main.video.local_uri != Files.video_uri(escaped) and Time.get_ticks_msec() < deadline: await process_frame
	check(main.video.local_uri == Files.video_uri(escaped) and main.video.media.state == "playing", "Selected MP4 actually decodes and plays")
	check(main.video.material.get_shader_parameter("color_texture") is Texture2D, "Real decoded movie texture reaches production video shader")
	check(main.video._flat.size.is_equal_approx(Vector2(32, 18)), "Own 16:9 movie fits the fixed 32 by 18 metre image area", main.video._flat.size)
	main.video.loop_enabled = true
	main.video.set_volume_level(5)
	main._look_at_cinema()
	await shot("01-local-movie")
	var blocker := MeshInstance3D.new()
	var box := BoxMesh.new(); box.size = Vector3(2, 2, 0.5); blocker.mesh = box
	var blocker_material := StandardMaterial3D.new()
	blocker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	blocker_material.albedo_color = Color(1, 0.03, 0.8)
	blocker.material_override = blocker_material
	main.add_child(blocker)
	blocker.global_position = main.xr_camera.global_position.lerp(main.video.panel.global_position, 0.5)
	await shot("01b-live-movie-occlusion")
	var blocked_frame := viewport.get_texture().get_image()
	var blocked_point: Vector2 = main.xr_camera.unproject_position(blocker.global_position)
	var centre := blocked_frame.get_pixel(int(blocked_point.x), int(blocked_point.y))
	check(centre.r > 0.9 and centre.b > 0.6 and centre.g < 0.15, "Opaque foreground actually occludes the live movie in the desktop depth buffer", centre)
	blocker.queue_free(); await process_frame
	var pose: Transform3D = main.video.panel.global_transform
	var size: Vector2 = main.video._flat.size
	var bar_pose: Transform3D = transport.global_transform
	check(_tap(transport, 102), "Original play/pause icon accepts mouse press and release")
	check(not main.video.requested_play, "Original control pauses the actual decoder")
	var paused_position: int = main.video.control.display_position_ms()
	await create_timer(0.25).timeout
	check(absi(main.video.control.display_position_ms() - paused_position) < 80, "Actual movie clock remains paused")
	check(_tap(transport, 102), "Original play/pause icon resumes")
	check(main.video.requested_play, "Actual decoder resumes through original transport")
	_drag(transport.to_global(Vector3(-0.3, -0.08, 0.005)), transport.to_global(Vector3(0.205, -0.08, 0.005)))
	await create_timer(0.3).timeout
	check(main.video.control.display_position_ms() >= 2900, "Dragging the original timeline seeks the actual local movie", main.video.control.display_position_ms())
	check(main.video.panel.global_transform.is_equal_approx(pose) and main.video._flat.size.is_equal_approx(size), "Pause/resume/seek preserve fixed movie world pose and size")
	check(transport.global_transform.is_equal_approx(bar_pose), "Playback operations preserve the fixed transport world pose")
	main.xr_camera.look_at(transport.global_position, Vector3.UP)
	await shot("02-production-controls-below-screen")
	check(_tap(transport, transport.FREE_MOVEMENT), "Teleport is reachable directly from the playback bar")
	check(main.cinema_environment.interaction == "move" and main._active_menu() == null, "Quick action starts teleport and dismisses controls")
	var before: Vector3 = main.xr_camera.global_position
	main.cinema_environment.poll_sticks(Vector2.ZERO, Vector2.ZERO, 0.016)
	for frame in 30: main.cinema_environment.poll_sticks(Vector2(1, 0), Vector2.ZERO, 1.0 / 60)
	check(main.xr_camera.global_position.is_equal_approx(before), "Left stick no longer causes continuous movement")
	var aim := Vector3.ZERO
	for x in [-2.0, -1.0, 1.0, 2.0]:
		for z in [-1.0, 0.0, 1.0]:
			var direction := Vector3(x, -1.65, z).normalized()
			var hit: Dictionary = main.cinema_environment.ray_hit(before, direction)
			if hit.get("valid", false): aim = direction; break
		if aim != Vector3.ZERO: break
	check(aim != Vector3.ZERO, "Current desktop camera can aim at a clear nearby floor")
	if aim != Vector3.ZERO:
		main.xr_camera.look_at(before + aim, Vector3.UP)
		for pressed in [true, false]:
			var event := InputEventMouseButton.new(); event.button_index = MOUSE_BUTTON_RIGHT; event.pressed = pressed
			event.position = viewport.size / 2
			main._unhandled_input(event)
			if pressed:
				check(not main._looking and main.cinema_environment._capture_hand == "desktop", "Right mouse begins movement aim instead of consuming it for camera look")
				main.cinema_environment.update_pointer("desktop", before, aim, true)
				check(main.cinema_environment._pointer_visuals.desktop.root.visible, "Right mouse displays the actual movement arc")
	check(main.xr_camera.global_position.distance_to(before) > .2, "Right mouse hold and release moves through the production input route")
	check(main.video.panel.global_transform.is_equal_approx(pose), "Teleport preserves the movie plane")
	var moved_eye: Vector3 = main.xr_camera.global_position
	main._show_player_menu()
	check(main.cinema_environment.interaction == "move", "Opening controls keeps free movement selected")
	await shot("03-free-movement-footer")
	check(_tap(transport, transport.FREE_MOVEMENT), "Shared footer turns off free movement")
	check(main.cinema_environment.interaction == "watch" and transport.visible, "Footer returns to playback with controls visible")
	check(main.xr_camera.global_position.is_equal_approx(moved_eye), "Returning to playback keeps the chosen viewpoint")
	check(transport.global_position.distance_to(main.xr_camera.global_position) < 2, "Reopened playback bar is near the new viewer position")
	main._look_at_cinema()
	await shot("03-movie-after-teleport")
	main._cinema_request_interaction("move")
	var escape := InputEventKey.new(); escape.keycode = KEY_ESCAPE; escape.pressed = true
	main._unhandled_key_input(escape)
	check(main.cinema_environment.interaction == "watch" and transport.visible, "Escape also exits movement with playback controls visible")
	main._cinema_request_interaction("move")
	var held := InputEventMouseButton.new(); held.button_index = MOUSE_BUTTON_RIGHT; held.pressed = true; held.position = viewport.size / 2
	main._unhandled_input(held)
	main._notification(main.NOTIFICATION_APPLICATION_FOCUS_OUT)
	check(not main._input_focused() and not main._looking, "Focus loss suspends desktop interaction")
	check(main.cinema_environment._capture_hand.is_empty(), "Focus loss cancels held right-button movement")
	main._notification(main.NOTIFICATION_APPLICATION_FOCUS_IN)
	await _finish()

func _tap(menu: Node3D, target: int) -> bool:
	for button in menu._buttons:
		if int(button.target) != target or not button.node.is_visible_in_tree(): continue
		main.xr_camera.look_at(button.node.global_position, Vector3.UP)
		var position: Vector2 = main.xr_camera.unproject_position(button.node.global_position)
		for pressed in [true, false]:
			var event := InputEventMouseButton.new(); event.button_index = MOUSE_BUTTON_LEFT; event.pressed = pressed; event.position = position
			main._unhandled_input(event)
		return true
	return false

func _drag(start: Vector3, end: Vector3) -> void:
	main.xr_camera.look_at((start + end) * 0.5, Vector3.UP)
	var first: Vector2 = main.xr_camera.unproject_position(start)
	var last: Vector2 = main.xr_camera.unproject_position(end)
	var press := InputEventMouseButton.new(); press.button_index = MOUSE_BUTTON_LEFT; press.pressed = true; press.position = first
	main._unhandled_input(press)
	var motion := InputEventMouseMotion.new(); motion.position = last; motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	main._unhandled_input(motion)
	var release := InputEventMouseButton.new(); release.button_index = MOUSE_BUTTON_LEFT; release.pressed = false; release.position = last
	main._unhandled_input(release)

func shot(name: String) -> void:
	await process_frame; await RenderingServer.frame_post_draw; await RenderingServer.frame_post_draw
	var frame := viewport.get_texture().get_image()
	check(frame.save_png(output.path_join(name + ".png")) == OK, "Save actual movie render " + name)

func _finish() -> void:
	if main and main.video: main.video.close_video()
	if viewport: viewport.queue_free()
	await process_frame; await process_frame
	var file := FileAccess.open(output.path_join("summary.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": checks, "failures": failures, "passed": failures.is_empty(),
		"scope": "Actual production Main/PlayerMenu/LibraryMenu mouse input, native FFmpeg software decode, and desktop GL Compatibility; no Android/OpenXR verification."}, "\t")); file.close()
	print("Cinema desktop player: %d checks, %d failures" % [checks.size(), failures.size()])
	quit(0 if failures.is_empty() else 1)
