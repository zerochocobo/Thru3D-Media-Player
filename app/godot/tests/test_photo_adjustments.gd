extends SceneTree
const Main := preload("res://scripts/main.gd")
const Photo := preload("res://scripts/photo_display.gd")
const Menu := preload("res://scripts/photo_menu.gd")
var failures: Array[String] = []
var checks := 0
var commits: Array = []

class InputMain extends "res://scripts/main.gd":
	var test_ray: Variant
	func _ray(_hand: String) -> Variant: return test_ray

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("_run")

func point(menu: Node3D, x: float, y: float) -> Vector3:
	return menu.to_global(Vector3(x, y, 1))

func _run() -> void:
	var main := InputMain.new()
	var settings_output := ProjectSettings.globalize_path("res://../../build/output/photo-adjustments-gallery")
	DirAccess.make_dir_recursive_absolute(settings_output)
	main.settings_path = settings_output.path_join("settings-%d.cfg" % Time.get_ticks_usec())
	root.add_child(main)
	main.set_process(false)
	main.photo.set_process(false)
	main.photo_menu.set_process(false)
	main.photo_active = true
	main.player_menu = main.photo_menu
	main.recent_menu.dismiss()
	var photo: Node3D = main.photo
	var menu: Node3D = main.photo_menu
	var image := Image.create(128, 64, false, Image.FORMAT_RGB8)
	image.fill(Color.WHITE)
	photo._texture = ImageTexture.create_from_image(image)
	photo._size = Vector2(128, 64)
	photo.material.set_shader_parameter("photo_texture", photo._texture)
	photo._apply_geometry(); photo.panel.visible = true
	main._place_screen()
	check(photo.screen_distance == 3.0 and photo.screen_scale == 1.0 and photo.inspect_magnification == 2.0 and not photo.inspect,
		"Fresh image starts farther away at 3m, natural size, with 2x available without cropping")
	var video_before := Vector2(main.video.screen_distance, main.video.screen_scale)
	menu.toggle()
	var entry: Dictionary = menu._buttons.filter(func(b): return b.target == Menu.PHOTO_ADJUST)[0]
	check(entry.rect.get_center().x < 0, "Adjustment icon is on the left of the photo transport")
	menu.press_pointer("right_hand", entry.node.global_position + Vector3(0, 0, 1), -menu.global_basis.z, true)
	menu.release_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)
	check(menu._adjustment == "photo_view" and menu._adjust_rows.size() == 3, "Real ray/trigger opens three adjustment sliders")
	check(not menu.allows_playback_sticks(), "Image adjustment panel isolates playback shortcuts")
	menu.adjustment_committed.connect(func(): commits.append(true))
	for target in [450, 451, 452]:
		var row: Dictionary = menu._adjust_rows[target]
		var y: float = row.knob.position.y
		var knob: Object = row.knob
		var before := main.settings.encode_to_text()
		var saves := commits.size()
		check(menu.press_pointer("right_hand", point(menu, 0.03, y), -menu.global_basis.z, true),
			"Owner trigger captures " + row.key)
		check(menu.has_pointer_capture() and is_equal_approx(float(photo.snapshot()[row.key]), row.span.x) and main.settings.encode_to_text() == before,
			"Lower endpoint previews live without saving: " + row.key)
		check(not menu.press_pointer("left_hand", point(menu, 0.63, y), -menu.global_basis.z, true),
			"Other hand cannot steal slider: " + row.key)
		menu.update_pointer("left_hand", point(menu, 0.63, y), -menu.global_basis.z, true)
		check(is_equal_approx(float(photo.snapshot()[row.key]), row.span.x), "Other hand cannot move slider: " + row.key)
		menu.refresh_values()
		check(menu._adjust_rows[target].knob == knob, "Live refresh preserves slider node and capture: " + row.key)
		menu.update_pointer("right_hand", point(menu, 0.73, y), -menu.global_basis.z, true)
		check(is_equal_approx(float(photo.snapshot()[row.key]), row.span.y), "Drag past rail clamps to upper endpoint: " + row.key)
		menu.release_pointer("left_hand", Vector3.ZERO, Vector3.ZERO, false)
		check(menu.has_pointer_capture() and commits.size() == saves, "Other hand cannot commit slider: " + row.key)
		menu.release_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)
		check(not menu.has_pointer_capture() and commits.size() == saves + 1, "Owner tracking loss commits once: " + row.key)
		var stored := ConfigFile.new()
		check(stored.load(main.settings_path) == OK, "Slider release saves configuration")
		var stored_key: String = "magnification" if row.key == "inspect_magnification" else row.key.trim_prefix("screen_")
		check(is_equal_approx(float(stored.get_value("photo_screen", stored_key)), row.span.y), "Saved value matches live preview: " + row.key)
	check(is_equal_approx(photo.panel.global_position.distance_to(main._eye()), 10.0), "Distance slider moves the actual screen to 10m")
	check(photo._flat.size.is_equal_approx(photo._screen_base * 6.0), "Size slider enlarges the complete screen mesh sixfold")
	check(not photo.inspect and not photo._detail.visible and photo.material.get_shader_parameter("content_zoom") == 1.0
		and photo.inspect_magnification == 8.0, "Magnification slider changes only the saved default and never opens a window")
	check(Vector2(main.video.screen_distance, main.video.screen_scale) == video_before, "Photo adjustments preserve separate video parameters")
	photo.set_screen_distance(0.3)
	photo.set_screen_scale(6.0)
	photo.set_screen_curve(1.0)
	for corner in 4:
		check(photo.screen_corner(corner).z < photo.screen_distance, "Largest curved image stays in front at closest distance")
	photo.set_screen_scale(1.0)
	# Capture dismissal commits the last preview once.
	var y: float = menu._adjust_rows[450].knob.position.y
	menu.press_pointer("right_hand", point(menu, 0.3, y), -menu.global_basis.z, true)
	var saves := commits.size()
	menu.dismiss()
	check(commits.size() == saves + 1 and not menu.has_pointer_capture(), "Closing an active slider saves and clears capture once")
	var config := ConfigFile.new(); config.load(main.settings_path)
	var restored := Photo.new()
	restored.restore_view_settings(config)
	check(restored.screen_distance == photo.screen_distance and restored.screen_scale == photo.screen_scale and restored.inspect_magnification == 8.0,
		"Restart restores all three image preferences")
	restored.free()
	photo.toggle_inspect()
	photo.toggle_inspect()
	photo.toggle_inspect()
	check(photo.inspect and photo.magnification == 8.0, "Reopening magnifier remembers chosen zoom")
	main._reset_picture()
	check(not photo.inspect and photo.screen_distance == 3.0 and photo.screen_scale == 1.0
		and is_equal_approx(photo.panel.global_position.distance_to(main._eye()), 3.0), "Stick reset restores the new 3m distance and whole image")
	# Move the ray without pressing: the fixed-magnification window follows its sample.
	photo.local_uri = "file://photo-adjustments-fixture.png"
	photo.set_screen_curve(0.0); photo.set_inspect_magnification(4.0)
	var pose_before: Transform3D = photo.panel.global_transform
	var size_before: Vector2 = photo._flat.size
	for u in [0.25, 0.75]:
		var hit: Vector3 = photo.panel.to_global(Vector3((u - 0.5) * photo._flat.size.x, 0, 0))
		main.test_ray = [main._eye(), (hit - main._eye()).normalized()]
		if u == 0.25: main._toggle_photo_inspect("right_hand")
		else: main._update_photo_inspect()
		check(is_equal_approx(photo.crop_center.x, u), "Flat pointer samples its actual source position: %s" % u)
		check(photo.panel.global_transform.is_equal_approx(pose_before) and photo._flat.size == size_before,
			"Inspect selection preserves original photo pose and size")
	main._on_pointer_button("trigger_click", "right_hand")
	main._on_pointer_release("trigger_click", "right_hand")
	main.test_ray = null
	check(not photo._detail.visible and photo.material.get_shader_parameter("content_zoom") == 1.0, "Second trigger closes the detail window while the original remains whole")
	menu.dismiss()
	# Actual main stick routing keeps the panel quiet and requires neutral after dismissal.
	menu.toggle(); menu._activate(Menu.PHOTO_ADJUST)
	main._process_sticks(Vector2.ZERO, Vector2(0, 0.99), 0.1)
	check(photo.screen_scale == 1.0 and menu._adjustment == "photo_view", "Open panel blocks stick scaling and remains visible")
	menu.dismiss()
	main._process_sticks(Vector2.ZERO, Vector2(0, 0.99), 0.1)
	check(photo.screen_scale == 1.0, "Held stick remains blocked after panel closes")
	main._process_sticks(Vector2.ZERO, Vector2.ZERO, 0.1)
	main._process_sticks(Vector2.ZERO, Vector2(0, 0.99), 0.1)
	check(photo.screen_scale > 1.0, "Recentered stick resumes whole-photo scaling")
	photo.set_projection(3)
	menu.toggle(); menu._activate(Menu.PHOTO_ADJUST)
	check(menu._buttons.filter(func(b): return b.target in [450, 451]).all(func(b): return not b.enabled)
		and menu._buttons.filter(func(b): return b.target == 452)[0].enabled, "Panorama disables flat distance/size but retains magnification")
	var sphere_pose: Transform3D = photo.panel.global_transform
	var zoom_y: float = menu._adjust_rows[452].knob.position.y
	menu.press_pointer("right_hand", point(menu, 0.33, zoom_y), -menu.global_basis.z, true)
	check(not photo._detail.visible and not photo.inspect and is_equal_approx(photo.inspect_magnification, 5.0) and photo.panel.global_transform.is_equal_approx(sphere_pose),
		"Panorama default slider also changes only a parameter")
	menu.update_pointer("right_hand", Vector3.ZERO, Vector3.ZERO, false)
	check(not menu.has_pointer_capture(), "Lost tracking ends magnifier drag")
	menu._activate(Menu.PHOTO_ADJUST_BACK)
	check(menu._adjustment.is_empty() and menu._buttons.any(func(b): return b.target == Menu.PHOTO_ADJUST), "Back returns to photo controls")
	var legacy := ConfigFile.new(); legacy.set_value("photo_screen", "distance", 2.0)
	var legacy_photo := Photo.new(); legacy_photo.restore_view_settings(legacy)
	check(legacy_photo.screen_distance == 2.0, "Existing explicitly saved distance remains intact")
	legacy.set_value("photo_screen", "distance", NAN)
	legacy.set_value("photo_screen", "scale", INF)
	legacy.set_value("photo_screen", "magnification", NAN)
	legacy_photo.restore_view_settings(legacy)
	check(legacy_photo.screen_distance == 3.0 and legacy_photo.screen_scale == 1.0 and legacy_photo.inspect_magnification == 2.0,
		"Non-finite preferences fall back to defaults")
	legacy_photo.free()
	await gallery_sliders(main, image)
	main.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Photo adjustment regression: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func gallery_sliders(main: Node3D, image: Image) -> void:
	var photo: Node3D = main.photo
	var menu: Node3D = main.photo_menu
	var output := ProjectSettings.globalize_path("res://../../build/output/photo-adjustments-gallery")
	DirAccess.make_dir_recursive_absolute(output)
	var items: Array[Dictionary] = []
	for index in 12:
		var path := output.path_join("slider-%d.png" % index)
		image.save_png(path)
		items.append({"uri":"file://" + path, "title":"slider-%d.png" % index, "kind":"image"})
	photo.history_enabled = false; photo.auto_depth = false
	photo.mode_memory = preload("res://scripts/file_mode_memory.gd").new(output.path_join("modes"))
	menu.dismiss(); photo.set_projection(0); photo.set_screen_scale(1); photo.set_screen_distance(3)
	photo.set_process(true)
	photo.open_image(str(items[0].uri), "slider.png", items)
	var deadline := Time.get_ticks_msec() + 5000
	while photo.loading and Time.get_ticks_msec() < deadline: await create_timer(.01).timeout
	check(not photo.loading and photo.error.is_empty(), "Gallery slider fixture loads a real photo")
	photo.finish_transition(); photo.set_process(false); photo.gallery.set_process(false)
	for layout in [2,3]:
		photo.set_layout_mode(layout); photo.gallery._process(.02)
		for expanded in [false,true]:
			if expanded:
				photo.gallery.activate(photo.index); photo.gallery._process(1)
				check(photo.gallery.focus >= 0 and photo.panel.visible, "Expanded fixture exposes the focused photo controls: layout=%d" % layout)
			menu.toggle(); menu._activate(Menu.PHOTO_ADJUST)
			for hand in ["right_hand","left_hand"]:
				var optical: bool = hand == "left_hand"
				for target in [450,451]:
					var row: Dictionary = menu._adjust_rows[target]
					var y: float = row.knob.position.y
					var node: Object = row.knob
					var key: String = row.key
					var context := "layout=%d expanded=%s hand=%s key=%s" % [layout,expanded,hand,key]
					main.test_ray = [point(menu,.03,y),-menu.global_basis.z]
					var hit: Dictionary = menu.ray_hit(main.test_ray[0],main.test_ray[1])
					check(hit.get("target",-1) == target, "Actual ray reaches the photo adjustment rail: " + context)
					if hit.get("target",-1) != target: continue
					var before := commits.size()
					if optical: main._dispatch_hand_input({hand:{"source":"hand","tracked":true,"down":true,"pressed":true,"position":main.test_ray[0]}})
					else: main._on_controller_button("trigger_click",hand)
					check(menu.has_pointer_capture() and menu._adjust_hand == hand and is_equal_approx(float(photo.snapshot()[key]),row.span.x), "Trigger/pinch captures and previews the lower endpoint: " + context)
					main.test_ray = [point(menu,.63,y),-menu.global_basis.z]
					main._update_menu_pointer(hand)
					photo.gallery._process(.02); menu.refresh_values()
					check(menu.has_pointer_capture() and menu._adjust_rows[target].knob == node and is_equal_approx(float(photo.snapshot()[key]),row.span.y), "Drag and gallery reflow retain capture while reaching the upper endpoint: " + context)
					check(commits.size() == before, "Live drag does not commit before release: " + context)
					if optical: main._dispatch_hand_input({hand:{"source":"hand","tracked":true,"down":false,"released":true,"position":main.test_ray[0]}})
					else: main._on_controller_release("trigger_click",hand)
					check(not menu.has_pointer_capture() and commits.size() == before + 1, "Release commits the photo adjustment exactly once: " + context)
					var saved := ConfigFile.new(); saved.load(main.settings_path)
					var restored := Photo.new(); restored.restore_view_settings(saved)
					if key.begins_with("gallery_"): restored.gallery.set_mode(layout)
					check(is_equal_approx(float(restored.snapshot()[key]),row.span.y), "Released adjustment survives configuration reload: " + context)
					restored.free()
			menu.dismiss()
			if expanded: photo.gallery.return_focus(); photo.gallery._process(1)
	main.test_ray = null
