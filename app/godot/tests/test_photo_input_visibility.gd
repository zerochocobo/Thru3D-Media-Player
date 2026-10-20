extends SceneTree
const Main := preload("res://scripts/main.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func _initialize() -> void: call_deferred("run")

func world_ray_visible(main: Node3D, hand: String) -> bool:
	var line: Node3D = main.controller_feedback.hands[hand].nodes.get("line")
	return line != null and line.visible

func update(main: Node3D, delta: float = 0.014) -> void:
	main._update_hand_input(delta)
	main._update_photo_inspect()
	main._update_controller_feedback(delta)
	for hand in Main.ControllerBindings.HANDS: main._update_menu_pointer(hand)

func run() -> void:
	var main := Main.new(); main.settings_path = "user://photo-input-visibility-%d.cfg" % Time.get_ticks_usec()
	root.add_child(main); main.set_process(false)
	main.photo.set_process(false); main.video.set_process(false)
	main.photo_menu.set_process(false); main.video_menu.set_process(false); main.recent_menu.set_process(false)
	main.recent_menu.dismiss(); main.video_menu.dismiss(); main.photo_menu.dismiss()
	main.photo_active = true; main.player_menu = main.photo_menu
	main.display.preview = false; main.display.session_state = "session_focussed"
	var photo: Node3D = main.photo
	photo.history_enabled = false; photo.auto_depth = false
	photo.local_uri = "file:///visibility.png"
	var image := Image.create(256, 128, false, Image.FORMAT_RGB8); image.fill(Color.WHITE)
	photo._texture = ImageTexture.create_from_image(image); photo._size = Vector2(256, 128)
	photo.material.set_shader_parameter("photo_texture", photo._texture)
	photo._detail_material.set_shader_parameter("photo_texture", photo._texture)
	photo.panel.visible = true
	var head := XRPositionalTracker.new(); head.type = XRServer.TRACKER_HEAD; head.name = "head"
	head.set_pose("default", Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	XRServer.add_tracker(head)
	var controllers := []
	var trackers := []
	var aims := []
	for side in ["left", "right"]:
		var pose := Transform3D(Basis.IDENTITY, Vector3(-0.2 if side == "left" else 0.2, 1.4, -0.4))
		var controller := XRControllerTracker.new(); controller.name = side + "_hand"
		for key in ["aim", "grip"]: controller.set_pose(key, pose, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		XRServer.add_tracker(controller); controllers.append(controller)
		var tracker := XRHandTracker.new(); tracker.name = "/user/hand_tracker/" + side
		tracker.hand = XRPositionalTracker.TRACKER_HAND_LEFT if side == "left" else XRPositionalTracker.TRACKER_HAND_RIGHT
		tracker.has_tracking_data = false; tracker.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED
		tracker.set_pose("default", pose, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		XRServer.add_tracker(tracker); trackers.append(tracker)
		var aim := XRControllerTracker.new(); aim.name = "/user/fbhandaim/" + side
		aim.set_pose("default", pose, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		aim.set_input("index_pinch", false)
		XRServer.add_tracker(aim); aims.append(aim)
	await process_frame
	for optical in [false, true]:
		for tracker in trackers: tracker.has_tracking_data = optical
		for projection in [0, 1, 2, 3]:
			photo.set_projection(projection); main._place_screen()
			update(main, 6.0)
			check(main._active_menu() == null and main._input_feedback_visible(), "Photos allow input visuals without a panel: %s/%d" % [optical, projection])
			for hand in Main.ControllerBindings.HANDS:
				var entry: Dictionary = main.input_visuals.hands[hand]
				var feedback: Dictionary = main.controller_feedback.hands[hand]
				check(entry.hand_gate.visible if optical else entry.controller_gate.visible, "Tracked photo model stays visible after idle: %s/%d/%s" % [optical, projection, hand])
				check(feedback.opacity == 1.0 and not feedback.nodes.is_empty() and feedback.nodes.line.visible, "Photo aim ray stays visible after idle: %s/%d/%s" % [optical, projection, hand])
				if optical: check(main.hand_marks[hand].visible and main._move_pose(hand) == null, "Optical photo ray needs no controller grip: " + hand)
		photo.set_projection(0)
		for layout in [0, 1, 2, 3]:
			photo.gallery.mode = layout; update(main, 6.0)
			check(Main.ControllerBindings.HANDS.all(func(hand): return world_ray_visible(main, hand)), "All photo layouts retain stationary rays: %s/%d" % [optical, layout])
		photo.gallery.mode = 0
		main.photo_menu.visible = true; main.photo_menu.refresh(); update(main, 6.0)
		check(Main.ControllerBindings.HANDS.all(func(hand): return main.photo_menu._pointers[hand].line.visible and not world_ray_visible(main, hand)), "Photo panel owns visible rays without duplicate world rays")
		main.photo_menu.dismiss(); update(main, 0.0)
		check(Main.ControllerBindings.HANDS.all(func(hand): return world_ray_visible(main, hand)), "Dismissing a photo panel immediately restores world rays")
	# Switching media must apply video's hidden-panel policy on the same frame.
	main.photo_active = false; main.player_menu = main.video_menu; update(main, 0.0)
	check(not main._input_feedback_visible(), "Video keeps a separate panel-only visibility policy")
	for hand in Main.ControllerBindings.HANDS:
		check(not main.input_visuals.hands[hand].hand_gate.visible and not main.hand_marks[hand].visible and not world_ray_visible(main, hand), "Returning to video hides optical visuals immediately: " + hand)
	main.photo_active = true; main.player_menu = main.photo_menu; update(main, 0.0)
	check(Main.ControllerBindings.HANDS.all(func(hand): return main.input_visuals.hands[hand].hand_gate.visible and world_ray_visible(main, hand)), "Returning to photos needs no pinch or wake")
	main.display.session_state = "session_visible"; update(main)
	check(Main.ControllerBindings.HANDS.all(func(hand): return not main.input_visuals.hands[hand].hand_gate.visible and not main.hand_marks[hand].visible and not world_ray_visible(main, hand)), "System focus loss still hides photo input visuals")
	main.display.session_state = "session_focussed"; update(main)
	check(Main.ControllerBindings.HANDS.all(func(hand): return main.input_visuals.hands[hand].hand_gate.visible and world_ray_visible(main, hand)), "Photo visuals recover immediately with input focus")
	for aim in aims: aim.invalidate_pose("default")
	update(main)
	check(Main.ControllerBindings.HANDS.all(func(hand): return not main.hand_marks[hand].visible and not world_ray_visible(main, hand)), "Missing optical aim never leaves stale rays")
	# PICO's joint-based pointing path has no dedicated runtime aim tracker.
	for aim in aims: XRServer.remove_tracker(aim)
	aims.clear()
	for index in trackers.size():
		var center := Vector3(-0.2 if index == 0 else 0.2, 1.4, -0.4)
		var points := [center - Vector3(0.03, 0, 0), center + Vector3(0.03, 0, 0), center - Vector3(0.035, 0, 0), center + Vector3(0.035, 0, 0)]
		for joint in Main.HandPointer.JOINTS.size():
			trackers[index].set_hand_joint_flags(Main.HandPointer.JOINTS[joint], Main.HandPointer.POSITION_FLAGS)
			trackers[index].set_hand_joint_transform(Main.HandPointer.JOINTS[joint], Transform3D(Basis.IDENTITY, points[joint]))
	update(main, 6.0)
	for hand in Main.ControllerBindings.HANDS:
		check(main.hand_pointers[hand].provider == "joints" and main.hand_marks[hand].visible and world_ray_visible(main, hand), "Joint-based photo pointing stays visible without runtime aim: " + hand)
	for tracker in trackers: tracker.has_tracking_data = false
	for controller in controllers:
		controller.invalidate_pose("aim"); controller.invalidate_pose("grip")
	update(main)
	check(Main.ControllerBindings.HANDS.all(func(hand): return not main.input_visuals.hands[hand].hand_gate.visible and not main.input_visuals.hands[hand].controller_gate.visible and not world_ray_visible(main, hand)), "Tracking loss still hides stale models and rays")
	for tracker in controllers + trackers + aims + [head]: XRServer.remove_tracker(tracker)
	main.queue_free(); await process_frame
	for failure in failures: push_error(failure)
	print("Photo input visibility: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
