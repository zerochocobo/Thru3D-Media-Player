extends SceneTree
const Guide := preload("res://scripts/picture_center_guide.gd")
const Video := preload("res://scripts/mpv_video_display.gd")
const InputMain := preload("res://tests/test_controller_bindings.gd").InputMain
var checks := 0
var failures: Array[String] = []

class PhotoBar extends Node3D:
	var captured := false
	func has_pointer_capture() -> bool: return captured

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func _initialize() -> void: _run.call_deferred()

func sample(angle: float = 0.0, hand: String = "right_hand") -> Dictionary:
	return {"identity": "movie:1", "head": Transform3D.IDENTITY,
		"centre": Vector3.FORWARD.rotated(Vector3.UP, deg_to_rad(angle)) * 2.0, "held": true, "hand": hand}

func make_video(name: String) -> Node3D:
	var video := Video.new()
	var path := ProjectSettings.globalize_path("res://../../build/output/picture-center-guide/" + name)
	for field in ["mode_memory", "track_memory", "subtitle_timing", "subtitle_encoding", "audio_timing", "whisper_memory", "recent_files", "bookmark_store"]:
		video.get(field).directory = path.path_join(field)
	video.narration.memory.directory = path.path_join("narration")
	video.listening.memory.directory = path.path_join("listening")
	video.history_enabled = false
	root.add_child(video); video.set_process(false)
	return video

func lifecycle() -> void:
	var guide := Guide.new(); root.add_child(guide); guide.set_process(false)
	var pulses: Array[String] = []; guide.aligned.connect(func(hand): pulses.append(hand))
	guide.sync(sample(10), 1000)
	check(guide.visible and guide.holding and guide.opacity == 1.0, "Capture shows both references immediately")
	for now in range(1100, 10100, 100): guide.sync(sample(10), now)
	check(guide.visible and guide.opacity == 1.0 and pulses.is_empty(), "An unmoving held picture has no idle timeout or vibration")
	guide.sync(sample(), 10100); guide.sync(sample(), 10200)
	check(pulses.is_empty(), "Passing near centre does not immediately vibrate")
	guide.sync(sample(), 10260)
	check(guide.joined and pulses == ["right_hand"], "Stable alignment emits exactly one pulse for its owner")
	guide.sync(sample(), 10400)
	check(float(guide.ring.material_override.get_shader_parameter("shape_scale")) < 0.93, "Alignment contracts the ring slightly")
	for now in range(10500, 11500, 100): guide.sync(sample(0.35), now)
	check(pulses.size() == 1 and guide.joined, "Hysteresis tolerates head/hand jitter without repeated pulses")
	guide.sync(sample(1), 11600); guide.sync(sample(1), 11800)
	guide.sync(sample(), 11900); guide.sync(sample(), 12060)
	check(pulses.size() == 2, "A deliberate separated-and-rejoined alignment can confirm once again")
	guide.release("left_hand", 12070)
	check(guide.holding, "Other hand release cannot end the owner's guide")
	guide.release("right_hand", 12100)
	var released := sample(); released.held = false; released.hand = ""
	guide.sync(released, 12190)
	check(guide.visible and is_equal_approx(guide.opacity, 0.5), "Normal release fades halfway after 90ms")
	guide.sync(released, 12280)
	check(not guide.visible and guide.opacity == 0.0, "Normal release is gone after 180ms")
	guide.sync(sample(0, "left_hand"), 13000); guide.sync(sample(0, "left_hand"), 13160)
	check(pulses.back() == "left_hand", "Either controller owns alignment feedback independently")
	guide.sync(released, 13170)
	check(not guide.visible, "Ownership loss without a normal release cancels immediately")
	guide.sync(sample(), 14000); guide.sync({}, 14100)
	check(not guide.visible and guide.identity.is_empty(), "Focus/tracking loss clears all feedback")
	var invalid := sample(); invalid.centre = Vector3(NAN, 0, 0); guide.sync(invalid, 14200)
	check(not guide.visible, "Invalid tracked geometry cannot render or vibrate")
	guide.sync(sample(), 15000); guide.sync(sample(), 16000)
	var count := pulses.size()
	check(not guide.joined, "A long unobserved frame does not count as stable alignment")
	guide.sync(sample(), 16160)
	check(pulses.size() == count + 1, "Confirmation resumes with continuous samples")
	guide.release("right_hand", 16200); released.identity = "another:2"; guide.sync(released, 16240)
	check(not guide.visible, "Changing media discards an old fade")
	guide.sync(sample(180), 17000)
	check(guide.visible and guide.ring.visible and not guide.cross.visible and not guide.joined, "Rear centre never produces a false front alignment")
	check(guide.ring.layers == 1 and guide.cross.layers == 1 and guide.get_child_count() == 2, "Two eye-buffer quads allocate no viewport or composition layer")
	check(Guide.HAPTIC_AMPLITUDE <= 0.1 and Guide.HAPTIC_DURATION <= 0.02, "Alignment pulse is lighter and shorter than normal UI confirmation")
	guide.free()

