extends SceneTree
const Video := preload("res://scripts/mpv_video_display.gd")
const Memory := preload("res://scripts/file_mode_memory.gd")
const Fixtures := preload("res://tests/test_file_mode_memory.gd")
const Controls := preload("res://scripts/immersive_adjustments.gd")
const Menu := preload("res://scripts/player_menu.gd")
const Privacy := preload("res://scripts/media_privacy.gd")
var checks := 0
var failures: Array[String] = []

class Dispatch extends "res://scripts/main.gd":
	var seeks: Array = []
	func _begin_stick_seek(hand: String, input: String, step: int, _id: String = "") -> void:
		seeks.append([hand, input, step])

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: _run.call_deferred()

func values(video: Node) -> Vector4:
	return Vector4(video.view_horizontal, video.view_vertical, video.view_zoom, video.stereo_horizontal)

func centre(main: Node) -> void:
	main._process_stick_input(Vector2.ZERO, Vector2.ZERO, 1.0 / 72.0)

func hold(main: Node, hand: String) -> void:
	main.controller_bindings.press(hand, "grip_click")
	centre(main)

func release(main: Node, hand: String) -> void:
	main._on_controller_release("grip_click", hand)
	centre(main)

func slide(menu: Node, key: String, fraction: float, main: Node) -> void:
	var row: Dictionary = menu._adjust_rows.values().filter(func(item): return item.key == key)[0]
	var point: Vector3 = row.knob.position
	point.x = row.left + fraction * row.width; point.z += 1
	var origin: Vector3 = row.knob.get_parent().to_global(point)
	var direction: Vector3 = -row.knob.global_basis.z
	check(menu.press_pointer("right", origin, direction, true), "Capture real settings slider: " + key)
	var sequence: int = main.video.mode_memory.sequence
	centre(main)
	check(main.video.mode_memory.sequence == sequence, "Idle sticks cannot flush a captured slider each frame: " + key)
	menu.release_pointer("right", origin, direction, true)

