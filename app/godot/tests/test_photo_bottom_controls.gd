extends SceneTree
const Controls := preload("res://scripts/photo_magazine_controls.gd")
const I18n := preload("res://scripts/i18n.gd")
var checks := 0
var failures: Array[String] = []
var folder := "user://photo-bottom-controls"
var entries: Array[Dictionary] = []
var app: Node3D
var controls: Node3D

class Harness extends "res://scripts/main.gd":
	var rays := {}
	func _ray(hand: String) -> Variant: return rays.get(hand)
	func _input_focused() -> bool: return true
	func _controller_allowed(_hand: String) -> bool: return true

func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func settle() -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while app.photo.snapshot().loading and Time.get_ticks_msec() < deadline: await create_timer(0.01).timeout
	app.photo.finish_transition()
	check(not app.photo.snapshot().loading and app.photo.error.is_empty(), "Photo completes production presentation")

func open_photo(layout: int) -> void:
	app.rays.clear(); app._grab.clear(); app.interface_move.cancel(); app.photo_hands.cancel()
	app._controller_consumed.clear(); app.controller_bindings.restore_all()
	app.photo.close_image(); app.photo.auto_depth = false; app.photo.spatial_preferred = false
	app.photo.set_layout_mode(0)
	app.photo.open_image(entries[0].uri, entries[0].title, entries); await settle()
	app.photo.set_projection(0); app.photo.set_stereo_layout(0); app.photo.set_screen_curve(0)
	app.photo.set_flat_world_pose(app.xr_camera.global_transform * Transform3D(Basis.IDENTITY, Vector3(0, 0, -3)))
	app.photo.set_layout_mode(layout); await settle()
	app.photo.gallery._process(0.01)
	if layout in [2, 3]:
		app.photo.gallery.activate(0); await settle(); app.photo.gallery._process(1.0)
	app.recent_menu.dismiss(); app.photo_menu.dismiss(); app.music_menu.dismiss()
	controls.sync()

func aim(point: Vector3, hand: String = "right_hand") -> Array:
	var origin: Vector3 = app.xr_camera.global_position
	var ray := [origin, (point - origin).normalized()]
	app.rays[hand] = ray
	return ray

func reveal() -> void:
	controls.dismiss(); controls._entered_ms = -1; controls._last_near_ms = -1
	var now := Time.get_ticks_msec()
	controls.sync(now - Controls.ENTER_MS)
	check(not controls.visible, "Wake dwell prevents flashes")
	controls.sync(now)
	check(controls.visible, "Pointing at the photo or control region reveals controls")

func button(target: int) -> Dictionary:
	for item in controls._buttons:
		if item.target == target: return item
	return {}

func tap(target: int, hand: String = "right_hand") -> void:
	controls.sync()
	var item := button(target)
	check(not item.is_empty() and item.enabled, "Action enabled: %d" % target)
	if item.is_empty(): return
	aim(item.node.global_position, hand); reveal()
	app._on_controller_button("trigger_click", hand)
	app._on_controller_release("trigger_click", hand)

func visibility_checks() -> void:
	for layout in [0, 1, 2, 3, 4]:
		await open_photo(layout)
		check(not controls.visible, "No rays keeps layout %d hidden" % layout)
		aim(app.photo.panel.global_position); reveal()
		check(app._active_menu() == null, "Photo wake does not reserve menu input")
		check(not button(Controls.RETURN_TO_WALL).is_empty() == (layout in [2, 3]), "Return follows wall origin")
		check(controls._buttons.size() == (6 if layout == 4 else (4 if layout in [2, 3] else 3)), "Correct operations for layout %d" % layout)
		var now := Time.get_ticks_msec()
		controls.sync(now); app.rays.clear(); controls.sync(now + Controls.LEAVE_MS - 1)
		check(controls.visible, "Leaving briefly retains the row")
		controls.sync(now + Controls.LEAVE_MS)
		check(not controls.visible, "Both rays absent hides the row")
		var target: Vector3 = button(Controls.ROTATE_IMAGE).node.global_position
		var ray := aim(target)
		check(not controls.press_pointer("right_hand", ray[0], ray[1], true), "Hidden target cannot be clicked")
		reveal()
		aim(app.photo.panel.global_position, "left_hand"); app.rays.erase("right_hand")
		controls.sync(now + 1000)
		check(controls.visible, "Either hand keeps the controls awake")
		for panel in [app.photo_menu, app.recent_menu, app.music_menu]:
			panel.visible = true; controls.sync()
			check(not controls.visible, "An open panel suppresses attached controls")
			panel.dismiss(); reveal()
		app.photo.toggle_inspect(); controls.sync()
		check(not controls.visible, "Magnifier owns photo input")
		app.photo.close_inspect()
		if layout in [2, 3]:
			app.photo.gallery.return_focus(); app.photo.gallery._process(1.0); controls.sync()
			check(not controls.visible, "Wall overview has no full-photo controls")