func geometry() -> void:
	var surface := make_video("geometry")
	var camera := Camera3D.new(); root.add_child(camera); surface.view_camera = camera
	var guide := Guide.new(); root.add_child(guide); guide.set_process(false)
	var world := Transform3D(Basis.from_euler(Vector3(0.17, 0.32, -0.12)), Vector3(2, 1.7, -3))
	camera.global_transform = world
	for projection in [0, 1, 2, 3]:
		surface.geometry = projection; surface.screen_rotation = 25
		surface._view_basis = world.basis; surface.view_yaw = 0.25; surface.view_pitch = -0.17
		surface.view_horizontal = 0.2; surface.view_vertical = -0.1; surface.view_zoom = 0.3
		surface.set_flat_world_pose(world * Transform3D(Basis.IDENTITY, Vector3(0.4, -0.2, -3)))
		surface._apply_geometry()
		var expected: Vector3 = surface.panel.to_global(Vector3.ZERO if projection == 0 else Vector3.FORWARD * surface.SPHERE_RADIUS)
		for stereo in [false, true]:
			for top_bottom in [false, true]:
				surface.stereo_sbs = stereo; surface.top_bottom = top_bottom
				surface.stereo_horizontal = 10.0; surface.stereo_vertical = -5.0
				check(surface.picture_center_world().is_equal_approx(expected), "Content centre is independent of packing/calibration: %d/%s/%s" % [projection, stereo, top_bottom])
	for distance in [0.6, 2.0, 24.0, 80.0]:
		var centre: Vector3 = world * Vector3(0, 0, -distance)
		var placed := Guide.placement(world, centre)
		check(placed.ring.origin.is_equal_approx(placed.cross.origin), "Both marks share an angular centre at every content depth")
		check(placed.cross.origin.is_equal_approx(world * Vector3.FORWARD), "Picture depth does not change the angular reference geometry")
		for eye_offset in [-0.032, 0.032]:
			var eye := world * Transform3D(Basis(Vector3.UP, eye_offset), Vector3(eye_offset, 0, 0))
			var a: Vector3 = eye.affine_inverse() * placed.ring.origin
			var b: Vector3 = eye.affine_inverse() * placed.cross.origin
			check(a.is_equal_approx(b), "Alignment agrees in both translated/canted eye views")
		var data := sample(); data.head = world; data.centre = centre
		guide.sync(data, int(1000 + distance))
		check(is_equal_approx(guide.ring.global_basis.get_scale().x, 1.0), "Angular size is independent of picture depth")
		check((guide.ring.material_override.get_shader_parameter("head_origin") as Vector3).is_equal_approx(world.origin), "Both eyes use the tracked head centre, including world translation")
		var shifted: Vector3 = world * (Vector3(0.2, -0.1, -1).normalized() * distance)
		var off_centre := Guide.placement(world, shifted)
		check((off_centre.cross.origin - world.origin).normalized().is_equal_approx((shifted - world.origin).normalized()), "Off-centre marker keeps the original picture direction at every depth")
	var snapshot: Transform3D = surface.panel.global_transform
	guide.sync({"identity": "passive", "head": world, "centre": surface.picture_center_world(), "held": true, "hand": "right_hand"}, 20000)
	check(surface.panel.global_transform.is_equal_approx(snapshot), "Guide never snaps or changes a content transform")
	surface.free(); camera.free(); guide.free()