func _run() -> void:
	Privacy.configure(Privacy.NONE); Privacy.configure_file_settings(Privacy.ALL)
	var path := ProjectSettings.globalize_path("res://../../build/output/immersive-adjustments/memory-" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(path)
	var video := Video.new(); root.add_child(video); video.set_process(false)
	video.platform = Fixtures.Host.new(); video.history_enabled = false
	video.mode_memory = Memory.new(path); video.recent_files.directory = path.path_join("recent")
	video.bookmark_store.directory = path.path_join("bookmarks")
	var head := Camera3D.new(); root.add_child(head); head.position = Vector3(2, 1.6, -1)
	video.view_camera = head
	var main := Dispatch.new(); main.video = video; main.display.preview = true
	main.settings_path = path.path_join("settings.cfg")
	check(video.open_local("file:///fixed_180_LR.mp4", "fixed_180_LR.mp4"), "Open VR180 stereo video")
	check(video.geometry != 0 and video.stereo_sbs, "Fixture uses immersive projection")
	centre(main)
	# Unmodified sticks retain seek and the original zoom direction.
	main._process_stick_input(Vector2(.99, 0), Vector2.ZERO, .05)
	check(main.seeks.size() == 1 and main.seeks[0][2] == 20000, "Bare left stick retains forward seek")
	centre(main); main._process_stick_input(Vector2.ZERO, Vector2(0, 1), .05)
	check(video.view_zoom > 0, "Bare right stick retains original zoom direction")
	check(main._immersive_adjustment_sample()[0].key == "view_zoom", "Bare zoom shows its own gauge")
	var zoom_sequence: int = video.mode_memory.sequence
	for frame in 10: main._process_stick_input(Vector2.ZERO, Vector2(0, 1), .01)
	check(video.mode_memory.sequence == zoom_sequence, "Continuous bare zoom does not write settings each frame")
	centre(main)
	check(video.mode_memory.sequence > zoom_sequence, "Centring bare zoom saves its final value")
	video.reset_immersive_adjustments()
	hold(main, "left_hand")
	var basis: Basis = video.panel.global_basis
	main._process_stick_input(Vector2(1, 0), Vector2.ZERO, .1)
	check(video.view_horizontal > 0 and video.view_vertical == 0 and video.view_zoom == 0, "Left grip horizontal moves only X")
	check(main._immersive_adjustment_sample()[0].key == "view_horizontal", "Left horizontal adjustment is identified on screen")
	var x := video.view_horizontal
	main._process_stick_input(Vector2(0, 1), Vector2.ZERO, .1)
	check(video.view_vertical == 0, "Deflection cannot switch from X to Y before centring")
	centre(main); main._process_stick_input(Vector2(0, 1), Vector2.ZERO, .1)
	check(video.view_vertical > 0 and video.view_horizontal == x, "Left grip vertical moves only Y")
	check(video.panel.global_basis.is_equal_approx(basis), "Translation never rotates the sphere")
	check(video.panel.global_position.is_equal_approx(head.global_position + basis * Vector3(video.view_horizontal, video.view_vertical, -video.view_zoom) * video.SPHERE_RADIUS), "Offsets reach the shared projection sphere")
	release(main, "left_hand")
	hold(main, "right_hand")
	main._process_stick_input(Vector2.ZERO, Vector2(0, 1), .1)
	check(video.view_zoom > 0 and video.view_horizontal == x, "Right grip vertical changes only Z zoom")
	centre(main)
	var z := video.view_zoom
	for frame in 120: main._process_stick_input(Vector2.ZERO, Vector2(1, 0), 1.0 / 120.0)
	check(is_equal_approx(video.stereo_horizontal, 2.0) and video.view_zoom == z, "120 Hz alignment accumulates sub-step motion into 2 percent")
	check(main._immersive_adjustment_sample().back().value == video.stereo_horizontal, "Gauge shows the applied snapped horizontal value")
	for frame in 100: main._process_stick_input(Vector2.ZERO, Vector2(1, 0), .1)
	check(video.stereo_horizontal == 10 and main._immersive_adjustment_sample().back().value == 10, "Stick and gauge reach the positive expanded limit")
	centre(main)
	for frame in 120: main._process_stick_input(Vector2.ZERO, Vector2(-1, 0), .1)
	check(video.stereo_horizontal == -10 and main._immersive_adjustment_sample().back().value == -10, "Stick and gauge reach the negative expanded limit")
	check(main.seeks.size() == 1, "Grip horizontal never seeks")
	var saved := values(video)
	release(main, "right_hand")
	var fresh := Memory.new(path); fresh.load_saved()
	check(is_equal_approx(float(fresh.lookup(video.local_uri).get("view_horizontal", 0.0)), saved.x) and is_equal_approx(float(fresh.lookup(video.local_uri).get("stereo_horizontal", 0.0)), saved.w), "Grip release persists movie settings with history disabled")
	# A held stick must not jump when a grip starts, or keep adjusting after reset.
	main.controller_bindings.press("left_hand", "grip_click")
	main._process_stick_input(Vector2(1, 0), Vector2.ZERO, .1)
	check(values(video).is_equal_approx(saved), "Grip while stick is deflected waits for centre")
	video.stereo_vertical = .7
	main._on_controller_button("primary_click", "left_hand")
	check(values(video) == Vector4.ZERO and video.geometry == 1 and video.stereo_vertical == .7, "Left grip-click resets four values without switching projection or vertical stereo calibration")
	main._process_stick_input(Vector2(1, 0), Vector2.ZERO, .1)
	check(values(video) == Vector4.ZERO, "Reset cannot immediately reapply held stick")
	check(main._immersive_adjustment_sample().is_empty(), "Reset removes stale adjustment gauges")
	main._on_controller_release("primary_click", "left_hand")
	centre(main); main._process_stick_input(Vector2(1, 0), Vector2.ZERO, .1)
	check(video.view_horizontal > 0, "Adjustment resumes after centre")
	release(main, "left_hand"); hold(main, "right_hand")
	main._on_controller_button("primary_click", "right_hand")
	check(values(video) == Vector4.ZERO, "Right grip-click has identical reset semantics")
	main._on_controller_release("primary_click", "right_hand"); release(main, "right_hand")
	hold(main, "left_hand"); hold(main, "right_hand")
	main._process_stick_input(Vector2(1, 0), Vector2(0, 1), .1)
	check(video.view_horizontal > 0 and video.view_zoom > 0, "Both grips can adjust separate axes together")
	check(main._immersive_adjustment_sample().size() == 2, "Two moving hands each retain a visible gauge")
	main._on_controller_button("primary_click", "left_hand")
	main._process_stick_input(Vector2(1, 0), Vector2(0, 1), .1)
	check(values(video) == Vector4.ZERO, "Either reset suspends both held sticks")
	main._on_controller_release("primary_click", "left_hand"); release(main, "left_hand"); release(main, "right_hand")
	# Input focus, menu capture and grip+trigger chords retain their boundaries.
	hold(main, "left_hand"); main.display.preview = false
	main._process_stick_input(Vector2(1, 0), Vector2.ZERO, .1)
	check(values(video) == Vector4.ZERO, "Lost focus blocks fixed controls")
	main.display.preview = true
	main._process_stick_input(Vector2(1, 0), Vector2.ZERO, .1)
	check(values(video) == Vector4.ZERO, "Focus regain waits for centre")
	release(main, "left_hand")
	main.controller_bindings.press("right_hand", "grip_click")
	main.controller_bindings.press("right_hand", "trigger_click")
	check(not main._process_immersive_sticks(Vector2.ZERO, Vector2(1, 0), .1), "Existing grip-trigger chords are not claimed")
	main.controller_bindings.release("right_hand", "trigger_click"); release(main, "right_hand")
	var menu := Menu.new(); root.add_child(menu); menu.set_process(false)
	menu.state_provider = main._menu_state
	menu.adjustment_requested.connect(main._on_playback_adjustment)
	menu.adjustment_committed.connect(main._save_playback_adjustments)
	main.player_menu = menu; menu.visible = true; menu.section = 1; menu._adjustment = "screen"; menu.refresh()
	hold(main, "left_hand"); main._process_stick_input(Vector2(1, 0), Vector2.ZERO, .1)
	check(values(video) == Vector4.ZERO, "Open VR settings own input instead of moving video")
	check(main._immersive_adjustment_sample().is_empty(), "Settings with their own sliders hide passive gauges")
	release(main, "left_hand")
	for prefix in ["file:///", "smb://server/share/", "cloud://account/", "medialib://server/"]:
		var uri: String = prefix + "per_movie_180_LR.mp4"
		video.open_local(uri, "per_movie_180_LR.mp4"); menu.refresh()
		for key in Controls.KEYS + ["stereo_horizontal"]: slide(menu, key, .65, main)
		var expected := values(video)
		check(expected.x > 0 and expected.y > 0 and expected.z > 0 and expected.w > 0, "All four settings sliders apply")
		video.close_video(); fresh = Memory.new(path); fresh.load_saved(); video.mode_memory = fresh
		video.open_local(prefix + "other_180_LR.mp4", "other_180_LR.mp4")
		check(values(video) == Vector4.ZERO, "Another movie starts neutral: " + prefix)
		video.open_local(uri, "per_movie_180_LR.mp4")
		check(values(video).is_equal_approx(expected), "Fresh store restores four values after open/recenter: " + prefix)
		video._reopen_after_context_loss(uri, video.display_name, 0, true)
		check(values(video).is_equal_approx(expected), "Graphics recovery preserves placement: " + prefix)
	menu.refresh(); menu._activate_adjustment(Menu.VR_RESET)
	check(values(video) == Vector4.ZERO, "Settings reset matches grip-click")
	menu.visible = false
	# USB connection tokens change; restoration must wait for the stable identity.
	var identity := "usb://stable/" + "d".repeat(64) + "/per_movie.mp4"
	video.open_local("usb://connection-a/partition/per_movie.mp4", "per_movie_180_LR.mp4")
	video._restore_usb_mode(identity)
	video.set_immersive_adjustment("view_horizontal", .12); video.set_immersive_adjustment("view_vertical", -.08)
	video.set_immersive_adjustment("view_zoom", .21); video.set_stereo_alignment("stereo_horizontal", .75)
	var usb_expected := values(video)
	video.close_video(); fresh = Memory.new(path); fresh.load_saved(); video.mode_memory = fresh
	video.open_local("usb://connection-b/partition/per_movie.mp4", "per_movie_180_LR.mp4")
	check(values(video) == Vector4.ZERO, "USB waits for a stable file identity")
	video._restore_usb_mode(identity)
	check(values(video).is_equal_approx(usb_expected), "USB reconnect restores all four values")
	video.open_local("usb://connection-c/partition/per_movie.mp4", "per_movie_180_LR.mp4")
	video.set_immersive_adjustment("view_horizontal", .3); video._restore_usb_mode(identity)
	check(is_equal_approx(video.view_horizontal, .3), "Late USB restore cannot overwrite the user's new position")
	# Both composition paths use the same pose, and a later head turn must not retarget it.
	video.set_immersive_adjustment("view_horizontal", .2); video.set_immersive_adjustment("view_vertical", -.1)
	var before: Vector3 = video.panel.global_position - head.global_position
	head.rotate_y(.6); head.position += Vector3(.1, .2, -.3); video._center_on_view()
	check((video.panel.global_position - head.global_position).is_equal_approx(before), "Head movement retains the saved picture-relative offset")
	var origin := Node3D.new(); root.add_child(origin)
	var layer := preload("res://scripts/video_layer.gd").new(null)
	var packed: PackedFloat32Array = layer.layer_values(video, origin)
	check(Vector3(packed[2], packed[3], packed[4]).is_equal_approx(video.panel.global_position), "Compositor and eye-buffer sphere share translated pose")
	video.commit_stereo_view(); var sequence: int = video.mode_memory.sequence
	Privacy.configure_file_settings(Privacy.NONE)
	video.set_immersive_adjustment("view_horizontal", .3); video.commit_stereo_view()
	check(video.mode_memory.sequence == sequence, "Disabled file memory cannot write adjustments")
	Privacy.configure_file_settings(Privacy.ALL)
	var valid := {"geometry": 1, "profile": "320x320", "stereo_sbs": true, "swap_eyes": false, "alpha_requested": false}
	for bad in [{"view_horizontal": NAN}, {"view_vertical": .51}, {"view_zoom": -.51}, {"view_zoom": "0"}]:
		var invalid := valid.duplicate(); invalid.merge(bad, true)
		check(not Memory.valid_mode(invalid), "Reject malformed saved offset")
		check(Memory.new()._recover_saved_value(invalid).geometry == 1, "Bad display offset does not erase valid projection")
	var library := preload("res://scripts/library_menu.gd").new()
	var guide := preload("res://scripts/controls_page.gd").new(library)
	var fixed: Array = guide.items().filter(func(row): return row.get("fixed", "") in ["Left grip + stick ← / →", "Left grip + stick ↑ / ↓", "Right grip + stick ↑ / ↓", "Right grip + stick ← / →", "Either grip + same stick press"])
	check(fixed.size() == 5 and fixed.all(func(row): return not row.has("id")), "All five fixed operations are instructions, not editable bindings")
	var feedback := Controls.new()
	feedback.show_feedback("view_horizontal", .12, "movie", 1000)
	check(feedback.feedback_snapshot("movie", 1000)[0].value == 12 and feedback.feedback_snapshot("movie", 1000)[0].span == Vector2(-50, 50), "Position gauge uses the settings percentage scale")
	feedback.show_feedback("view_vertical", -.08, "movie", 1000)
	check(feedback.feedback_snapshot("movie", 1000).size() == 1 and feedback.feedback_snapshot("movie", 1000)[0].key == "view_vertical", "Changing axis replaces the old gauge for that hand")
	feedback.show_feedback("stereo_horizontal", -7.75, "movie", 1000)
	check(feedback.feedback_snapshot("movie", 1000).back().span == Vector2(-10, 10), "Alignment gauge exposes the expanded range")
	check(feedback.feedback_snapshot("movie", 1850).size() == 2 and feedback.feedback_snapshot("movie", 1850)[0].alpha == 1, "Released gauges stay readable briefly")
	check(is_equal_approx(feedback.feedback_snapshot("movie", 2025)[0].alpha, .5), "Released gauges fade smoothly")
	check(feedback.feedback_snapshot("movie", 2200).is_empty(), "Released gauges disappear completely")
	feedback.show_feedback("view_zoom", .2, "movie", 3000)
	check(feedback.feedback_snapshot("other", 3000).is_empty(), "Changing movie discards old gauges")
	check(Controls.value_text("stereo_horizontal", -7.75) == "-7.75%" and Controls.value_text("view_horizontal", -.001) == "+0.0%", "Feedback keeps alignment precision and avoids negative zero")
	library.free()
	video.close_video(); main.player_menu = null; menu.free(); main.free(); video.free(); head.free(); origin.free()
	Privacy.configure(Privacy.ALL)
	for failure in failures: push_error(failure)
	print("Immersive adjustments: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
