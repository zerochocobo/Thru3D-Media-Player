extends SceneTree
const Depth := preload("res://scripts/playback_menu_depth.gd")
const InputMain := preload("res://tests/test_controller_bindings.gd").InputMain
const Layout := preload("res://scripts/menu_surface_layout.gd")
const Mono := preload("res://scripts/mono_menu_capture.gd")
var checks := 0
var failures: Array[String] = []
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var layer := OpenXRCompositionLayerEquirect.new()
	layer.radius = INF
	check(is_inf(layer.radius), "Installed engine accepts OpenXR infinite radius without approximation")
	layer.free()
	for rect in [Rect2(-0.5,-0.7,1.0,0.3), Rect2(0.1,0.2,0.7,0.8), Rect2(-1,-1,2,2)]:
		var angles := Mono.capture_angles(rect)
		for point in [rect.position, rect.end, rect.get_center(), Vector2(rect.position.x,rect.end.y), Vector2(rect.end.x,rect.position.y)]:
			var longitude := atan(point.x)
			var latitude := atan(point.y/sqrt(1.0+point.x*point.x))
			check(absf(longitude) <= angles.x*0.5+0.00001 and latitude <= angles.y+0.00001 and latitude >= -angles.z-0.00001, "Native angular rectangle contains off-axis menu corners")
			check(Vector2(tan(longitude),tan(latitude)/cos(longitude)).is_equal_approx(point), "Spherical texture conversion preserves flat menu coordinates")
	# Godot composes per-eye projection with inverse eye pose. Directions remove
	# translation while retaining asymmetric FOV/canted orientation (not copied NDC).
	for separation in [0.058, 0.072]:
		for side in [-1.0, 1.0]:
			var lens := Projection.create_perspective(95.0, 1.1, 0.05, 100.0)
			lens.z.x += side * 0.08
			var eye_pose := Transform3D(Basis(Vector3.UP, side * 0.12), Vector3(side * separation * 0.5, 0.003, 0.01))
			for distance in [1.4, 3.0]:
				var direction: Vector3 = Vector3(0.25, -0.15, -1.0) * distance
				var clip := lens * Projection(eye_pose.affine_inverse()) * Vector4(direction.x, direction.y, direction.z, 0)
				var recovered := lens.inverse() * clip
				var world_ray := eye_pose.basis * Vector3(recovered.x, recovered.y, recovered.z)
				check(world_ray.normalized().is_equal_approx(direction.normalized()), "Zero parallax preserves calibrated angular direction for canted asymmetric eyes")
	var settings := ConfigFile.new()
	for invalid in [null, 3, true, "bad", [], INF]:
		settings.set_value("ui", Depth.KEY, invalid)
		check(Depth.load_mode(settings) == Depth.DEFAULT, "Invalid saved depth restores the default")
	var path := "user://playback_depth_%d.cfg" % Time.get_ticks_usec()
	settings = ConfigFile.new(); settings.set_value("appearance", "background", "dark"); settings.save(path)
	var main := InputMain.new(); main.settings_path = path; root.add_child(main); main.set_process(false)
	main.xr_camera.global_transform = main.head_pose
	main.recent_menu.section = main.recent_menu.Section.SETTINGS
	main.recent_menu.tab = main.recent_menu.DISPLAY_TAB; main.recent_menu.refresh()
	check(main.recent_menu.rows[-2].key == Depth.KEY and main.recent_menu.rows[-2].choices == Depth.choices(), "Depth choices sit immediately above thumbstick progress visibility")
	main.video.local_uri = "file:///depth-fixture.mp4"; main.video.media.begin(1); main.video.media.state = "playing"
	main._show_player_menu()
	var menu: Node3D = main.video_menu
	var flat := menu.global_transform
	var flat_key: StringName = main._menu_key(menu)
	for stereo in [false, true]:
		main.video.stereo_sbs = stereo
		for mode in Depth.MODES:
			main._on_setting_changed(Depth.KEY, mode); main.mono_menu_capture.update()
			check(main._playback_menu_depth_mode() == Depth.DEFAULT and menu.global_transform.is_equal_approx(flat), "Flat video ignores experimental depth, including stereo flat video")
			check(main._menu_key(menu) == flat_key and main.mono_menu_capture.active == null and not menu.has_meta("menu_mono_pointer"), "Flat video retains ordinary placement, rendering and pointer projection")
	main._on_setting_changed(Depth.KEY, Depth.DEFAULT)
	main.video.set_projection(1)
	var normal := menu.global_transform
	var library_scale := main.recent_menu.global_basis.get_scale()
	var photo_pose := main.photo_menu.global_transform
	var video_pose := main.video.global_transform
	main._on_setting_changed(Depth.KEY, Depth.MEDIUM)
	var medium := menu.global_transform
	var factor := 3.0 / 1.4
	check(medium.basis.get_scale().is_equal_approx(Vector3.ONE * factor), "Three metres preserves angular button size")
	check(medium.origin.is_equal_approx(main.head_pose.origin + (normal.origin - main.head_pose.origin) * factor), "Three metres scales the whole placement around the viewer")
	check(main.video.global_transform == video_pose and main.photo_menu.global_transform == photo_pose, "Video and photo controls are untouched")
	var ray_origin := main.head_pose.origin + Vector3(0.2, -0.2, -0.2)
	for button in menu._buttons:
		if not button.enabled: continue
		var point: Vector3 = button.node.global_position
		var hit: Dictionary = menu.ray_hit(ray_origin, point - ray_origin)
		check(not hit.is_empty(), "Scaled controls still accept actual controller rays")
		break
	var popup_bounds := Rect2(-0.5, 0.2, 1.0, 0.7)
	var a := Layout.above(normal, main.head_pose.origin, Vector3.ZERO, 0.25, popup_bounds, Vector3.UP)
	var b := Layout.above(medium, main.head_pose.origin, Vector3.ZERO, 0.25, popup_bounds, Vector3.UP)
	check(b.basis.get_scale().is_equal_approx(Vector3.ONE * factor), "Popups keep the scaled physical size")
	check((b.origin - main.head_pose.origin).is_equal_approx((a.origin - main.head_pose.origin) * factor), "Popups keep their angular spacing at three metres")
	main._show_recent_menu()
	check(main._library_is_attached() and main.recent_menu.global_basis.get_scale().is_equal_approx(Vector3.ONE * factor), "Playback browser shares three-metre scale")
	main._show_full_library()
	check(main.recent_menu.global_basis.get_scale().is_equal_approx(library_scale), "Leaving three-metre controls restores library size")
	main._show_player_menu()
	main._toggle_controls_lock()
	main._on_setting_changed(Depth.KEY, Depth.DEFAULT)
	check(menu.space_locked() and menu.global_basis.get_scale().is_equal_approx(Vector3.ONE), "Changing depth updates a locked control bar without unlocking it")
	main._toggle_controls_lock()
	main._on_setting_changed(Depth.KEY, Depth.MONO)
	main.mono_menu_capture.update()
	check(main.mono_menu_capture.active == menu and main.mono_menu_capture.surface.visible, "Zero parallax captures the production video menu")
	check(menu.global_basis.get_scale().is_equal_approx(Vector3.ONE), "Mono hit geometry remains at its finite default size")
	for projection in [1, 2, 3]:
		for stereo in [false, true]:
			main.video.geometry = projection; main.video.stereo_sbs = stereo; main.video.changed.emit()
			main.mono_menu_capture.update()
			check(main._playback_menu_depth_mode() == Depth.MONO and main.mono_menu_capture.active == menu, "VR180, fisheye and 360 use mono capture regardless of stereo packing")
			main.video.geometry = 0; main.video.changed.emit(); main.mono_menu_capture.update()
			check(main._playback_menu_depth_mode() == Depth.DEFAULT and main.mono_menu_capture.active == null and not menu.has_meta("menu_mono_pointer"), "Returning from VR to flat immediately restores ordinary rendering and picking")
	main.video.geometry = 1; main.video.changed.emit()
	main._on_setting_changed(Depth.KEY, Depth.MEDIUM); main._toggle_controls_lock(); menu.hide()
	main.video.set_projection(0)
	check(menu.space_locked() and menu.global_basis.get_scale().is_equal_approx(Vector3.ONE), "A hidden locked VR control bar restores default depth when switching to flat")
	main._show_player_menu()
	check(menu.space_locked() and menu.global_basis.get_scale().is_equal_approx(Vector3.ONE), "Reopening flat controls cannot restore a stale locked three-metre pose")
	main.video.set_projection(1)
	check(menu.space_locked() and menu.global_basis.get_scale().is_equal_approx(Vector3.ONE * factor), "Returning to VR restores the saved depth while preserving the lock")
	main._toggle_controls_lock(); main._on_setting_changed(Depth.KEY, Depth.MONO)
	check(is_equal_approx(menu.bar_transparency, 14.0) and is_equal_approx(main.video.stereo_horizontal, 0.0), "No background attenuation or video disparity edits")
	var mono_layers: int = main.mono_menu_capture.originals.size()
	main._show_recent_menu(); main.mono_menu_capture.update()
	check(main._library_is_attached() and main.mono_menu_capture.originals.size() > mono_layers, "Attached playback library joins the same mono capture")
	main._show_full_library(); main.mono_menu_capture.update()
	check(main.mono_menu_capture.active == null and main.recent_menu.global_basis.get_scale().is_equal_approx(library_scale), "Independent library restores ordinary stereo and size")
	main._show_player_menu(); main._on_setting_changed(Depth.KEY, Depth.DEFAULT)
	check(main.mono_menu_capture.active == null and menu.global_transform.is_equal_approx(normal), "Default restores the original pose and rendering")
	main._on_setting_changed(Depth.KEY, "bad")
	check(Depth.load_mode(main.settings) == Depth.DEFAULT, "Unknown setting rejected")
	main._on_setting_changed(Depth.KEY, Depth.MONO)
	settings.load(path); check(Depth.load_mode(settings) == Depth.MONO, "Choice persists independently of the source")
	# Use the actual attached-browser selection route, which restores a retained
	# controls pose after opening. It must not overwrite the new projection's depth.
	main.video.platform = preload("res://tests/test_player_menu.gd").Host.new()
	main.video.mode_memory = preload("res://scripts/file_mode_memory.gd").new(path + ".modes")
	main.video.history_enabled = false; main.video._remember_file = false
	main._on_setting_changed(Depth.KEY, Depth.MEDIUM); main._show_recent_menu()
	main._on_library_chosen("file:///depth-scope/next_2D.mp4", "next_2D.mp4")
	check(main.video.geometry == 0 and menu.global_basis.get_scale().is_equal_approx(Vector3.ONE), "Selecting a flat video through the VR browser does not copy the old three-metre pose")
	main._show_recent_menu()
	main._on_library_chosen("file:///depth-scope/next_LR_180.mp4", "next_LR_180.mp4")
	check(main.video.geometry == 1 and menu.global_basis.get_scale().is_equal_approx(Vector3.ONE * factor), "Selecting VR through a flat browser applies its saved experimental depth")
	main._on_setting_changed(Depth.KEY, Depth.MONO)
	main._close_current_media(false); main.mono_menu_capture.update()
	check(main.mono_menu_capture.active == null and main.recent_menu.visible, "Closing playback restores the media library")
	main.recent_menu.dismiss(); main.queue_free(); await process_frame
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(path + ".modes")
	for failure in failures: push_error(failure)
	print("Playback menu depth: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