func rotation_checks() -> void:
	for layout in [0, 1, 2, 3, 4]:
		await open_photo(layout)
		for curve in [0.0, 0.7]:
			app.photo.set_screen_curve(curve)
			var center: Vector3 = app.photo.panel.global_position
			var placement: Transform3D = app.photo.flat_pose
			var texture: Texture2D = app.photo._texture
			for turn in 4:
				tap(Controls.ROTATE_IMAGE, "left_hand" if turn % 2 else "right_hand")
				check(is_equal_approx(app.photo.screen_rotation, float((turn + 1) % 4) * 90), "Quarter turn %d in layout %d" % [turn, layout])
				check(app.photo.panel.global_position.is_equal_approx(center) and app.photo.flat_pose.is_equal_approx(placement), "Rotation preserves exact centre and placement")
				check(app.photo._texture == texture, "Rotation preserves decoded pixels")
				check(controls.global_basis.orthonormalized().is_equal_approx((app.photo.global_transform * placement).basis.orthonormalized()), "Buttons remain upright in the placement plane")
				for corner in 4:
					var point: Vector3 = controls.to_local(app.photo.panel.to_global(app.photo.screen_corner(corner)))
					check(point.y >= 0.129, "Controls stay below the rotated image bounds")
				check(not app.photo.gallery.returning and not app.photo.gallery.has_capture(), "Button press cannot also close or drag a wall photo")
		# A selected photo retains its own session roll, never the next photo's roll.
		tap(Controls.ROTATE_IMAGE); tap(Controls.NEXT_IMAGE); await settle()
		app.photo.gallery._process(1.0)
		check(app.photo.index == (2 if layout == 4 else 1) and app.photo.screen_rotation == 0, "Navigation respects pair size and isolates rotations")
		tap(Controls.PREVIOUS_IMAGE); await settle(); app.photo.gallery._process(1.0)
		check(app.photo.index == 0 and app.photo.screen_rotation == 90, "Returning restores this photo's session rotation")

func interaction_checks() -> void:
	await open_photo(2)
	aim(app.photo.panel.global_position); reveal()
	var ray: Array = app.rays.right_hand
	app._on_controller_button("trigger_click", "right_hand")
	check(app.photo.gallery.has_capture(), "Visible buttons do not intercept a photo press")
	controls.sync()
	check(controls.input_menu() == null, "Photo drag capture keeps priority")
	app._on_controller_release("trigger_click", "right_hand")
	check(app.photo.gallery.returning, "Existing photo click-to-close still works")
	for layout in [2, 3]:
		await open_photo(layout)
		var anchor: Transform3D = app.photo.gallery.anchor
		tap(Controls.RETURN_TO_WALL); app.photo.gallery._process(1.0)
		check(app.photo.gallery.focus < 0 and app.photo.gallery.mode == layout and app.photo.gallery.anchor.is_equal_approx(anchor), "Return restores the same wall placement")
	await open_photo(0)
	aim(app.photo.panel.global_position); reveal()
	app._grab = {"hand": "left_hand"}; controls.sync()
	check(controls._buttons.all(func(b): return not b.enabled) and controls.input_menu() == null, "Moving a photo disables actions")
	app._grab.clear()
	app.photo.queue_complete = false; controls.sync()
	check(not button(Controls.PREVIOUS_IMAGE).enabled, "Incomplete queues cannot wrap before the first image")
	app.photo.queue_complete = true; controls.sync()
	check(button(Controls.PREVIOUS_IMAGE).enabled, "Complete photo queues preserve wrap navigation")
	tap(Controls.ROTATE_IMAGE)
	app.photo.loading = true; controls.sync()
	check(controls._buttons.all(func(b): return not b.enabled), "In-flight decode disables image actions")
	app.photo.loading = false
	app.photo.set_projection(3); aim(app.xr_camera.global_position + Vector3.FORWARD); reveal()
	check(app.photo.screen_rotation == 0, "Planar rotation does not tilt a panorama")
	check(button(Controls.ROTATE_IMAGE).is_empty() and not button(Controls.NEXT_IMAGE).is_empty(), "Panorama has navigation at a stable lower anchor")
	var anchor: Transform3D = controls.global_transform
	app.xr_camera.rotate_y(0.2); controls.sync()
	check(controls.global_transform.is_equal_approx(anchor), "Panorama controls do not follow every head turn")
	app.xr_camera.rotate_y(-0.2)
	app.photo.set_projection(0)
	check(app.photo.screen_rotation == 90, "Returning to flat presentation restores its rotation")
	await open_photo(0)
	for stereo in [1, 2]:
		app.photo.set_stereo_layout(stereo)
		var center: Vector3 = app.photo.panel.global_position
		var texture: Texture2D = app.photo._texture
		tap(Controls.ROTATE_IMAGE)
		check(app.photo.stereo_sbs and app.photo.top_bottom == (stereo == 2) and app.photo._texture == texture, "Rotation preserves SBS/TB eye packing")
		check(app.photo.panel.global_position.is_equal_approx(center), "Stereo photo rotates around its centre")
	await open_photo(2)
	# A completed portrait presentation uses the same full-photo controls and wall origin.
	app.photo.portrait_requested = true; app.photo.portrait_enabled = true
	app.photo.gallery.visible = false; app.photo.panel.visible = true
	tap(Controls.RETURN_TO_WALL); app.photo.gallery._process(1.0)
	check(not app.photo.portrait_requested and app.photo.gallery.focus < 0, "Return exits portrait and closes the wall photo in one operation")

