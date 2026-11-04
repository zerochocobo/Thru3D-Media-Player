extends SceneTree
const Aspect := preload("res://scripts/video_aspect.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const Layer := preload("res://scripts/video_layer.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
var failures: Array[String] = []
var checks := 0
var output := ProjectSettings.globalize_path("res://../../build/output/video-aspect-20261103/host/" + str(Time.get_ticks_usec()))

class Host extends "res://tests/test_file_mode_memory.gd".Host:
	var revisions := 0
	func revise_mpv_video(_id: int, _stereo: bool, _alpha: bool, _profile: String, _position: int, _depth: bool = false, _top_bottom: bool = false, _exact: bool = false) -> int:
		revisions += 1
		return 0

class Cinema extends Node3D:
	func snapshot() -> Dictionary:
		return {"screen": {"width": 32.0, "height": 22.38, "position": [0, 12, -10], "yaw": 0}}

class Main extends "res://scripts/main.gd":
	var fixed_cinema := false
	func _cinema_scene_active() -> bool: return fixed_cinema
	func _cinema_video_locked() -> bool: return fixed_cinema
	func _sync_cinema_lights() -> void: pass
	func _sync_cinema_transport(_recenter: bool = false) -> void: pass
	func _place_screen(_recenter: bool = false) -> void: pass

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func ratio(video: Node) -> float: return video._flat.size.x / video._flat.size.y

func click(menu: Node3D, target: int) -> bool:
	for button in menu._buttons:
		if button.target != target or not button.enabled: continue
		var point: Vector3 = button.node.to_global(Vector3(0, 0, 1))
		var direction: Vector3 = -button.node.global_basis.z
		menu.press_pointer("right", point, direction, true)
		menu.release_pointer("right", point, direction, true)
		return true
	return false

func choose(menu: Node3D, value: String) -> bool:
	for id in menu.choices.targets:
		var item: Dictionary = menu.choices.targets[id]
		if item.kind == "open" and item.key == "video_aspect_preset":
			if not click(menu, id): return false
			break
	for attempt in 4:
		for id in menu.choices.targets:
			var item: Dictionary = menu.choices.targets[id]
			if item.kind == "choose" and item.value == value: return click(menu, id)
		for id in menu.choices.targets:
			var item: Dictionary = menu.choices.targets[id]
			if item.kind == "scroll" and item.step == 1:
				if not click(menu, id): return false
				break
	return false

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	Privacy.configure(Privacy.NONE); Privacy.configure_file_settings(Privacy.ALL)
	check(Aspect.PRESETS == ["original", "9:16", "1:1", "4:3", "16:10", "16:9", "2:1", "21:9"], "Eight integer choices in agreed order")
	check(is_equal_approx(Aspect.RATIOS["21:9"], 7.0 / 3.0), "21:9 is exact, not 2.35 or 2.39")
	for item in [[0.0, 0.5], [0.5, 1.0], [1.0, 2.0]]:
		check(is_equal_approx(Aspect.slider_value(item[0]), item[1]) and is_equal_approx(Aspect.slider_fraction(item[1]), item[0]), "Slider end/center positions")
	var previous := 0.0
	for i in 201:
		var value := Aspect.slider_value(i / 200.0)
		check(value >= previous and value >= 0.5 and value <= 2.0 and absf(Aspect.slider_fraction(value) - i / 200.0) <= 0.0051, "Monotone logarithmic slider with bounded rounding")
		previous = value
	var video := Video.new(); root.add_child(video); video.set_process(false)
	video.mode_memory = Memory.new(output.path_join("modes"))
	var host := Host.new(); video.platform = host
	video.local_uri = "file:///aspect_a.mp4"; video.media.begin(7); video._remember_file = true
	var layer := Layer.new(null); var origin := Node3D.new(); root.add_child(origin)
	var source_cases := [[1920,1080,1.0,0,16.0/9], [3840,1080,1.0,1,16.0/9], [1920,2160,1.0,2,16.0/9],
		[1920,1080,1.0,3,16.0/9], [1920,1080,1.0,4,16.0/9], [1920,1080,2.0,3,16.0/9],
		[1920,1080,0.5,4,16.0/9], [1920,1080,2.0,1,16.0/9], [1920,1080,0.5,2,16.0/9],
		[1080,1920,1.0,0,9.0/16], [720,576,16.0/15,0,4.0/3]]
	for item in source_cases:
		video.media.format = {"width":item[0],"height":item[1],"pixel_aspect":item[2]}
		video.stereo_sbs = item[3] != 0; video.top_bottom = item[3] in [2,4]; video.stereo_half = item[3] in [3,4]
		var format: Dictionary = video.media.format.duplicate(true)
		for curve in [0.0, 0.7]:
			video.screen_curve = curve
			for preset in Aspect.PRESETS:
				check(video.set_video_aspect("video_aspect_preset", preset), "Preset accepted on a flat/curved video")
				for factor in [0.5,1.0,2.0]:
					video.set_video_aspect("video_aspect_factor", factor)
					var expected: float = float(Aspect.RATIOS.get(preset, item[4])) * factor
					check(is_equal_approx(ratio(video), expected) and video.media.format == format, "Single-eye ratio without modifying source metadata")
					var values := layer.layer_values(video, origin)
					var eyes := 2 if video.stereo_sbs else 1
					check(values.size() == Layer.STRIDE * eyes, "Expected compositor eye count")
					for eye in eyes:
						var record := values.slice(eye * Layer.STRIDE, (eye + 1) * Layer.STRIDE)
						var shown: float = record[13] / record[14] if curve == 0 else record[15]
						check(is_equal_approx(shown, expected), "Compositor and eye buffer share each eye's ratio")
	check(host.calls.is_empty() and host.revisions == 0, "All live ratio previews avoid decoder opens/revisions")
	video.screen_curve = 0; video.stereo_sbs = false; video.top_bottom = false; video.stereo_half = false
	video.media.format = {"width":1920,"height":1080,"pixel_aspect":1.0,"source_rotation_degrees":90}
	video._binding.warped = true; video.depth_requested = true
	video.set_video_aspect("video_aspect_preset", "4:3")
	check(is_equal_approx(ratio(video), 4.0/3), "Generated stereo atlas is not split twice")
	video._binding.warped = false; video.depth_requested = false
	var pose: Transform3D = video.flat_pose
	var scale: float = video.screen_scale; var distance: float = video.screen_distance
	video.set_video_aspect("video_aspect_preset", "21:9")
	check(video.flat_pose == pose and video.screen_scale == scale and video.screen_distance == distance, "Free-screen pose, size factor and distance remain unchanged")
	video.cinema.configure(video, true, Transform3D.IDENTITY)
	var bottom: Transform3D = video.cinema.bottom
	video.set_video_aspect("video_aspect_preset", "9:16")
	check(video.cinema.bottom == bottom, "Upright screen keeps its bottom anchor")
	video.screen_preset = "tv100"; video.set_video_aspect("video_aspect_preset", "21:9")
	check(video.screen_preset == "tv100" and video._flat.size.x <= 2.214 and video._flat.size.y <= 1.246, "TV envelope still fits adjusted ratio")
	video.cinema.configure(video, false, Transform3D.IDENTITY); video.screen_preset = ""
	video.set_video_aspect("video_aspect_factor", 1.25)
	var sequence: int = video.mode_memory.sequence
	video._remember_mode(false)
	check(video.mode_memory.sequence == sequence, "Metadata does not persist a preview before release")
	video.commit_stereo_view()
	var saved: Dictionary = video.mode_memory.lookup(video.local_uri)
	check(saved.video_aspect_preset == "21:9" and saved.video_aspect_factor == 1.25, "Aspect persists independently of disabled history")
	var restored := Memory.new(video.mode_memory.directory); restored.load_saved()
	check(restored.lookup(video.local_uri).video_aspect_preset == "21:9" and restored.lookup(video.local_uri).video_aspect_factor == 1.25, "Fresh store restores saved ratio")
	for field in Aspect.FIELDS:
		for invalid in ([null, "bad", 16, {}, []] if field == "video_aspect_preset" else [null,"bad",NAN,INF,0,3,{},[]]):
			check(not video.set_video_aspect(field, invalid), "Invalid UI values rejected")
			var corrupted := saved.duplicate(true); corrupted[field] = invalid
			var repaired: Dictionary = video.mode_memory._recover_saved_value(corrupted)
			check(not repaired.is_empty() and repaired.geometry == saved.geometry and repaired.stereo_sbs == saved.stereo_sbs and Aspect.valid(repaired), "Corrupt aspect field does not erase video mode")
			video._restore_saved_mode(corrupted)
			check(Aspect.valid({"video_aspect_preset": video.video_aspect_preset, "video_aspect_factor": video.video_aspect_factor}), "Direct private-store restore also sanitizes aspect values")
	var legacy := saved.duplicate(); for field in Aspect.FIELDS: legacy.erase(field)
	video._restore_saved_mode(legacy)
	check(video.video_aspect_preset == "original" and video.video_aspect_factor == 1, "Legacy preferences keep original appearance")
	check(video.open_local("file:///aspect_a.mp4", "aspect_a.mp4"), "Previously corrected video opens")
	check(video.video_aspect_preset == "21:9" and video.video_aspect_factor == 1.25, "Per-file correction restored on open")
	video.reuse_last_mode = true; video.media.frame_counter = 1; video._layout_pending = null
	video._remember_last_mode()
	check(not video.last_mode.has("video_aspect_preset"), "Ratio never enters reuse-last-mode preference")
	check(video.open_local("file:///aspect_b.mp4", "aspect_b.mp4"), "Different video opens")
	check(video.video_aspect_preset == "original" and video.video_aspect_factor == 1, "Next video does not inherit correction")
	video.geometry = 0; video.set_video_aspect("video_aspect_preset", "16:10"); video.set_video_aspect("video_aspect_factor", 0.75)
	video._reopen_after_context_loss(video.local_uri, "recovered", 0, true)
	check(video.video_aspect_preset == "16:10" and video.video_aspect_factor == 0.75, "Context recovery retains live corrected ratio")
	var before_cast := video.capture_cast_view()
	check(video.open_cast("http://127.0.0.1/cast", "cast", 42, 0), "Cast source opens")
	check(video.video_aspect_preset == "original" and video.video_aspect_factor == 1, "Cast starts without local correction")
	video.set_video_aspect("video_aspect_preset", "4:3"); video.commit_stereo_view()
	check(video.cast_allows("video_aspect_factor") and not video._remember_file, "Live cast allows display-only correction without saving")
	video.cast_token = 0; video.restore_cast_view(before_cast)
	check(video.video_aspect_preset == "16:10" and video.video_aspect_factor == 0.75, "Cast exit restores preceding view")
	video.geometry = 1; video._apply_geometry()
	check(not video.set_video_aspect("video_aspect_factor", 2.0) and video.video_aspect_factor == 0.75, "Immersive projection does not apply flat adjustments")
	video.geometry = 0; video._apply_geometry()
	check(is_equal_approx(ratio(video), 1.2), "Returning to flat restores correction")
	Privacy.configure_file_settings(Privacy.NONE)
	video._remember_file = true; sequence = video.mode_memory.sequence
	video.set_video_aspect("video_aspect_preset", "1:1"); video.commit_stereo_view()
	check(video.mode_memory.sequence == sequence, "Disabled file memory does not persist adjustments")
	Privacy.configure_file_settings(Privacy.ALL)
	video.discard_file_settings()
	check(video.video_aspect_preset == "original" and video.video_aspect_factor == 1 and not video._video_aspect_dirty, "Explicit clear resets ratio without leaving a pending save")
	# USB identity arrives after open; a user may already be dragging the ratio slider.
	var stable := "usb://stable/" + "a".repeat(64) + "/aspect.mp4"
	video.mode_memory.remember(stable, saved); video.mode_memory.save()
	video.open_local("usb://mount-one/aspect.mp4", "aspect.mp4")
	video._restore_usb_mode(stable)
	check(video.video_aspect_preset == "21:9" and video.video_aspect_factor == 1.25, "Late USB identity restores per-file ratio")
	video.open_local("usb://mount-two/aspect.mp4", "aspect.mp4")
	video.set_video_aspect("video_aspect_preset", "4:3"); video.set_video_aspect("video_aspect_factor", 0.8)
	video._restore_usb_mode(stable)
	check(video.video_aspect_preset == "4:3" and video.video_aspect_factor == 0.8, "Late USB identity cannot overwrite active ratio preview")
	check(video.mode_memory.lookup(stable).video_aspect_preset == "21:9", "USB identity does not persist a drag before release")
	video.commit_stereo_view()
	check(video.mode_memory.lookup(stable).video_aspect_preset == "4:3" and video.mode_memory.lookup(stable).video_aspect_factor == 0.8, "Release saves correction against stable USB identity")
	video.media.format = {"width":1080,"height":1920,"pixel_aspect":1.0}; video._apply_geometry()
	check(is_equal_approx(ratio(video), 4.0/3*0.8), "Late source size does not undo a fixed ratio")
	video.set_video_aspect("video_aspect_preset", "original")
	check(is_equal_approx(ratio(video), 9.0/16), "Original follows updated source dimensions")
	video.open_local("usb://mount-three/aspect.mp4", "aspect.mp4"); video.discard_file_settings(); video._restore_usb_mode(stable)
	check(video.video_aspect_preset == "original" and video.video_aspect_factor == 1, "Late USB identity cannot reactivate cleared ratio")
	var surface := preload("res://scripts/media_surface.gd").new()
	check(surface._display_aspect(1.5) == 1.5, "Shared photo surface retains source ratio"); surface.free()
	await _ui(video)
	video.close_video(); video.queue_free(); origin.queue_free()
	await process_frame
	for failure in failures: push_error(failure)
	var report := FileAccess.open(output.path_join("verification.json"), FileAccess.WRITE)
	report.store_string(JSON.stringify({"checks":checks,"failures":failures}, "\t")); report.close()
	print("Video aspect: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _ui(video: Node3D) -> void:
	var main := Main.new(); main.video = video; main.settings_path = output.path_join("settings.cfg")
	main.recent_menu = preload("res://scripts/library_menu.gd").new()
	main.cinema_environment = Cinema.new(); root.add_child(main.cinema_environment)
	var menu := Menu.new(); main.player_menu = menu
	menu.state_provider = main._menu_state
	menu.adjustment_requested.connect(main._on_playback_adjustment)
	menu.adjustment_committed.connect(main._save_playback_adjustments)
	menu.setting_requested.connect(main._on_player_setting)
	root.add_child(menu); menu.set_process(false); menu.visible = true
	video.local_uri = "file:///aspect_ui.mp4"; video.media.begin(8); video._remember_file = true
	video.geometry = 0; video.stereo_sbs = true; video.media.format = {"width":3840,"height":1080,"pixel_aspect":1.0}
	video._apply_geometry(); video.panel.visible = true
	for language in ["zh", "zh_Hant", "en", "ja"]:
		Menu.I18n.use(language)
		for cinema in [false,true]:
			main.fixed_cinema = cinema; main._sync_cinema_screen()
			menu.section = 1; menu._adjustment = "screen"; menu.refresh()
			check(menu.text_snapshot().contains(Menu.I18n.t("Per-eye ratio")), "Translated per-eye label in ordinary/cinema settings")
			check(menu._adjust_rows.has(Menu.VIDEO_ASPECT_FACTOR), "Ratio slider visible in ordinary/cinema screen settings")
			check(choose(menu, "21:9") and video.video_aspect_preset == "21:9", "Ray selection reaches last preset through dropdown scroll")
			for point in [[0.0,0.5],[0.5,1.0],[1.0,2.0]]:
				var row: Dictionary = menu._adjust_rows[Menu.VIDEO_ASPECT_FACTOR]
				var p := Vector3(row.left + point[0] * row.width, row.button.rect.get_center().y, 1)
				var plane: Node3D = menu._input_surface(Menu.VIDEO_ASPECT_FACTOR)
				var sequence: int = video.mode_memory.sequence
				var hit: Dictionary = menu.ray_hit(plane.to_global(p), -plane.global_basis.z)
				menu.press_pointer("right", plane.to_global(p), -plane.global_basis.z, true)
				check(is_equal_approx(video.video_aspect_factor, point[1]) and menu.has_pointer_capture(), "Ray press previews ratio with pointer capture: %s %s requested=%s actual=%s hit=%s" % [language,cinema,point,video.video_aspect_factor,hit.get("target")])
				check(video.mode_memory.sequence == sequence, "Ray preview does not save before release")
				menu.release_pointer("right", plane.to_global(p), -plane.global_basis.z, true)
				check(not menu.has_pointer_capture() and is_equal_approx(video.mode_memory.lookup(video.local_uri).video_aspect_factor, point[1]), "Release commits ratio and ends capture")
				check(is_equal_approx(ratio(video), 7.0 / 3.0 * point[1]), "Ray slider changes both eyes' ratio")
				if cinema: check(video._flat.size.x <= 32.001 and video._flat.size.y <= 22.381, "Adjusted picture stays inside fixed cinema wall")
			check(click(menu, Menu.SLIDER_RESET_BASE + Menu.VIDEO_ASPECT_FACTOR) and video.video_aspect_factor == 1 and video.video_aspect_preset == "21:9", "Inline reset preserves preset")
			check(choose(menu, "original") and video.video_aspect_preset == "original" and video.video_aspect_factor == 1, "Original restores source ratio")
			if cinema:
				var size: Vector2 = video._flat.size
				main._on_playback_adjustment("screen_scale", 200)
				check(video._flat.size == size, "Ratio access does not unlock physical cinema screen size")
	main.fixed_cinema = false; main._sync_cinema_screen()
	video.geometry = 1; menu.refresh()
	check(not menu._adjust_rows.has(Menu.VIDEO_ASPECT_FACTOR), "No ratio slider in panorama settings")
	main.photo_active = true; video.geometry = 0
	main._on_playback_adjustment("video_aspect_factor", 2)
	check(video.video_aspect_factor == 1, "Photo context cannot change video ratio")
	menu.queue_free(); main.recent_menu.free(); main.cinema_environment.queue_free(); main.free()
	await process_frame
