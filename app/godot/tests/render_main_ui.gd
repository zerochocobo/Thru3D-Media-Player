extends SceneTree

# Instantiate the real entry scene. No mocked catalog or replacement menu nodes.
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	# English unless a language preview is asked for (QUEST_UI_LANGUAGE=zh).
	preload("res://scripts/i18n.gd").use(OS.get_environment("QUEST_UI_LANGUAGE") if OS.has_environment("QUEST_UI_LANGUAGE") else "en")
	var output := OS.get_environment("QUEST_MAIN_UI_PREVIEW_DIR")
	if output.is_empty():
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output)
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var failures: Array[String] = []
	var logo: MeshInstance3D = main.xr_camera.get_node_or_null("StartupLogo")
	if logo == null or not logo.visible or main.recent_menu.visible:
		failures.append("Startup must show the transparent main logo before the library")
	if logo != null:
		var elapsed: float = logo.elapsed
		logo.ready_to_present = func(): return false
		await process_frame
		await process_frame
		if logo.elapsed != elapsed: failures.append("Startup timer must wait for visible tracked frames")
		logo.ready_to_present = func(): return true
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join("startup-logo.png"))
	if is_instance_valid(logo): await logo.finished
	await process_frame
	if not main.recent_menu.visible or main.player_menu.visible:
		failures.append("Real startup must show the library only")
	if main.status_label.visible or main.calibration_board.visible:
		failures.append("Diagnostics must be hidden during normal startup")
	var menu_logo: MeshInstance3D = main.recent_menu._side.find_child("MainLogo", true, false)
	if menu_logo == null:
		failures.append("Full library must retain its main logo")
	else:
		for part in [menu_logo] + menu_logo.get_children():
			if not part is MeshInstance3D: continue
			var centre: Vector3 = main.recent_menu._side.to_local(part.global_position)
			var logo_rect := Rect2(Vector2(centre.x, centre.y) - part.mesh.size * 0.5, part.mesh.size)
			for button in main.recent_menu._buttons:
				if button.node.get_parent() == main.recent_menu._side and logo_rect.intersects(button.rect):
					failures.append("Main logo overlaps a navigation target")
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	if root.get_texture().get_image().save_png(output.path_join("startup.png")) != OK:
		failures.append("Startup screenshot failed")
	# Render the actual sidebar face-on so artwork margins can be reviewed clearly.
	var detail := SubViewport.new()
	detail.size = Vector2i(640, 640)
	detail.world_3d = main.get_world_3d()
	detail.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(detail)
	var detail_camera := Camera3D.new()
	detail_camera.fov = 45
	detail.add_child(detail_camera)
	detail_camera.global_transform = main.recent_menu._side.global_transform * Transform3D(Basis.IDENTITY, Vector3(0, 0.33, 0.65))
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	if detail.get_texture().get_image().save_png(output.path_join("navigation-closeup.png")) != OK:
		failures.append("Navigation closeup screenshot failed")
	detail.queue_free()
	main._show_player_menu()
	await process_frame
	if not main.player_menu.visible or main.recent_menu.visible:
		failures.append("Player and library must remain mutually exclusive")
	if main.player_menu.text_snapshot().contains("Press trigger"):
		failures.append("Instruction wall must be absent")
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	if root.get_texture().get_image().save_png(output.path_join("empty-player.png")) != OK:
		failures.append("Empty player screenshot failed")
	# A user-opened menu must cancel the intro without being replaced by the library.
	main.queue_free()
	await process_frame
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	main._show_player_menu()
	await process_frame
	await process_frame
	if main.xr_camera.has_node("StartupLogo") or not main.player_menu.visible or main.recent_menu.visible:
		failures.append("Startup completion must not replace a menu opened by the user")
	FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE).store_string(JSON.stringify({
		"state": "passed" if failures.is_empty() else "failed", "failures": failures,
		"scope": "Actual Godot entry scene desktop OpenGL startup; Quest physical rays, binocular compositor and native playback not tested"}, "\t"))
	for failure in failures: push_error(failure)
	main.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