func magazine_checks() -> void:
	await open_photo(4)
	aim(app.photo.panel.global_position); reveal()
	for item in controls._buttons:
		for other in controls._buttons:
			if item.target == other.target: continue
			check(not item.rect.intersects(other.rect), "Magazine and transport hit rectangles never overlap")
	tap(1); await settle()
	check(app.photo.index == 1, "Pair correction still moves one source image")
	tap(Controls.NEXT_IMAGE); await settle()
	check(app.photo.index == 3, "Normal magazine navigation still moves a spread")
	app.photo.magazine.right_to_left = true
	tap(Controls.PREVIOUS_IMAGE); await settle()
	check(app.photo.index == 1, "RTL navigation preserves source sequence")
	tap(2); await settle(); tap(Controls.NEXT_IMAGE); await settle()
	check(app.photo.index == 2, "A single magazine page advances by one")
	app.photo.select_image(5); await settle()
	aim(app.photo.panel.global_position); reveal()
	check(not button(Controls.NEXT_IMAGE).enabled and not button(1).enabled, "Last magazine page disables both forward operations")
	for language in ["en", "zh", "zh_Hant", "ja"]:
		I18n.use(language); controls.sync(); aim(app.photo.panel.global_position); reveal()
		for item in controls._buttons:
			var origin: Vector3 = item.node.to_global(Vector3(0, 0, 1))
			controls.update_pointer("right_hand", origin, -controls.global_basis.z, true)
			check(controls._tooltip.visible and controls._tooltip.position.y + controls._tooltip.mesh.size.y * 0.5 < -Controls.ROW_GAP - 0.06, "Tooltip stays below both rows")
			var puzzle: Vector3 = controls.to_local(controls.puzzle_pose().origin)
			check(puzzle.y + 0.04 < controls._tooltip.position.y - controls._tooltip.mesh.size.y * 0.5, "Puzzle entry stays below tooltip")
	I18n.use("en")

func run() -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	for index in 6:
		var pixels := Image.create(240, 160, false, Image.FORMAT_RGBA8)
		pixels.fill(Color(0.1, 0.3 + index * 0.07, 0.65))
		pixels.fill_rect(Rect2i(0, 0, 100, 60), Color(0.9, 0.3, 0.15))
		var path := ProjectSettings.globalize_path(folder.path_join("%d.png" % index)); pixels.save_png(path)
		entries.append({"uri": "file://" + path, "title": "%d.png" % index, "kind": "image"})
	app = Harness.new(); app.settings_path = folder.path_join("settings.cfg"); root.add_child(app)
	app.set_process(false); app.photo.gallery.set_process(false); app.photo.history_enabled = false
	app.display.preview = false; app.photo_active = true; app.player_menu = app.photo_menu
	controls = app.photo_magazine_controls; controls.set_process(false)
	await visibility_checks(); await rotation_checks(); await interaction_checks(); await magazine_checks()
	app.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Photo bottom controls: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
