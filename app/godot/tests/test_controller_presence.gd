extends SceneTree
## PICO enterprise mixed interaction reports an optical hand while it holds a controller.
const Presence := preload("res://scripts/controller_presence.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures.append(label)

func _initialize() -> void:
	var tracker := XRControllerTracker.new()
	tracker.type = XRServer.TRACKER_CONTROLLER
	tracker.name = "left_hand"
	tracker.profile = "/interaction_profiles/bytedance/pico4_controller"
	XRServer.add_tracker(tracker)
	var presence := Presence.new()
	var at := func(origin: Vector3, basis := Basis()) -> void:
		tracker.set_pose("aim", Transform3D(basis, origin), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	var step := func(frames: int) -> void:
		for i in frames: presence.update("left_hand", 0.1)

	at.call(Vector3(0, 1, 0)); step.call(40)
	check(not presence.engaged("left_hand"), "A tracked controller lying still leaves the hand to gestures")
	at.call(Vector3(0, 1.0005, 0)); step.call(1)
	check(not presence.engaged("left_hand"), "Tracking jitter does not engage")
	at.call(Vector3(0.03, 1, 0)); step.call(1)
	check(presence.engaged("left_hand"), "Picking the controller up engages it")
	step.call(25)
	check(presence.engaged("left_hand"), "A held controller stays engaged inside the idle window")
	step.call(10)
	check(not presence.engaged("left_hand"), "A controller set down hands the hand back after the idle window")
	at.call(Vector3(0.03, 1, 0), Basis(Vector3.UP, deg_to_rad(6))); step.call(1)
	check(presence.engaged("left_hand"), "Turning the controller engages it")
	step.call(40)
	tracker.set_input("trigger", 0.6); step.call(1)
	check(presence.engaged("left_hand"), "Pulling the trigger engages a still controller")
	tracker.set_input("trigger", 0.0); step.call(40)
	presence.touch("left_hand")
	check(presence.engaged("left_hand"), "A button press engages before the frame update")
	tracker.profile = "/interaction_profiles/ext/hand_interaction_ext"; step.call(1)
	check(not presence.engaged("left_hand"), "A hand interaction profile is never a controller")
	presence.touch("left_hand")
	check(not presence.engaged("left_hand"), "Buttons routed through a hand profile do not engage")
	tracker.profile = "/interaction_profiles/khr/simple_controller"; at.call(Vector3(0.2, 1, 0)); step.call(1)
	at.call(Vector3(0.4, 1, 0)); step.call(1)
	check(not presence.engaged("left_hand"), "The simple profile may carry a hand and does not engage")
	tracker.profile = "/interaction_profiles/bytedance/pico4_controller"; step.call(1)
	at.call(Vector3(0.6, 1, 0)); step.call(1)
	check(presence.engaged("left_hand"), "Back on the controller profile, movement engages")

	var joints := XRHandTracker.new()
	joints.name = "/user/hand_tracker/left"
	joints.hand = XRPositionalTracker.TRACKER_HAND_LEFT
	XRServer.add_tracker(joints)
	var palm_at := func(origin: Vector3, flags: int = XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) -> void:
		joints.has_tracking_data = true
		joints.set_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM, Transform3D(Basis(), origin))
		joints.set_hand_joint_flags(XRHandTracker.HAND_JOINT_PALM, flags)
	tracker.set_pose("grip", Transform3D(Basis(), Vector3(0.6, 0.95, 0.05)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	palm_at.call(Vector3(0.62, 0.96, 0.07)); step.call(80)
	check(presence.engaged("left_hand"), "A palm at the grip keeps a still controller engaged")
	palm_at.call(Vector3(0.62, 0.96, 0.4)); step.call(1)
	check(presence.engaged("left_hand"), "A hand leaving the controller still gets the idle window")
	step.call(40)
	check(not presence.engaged("left_hand"), "A hand away from a still controller returns to gestures")
	palm_at.call(Vector3(0.62, 0.96, 0.07), 0); step.call(1)
	check(not presence.engaged("left_hand"), "A palm without a valid position does not hold")
	palm_at.call(Vector3(0.62, 0.96, 0.07)); joints.has_tracking_data = false; step.call(1)
	check(not presence.engaged("left_hand"), "An untracked hand does not hold")
	tracker.invalidate_pose("grip"); palm_at.call(Vector3(0.6, 1, 0.08)); step.call(1)
	check(presence.engaged("left_hand"), "Without a grip pose the aim pose locates the controller")
	palm_at.call(Vector3(0.62, 0.96, 0.07))
	tracker.profile = "/interaction_profiles/khr/simple_controller"; step.call(1)
	check(not presence.engaged("left_hand"), "A palm on a simple profile does not hold")
	tracker.profile = "/interaction_profiles/bytedance/pico4_controller"
	tracker.invalidate_pose("aim"); step.call(1)
	check(not presence.engaged("left_hand"), "A lost controller pose releases at once")
	XRServer.remove_tracker(joints)
	XRServer.remove_tracker(tracker)
	print("controller presence checks: %d, failures: %d" % [checks, failures.size()])
	for failure in failures: push_error(failure)
	quit(1 if failures.size() > 0 else 0)