func integration() -> void:
	var main := InputMain.new(); main.display.preview = true
	main.settings_path = ProjectSettings.globalize_path("res://../../build/output/picture-center-guide/settings.cfg")
	var video := make_video("integration"); main.video = video
	video.platform = preload("res://tests/test_file_mode_memory.gd").Host.new(); video.history_enabled = false
	var camera := Camera3D.new(); root.add_child(camera); camera.global_transform = main.head_pose; video.view_camera = camera
	var guide := Guide.new(); root.add_child(guide); guide.set_process(false); main.picture_center_guide = guide
	var pulses: Array[String] = []; guide.aligned.connect(func(hand): pulses.append(hand))
	video.open_local("file:///centre_180_LR.mp4", "centre_180_LR.mp4"); video.panel.visible = true
	for hand in ["left_hand", "right_hand"]:
		main.rays[hand] = [main.pose.origin, Vector3.FORWARD]
		main._begin_interface_move(hand, "grip_click")
		var state: Dictionary = main._picture_center_sample()
		check(state.get("held", false) and state.hand == hand, "Real grip capture provides the owner and content centre")
		guide.sync(state, 1000); guide.sync(state, 1160)
		check(guide.visible and pulses.back() == hand, "Real held immersive picture shows and confirms both references")
		var before: Transform3D = video.panel.global_transform
		main.pose.origin += Vector3(0.025, 0, 0); main.pose.basis = Basis(Vector3.UP, 0.15)
		main._update_interface_move(); guide.sync(main._picture_center_sample(), 1200)
		check(not video.panel.global_transform.is_equal_approx(before), "Existing grip motion remains free after alignment")
		main._on_controller_release("grip_click", hand)
		guide.sync(main._picture_center_sample(), Time.get_ticks_msec() + 90)
		check(guide.visible and guide.opacity < 1.0, "Real grip release uses the fade path")
		guide.clear(); main.pose = Transform3D(Basis.IDENTITY, Vector3(0, 1.5, -0.5)); video.reset_view()
	main._begin_interface_move("right_hand", "grip_click")
	guide.sync(main._picture_center_sample(), 2000)
	main.pose_available = false
	guide.sync(main._picture_center_sample(), 2100)
	check(not guide.visible, "Lost controller tracking cancels instead of fading")
	main.pose_available = true; main.interface_move.cancel()
	main._begin_interface_move("right_hand", "grip_click")
	video.local_uri = "file:///different.mp4"
	check(main._picture_center_sample().is_empty(), "Old capture cannot carry a marker into a different media item")
	main.interface_move.cancel()
	main._grab = {"hand": "right_hand", "resize": {}}
	check(main._picture_center_sample().is_empty(), "Corner resizing does not impersonate picture positioning")
	main._grab.clear(); main._begin_interface_move("right_hand", "grip_click")
	main.interface_move.capture.targets = [{"node": Node3D.new(), "kind": "menu"}]
	check(main._picture_center_sample().is_empty(), "Menu-only movement does not show picture references")
	main.interface_move.capture.targets[0].node.free(); main.interface_move.cancel()
	for projection in [1, 2, 3]:
		video.geometry = projection; video.stereo_sbs = false; video._apply_geometry()
		main._begin_interface_move("right_hand", "grip_click")
		check(main._picture_center_sample().get("held", false), "Mono immersive projection still receives direction guidance: %d" % projection)
		main.interface_move.cancel()
	for stereo in [false, true]:
		video.geometry = 0; video.stereo_sbs = stereo; video.screen_curve = 0.5 if stereo else 0.0; video._apply_geometry()
		video.set_flat_world_pose(main.head_pose * Transform3D(Basis.IDENTITY, Vector3(0, 0, -2)))
		main._begin_interface_move("right_hand", "grip_click")
		check(not main.interface_move.capture.is_empty() and main._picture_center_sample().is_empty(), "Flat/curved screens keep their grip capture without centre guidance, regardless of stereo packing")
		var pulse_count := pulses.size()
		guide.sync(main._picture_center_sample(), 2500); guide.sync(main._picture_center_sample(), 2660)
		check(not guide.visible and pulses.size() == pulse_count, "Flat video neither renders markers nor confirms alignment")
		var before: Transform3D = video.panel.global_transform
		main.pose.origin += Vector3(0.05, 0, 0); main._update_interface_move()
		check(not video.panel.global_transform.is_equal_approx(before), "Suppressing the guide does not stop flat screen movement")
		main.interface_move.cancel(); guide.clear(); main.pose = Transform3D(Basis.IDENTITY, Vector3(0, 1.5, -0.5))
	var photo := preload("res://scripts/photo_display.gd").new()
	photo.mode_memory.directory = ProjectSettings.globalize_path("res://../../build/output/picture-center-guide/photo")
	photo.history_enabled = false; root.add_child(photo); photo.set_process(false)
	photo.local_uri = "file:///centre-photo.jpg"; photo.view_camera = camera; photo._apply_geometry(); photo.panel.visible = true
	photo.set_flat_world_pose(main.head_pose * Transform3D(Basis.IDENTITY, Vector3(0, 0, -2)))
	main.photo = photo; main.photo_active = true
	main._begin_interface_move("left_hand", "grip_click")
	check(not main.interface_move.capture.is_empty() and main._picture_center_sample().is_empty(), "Flat photo grip moves without centre guidance")
	main.interface_move.cancel(); main._begin_grab("right_hand", true)
	check(not main._grab.is_empty() and main._picture_center_sample().is_empty(), "Flat photo trigger/pinch capture does not show centre guidance")
	guide.sync(main._picture_center_sample(), 2800)
	check(not guide.visible, "Flat photo capture leaves no visible guide")
	main._grab.clear(); photo.geometry = 1; photo._apply_geometry()
	main._begin_interface_move("left_hand", "grip_click")
	var photo_sample: Dictionary = main._picture_center_sample()
	check(photo_sample.get("held", false) and photo_sample.hand == "left_hand" and photo_sample.centre.is_equal_approx(photo.picture_center_world()), "Immersive photo grip reuses the same picture-centre guide")
	var bar := PhotoBar.new(); root.add_child(bar); main.photo_menu = bar; main.player_menu = bar
	check(main._picture_center_sample().get("held", false), "Photo transport has no video-only playback-stick API")
	bar.captured = true
	check(main._picture_center_sample().is_empty(), "Captured timeline/slider suppresses centre guidance")
	bar.captured = false
	guide.sync(photo_sample, 3000)
	main._on_controller_release("grip_click", "left_hand")
	guide.sync(main._picture_center_sample(), Time.get_ticks_msec() + 90)
	check(guide.visible and guide.opacity < 1.0, "Photo grip release fades normally")
	bar.visible = false; guide.clear(); main._begin_grab("right_hand", true)
	check(main._picture_center_sample().get("held", false), "Existing photo trigger positioning also receives centre guidance")
	main._grab.clear(); guide.sync(main._picture_center_sample(), 4000)
	check(not guide.visible, "Cancelled photo positioning leaves no guide")
	main.photo_active = false; main.photo = null; main.photo_menu = null; main.player_menu = null; photo.free(); bar.free()
	main.display.preview = false
	check(main._picture_center_sample().is_empty(), "Unfocused session has no centre guide")
	video.free(); camera.free(); guide.free(); main.free()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://../../build/output/picture-center-guide"))
	lifecycle(); geometry(); integration()
	for failure in failures: push_error(failure)
	print("Picture centre guide: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
